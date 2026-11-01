import AppKit
import ServiceManagement
import SwiftUI
import TrackerCore
import TrackerStore
import UniformTypeIdentifiers

enum WorkspacePage: String, CaseIterable, Identifiable {
  case all = "Tickets & tasks"
  case next = "Ready for action"
  case waiting = "Waiting on others"
  case followUps = "Follow-ups"
  case releases = "Releases"
  case archive = "Completed"
  case workspaceMRs = "Workspace MRs"
  case summary = "Stand-up summary"
  case endOfDay = "End of day"
  case insights = "Insights"
  case brag = "Brag doc"
  case notes = "Notes"
  case links = "Links"
  static let sidebarGroups: [(title: String, pages: [WorkspacePage])] = [
    ("Work", [.all, .releases, .archive, .workspaceMRs]),
    ("Reviews", [.summary, .endOfDay, .insights, .brag]),
    ("Reference", [.notes, .links]),
  ]
  var isLibrary: Bool { self == .notes || self == .links }
  var isReport: Bool {
    [.summary, .endOfDay, .releases, .insights, .brag].contains(self)
  }
  /// Filters of the main list that are reached through the metric cards.
  var isListFilter: Bool { self == .next || self == .waiting || self == .followUps }
  var sidebarPage: WorkspacePage { isListFilter ? .all : self }
  var id: String { rawValue }
  var navigationTitle: String {
    switch self {
    case .summary: "Stand-up"
    default: rawValue
    }
  }
  var symbol: String {
    switch self {
    case .next: "bolt"
    case .waiting: "hourglass"
    case .followUps: "calendar.badge.clock"
    case .all: "tray.full"
    case .releases: "shippingbox"
    case .summary: "list.bullet.rectangle"
    case .endOfDay: "moon.stars"
    case .insights: "chart.bar.xaxis"
    case .brag: "star.bubble"
    case .archive: "checkmark.circle"
    case .workspaceMRs: "arrow.triangle.merge"
    case .notes: "note.text"
    case .links: "link"
    }
  }
}

@MainActor
final class WorkspaceModel: ObservableObject {
  @Published var snapshots: [ItemSnapshot] = []
  @Published var settings = TrackerSettings()
  @Published var settingsPane: String?
  @Published var workflows: WorkflowCatalogSnapshot?
  @Published var library: WorkspaceLibrarySnapshot?
  @Published var referenceEditor: ReferenceEditRequest?
  @Published var showWorkflows = false
  /// Tab the workflow editor opens on (UI validation uses it to capture each tab).
  var workflowEditorTab = "Step"
  @Published var workspaceMRFilter = "Unmerged"
  @Published var mergeConfirmation: MergeConfirmation?
  @Published var page: WorkspacePage = .all
  @Published var search = ""
  @Published var kindFilter = "Everything"
  @Published var selectedID: String?
  @Published var showsItemDetail = false
  @Published var showNewItem = false
  @Published var showSettings = false
  @Published var completion: CompletionConfirmation?
  @Published var draft: DraftRequest?
  @Published var errorMessage: String?
  @Published var storageFailure: String?
  @Published var toast: String?
  @Published var isBusy = false
  @Published var celebration: Celebration?
  @Published var notificationStatus = "Not enabled"
  @Published var loginStatus = "Off"
  @Published private var clock = Date()
  private(set) var store: TrackerStore?
  private var polling: Task<Void, Never>?
  private var hasStarted = false
  private var lastDataVersion: Int?
  let reminders = ReminderManager()
  var isThemePreview: Bool {
    #if DEBUG
      Bundle.main.bundleIdentifier == "com.tickettracker.local.preview"
        || ProcessInfo.processInfo.environment["TICKET_TRACKER_UI_PREVIEW"] == "1"
    #else
      false
    #endif
  }
  var isUISmoke: Bool {
    #if DEBUG
      isThemePreview || Bundle.main.bundleIdentifier == "com.tickettracker.local.validation"
        || ProcessInfo.processInfo.environment["TICKET_TRACKER_UI_SMOKE"] == "1"
    #else
      false
    #endif
  }

  var active: [ItemSnapshot] { snapshots.filter { !$0.item.isDone } }
  var selected: ItemSnapshot? { snapshots.first { $0.id == selectedID } }
  var dueCount: Int {
    active.filter { ($0.item.followUpAt ?? .distantFuture) <= Date() || !$0.nudges.isEmpty }.count
  }
  var waitingCount: Int { active.filter(\.isWaiting).count }
  var actionCount: Int { active.filter(\.hasActionableWork).count }
  var standupSummary: StandupSummary { StandupSummary(snapshots: snapshots) }
  var releaseSchedule: ReleaseSchedule { ReleaseSchedule(snapshots: snapshots) }
  var endOfDayReview: EndOfDayReview { EndOfDayReview(snapshots: snapshots) }
  var hasOverdueFollowUp: Bool { dueCount > 0 }

