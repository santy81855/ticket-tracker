import AppKit
import Darwin
import SwiftTerm
import SwiftUI

@MainActor
final class TerminalTab: Identifiable {
  let id = UUID()
  let view: LocalProcessTerminalView
  var customTitle: String?
  var programTitle: String?
  var program = ""
  var folder = ""

  init(view: LocalProcessTerminalView) { self.view = view }

  var title: String {
    if let customTitle { return customTitle }
    if let programTitle { return programTitle }
    let name = program.isEmpty ? "Shell" : program
    return folder.isEmpty ? name : "\(name) · \(folder)"
  }
}

/// Owns every embedded shell so sessions survive hiding the panel or closing the window.
@MainActor
final class TerminalSessions: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
  static let shared = TerminalSessions()
  static let directoryKey = "terminal.directory"
  static let background = NSColor(srgbRed: 0.075, green: 0.08, blue: 0.095, alpha: 1)
  static let chrome = NSColor(srgbRed: 0.105, green: 0.11, blue: 0.13, alpha: 1)

  @Published private(set) var tabs: [TerminalTab] = []
  @Published var selectedID: UUID?
  @Published private(set) var isVisible = false
  @Published var isMaximized = false
  private var monitor: Task<Void, Never>?
  /// Tabs from the last run, reopened the first time the panel is shown.
  private var savedTabs: SavedSession?

  override private init() {
    super.init()
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        TerminalSessions.shared.saveSession()
        TerminalSessions.shared.terminateAll()
      }
    }
    guard BrowserModel.keepsSession,
      let data = UserDefaults.standard.data(forKey: Self.sessionKey),
      let saved = try? JSONDecoder().decode(SavedSession.self, from: data), !saved.tabs.isEmpty
    else { return }
    savedTabs = saved
    if saved.visible { show() }
  }

  // MARK: Session restore

  private static let sessionKey = "terminal.session"

  private struct SavedSession: Codable {
    struct Tab: Codable {
      var directory: String?
      var title: String?
    }
    var tabs: [Tab]
    var selected: Int
    var visible: Bool
  }

  private func saveSession() {
    guard BrowserModel.keepsSession else { return }
    let saved = SavedSession(
      tabs: tabs.map { .init(directory: workingDirectory(of: $0), title: $0.customTitle) },
      selected: tabs.firstIndex { $0.id == selectedID } ?? 0, visible: isVisible)
    UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: Self.sessionKey)
  }

  private func restoreSession(_ saved: SavedSession) {
    for tab in saved.tabs { newTab(in: tab.directory, title: tab.title) }
    if tabs.indices.contains(saved.selected) { select(tabs[saved.selected]) }
  }

  var selected: TerminalTab? { tabs.first { $0.id == selectedID } ?? tabs.first }

  func toggle() { isVisible ? hide() : show() }

  func show() {
    isVisible = true
    if tabs.isEmpty, let saved = savedTabs {
      savedTabs = nil
      restoreSession(saved)
    } else if tabs.isEmpty {
      newTab()
    } else if let selected {
      focus(selected)
    }
  }

  func hide() {
    isVisible = false
    if let window = NSApp.keyWindow, window.firstResponder is TerminalView {
      window.makeFirstResponder(nil)
    }
  }

  func newTab(in directory: String? = nil, title: String? = nil) {
    let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 320))
    view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    view.nativeBackgroundColor = Self.background
    view.nativeForegroundColor = NSColor(srgbRed: 0.87, green: 0.88, blue: 0.9, alpha: 1)
    view.caretColor = NSColor(srgbRed: 0.42, green: 0.82, blue: 0.74, alpha: 1)
    view.processDelegate = self
    let tab = TerminalTab(view: view)
    tab.customTitle = title
    tabs.append(tab)
    selectedID = tab.id
    isVisible = true
    let shell = Self.loginShell()
    let name = (shell as NSString).lastPathComponent
    tab.program = name
    view.startProcess(
      executable: shell, environment: Self.environment(shell: shell), execName: "-\(name)",
      currentDirectory: directory.flatMap(Self.existingDirectory) ?? Self.startDirectory())
    startMonitor()
    focus(tab)
  }

  func select(_ tab: TerminalTab) {
    selectedID = tab.id
    focus(tab)
  }

  func selectAdjacent(_ offset: Int) {
    guard !tabs.isEmpty else { return }
    let index = tabs.firstIndex { $0.id == selected?.id } ?? 0
    select(tabs[(index + offset + tabs.count) % tabs.count])
  }

  func closeSelected() {
    if let selected { close(selected) }
  }

  func close(_ tab: TerminalTab, confirm: Bool = true) {
    if confirm, let job = foregroundJob(of: tab) {
      let alert = NSAlert()
      alert.messageText = "Close “\(tab.title)”?"
      alert.informativeText = "\(job) is still running in this tab. Closing the tab ends it."
      alert.addButton(withTitle: "Close Tab")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    remove(tab)
    hangUp(tab)
  }

  func rename(_ tab: TerminalTab, to title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    tab.customTitle = trimmed.isEmpty ? nil : trimmed
    objectWillChange.send()
  }

  func terminateAll() {
    tabs.forEach(hangUp)
  }

  private func remove(_ tab: TerminalTab) {
    guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
    tabs.remove(at: index)
    tab.view.removeFromSuperview()
    if tabs.isEmpty {
      selectedID = nil
      isMaximized = false
      hide()
    } else if selectedID == tab.id {
      select(tabs[max(0, index - 1)])
    }
  }

  private func hangUp(_ tab: TerminalTab) {
    let process: LocalProcess? = tab.view.process
    if let process, process.running {
      let foreground = tcgetpgrp(process.childfd)
      if foreground > 0 { kill(-foreground, SIGHUP) }
      kill(-process.shellPid, SIGHUP)
    }
    tab.view.terminate()
  }

  private func focus(_ tab: TerminalTab) {
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(60))
      guard tab.id == self.selectedID, let window = tab.view.window else { return }
      window.makeFirstResponder(tab.view)
    }
  }

  /// Names the program in the foreground when it is not the tab's own shell.
  private func foregroundJob(of tab: TerminalTab) -> String? {
    let process: LocalProcess? = tab.view.process
    guard let process, process.running else { return nil }
    let group = tcgetpgrp(process.childfd)
    guard group > 0, group != process.shellPid else { return nil }
    return Self.processName(group).map { "“\($0)”" } ?? "A program"
  }

  private func startMonitor() {
    guard monitor == nil else { return }
    monitor = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self, !self.tabs.isEmpty else { break }
        if self.isVisible { self.refreshTitles() }
        try? await Task.sleep(for: .seconds(1.5))
      }
      self?.monitor = nil
    }
  }

  private func refreshTitles() {
    var changed = false
    for tab in tabs {
      let process: LocalProcess? = tab.view.process
      guard let process, process.running else { continue }
      let group = tcgetpgrp(process.childfd)
      let program = Self.processName(group > 0 ? group : process.shellPid) ?? tab.program
      let folder = Self.workingDirectory(of: process.shellPid).map(Self.displayFolder) ?? tab.folder
      if program != tab.program || folder != tab.folder {
        tab.program = program
        tab.folder = folder
        changed = true
      }
    }
    if changed { objectWillChange.send() }
  }

  // MARK: LocalProcessTerminalViewDelegate

  func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

  func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
    guard let tab = tabs.first(where: { $0.view === source }) else { return }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    tab.programTitle = trimmed.isEmpty ? nil : String(trimmed.prefix(60))
    objectWillChange.send()
  }

  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

  func processTerminated(source: TerminalView, exitCode: Int32?) {
    if let tab = tabs.first(where: { $0.view === source }) { remove(tab) }
  }

  // MARK: Process environment

  static func startDirectory() -> String {
    let stored = (UserDefaults.standard.string(forKey: directoryKey) ?? "") as NSString
    return existingDirectory(stored.expandingTildeInPath)
      ?? FileManager.default.homeDirectoryForCurrentUser.path
  }

  private static func existingDirectory(_ path: String) -> String? {
    var isDirectory: ObjCBool = false
    guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return nil }
    return path
  }

  private static func loginShell() -> String {
    var candidates: [String] = []
    if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
      candidates.append(String(cString: shell))
    }
    if let shell = ProcessInfo.processInfo.environment["SHELL"] { candidates.append(shell) }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/bin/zsh"
  }

  private static func environment(shell: String) -> [String] {
    var values = ProcessInfo.processInfo.environment.filter { key, _ in
      !key.hasPrefix("TICKET_TRACKER_") && !key.hasPrefix("__CF") && !key.hasPrefix("XPC_")
    }
    values["TERM"] = "xterm-256color"
    values["COLORTERM"] = "truecolor"
    values["TERM_PROGRAM"] = "TicketTracker"
    values["SHELL"] = shell
    values["HOME"] = values["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    values["LANG"] = values["LANG"] ?? "en_US.UTF-8"
    values["PATH"] = values["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    return values.map { "\($0.key)=\($0.value)" }
  }

  private static func processName(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 256)
    guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    let name = String(cString: buffer)
    return name.isEmpty ? nil : name
  }

  func workingDirectory(of tab: TerminalTab) -> String? {
    let process: LocalProcess? = tab.view.process
    guard let process, process.running else { return nil }
    return Self.workingDirectory(of: process.shellPid)
  }

  private static func workingDirectory(of pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
      String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
    }
    return path.isEmpty ? nil : path
  }

  private static func displayFolder(_ path: String) -> String {
    path == FileManager.default.homeDirectoryForCurrentUser.path
      ? "~" : (path as NSString).lastPathComponent
  }
}

