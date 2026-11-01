import AppKit
import Carbon.HIToolbox
import SwiftUI
import TrackerCore

/// Global ⌃⌥Space ticket switcher shown in a floating panel above every app.
@MainActor
final class QuickSwitcher: NSObject, NSWindowDelegate {
  static let shared = QuickSwitcher()
  let shortcutLabel = "⌃⌥Space"
  private(set) var isShortcutRegistered = false
  private weak var model: WorkspaceModel?
  private var openWorkspace: (() -> Void)?
  private var panel: QuickSwitcherPanel?
  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private let session = QuickSwitcherSession()

  func configure(model: WorkspaceModel, openWorkspace: @escaping () -> Void) {
    self.model = model
    self.openWorkspace = openWorkspace
  }

  func registerShortcut() {
    guard hotKey == nil else { return }
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let installed = InstallEventHandler(
      GetEventDispatcherTarget(),
      { _, _, _ in
        Task { @MainActor in QuickSwitcher.shared.toggle() }
        return noErr
      }, 1, &spec, nil, &handler)
    let identifier = EventHotKeyID(signature: OSType(0x5454_5153), id: 1)
    let registered = RegisterEventHotKey(
      UInt32(kVK_Space), UInt32(optionKey | controlKey), identifier, GetEventDispatcherTarget(), 0,
      &hotKey)
    isShortcutRegistered = installed == noErr && registered == noErr
    if !isShortcutRegistered {
      NSLog("Quick switcher shortcut unavailable (handler %d, hotkey %d)", installed, registered)
    }
  }

  func toggle() {
    if panel?.isVisible == true { close() } else { show() }
  }

  func show() {
    guard let model else { return }
    let panel = panel ?? makePanel(model: model)
    self.panel = panel
    session.reset()
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    if let frame = screen?.visibleFrame {
      let size = panel.frame.size
      panel.setFrameOrigin(
        NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.22 - size.height))
    }
    panel.makeKeyAndOrderFront(nil)
  }

  func close() {
    panel?.orderOut(nil)
  }

  /// Esc steps back from a ticket to the results before closing the panel.
  func escape() {
    if session.detailID != nil {
      session.detailID = nil
      session.armedStepID = nil
      session.focusToken = UUID()
    } else {
      close()
    }
  }

  func open(_ snapshot: ItemSnapshot, thenComplete step: WorkflowStep? = nil) {
    close()
    guard let model else { return }
    model.reveal(snapshot.id)
    openWorkspace?()
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first { $0.title == "Ticket Tracker" }?.makeKeyAndOrderFront(nil)
    if let step { model.requestCompletion(snapshot, step: step) }
  }

  nonisolated func windowDidResignKey(_ notification: Notification) {
    Task { @MainActor in self.close() }
  }

  private func makePanel(model: WorkspaceModel) -> QuickSwitcherPanel {
    let panel = QuickSwitcherPanel(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovableByWindowBackground = true
    panel.delegate = self
    panel.contentView = NSHostingView(
      rootView: QuickSwitcherView(model: model, session: session, switcher: self))
    return panel
  }
}

private final class QuickSwitcherPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override func cancelOperation(_ sender: Any?) {
    MainActor.assumeIsolated { QuickSwitcher.shared.escape() }
  }
}

@MainActor
final class QuickSwitcherSession: ObservableObject {
  @Published var query = ""
  @Published var highlighted = 0
  @Published var armedStepID: String?
  @Published var message: String?
  @Published var focusToken = UUID()
  @Published var detailID: String?
  @Published var error: String?
  func reset() {
    detailID = nil
    error = nil
    query = ""
    highlighted = 0
    armedStepID = nil
    message = nil
    focusToken = UUID()
  }
}

private struct QuickSwitcherView: View {
  @ObservedObject var model: WorkspaceModel
  @ObservedObject var session: QuickSwitcherSession
  let switcher: QuickSwitcher
  @FocusState private var focused: Bool
  @AppStorage("workspace.theme") private var theme = WorkspaceTheme.classic