  var visible: [ItemSnapshot] {
    snapshots.filter { snapshot in
      let item = snapshot.item
      let matchesPage: Bool
      switch page {
      case .next:
        matchesPage = snapshot.hasActionableWork
      case .waiting: matchesPage = !item.isDone && snapshot.isWaiting
      case .followUps:
        matchesPage = !item.isDone && (item.followUpAt != nil || !snapshot.nudges.isEmpty)
      case .all: matchesPage = !item.isDone
      case .summary: matchesPage = item.kind == .ticket && !item.isDone
      case .releases, .endOfDay, .insights, .brag: matchesPage = false
      case .archive: matchesPage = item.isDone
      case .workspaceMRs:
        matchesPage =
          !item.workspaceMRs.isEmpty
          && (workspaceMRFilter == "All"
            || (workspaceMRFilter == "Unmerged"
              ? item.workspaceMRs.contains { !item.has(.mergeMR, mrID: $0.id) }
              : item.workspaceMRs.allSatisfy { item.has(.mergeMR, mrID: $0.id) }))
      case .notes, .links: matchesPage = false
      }
      let matchesKind =
        kindFilter == "Everything"
        || (kindFilter == "Tickets" ? item.kind == .ticket : item.kind == .task)
      return matchesPage && matchesKind
        && (search.isEmpty
          || "\(item.jiraKey) \(item.title) \(item.notes)".localizedCaseInsensitiveContains(search))
    }.sorted { lhs, rhs in
      let left = lhs.item.followUpAt ?? .distantFuture
      let right = rhs.item.followUpAt ?? .distantFuture
      if left != right { return left < right }
      return lhs.item.updatedAt > rhs.item.updatedAt
    }
  }

  func start() async {
    guard !hasStarted else { return }
    hasStarted = true
    do {
      if isUISmoke && ProcessInfo.processInfo.environment["TICKET_TRACKER_DATA_DIR"] == nil {
        throw TrackerError.storage("UI validation requires an isolated data directory.")
      }
      let directory =
        ProcessInfo.processInfo.environment["TICKET_TRACKER_DATA_DIR"].map {
          URL(fileURLWithPath: $0, isDirectory: true)
        }
        ?? TrackerStore.defaultDirectory()
      let opened = try TrackerStore(directory: directory)
      store = opened
      try await load()
      storageFailure = nil
      do { try await opened.dailyBackup() } catch {
        errorMessage = "Your workspace opened, but its backup failed: \(error.localizedDescription)"
      }
      if isUISmoke { return }
      reminders.onSelect = { [weak self] id in
        guard let self else { return }
        self.reveal(id)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first {
          $0.identifier?.rawValue.contains("workspace") == true || $0.title == "Ticket Tracker"
        }?.makeKeyAndOrderFront(nil)
      }
      await refreshOSStatus()
      do { try await reminders.reconcile(snapshots) } catch {
        errorMessage =
          "Your workspace is open, but reminders could not be scheduled: \(error.localizedDescription)"
      }
      polling = Task { [weak self] in
        while !Task.isCancelled {
          do {
            try await Task.sleep(for: .seconds(NSApp.isActive ? 1 : 15))
          } catch is CancellationError { return } catch {
            self?.errorMessage = error.localizedDescription
            return
          }
          await self?.poll()
        }
      }
    } catch {
      storageFailure = error.localizedDescription
    }
  }

  func retryStorage() async {
    hasStarted = false
    polling?.cancel()
    await start()
  }

  func load() async throws {
    guard let store else { throw TrackerError.storage("Storage is not available.") }
    let workspace = try await store.workspaceSnapshot()
    snapshots = workspace.items
    settings = workspace.settings
    workflows = workspace.workflows
    library = workspace.library
    lastDataVersion = workspace.dataVersion
    // A finished item leaves the current list (unless it's the archive), so move on instead of
    // leaving its details on screen with nothing selected in the sidebar.
    let current = snapshots.first { $0.id == selectedID }
    if current == nil || (current?.item.isDone == true && !visible.contains { $0.id == selectedID })
    {
      if current != nil { showsItemDetail = false }
      selectedID = visible.first?.id
    }
  }

  private func poll() async {
    guard let store else { return }
    do {
      if abs(clock.timeIntervalSinceNow) >= 60 { clock = Date() }
      let version = try await store.dataVersion()
      if version != lastDataVersion {
        try await load()
        if !isUISmoke { try await reminders.reconcile(snapshots) }
      }
    } catch {
      if errorMessage == nil { errorMessage = error.localizedDescription }
    }
  }