struct TerminalPanel: View {
  @ObservedObject var sessions: TerminalSessions
  let canMaximize: Bool
  var resize: (height: Binding<Double>, range: ClosedRange<Double>)?
  @State private var renaming: TerminalTab?
  @State private var newTitle = ""

  var body: some View {
    VStack(spacing: 0) {
      tabBar
      TerminalHost(view: sessions.selected?.view)
        .padding(.leading, 8).padding(.top, 4)
        .background(Color(nsColor: TerminalSessions.background))
    }
    .background(Color(nsColor: TerminalSessions.background))
    .environment(\.colorScheme, .dark)
    .alert(
      "Rename tab",
      isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    ) {
      TextField("Tab name", text: $newTitle)
      Button("Rename") {
        if let renaming { sessions.rename(renaming, to: newTitle) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Leave the name empty to show the running program again.")
    }
  }

  private var tabBar: some View {
    HStack(spacing: 6) {
      ForEach(Array(sessions.tabs.enumerated()), id: \.element.id) { index, tab in
        tabButton(tab, index: index)
      }
      chromeButton("plus", help: "New tab (⌘T)") { sessions.newTab() }
      Spacer(minLength: 4)
      if canMaximize {
        chromeButton(
          sessions.isMaximized
            ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
          help: sessions.isMaximized ? "Restore terminal (⇧⌘↩)" : "Maximize terminal (⇧⌘↩)"
        ) { sessions.isMaximized.toggle() }
      }
      chromeButton("chevron.down", help: "Hide terminal (⌘J)") { sessions.hide() }
    }
    .padding(.horizontal, 8).frame(height: 34)
    .background(Color(nsColor: TerminalSessions.chrome))
    .modifier(TerminalResizeDrag(height: resize?.height, range: resize?.range ?? 0...0))
    .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
  }

  private func tabButton(_ tab: TerminalTab, index: Int) -> some View {
    let isSelected = tab.id == sessions.selected?.id
    return HStack(spacing: 6) {
      Image(systemName: "terminal").font(.system(size: 10, weight: .semibold))
        .foregroundStyle(isSelected ? Palette.accent : .secondary)
      Text(tab.title).font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
        .lineLimit(1).truncationMode(.middle).frame(
          minWidth: 20, maxWidth: 190, alignment: .leading)
      Button {
        sessions.close(tab)
      } label: {
        Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).frame(
          width: 15, height: 15)
      }.buttonStyle(.plain).foregroundStyle(.secondary).help("Close tab")
        .accessibilityLabel("Close \(tab.title)")
    }
    .padding(.leading, 10).padding(.trailing, 5).frame(height: 25)
    .foregroundStyle(isSelected ? .primary : .secondary)
    .background(
      RoundedRectangle(cornerRadius: 7).fill(.white.opacity(isSelected ? 0.11 : 0.025))
    )
    .contentShape(RoundedRectangle(cornerRadius: 7))
    .onTapGesture { sessions.select(tab) }
    .help(index < 9 ? "\(tab.title) — ⌘\(index + 1)" : tab.title)
    .contextMenu {
      Button("Rename Tab…") {
        newTitle = tab.customTitle ?? ""
        renaming = tab
      }
      Button("Close Tab") { sessions.close(tab) }
    }
  }

  private func chromeButton(_ symbol: String, help: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
        .frame(width: 26, height: 24).contentShape(Rectangle())
    }.buttonStyle(.plain).foregroundStyle(.secondary).help(help).accessibilityLabel(help)
  }
}