  private enum Row: Identifiable {
    case item(ItemSnapshot)
    case capture(String)
    var id: String {
      switch self {
      case .item(let snapshot): snapshot.id
      case .capture: "capture"
      }
    }
  }

  private var rows: [Row] {
    let query = session.query.trimmingCharacters(in: .whitespaces)
    let matches = model.snapshots.filter { snapshot in
      query.isEmpty
        ? !snapshot.item.isDone
        : "\(snapshot.item.jiraKey) \(snapshot.item.title)".localizedCaseInsensitiveContains(query)
    }.sorted { lhs, rhs in
      if lhs.item.isDone != rhs.item.isDone { return !lhs.item.isDone }
      if lhs.hasActionableWork != rhs.hasActionableWork { return lhs.hasActionableWork }
      return lhs.item.updatedAt > rhs.item.updatedAt
    }.prefix(7).map(Row.item)
    return query.isEmpty ? matches : matches + [.capture(query)]
  }

  private var detail: ItemSnapshot? {
    session.detailID.flatMap { id in model.snapshots.first { $0.id == id } }
  }

  var body: some View {
    VStack(spacing: 0) {
      if let detail {
        QuickTicketDetail(model: model, session: session, switcher: switcher, snapshot: detail)
          .id(detail.id)
      } else {
        results(rows)
      }
      if let error = session.error {
        Divider().opacity(0.5)
        Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12))
          .foregroundStyle(.red).padding(10).frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10)
      } else if let message = session.message {
        Divider().opacity(0.5)
        Label(message, systemImage: "checkmark.circle.fill")
          .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.green).padding(10)
      }
      Divider().opacity(0.5)
      HStack(spacing: 14) {
        if detail == nil {
          QuickHint(key: "↩", title: "Details")
          QuickHint(key: "⌘↩", title: "Complete step")
          QuickHint(key: "esc", title: "Close")
        } else {
          QuickHint(key: "↩", title: "Complete")
          QuickHint(key: "⌘K", title: "Copy message")
          QuickHint(key: "⌘O", title: "Open in app")
          QuickHint(key: "esc", title: "Back")
        }
        Spacer()
      }.padding(.horizontal, 20).padding(.vertical, 9)
    }
    .frame(width: 640, height: 540)
    .background(
      LinearGradient(colors: theme.colors, startPoint: .top, endPoint: .bottom).opacity(0.97),
      in: RoundedRectangle(cornerRadius: 18)
    )
    .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18))
    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.18)))
    .clipShape(RoundedRectangle(cornerRadius: 18))
    .tint(Palette.accent)
    .overlay { CelebrationOverlay(model: model) }
    .environment(\.workspaceTheme, theme)
    .preferredColorScheme(theme.colorScheme)
    .onAppear { focused = true }
    .onChange(of: session.focusToken) { _, _ in focused = true }
    .onChange(of: session.query) { _, _ in
      session.highlighted = 0
      session.armedStepID = nil
    }
    .onChange(of: model.errorMessage) { _, message in
      // Surface failures here instead of as an alert in the hidden main window.
      guard let message else { return }
      session.error = message
      model.errorMessage = nil
    }
  }

  private func results(_ rows: [Row]) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(.secondary)
        TextField("Find a ticket, or type a new task…", text: $session.query)
          .textFieldStyle(.plain).font(.system(size: 20)).focused($focused)
          .onSubmit { activate(rows, primary: true) }
          .onKeyPress(.downArrow) {
            move(1, rows)
            return .handled
          }
          .onKeyPress(.upArrow) {
            move(-1, rows)
            return .handled
          }
          .onKeyPress(.escape) {
            switcher.escape()
            return .handled
          }
          .onKeyPress(keys: [.return], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            activate(rows, primary: false)
            return .handled
          }
        Text(switcher.shortcutLabel).font(.system(size: 11, design: .rounded))
          .foregroundStyle(.secondary)
      }.padding(.horizontal, 20).padding(.vertical, 16)
      Divider().opacity(0.5)
      ScrollView {
        VStack(spacing: 4) {
          if rows.isEmpty {
            Text("No active tickets or tasks.").font(.system(size: 13))
              .foregroundStyle(.secondary).padding(24)
          }
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            rowView(row, highlighted: index == session.highlighted)
              .onTapGesture {
                session.highlighted = index
                activate(rows, primary: true)
              }
              .onHover { if $0 { session.highlighted = index } }
          }
        }.padding(8)
      }
    }
  }

  @ViewBuilder
  private func rowView(_ row: Row, highlighted: Bool) -> some View {
    switch row {
    case .capture(let text):
      HStack(spacing: 12) {
        Image(systemName: "plus.circle.fill").font(.system(size: 18))
          .foregroundStyle(Palette.accent)
        VStack(alignment: .leading, spacing: 2) {
          Text("New task").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
          Text(text).font(.system(size: 14, weight: .medium)).lineLimit(1)
        }
        Spacer()
      }.padding(12).background(quickRowBackground(highlighted, color: Palette.accent))
        .contentShape(Rectangle())
    case .item(let snapshot):
      HStack(alignment: .top, spacing: 12) {
        RoundedRectangle(cornerRadius: 2).fill(snapshot.stageColor).frame(width: 5)
        VStack(alignment: .leading, spacing: 4) {
          QuickTitle(snapshot: snapshot, keySize: 17)
          Text(snapshot.item.isDone ? "Done" : snapshot.phase)
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary.opacity(0.85))
          if highlighted, session.armedStepID != nil, let step = snapshot.nextStep,
            session.armedStepID == step.id
          {
            HStack(spacing: 8) {
              Button {
                Task { await complete(snapshot, step) }
              } label: {
                Label("Confirm: \(step.title)", systemImage: "checkmark")
              }.buttonStyle(AccentButtonStyle())
              Button("Cancel") { session.armedStepID = nil }.buttonStyle(QuietButtonStyle())
            }.padding(.top, 6)
          }
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary)
          .padding(.top, 4).opacity(highlighted ? 1 : 0)
      }.padding(12).background(quickRowBackground(highlighted, color: snapshot.stageColor))
        .contentShape(Rectangle())
    }
  }

  private func move(_ delta: Int, _ rows: [Row]) {
    guard !rows.isEmpty else { return }
    session.armedStepID = nil
    session.highlighted = (session.highlighted + delta + rows.count) % rows.count
  }

  private func activate(_ rows: [Row], primary: Bool) {
    guard rows.indices.contains(session.highlighted) else { return }
    session.error = nil
    switch rows[session.highlighted] {
    case .capture(let text):
      Task {
        if await model.create(NewItem(kind: .task, title: text)) {
          session.query = ""
          session.message = "Task captured: \(text)"
        }
      }
    case .item(let snapshot):
      if primary {
        session.message = nil
        session.armedStepID = nil
        session.detailID = snapshot.id
      } else if let step = snapshot.nextStep, step.canRecord, !step.isWait {
        if QuickTicketDetail.needsMergeDate(snapshot, step) {
          // The merge date is entered on the ticket's detail page inside the panel.
          session.detailID = snapshot.id
          session.armedStepID = step.id
        } else if session.armedStepID == step.id {
          Task { await complete(snapshot, step) }
        } else {
          session.armedStepID = step.id
        }
      }
    }
  }

  private func complete(_ snapshot: ItemSnapshot, _ step: WorkflowStep) async {
    session.armedStepID = nil
    if await model.complete(CompletionConfirmation(snapshot: snapshot, step: step)) {
      session.message = "\(quickName(snapshot)): \(step.title) ✓"
    }
  }
}