  func create(_ input: NewItem) async -> Bool {
    var createdID: String?
    let success = await operation {
      guard let store else { throw TrackerError.storage("Storage is unavailable.") }
      let result = try await store.create(input, source: .desktop, requestID: UUID().uuidString)
      createdID = result.id
      notify(input.kind == .ticket ? "Ticket added to your workspace" : "Task captured")
    }
    if let createdID, success { reveal(createdID) }
    return success
  }

  func reveal(_ id: String) {
    search = ""
    kindFilter = "Everything"
    page = snapshots.first(where: { $0.id == id })?.item.isDone == true ? .archive : .all
    selectedID = id
    showsItemDetail = true
  }

  func requestDraft(_ snapshot: ItemSnapshot, step: WorkflowStep) {
    guard let kind = DraftRequest.kind(for: step) else {
      errorMessage = "This step does not have a ticket message draft."
      return
    }
    draft = DraftRequest(
      item: snapshot.item, kind: kind,
      actionID: step.messageTemplate?.isEmpty == false ? step.id : nil)
  }

  func requestCompletion(_ snapshot: ItemSnapshot, step: WorkflowStep) {
    guard step.canRecord else {
      errorMessage = "This step cannot be completed yet. Review its prerequisites."
      return
    }
    if step.kind == .mergeMR && (snapshot.item.workflow != nil || step.isOptional == true) {
      mergeConfirmation = MergeConfirmation(snapshot: snapshot, step: step)
      return
    }
    completion = CompletionConfirmation(snapshot: snapshot, step: step)
  }
  func saveWorkflow(
    _ draft: WorkflowDefinition, token: RevisionToken, reason: String,
    makeDefault: Bool
  ) async -> Bool {
    await operation {
      guard let store else { throw TrackerError.storage("Storage is unavailable.") }
      _ = try await store.changeWorkflows(
        .publish(draft, reason: reason, makeDefault: makeDefault),
        expected: token, source: .desktop, requestID: UUID().uuidString)
      notify("Workflow published. Existing tickets keep their captured version.")
    }
  }
  func defaultWorkflow(_ definition: WorkflowDefinition, token: RevisionToken) async -> Bool {
    await operation {
      guard let store else { throw TrackerError.storage("Storage is unavailable.") }
      _ = try await store.changeWorkflows(
        .setDefault(id: definition.id, reason: "Selected as the default in the workflow editor."),
        expected: token, source: .desktop, requestID: UUID().uuidString)
      notify("Default saved for new items")
    }
  }

  @discardableResult
  func complete(_ confirmation: CompletionConfirmation) async -> Bool {
    completion = nil
    return await mutate(
      confirmation.snapshot,
      .record(
        actionID: confirmation.step.id,
        note: "Explicitly confirmed after reviewing the completion dialog in the desktop app."))
  }

  @discardableResult
  func mutate(_ snapshot: ItemSnapshot, _ mutation: ItemMutation) async -> Bool {
    let saved = await operation {
      guard let store else { throw TrackerError.storage("Storage is unavailable.") }
      _ = try await store.mutate(
        snapshot.id, expected: snapshot.token, mutation: mutation,
        source: .desktop, requestID: UUID().uuidString)
      if case .edit(let patch) = mutation, let date = patch.followUpAt, !patch.clearFollowUp {
        notify("Follow-up set for \(date.formatted(date: .abbreviated, time: .shortened))")
      } else {
        notify("Saved on this Mac")
      }
    }
    if saved, !snapshot.item.isDone { celebrateIfFinished(snapshot.id) }
    return saved
  }