struct TerminalResizeHandle: View {
  @Binding var height: Double
  let range: ClosedRange<Double>

  var body: some View {
    Rectangle().fill(Color(nsColor: TerminalSessions.chrome)).frame(height: 6)
      .overlay { Capsule().fill(.white.opacity(0.22)).frame(width: 34, height: 3) }
      .modifier(TerminalResizeDrag(height: $height, range: range))
      .accessibilityLabel("Resize terminal")
  }
}

struct TerminalResizeDrag: ViewModifier {
  let height: Binding<Double>?
  let range: ClosedRange<Double>
  @State private var startHeight: Double?

  func body(content: Content) -> some View {
    content.contentShape(Rectangle())
      .onHover { inside in
        guard height != nil else { return }
        inside ? NSCursor.resizeUpDown.push() : NSCursor.pop()
      }
      .simultaneousGesture(
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
          .onChanged { value in
            guard let height else { return }
            let start = startHeight ?? height.wrappedValue
            startHeight = start
            height.wrappedValue = min(
              max(start - value.translation.height, range.lowerBound), range.upperBound)
          }
          .onEnded { _ in startHeight = nil }
      )
  }
}

/// Hosts the selected tab's terminal view, keeping the shells alive when the tab changes.
struct TerminalHost: NSViewRepresentable {
  let view: LocalProcessTerminalView?

  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = TerminalSessions.background.cgColor
    return container
  }

  func updateNSView(_ container: NSView, context: Context) {
    guard container.subviews.first !== view else { return }
    for subview in container.subviews { subview.removeFromSuperview() }
    guard let view else { return }
    view.frame = container.bounds
    view.autoresizingMask = [.width, .height]
    container.addSubview(view)
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(60))
      view.window?.makeFirstResponder(view)
    }
  }
}

