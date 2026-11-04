import SwiftUI

@main
struct TicketTrackerApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = WorkspaceModel()
  @AppStorage("workspace.theme") private var theme = WorkspaceTheme.classic

  init() {
    #if DEBUG
      if Bundle.main.bundleIdentifier == "com.tickettracker.local.preview" {
        let previewTheme = ProcessInfo.processInfo.environment["TICKET_TRACKER_PREVIEW_THEME"]
        let selectedTheme = previewTheme.flatMap(WorkspaceTheme.init(rawValue:)) ?? .fireplace
        UserDefaults.standard.set(selectedTheme.rawValue, forKey: "workspace.theme")
      }
    #endif
  }

  var body: some Scene {
    Window("Ticket Tracker", id: "workspace") {
      WorkspaceView(model: model)
        .environment(\.workspaceTheme, theme)
        .id(theme.accent == nil ? "default" : theme.rawValue)
        .preferredColorScheme(theme.colorScheme)
        .frame(minWidth: 420, minHeight: 320)
        .task {
          await model.start()
          #if DEBUG
            if model.isUISmoke { UIValidation.start(model: model) }
          #endif
        }
    }
    .defaultSize(width: 1360, height: 900)
    .windowResizability(.contentMinSize)
    .windowStyle(.titleBar)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Item") {
          if model.page.isLibrary { model.newReference() } else { model.showNewItem = true }
        }
        .keyboardShortcut("n")
        Button("Open File…") {
          BrowserModel.showWorkspace?()
          BrowserModel.shared.chooseFile()
        }
        .keyboardShortcut("o")
      }
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { model.showSettings = true }
          .keyboardShortcut(",")
      }
      TerminalCommands()
      CommandGroup(after: .toolbar) {
        Button("Show or Hide Jira Browser") { BrowserModel.shared.isVisible.toggle() }
          .keyboardShortcut("b", modifiers: [.command, .shift])
      }
    }
    MenuBarExtra("Ticket Tracker", systemImage: "ticket") {
      MenuBarView(model: model)
    }
  }
}

/// Files opened with the app (Finder "Open With", `ticket-tracker open-file`) show in the viewer.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func application(_ application: NSApplication, open urls: [URL]) {
    let files = urls.filter(\.isFileURL)
    guard !files.isEmpty else { return }
    for file in files { BrowserModel.shared.openFile(file) }
    BrowserModel.showWorkspace?()
    NSApp.activate()
  }
}