  private func celebrateIfFinished(_ id: String) {
    guard UserDefaults.standard.object(forKey: "workspace.celebrations") as? Bool ?? true,
      let item = snapshots.first(where: { $0.id == id })?.item, item.kind == .ticket, item.isDone
    else { return }
    let calendar = Calendar.current
    let shipped = snapshots.filter { snapshot in
      snapshot.item.kind == .ticket
        && snapshot.item.completionDate.map {
          calendar.isDate($0, equalTo: Date(), toGranularity: .month)
        } ?? false
    }.count
    let celebration = Celebration(
      key: item.jiraKey.isEmpty ? "Ticket" : item.jiraKey, title: item.title,
      shippedThisMonth: max(1, shipped))
    self.celebration = celebration
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(4))
      if self?.celebration?.id == celebration.id { self?.celebration = nil }
    }
  }

  @discardableResult
  func saveLibrary(_ value: WorkspaceLibrary, expected: RevisionToken) async -> Bool {
    await operation {
      guard let store else { throw TrackerError.storage("Storage is unavailable.") }
      try await store.saveLibrary(value, expected: expected)
      notify("Saved")
    }
  }

  func newReference() {
    guard let library else {
      errorMessage = "Notes and links are not available. Refresh the workspace."
      return
    }
    referenceEditor = ReferenceEditRequest(
      snapshot: library, content: page == .notes ? .note(nil) : .link(nil))
  }

  @discardableResult
  func saveSettings(_ value: TrackerSettings) async -> Bool {
    await operation {
      guard let store else { throw TrackerError.storage("Storage is unavailable.") }
      try await store.saveSettings(value)
      notify("Preferences saved")
    }
  }

  private func operation(_ body: () async throws -> Void) async -> Bool {
    guard !isBusy else { return false }
    isBusy = true
    defer { isBusy = false }
    do {
      try await body()
      try await load()
    } catch {
      errorMessage = error.localizedDescription
      do { try await load() } catch { storageFailure = error.localizedDescription }
      return false
    }
    if !isUISmoke {
      do { try await reminders.reconcile(snapshots) } catch {
        errorMessage =
          "Your changes were saved, but reminders could not be updated: \(error.localizedDescription)"
      }
    }
    return true
  }

  func openLink(_ link: String) {
    do {
      let value = try Workflow.validatedLink(link)
      guard let url = URL(string: value), NSWorkspace.shared.open(url) else {
        throw TrackerError.invalid("macOS could not open this link.")
      }
    } catch { errorMessage = error.localizedDescription }
  }

  func openBoard(for item: WorkItem) {
    do {
      openLink(try Workflow.jiraBoardLink(settings.jiraBoardURL, issueKey: item.jiraKey))
    } catch { errorMessage = error.localizedDescription }
  }

  func copy(_ text: String, message: String = "Copied — remember to post it in Teams") {
    NSPasteboard.general.clearContents()
    if NSPasteboard.general.setString(text, forType: .string) {
      notify(message)
    } else {
      errorMessage = "The clipboard could not be updated."
    }
  }

  func notify(_ message: String) {
    toast = message
    Task {
      do { try await Task.sleep(for: .seconds(3)) } catch is CancellationError { return } catch {
        errorMessage = error.localizedDescription
        return
      }
      if toast == message { toast = nil }
    }
  }

  func setLogin(_ enabled: Bool) async {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try await SMAppService.mainApp.unregister()
      }
      await refreshOSStatus()
    } catch { errorMessage = error.localizedDescription }
  }

  func requestNotifications() async {
    do {
      _ = try await reminders.center.requestAuthorization(options: [.alert, .sound])
      await refreshOSStatus()
      try await reminders.reconcile(snapshots)
    } catch { errorMessage = error.localizedDescription }
  }

  func refreshOSStatus() async {
    let notification = await reminders.center.notificationSettings()
    switch notification.authorizationStatus {
    case .authorized, .provisional: notificationStatus = "Enabled"
    case .denied: notificationStatus = "Denied in System Settings"
    case .notDetermined: notificationStatus = "Not enabled"
    case .ephemeral: notificationStatus = "Temporarily enabled"
    @unknown default: notificationStatus = "Unknown"
    }
    switch SMAppService.mainApp.status {
    case .enabled: loginStatus = "On"
    case .requiresApproval: loginStatus = "Needs approval in System Settings"
    case .notFound: loginStatus = "App registration unavailable"
    case .notRegistered: loginStatus = "Off"
    @unknown default: loginStatus = "Unknown"
    }
  }

  func exportWorkspace() async {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "TicketTracker-export.json"
    panel.message =
      "This export contains work context and history. Choose a location permitted by your company."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      guard let store else { throw TrackerError.storage("Storage is unavailable.") }
      try await store.exportData().write(to: url, options: [.atomic])
      notify("Workspace exported")
    } catch { errorMessage = error.localizedDescription }
  }

  func restoreWorkspace() async {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      guard let store else { throw TrackerError.storage("Storage is unavailable.") }
      let data = try Data(contentsOf: url)
      let preview = try await store.previewRestore(data)
      let alert = NSAlert()
      alert.messageText = "Restore \(preview.items.count) items?"
      alert.informativeText =
        "This replaces the current workspace with this export, including its preferences. A local backup will be made first. Connected sessions must reread their ticket state."
      alert.addButton(withTitle: "Restore Workspace")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      _ = await operation {
        try await store.restore(data)
        selectedID = nil
        notify("Workspace restored")
      }
    } catch { errorMessage = error.localizedDescription }
  }
}