struct TerminalCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandMenu("Tabs") {
      Button("Show or Hide Terminal") {
        openWindow(id: "workspace")
        TerminalSessions.shared.toggle()
      }.keyboardShortcut("j")
      Button("New Tab") {
        if BrowserModel.shared.isVisible {
          BrowserModel.shared.newTab()
        } else {
          openWindow(id: "workspace")
          TerminalSessions.shared.newTab()
        }
      }.keyboardShortcut("t")
      Button("Close Tab") {
        let browser = BrowserModel.shared
        if browser.isVisible {
          browser.close(browser.selected)
        } else {
          TerminalSessions.shared.closeSelected()
        }
      }
      Divider()
      Button("Next Tab") {
        if BrowserModel.shared.isVisible {
          BrowserModel.shared.selectAdjacent(1)
        } else {
          TerminalSessions.shared.selectAdjacent(1)
        }
      }.keyboardShortcut("]", modifiers: [.command, .shift])
      Button("Previous Tab") {
        if BrowserModel.shared.isVisible {
          BrowserModel.shared.selectAdjacent(-1)
        } else {
          TerminalSessions.shared.selectAdjacent(-1)
        }
      }.keyboardShortcut("[", modifiers: [.command, .shift])
      ForEach(1..<10) { number in
        Button("Tab \(number)") {
          let browser = BrowserModel.shared
          if browser.isVisible {
            if number <= browser.tabs.count { browser.select(browser.tabs[number - 1]) }
          } else {
            let tabs = TerminalSessions.shared.tabs
            if number <= tabs.count { TerminalSessions.shared.select(tabs[number - 1]) }
          }
        }.keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
      }
      Divider()
      Button("Maximize or Restore Terminal") { TerminalSessions.shared.isMaximized.toggle() }
        .keyboardShortcut(.return, modifiers: [.command, .shift])
    }
  }
}