private struct QuickTicketDetail: View {
  @ObservedObject var model: WorkspaceModel
  @ObservedObject var session: QuickSwitcherSession
  let switcher: QuickSwitcher
  let snapshot: ItemSnapshot
  @State private var mergedAt = Date()
  @State private var checkedMergeDate = false

  static func needsMergeDate(_ snapshot: ItemSnapshot, _ step: WorkflowStep) -> Bool {
    step.kind == .mergeMR && (snapshot.item.workflow != nil || step.isOptional == true)
  }

  private var item: WorkItem { snapshot.item }
  private var actionable: WorkflowStep? {
    snapshot.nextStep.flatMap { $0.canRecord && !$0.isWait ? $0 : nil }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Button {
          switcher.escape()
        } label: {
          Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
        }.buttonStyle(.plain).foregroundStyle(.secondary).help("Back to results")
        QuickTitle(snapshot: snapshot, keySize: 20)
        Spacer()
        Button {
          switcher.open(snapshot)
        } label: {
          Image(systemName: "macwindow")
        }.buttonStyle(.plain).foregroundStyle(.secondary).help("Open in app")
          .keyboardShortcut("o")
      }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
      Divider().opacity(0.5)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(snapshot.stageColor).frame(width: 4, height: 26)
            Text(item.isDone ? "Done" : snapshot.phase)
              .font(.system(size: 20, weight: .bold, design: .rounded))
              .foregroundStyle(snapshot.stageColor)
          }
          if !item.isDone, let step = snapshot.nextStep { nextStep(step) }
          links
          followUp
          checklist
        }.padding(20)
      }
    }
  }

  @ViewBuilder
  private func nextStep(_ step: WorkflowStep) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(step.isWait ? "WAITING" : "NEXT STEP").font(.system(size: 10, weight: .semibold))
        .tracking(1.2).foregroundStyle(.secondary)
      Text(step.title).font(.system(size: 15, weight: .semibold))
      ForEach(snapshot.nudges) { waiting in
        Label("\(waiting.title): \(waiting.nudge ?? "")", systemImage: "bell.badge")
          .font(.system(size: 12)).foregroundStyle(Palette.amber)
          .fixedSize(horizontal: false, vertical: true)
      }
      RequiredFieldsEditor(model: model, snapshot: snapshot, step: step) {
        session.error = nil
        session.message = "Saved"
      }
      let fieldBlockers = RequiredFieldsEditor.fieldBlockers(for: step, in: item)
      let otherBlockers = step.blockers.filter { !fieldBlockers.contains($0) }
      if !otherBlockers.isEmpty {
        Label(otherBlockers.joined(separator: " "), systemImage: "lock")
          .font(.system(size: 12)).foregroundStyle(Palette.amber)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !item.waitingOn.isEmpty {
        Label("Waiting on \(item.waitingOn)", systemImage: "hourglass").font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        if let draftKind = DraftRequest.kind(for: step) { copyDraftButton(step, kind: draftKind) }
        if step.canRecord && !step.isWait { completeControls(step) }
      }
    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
      .background(snapshot.stageColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
      .overlay(
        RoundedRectangle(cornerRadius: 12).strokeBorder(snapshot.stageColor.opacity(0.25)))
  }

  @ViewBuilder
  private func completeControls(_ step: WorkflowStep) -> some View {
    if session.armedStepID != step.id {
      Button {
        session.error = nil
        session.armedStepID = step.id
      } label: {
        Label(
          Self.needsMergeDate(snapshot, step) ? "Record merge…" : "Complete",
          systemImage: "checkmark.circle")
      }.buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
    } else if Self.needsMergeDate(snapshot, step) {
      VStack(alignment: .leading, spacing: 8) {
        DatePicker(
          "Merged at", selection: $mergedAt, in: ...Date(),
          displayedComponents: [.date, .hourAndMinute]
        ).font(.system(size: 12)).fixedSize()
        Toggle("This is the actual GitLab merge time", isOn: $checkedMergeDate)
          .font(.system(size: 12))
        HStack(spacing: 8) {
          Button {
            Task { await recordMerge(step) }
          } label: {
            Label("Record merged", systemImage: "checkmark")
          }.buttonStyle(AccentButtonStyle()).disabled(!checkedMergeDate || model.isBusy)
            .keyboardShortcut(.defaultAction)
          Button("Cancel") { session.armedStepID = nil }.buttonStyle(QuietButtonStyle())
        }
      }
    } else {
      Button {
        Task { await complete(step) }
      } label: {
        Label("Confirm done", systemImage: "checkmark")
      }.buttonStyle(AccentButtonStyle()).disabled(model.isBusy).keyboardShortcut(.defaultAction)
      Button("Cancel") { session.armedStepID = nil }.buttonStyle(QuietButtonStyle())
    }
  }

  private func copyDraftButton(_ step: WorkflowStep, kind: DraftKind) -> some View {
    Button {
      session.error = nil
      do {
        let draft =
          step.messageTemplate?.isEmpty == false
          ? try Messages.draft(actionID: step.id, item: item, settings: model.settings)
          : try Messages.draft(kind, item: item, settings: model.settings)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(draft.text, forType: .string)
        session.message =
          draft.missing.isEmpty
          ? "Message copied. Review it before posting."
          : "Copied. Still missing: \(draft.missing.joined(separator: ", "))"
      } catch { session.error = error.localizedDescription }
    } label: {
      Label("Copy message", systemImage: "doc.on.doc")
    }.buttonStyle(QuietButtonStyle()).keyboardShortcut("k")
  }

  @ViewBuilder
  private var links: some View {
    let mrs = item.mergeRequests
    if !item.jiraURL.isEmpty || !item.threadURL.isEmpty || !mrs.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        QuickSection(title: "Links")
        FlowRow {
          if !item.jiraURL.isEmpty { linkButton("Jira", symbol: "ticket", url: item.jiraURL) }
          if !item.threadURL.isEmpty {
            linkButton("Teams thread", symbol: "bubble.left", url: item.threadURL)
          }
          ForEach(mrs) { mr in
            linkButton(
              mr.shortName,
              symbol: item.has(.mergeMR, mrID: mr.id) ? "checkmark" : "arrow.triangle.merge",
              url: mr.url)
          }
        }
      }
    }
  }

  private func linkButton(_ title: String, symbol: String, url: String) -> some View {
    Button {
      session.error = nil
      model.openLink(url)
    } label: {
      Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
    }.buttonStyle(QuietButtonStyle()).help(url)
  }

  @ViewBuilder
  private var followUp: some View {
    if !item.isDone {
      HStack(spacing: 10) {
        QuickSection(title: "Follow-up")
        if let due = item.followUpAt {
          Text(due.formatted(.relative(presentation: .named))).font(.system(size: 12))
            .foregroundStyle(due < Date() ? Palette.amber : .secondary)
        }
        Spacer()
        Menu {
          Button("In 1 hour") { setFollowUp(Date().addingTimeInterval(3600)) }
          Button("This afternoon (3 PM)") { setFollowUp(today(at: 15)) }
          Button("Tomorrow morning (9 AM)") { setFollowUp(today(at: 9, addingDays: 1)) }
          Button("Next Monday (9 AM)") { setFollowUp(nextMonday()) }
          if item.followUpAt != nil {
            Divider()
            Button("Clear follow-up") {
              var patch = DetailsPatch()
              patch.clearFollowUp = true
              Task { await save(patch, message: "Follow-up cleared") }
            }
          }
        } label: {
          Label(item.followUpAt == nil ? "Remind me" : "Change", systemImage: "bell")
            .font(.system(size: 12))
        }.menuStyle(.borderlessButton).fixedSize()
      }
    }
  }

  private var checklist: some View {
    VStack(alignment: .leading, spacing: 6) {
      QuickSection(title: "Checklist")
      ForEach(snapshot.steps.filter { $0.state != .notApplicable }, id: \.id) { step in
        HStack(spacing: 9) {
          Image(systemName: symbol(for: step)).font(.system(size: 12))
            .foregroundStyle(color(for: step)).frame(width: 16)
          Text(step.title).font(.system(size: 12, weight: isNext(step) ? .semibold : .regular))
            .foregroundStyle(step.state == .pending ? .primary : .secondary)
          if step.isOptional == true {
            Text("optional").font(.system(size: 10)).foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func isNext(_ step: WorkflowStep) -> Bool { snapshot.nextStep?.id == step.id }
  private func symbol(for step: WorkflowStep) -> String {
    switch step.state {
    case .completed: "checkmark.circle.fill"
    case .waived: "minus.circle"
    default: isNext(step) ? "arrow.right.circle.fill" : (step.isWait ? "hourglass" : "circle")
    }
  }
  private func color(for step: WorkflowStep) -> Color {
    switch step.state {
    case .completed: Palette.green
    case .waived: .secondary
    default: isNext(step) ? snapshot.stageColor : .secondary
    }
  }

  private func today(at hour: Int, addingDays days: Int = 0) -> Date {
    let calendar = Calendar.current
    let day = calendar.date(byAdding: .day, value: days, to: Date()) ?? Date()
    return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
  }
  private func nextMonday() -> Date {
    let calendar = Calendar.current
    let monday = calendar.nextDate(
      after: Date(), matching: DateComponents(hour: 9, weekday: 2), matchingPolicy: .nextTime)
    return monday ?? today(at: 9, addingDays: 7)
  }
  private func setFollowUp(_ date: Date) {
    var patch = DetailsPatch()
    patch.followUpAt = date
    Task {
      await save(
        patch, message: "Follow-up \(date.formatted(.relative(presentation: .named)))")
    }
  }
  private func save(_ patch: DetailsPatch, message: String) async {
    session.error = nil
    if await model.mutate(snapshot, .edit(patch)) { session.message = message }
  }

  private func complete(_ step: WorkflowStep) async {
    session.error = nil
    session.armedStepID = nil
    if await model.complete(CompletionConfirmation(snapshot: snapshot, step: step)) {
      finished(step)
    }
  }

  /// Back to the results after a step is done, keeping the confirmation visible.
  private func finished(_ step: WorkflowStep) {
    session.message = "\(quickName(snapshot)): \(step.title) ✓"
    session.detailID = nil
    session.focusToken = UUID()
  }

  private func recordMerge(_ step: WorkflowStep) async {
    session.error = nil
    let recorded = await model.mutate(
      snapshot,
      .recordFact(
        FactInput(
          actionID: step.id,
          note: "User confirmed the MR is merged and checked the actual GitLab merge timestamp.",
          occurredAt: mergedAt)))
    if recorded {
      session.armedStepID = nil
      finished(step)
    }
  }
}

private struct QuickTitle: View {
  let snapshot: ItemSnapshot
  var keySize: CGFloat
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(snapshot.item.kind == .ticket ? snapshot.item.jiraKey : "TASK")
        .font(
          .system(
            size: snapshot.item.kind == .ticket ? keySize : 11, weight: .bold, design: .monospaced))
      Text(snapshot.item.title).font(.system(size: 13)).foregroundStyle(.primary.opacity(0.75))
        .lineLimit(1)
    }
  }
}

private struct QuickSection: View {
  var title: String
  var body: some View {
    Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.2)
      .foregroundStyle(.secondary)
  }
}

private struct QuickHint: View {
  var key: String
  var title: String
  var body: some View {
    HStack(spacing: 5) {
      Text(key).font(.system(size: 10, weight: .semibold, design: .rounded))
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Color.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
      Text(title).font(.system(size: 11))
    }.foregroundStyle(.primary.opacity(0.75))
  }
}

private struct FlowRow<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) { content }
      VStack(alignment: .leading, spacing: 8) { content }
    }
  }
}

private func quickRowBackground(_ highlighted: Bool, color: Color) -> some View {
  RoundedRectangle(cornerRadius: 11).fill(highlighted ? Color.primary.opacity(0.10) : .clear)
    .overlay(
      RoundedRectangle(cornerRadius: 11).strokeBorder(highlighted ? color.opacity(0.6) : .clear))
}

private func quickName(_ snapshot: ItemSnapshot) -> String {
  snapshot.item.jiraKey.isEmpty ? "Task" : snapshot.item.jiraKey
}
