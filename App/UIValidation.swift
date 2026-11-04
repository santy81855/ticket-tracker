#if DEBUG
  import AppKit
  import SwiftUI
  import TrackerCore
  import TrackerStore

  @MainActor
  enum UIValidation {
    private static var hasStarted = false

    static func start(model: WorkspaceModel) {
      guard !hasStarted else { return }
      hasStarted = true
      Task { await run(model: model) }
    }

    private static func run(model: WorkspaceModel) async {
      do {
        guard let store = model.store, model.storageFailure == nil else {
          throw TrackerError.storage(model.storageFailure ?? "The validation store did not open.")
        }
        if model.isThemePreview {
          try await showThemePreview(model: model, store: store)
          return
        }
        guard let output = ProcessInfo.processInfo.environment["TICKET_TRACKER_UI_OUTPUT"] else {
          throw TrackerError.invalid("Pass TICKET_TRACKER_UI_OUTPUT for validation screenshots.")
        }
        guard let window = NSApp.windows.first(where: { $0.title == "Ticket Tracker" }),
          window.contentMinSize.width <= 420, window.contentMinSize.height <= 360
        else { throw TrackerError.invalid("The native window minimum does not fit a small tile.") }
        guard window.styleMask.contains(.titled),
          window.standardWindowButton(.zoomButton)?.isEnabled == true
        else {
          throw TrackerError.invalid("The native title bar and zoom control are unavailable.")
        }
        // Keep the user's tiling manager from resizing this isolated screenshot fixture.
        window.styleMask = [.borderless]
        window.level = .floating
        window.collectionBehavior = [.transient, .ignoresCycle]
        let folder = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        UserDefaults.standard.set(WorkspaceTheme.classic.rawValue, forKey: "workspace.theme")
        UserDefaults.standard.set(false, forKey: "workspace.breathingGuide")
        NSApp.appearance = NSAppearance(named: .aqua)
        if ProcessInfo.processInfo.environment["TICKET_TRACKER_SHOWCASE"] != nil {
          try await showcase(model: model, store: store, window: window, folder: folder)
          print("Showcase screenshots: \(folder.path)")
          NSApp.terminate(nil)
          return
        }
        try await capture(model, name: "empty", folder: folder)
        try await capture(
          model, name: "small-empty", folder: folder, size: NSSize(width: 420, height: 360))
        try await checkReferenceLibrary(model: model, store: store, window: window, folder: folder)
        model.page = .summary
        try await capture(model, name: "summary-empty", folder: folder)
        model.page = .all
        var ticket = try await store.create(
          NewItem(
            kind: .ticket, title: "Refine the saved-card checkout experience",
            jira: "https://jira.example.test/browse/WEB-248", qa: .required,
            notes: "Keep error states clear and make the recovery path easy to follow."),
          source: .desktop, requestID: UUID().uuidString
        )
        func change(_ snapshot: ItemSnapshot, _ mutation: ItemMutation) async throws -> ItemSnapshot
        {
          try await store.mutate(
            snapshot.id, expected: snapshot.token, mutation: mutation,
            source: .desktop, requestID: UUID().uuidString)
        }
        var patch = DetailsPatch()
        patch.threadURL = "https://teams.example.test/thread/248"
        patch.testingNotes = "Exercise the saved-card path, including a declined payment and retry."
        patch.environment = "Staging"
        patch.qe = "QE contact"
        ticket = try await change(ticket, .edit(patch))
        ticket = try await change(
          ticket, .addMR("https://gitlab.example.test/pod/checkout/-/merge_requests/86"))
        for action in ["jiraStart", "kickoff", "implementation"] {
          ticket = try await change(
            ticket, .record(actionID: action, note: "Synthetic UI validation data."))
        }
        _ = try await store.create(
          NewItem(
            kind: .task, title: "Ask Jack about the API rollout",
            notes: "Check whether the new endpoint is ready for integration."),
          source: .desktop, requestID: UUID().uuidString
        )
        var toggle = try await store.create(
          NewItem(
            kind: .ticket, title: "Enable the new search toggle in staging",
            jira: "https://jira.example.test/browse/WEB-251", qa: .notRequired),
          source: .desktop, requestID: UUID().uuidString
        )
        var togglePatch = DetailsPatch()
        togglePatch.followUpAt = Date().addingTimeInterval(3600)
        toggle = try await change(toggle, .edit(togglePatch))
        try await model.load()
        model.page = .all
        model.selectedID = ticket.id
        try await capture(model, name: "workspace", folder: folder)
        try await checkDraft(.approvals, model: model, window: window, folder: folder)
        ticket = try await change(
          ticket, .record(actionID: "approvalRequest", note: "Synthetic approval request."))
        for mr in ticket.item.mergeRequests {
          ticket = try await change(
            ticket, .record(actionID: "approveMR:\(mr.id)", note: "Synthetic pod approval."))
        }
        ticket = try await change(
          ticket, .record(actionID: "jiraValidate", note: "Synthetic Jira move."))
        try await model.load()
        try await checkDraft(.qa, model: model, window: window, folder: folder)
        ticket = try await change(
          ticket, .record(actionID: "qaHandoff", note: "Synthetic QE handoff."))
        ticket = try await change(
          ticket, .rework("QE found an unclear recovery message after a declined payment."))
        try await model.load()
        guard model.selected?.item.isInQA == true else {
          throw TrackerError.invalid("QA state was lost during UI validation.")
        }
        try await capture(model, name: "qa-fix", folder: folder)
        model.showNewItem = true
        try await capture(model, name: "new-item", folder: folder)
        model.showNewItem = false
        try await Task.sleep(for: .milliseconds(200))
        model.showSettings = true
        try await capture(model, name: "settings", folder: folder)
        try await showCopilotSettings(model)
        try await capture(model, name: "copilot-settings", folder: folder)
        model.showSettings = false
        try await checkTerminal(model: model, folder: folder)
        model.page = .all
        NSApp.appearance = NSAppearance(named: .darkAqua)
        UserDefaults.standard.set(WorkspaceTheme.slate.rawValue, forKey: "workspace.theme")
        try await capture(model, name: "dark-workspace", folder: folder)
        NSApp.appearance = NSAppearance(named: .aqua)
        UserDefaults.standard.set(WorkspaceTheme.classic.rawValue, forKey: "workspace.theme")
        model.showsItemDetail = false
        try await capture(
          model, name: "tiled-list", folder: folder, size: NSSize(width: 720, height: 600))
        try await capture(
          model, name: "small-list", folder: folder, size: NSSize(width: 420, height: 360))
        model.showsItemDetail = true
        try await capture(
          model, name: "small-detail", folder: folder, size: NSSize(width: 420, height: 360))
        try await capture(
          model, name: "small-detail-bottom", folder: folder, size: NSSize(width: 420, height: 360),
          scrollToEnd: true)
        try await capture(
          model, name: "tiled-detail", folder: folder, size: NSSize(width: 720, height: 450))
        try await capture(
          model, name: "medium-split", folder: folder, size: NSSize(width: 1000, height: 500))
        try await capture(
          model, name: "wide-short", folder: folder, size: NSSize(width: 1360, height: 360))
        try await capture(
          model, name: "small-detail", folder: folder, size: NSSize(width: 420, height: 360))
        model.showNewItem = true
        try await capture(
          model, name: "small-new-item", folder: folder, size: NSSize(width: 420, height: 360))
        try await capture(
          model, name: "small-new-item-bottom", folder: folder,
          size: NSSize(width: 420, height: 360),
          scrollToEnd: true)
        model.showNewItem = false
        try await Task.sleep(for: .milliseconds(300))
        model.showSettings = true
        try await capture(
          model, name: "small-settings", folder: folder, size: NSSize(width: 420, height: 360))
        try await capture(
          model, name: "short-settings", folder: folder, size: NSSize(width: 940, height: 400))
        try await capture(
          model, name: "small-settings-bottom", folder: folder,
          size: NSSize(width: 420, height: 360),
          scrollToEnd: true)
        try await showCopilotSettings(model)
        try await capture(
          model, name: "small-copilot-settings", folder: folder,
          size: NSSize(width: 420, height: 360), scrollToEnd: false)
        try await capture(
          model, name: "small-copilot-settings-bottom", folder: folder,
          size: NSSize(width: 420, height: 360), scrollToEnd: true)
        model.showSettings = false
        try await Task.sleep(for: .milliseconds(300))
        ticket = try await change(
          ticket, .record(actionID: "implementation", note: "Synthetic QA fix completed."))
        try await model.load()
        try await capture(
          model, name: "narrow-actions", folder: folder, size: NSSize(width: 420, height: 640),
          scrollToEnd: false)
        guard model.selectedID == ticket.id else {
          throw TrackerError.invalid("Resizing changed the selected ticket.")
        }
        for theme in WorkspaceTheme.allCases {
          UserDefaults.standard.set(theme.rawValue, forKey: "workspace.theme")
          try await capture(model, name: "theme-\(theme.rawValue)", folder: folder)
          let expected: NSAppearance.Name = theme.colorScheme == .dark ? .darkAqua : .aqua
          guard window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected else {
            throw TrackerError.invalid("The fixed appearance did not match \(theme.title).")
          }
        }
        try await GargantuaValidation.validate(window: window, folder: folder)
        UserDefaults.standard.set(WorkspaceTheme.space.rawValue, forKey: "workspace.theme")
        window.resignKey()
        try await capture(model, name: "space-motion-first", folder: folder)
        try await Task.sleep(for: .seconds(1))
        try await capture(model, name: "space-motion-second", folder: folder)
        let first = try Data(contentsOf: folder.appendingPathComponent("space-motion-first.png"))
        let second = try Data(contentsOf: folder.appendingPathComponent("space-motion-second.png"))
        guard first != second else {
          throw TrackerError.invalid("The visible, unfocused space background was not animating.")
        }
        UserDefaults.standard.set(WorkspaceTheme.classic.rawValue, forKey: "workspace.theme")
        let before = try await store.get(ticket.id)
        UserDefaults.standard.set(true, forKey: "workspace.breathingGuide")
        try await capture(model, name: "breathing-first", folder: folder)
        try await Task.sleep(for: .seconds(2))
        try await capture(model, name: "breathing-second", folder: folder)
        guard
          try Data(contentsOf: folder.appendingPathComponent("breathing-first.png"))
            != Data(contentsOf: folder.appendingPathComponent("breathing-second.png"))
        else { throw TrackerError.invalid("The breathing guide was not visibly changing.") }
        UserDefaults.standard.set(false, forKey: "workspace.breathingGuide")
        guard let step = before.nextStep else {
          throw TrackerError.invalid("No step was available for completion validation.")
        }
        model.requestCompletion(before, step: step)
        try await capture(model, name: "completion-confirmation", folder: folder)
        guard try await store.get(ticket.id).token == before.token else {
          throw TrackerError.invalid("Opening the completion dialog changed the item.")
        }
        model.completion = nil
        try await Task.sleep(for: .milliseconds(300))
        guard try await store.get(ticket.id).token == before.token else {
          throw TrackerError.invalid("Cancelling the completion dialog changed the item.")
        }
        model.requestCompletion(before, step: step)
        guard let confirmation = model.completion, await model.complete(confirmation) else {
          throw TrackerError.invalid("Confirming the completion dialog did not save the step.")
        }
        var after = try await store.get(ticket.id)
        guard after.item.has(step.kind, mrID: step.mrID),
          await model.mutate(after, .undo(actionID: step.id, reason: "Synthetic accidental click."))
        else { throw TrackerError.invalid("The confirmation could not be undone.") }
        after = try await store.get(ticket.id)
        guard !after.item.has(step.kind, mrID: step.mrID), after.item.isInQA else {
          throw TrackerError.invalid("Undo did not restore the pending step and preserve QA.")
        }
        model.requestCompletion(after, step: step)
        var externalEdit = DetailsPatch()
        externalEdit.notes = "Synthetic external update while a confirmation was open."
        ticket = try await change(after, .edit(externalEdit))
        guard let stale = model.completion, !(await model.complete(stale)),
          model.errorMessage != nil
        else { throw TrackerError.invalid("A stale completion dialog overwrote newer data.") }
        model.errorMessage = nil
        for action in ["approvalRequest"] + ticket.item.mergeRequests.map({ "approveMR:\($0.id)" })
        {
          ticket = try await change(
            ticket, .record(actionID: action, note: "Synthetic retest readiness."))
        }
        try await model.load()
        guard model.selected?.nextStep?.kind == .retestHandoff else {
          throw TrackerError.invalid("The retest handoff was not ready.")
        }
        try await checkDraft(.qa, model: model, window: window, folder: folder, name: "retest")
        try await checkStandupSummary(model: model, store: store, folder: folder)
        try await checkWorkflowEditor(model: model, store: store, window: window, folder: folder)
        try await checkDocumentViewer(model: model, folder: folder)
        print(
          "PASS: native title bar, wide/tiled/minimum layouts, fixed themes, visible-unfocused animation, breathing guide, embedded terminal tabs, draft routing, completion/cancel/stale-token safety, audited undo, and stand-up summary. Screenshots: \(folder.path)"
        )
        NSApp.terminate(nil)
      } catch {
        FileHandle.standardError.write(
          Data("UI validation failed: \(error.localizedDescription)\n".utf8))
        exit(1)
      }
    }

    private static func showThemePreview(model: WorkspaceModel, store: TrackerStore) async throws {
      guard Bundle.main.bundleIdentifier == "com.tickettracker.local.preview" else {
        throw TrackerError.invalid("Use the isolated theme preview app.")
      }
      if try await store.list().isEmpty {
        var ticket = try await store.create(
          NewItem(
            kind: .ticket, title: "Fix map recovery after saved state",
            jira: "https://jira.example.test/browse/ABC-1234", qa: .required,
            notes: "Handle late map errors without navigating after state is saved."),
          source: .desktop, requestID: "preview-ticket")
        var patch = DetailsPatch()
        patch.threadURL = "https://teams.example.test/thread/1234"
        patch.testingNotes =
          "Open the map, background the app, then simulate a map failure. Resume and verify safe recovery."
        patch.environment = "Staging"
        patch.qe = "QE contact"
        ticket = try await store.mutate(
          ticket.id, expected: ticket.token, mutation: .edit(patch),
          source: .desktop, requestID: UUID().uuidString)
        ticket = try await store.mutate(
          ticket.id, expected: ticket.token,
          mutation: .addMR("https://gitlab.example.test/pod/maps/-/merge_requests/86"),
          source: .desktop, requestID: UUID().uuidString)
        let approvalID = "approveMR:\(ticket.item.mergeRequests[0].id)"
        for action in [
          "jiraStart", "kickoff", "implementation", "approvalRequest",
          approvalID, "jiraValidate", "qaHandoff",
        ] {
          ticket = try await store.mutate(
            ticket.id, expected: ticket.token,
            mutation: .record(actionID: action, note: "Synthetic design preview."),
            source: .desktop, requestID: UUID().uuidString)
        }
        _ = try await store.create(
          NewItem(kind: .task, title: "Ask Jack about the API rollout"),
          source: .desktop, requestID: "preview-task")
        _ = try await store.create(
          NewItem(
            kind: .ticket, title: "Enable the new search toggle in staging",
            jira: "https://jira.example.test/browse/ABC-1298", qa: .notRequired),
          source: .desktop, requestID: "preview-toggle")
        let library = try await store.library()
        try await store.saveLibrary(referenceSamples(), expected: library.token)
      }
      try await model.load()
      model.page = .all
      model.selectedID = model.visible.first(where: { $0.item.jiraKey == "ABC-1234" })?.id
      model.showsItemDetail = false
      guard let window = NSApp.windows.first(where: { $0.title == "Ticket Tracker" }) else {
        throw TrackerError.invalid("The theme preview window did not appear.")
      }
      window.title = "Ticket Tracker — Design preview"
      window.setContentSize(NSSize(width: 1280, height: 840))
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      try await Task.sleep(for: .seconds(1))
      if let output = ProcessInfo.processInfo.environment["TICKET_TRACKER_UI_OUTPUT"],
        let view = window.contentView
      {
        let folder = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
          throw TrackerError.invalid("Could not capture the theme preview.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
          throw TrackerError.invalid("Could not encode the theme preview.")
        }
        try data.write(to: folder.appendingPathComponent("theme-preview.png"))
      }
      try FileHandle.standardOutput.write(
        contentsOf: Data(
          "PREVIEW_READY: scannable tickets, workspace Notes and Links, real native app; isolated sample data.\n"
            .utf8)
      )
    }

    private static func referenceSamples() -> WorkspaceLibrary {
      var value = WorkspaceLibrary()
      value.notes = [
        WorkspaceNote(
          id: "sample-weekly", title: "This week",
          body:
            "Things to keep in mind\n\n• Ask about the next release window.\n• Make time for the accessibility review.\n• Share the onboarding notes with the pod."
        ),
        WorkspaceNote(
          id: "sample-commands", title: "Useful commands",
          body:
            "Local reset\nClear derived data before a clean rebuild.\n\nBefore opening a review\nRun tests, check screenshots, and write down any setup steps."
        ),
        WorkspaceNote(
          id: "sample-ideas", title: "Ideas for later",
          body:
            "Small improvements worth coming back to.\n\nSimpler release checklists.\nA shared place for debugging tips.\nA better onboarding walkthrough."
        ),
      ]
      value.links = [
        WorkspaceLink(
          id: "sample-handbook", title: "Engineering handbook",
          url: "https://engineering.example.test/handbook",
          detail: "Team conventions, onboarding, and day-to-day reference."),
        WorkspaceLink(
          id: "sample-design", title: "Design system",
          url: "https://design.example.test/components",
          detail: "Components, patterns, and accessibility guidelines."),
        WorkspaceLink(
          id: "sample-releases", title: "Release dashboard",
          url: "https://releases.example.test/mobile",
          detail: "Builds, release windows, and rollout status."),
      ]
      return value
    }

    private static func checkReferenceLibrary(
      model: WorkspaceModel, store: TrackerStore, window: NSWindow, folder: URL
    ) async throws {
      model.page = .notes
      try await capture(model, name: "notes-empty", folder: folder)
      guard let initial = model.library,
        await model.saveLibrary(referenceSamples(), expected: initial.token),
        let saved = model.library, let note = saved.library.notes.first
      else { throw TrackerError.invalid("Workspace notes could not be saved.") }
      try await capture(model, name: "notes-wide", folder: folder)
      try await capture(
        model, name: "notes-small", folder: folder, size: NSSize(width: 420, height: 640))
      model.referenceEditor = ReferenceEditRequest(snapshot: saved, content: .note(note))
      try await capture(model, name: "note-editor", folder: folder)
      func textEditor(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView, !editor.isFieldEditor { return editor }
        return view.subviews.lazy.compactMap { textEditor(in: $0) }.first
      }
      guard let sheet = window.sheets.first?.contentView,
        textEditor(in: sheet)?.string == note.body
      else { throw TrackerError.invalid("The workspace note editor did not show the saved note.") }
      try await capture(
        model, name: "note-editor-small", folder: folder,
        size: NSSize(width: 420, height: 360), scrollToEnd: true)
      model.referenceEditor = nil
      try await Task.sleep(for: .milliseconds(300))
      guard try await store.library().token == saved.token else {
        throw TrackerError.invalid("Opening or cancelling a note changed saved content.")
      }
      model.page = .links
      try await capture(model, name: "links-wide", folder: folder)
      try await capture(
        model, name: "links-small", folder: folder, size: NSSize(width: 420, height: 640))
      guard let link = saved.library.links.first else {
        throw TrackerError.invalid("The general link fixture is missing.")
      }
      model.referenceEditor = ReferenceEditRequest(snapshot: saved, content: .link(link))
      try await capture(model, name: "link-editor", folder: folder)
      try await capture(
        model, name: "link-editor-small", folder: folder,
        size: NSSize(width: 420, height: 360), scrollToEnd: true)
      model.referenceEditor = nil
      try await Task.sleep(for: .milliseconds(300))
      guard try await store.library().token == saved.token else {
        throw TrackerError.invalid("Opening or cancelling a link changed saved content.")
      }
      model.page = .all
    }

    private static func checkStandupSummary(
      model: WorkspaceModel, store: TrackerStore, folder: URL
    ) async throws {
      var completed = try await store.create(
        NewItem(
          kind: .ticket, title: "Enable the saved-card recovery feature in staging",
          jira: "https://jira.example.test/browse/WEB-260", qa: .notRequired),
        source: .desktop, requestID: "summary-completed")
      func change(_ mutation: ItemMutation) async throws {
        completed = try await store.mutate(
          completed.id, expected: completed.token, mutation: mutation,
          source: .desktop, requestID: UUID().uuidString)
      }
      var patch = DetailsPatch()
      patch.threadURL = "https://teams.example.test/thread/260"
      try await change(.edit(patch))
      try await change(.addMR("https://gitlab.example.test/pod/checkout/-/merge_requests/93"))
      guard let mr = completed.item.mergeRequests.first else {
        throw TrackerError.invalid("The stand-up fixture has no merge request.")
      }
      for action in [
        "jiraStart", "kickoff", "implementation", "approvalRequest",
        "approveMR:\(mr.id)", "mergeMR:\(mr.id)", "jiraDone",
      ] {
        try await change(.record(actionID: action, note: "Synthetic stand-up validation."))
      }
      try await model.load()
      model.page = .summary
      model.search = "No matching tickets"
      model.kindFilter = "Tasks"
      model.showsItemDetail = true
      let report = model.standupSummary
      guard report.activeTickets.count == 2,
        report.recentlyCompleted.map(\.id) == [completed.id],
        !report.text.contains("Ask Jack"),
        report.text.contains("WEB-260")
      else { throw TrackerError.invalid("The stand-up summary omitted tickets or included tasks.") }
      try await capture(model, name: "summary-wide", folder: folder)
      try await capture(
        model, name: "summary-tiled", folder: folder, size: NSSize(width: 720, height: 600))
      try await capture(
        model, name: "summary-small", folder: folder, size: NSSize(width: 420, height: 360))
      try await capture(
        model, name: "summary-small-bottom", folder: folder,
        size: NSSize(width: 420, height: 360), scrollToEnd: true)
      model.reveal(completed.id)
      guard model.page == .archive, model.selectedID == completed.id else {
        throw TrackerError.invalid("A summary ticket did not open its detail.")
      }
      guard await model.mutate(completed, .undo(actionID: "jiraDone", reason: "Synthetic undo.")),
        model.standupSummary.recentlyCompleted.isEmpty,
        model.standupSummary.activeTickets.contains(where: { $0.id == completed.id })
      else { throw TrackerError.invalid("The summary did not refresh after undo.") }
      model.page = .summary
      try await capture(
        model, name: "summary-after-undo", folder: folder, size: NSSize(width: 720, height: 600))
    }

    /// Seeds realistic sample work and captures README screenshots across pages and themes.
    private static func checkDocumentViewer(model: WorkspaceModel, folder: URL) async throws {
      let browser = BrowserModel.shared
      let documents = folder.appendingPathComponent("viewer-documents", isDirectory: true)
      try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
      let plan = documents.appendingPathComponent("ABC-1298-plan.md")
      let notes = documents.appendingPathComponent("notes.txt")
      var markdown = """
        # ABC-1298 · Loyalty banner plan

        Show the **loyalty banner** on the booking summary behind a `remote config` toggle.

        ## Steps

        - [x] Add the `showLoyaltyBanner` flag
        - [ ] Render the banner in `SummaryView`
        - [ ] Unit tests for the flag states

        | Platform | Owner | Status |
        | --- | --- | --- |
        | iOS | Santiago | In progress |
        | Android | Priya | Not started |

        ```swift
        if config.showLoyaltyBanner { LoyaltyBanner() }
        ```

        > QA: verify with the toggle on and off in staging.

        <script>document.title = "unsafe"</script>

        See the [testing notes](notes.txt).
        """
      try Data(markdown.utf8).write(to: plan)
      try Data("Plain <b>text</b> stays literal.\n".utf8).write(to: notes)
      let webView = { browser.webView }
      func run(_ script: String) async throws -> Any? {
        try await webView().evaluateJavaScript(script)
      }
      func waitUntil(_ label: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<40 {
          if try await condition() { return }
          try await Task.sleep(for: .milliseconds(150))
        }
        throw TrackerError.invalid("File viewer: \(label).")
      }
      browser.openFile(plan)
      try await waitUntil("the plan did not load") {
        guard !webView().isLoading, webView().url?.path == plan.path else { return false }
        return try await run("document.querySelectorAll('#doc h1').length") as? Int == 1
      }
      let rendered =
        try await run(
          "document.querySelectorAll('#doc table, #doc input[type=checkbox], #doc pre code, #doc blockquote').length"
        ) as? Int ?? 0
      let scripts = try await run("document.querySelectorAll('#doc script').length") as? Int
      guard rendered == 6, scripts == 0, webView().title == "ABC-1298-plan.md",
        browser.address == plan.path
      else {
        throw TrackerError.invalid(
          "File viewer rendered \(rendered) Markdown blocks and \(scripts ?? -1) scripts.")
      }
      let tabCount = browser.tabs.count
      browser.openFile(plan)
      guard browser.tabs.count == tabCount else {
        throw TrackerError.invalid("Reopening a shown file added a duplicate tab.")
      }
      markdown += "\n\n## Added while open\n"
      try Data(markdown.utf8).write(to: plan)
      try await waitUntil("live refresh did not show the edit") {
        try await run("document.body.innerText.includes('Added while open')") as? Bool == true
      }
      try await capture(model, name: "file-viewer", folder: folder)
      let image = try await webView().takeSnapshot(configuration: nil)
      if let tiff = image.tiffRepresentation,
        let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
      {
        try png.write(to: folder.appendingPathComponent("file-viewer-page.png"))
      }
      _ = try await run("document.querySelector('a[href=\"notes.txt\"]').click()")
      try await waitUntil("a relative link did not open the text file in place") {
        guard webView().url?.path == notes.path else { return false }
        let text = try await run("document.querySelector('#doc pre')?.textContent ?? ''")
        return (text as? String)?.contains("<b>text</b>") == true
      }
      guard browser.tabs.count == tabCount else {
        throw TrackerError.invalid("A document link opened an extra tab.")
      }
      webView().goBack()
      try await waitUntil("going back did not restore the current plan") {
        guard webView().url?.path == plan.path else { return false }
        return try await run("document.body.innerText.includes('Added while open')") as? Bool
          == true
      }
      browser.openFile(documents)
      guard browser.failure?.contains("folder") == true else {
        throw TrackerError.invalid("Opening a folder did not explain the problem.")
      }
      browser.failure = nil
      browser.close(browser.selected)
      browser.isVisible = false
      try await Task.sleep(for: .milliseconds(300))
    }

    private static func showcase(
      model: WorkspaceModel, store: TrackerStore, window: NSWindow, folder: URL
    ) async throws {
      var settings = model.settings
      settings.jiraBaseURL = "https://jira.example.com"
      settings.jiraBoardURL = "https://jira.example.com/secure/RapidBoard.jspa?rapidView=42"
      settings.gitlabHost = "https://gitlab.example.com"
      settings.teamsChannelURL = "https://teams.example.com/channel/mobile-pod"
      settings.pod = "@Mobile Pod"
      settings.qe = "@Priya"
      guard await model.saveSettings(settings) else {
        throw TrackerError.invalid("Showcase settings were not saved.")
      }
      let hour: TimeInterval = 3600
      let day = 24 * hour
      let now = Date()
      var mrNumber = 400
      func mutate(_ snapshot: ItemSnapshot, _ mutation: ItemMutation) async throws -> ItemSnapshot {
        try await store.mutate(
          snapshot.id, expected: snapshot.token, mutation: mutation,
          source: .desktop, requestID: UUID().uuidString)
      }
      func ticket(
        _ key: String, _ title: String, qa: QARequirement, notes: String, repos: [String],
        testing: String = ""
      ) async throws -> ItemSnapshot {
        var snapshot = try await store.create(
          NewItem(
            kind: .ticket, title: title, jira: "https://jira.example.com/browse/\(key)", qa: qa,
            notes: notes),
          source: .desktop, requestID: UUID().uuidString)
        var patch = DetailsPatch()
        patch.threadURL = "https://teams.example.com/thread/\(key)"
        patch.testingNotes = testing
        patch.environment = "Staging"
        patch.qe = "@Priya"
        snapshot = try await mutate(snapshot, .edit(patch))
        for repo in repos {
          mrNumber += 7
          snapshot = try await mutate(
            snapshot,
            .addMR("https://gitlab.example.com/mobile/\(repo)/-/merge_requests/\(mrNumber)"))
        }
        return snapshot
      }
      /// Confirms steps with backdated times until `stop` matches the next step or the item is done.
      func advance(
        _ snapshot: ItemSnapshot, from start: Date, every gap: TimeInterval,
        until stop: (WorkflowStep) -> Bool = { _ in false }
      ) async throws -> ItemSnapshot {
        var snapshot = snapshot
        var time = start
        while let step = snapshot.nextStep, !stop(step) {
          if snapshot.item.fieldValues?["fix-version"] == nil,
            let version = ConfiguredWorkflow.fixVersion(for: snapshot.item)
          {
            var patch = DetailsPatch()
            patch.fieldValues = ["fix-version": version]
            snapshot = try await mutate(snapshot, .edit(patch))
          }
          do {
            snapshot = try await mutate(
              snapshot,
              .recordFact(
                FactInput(
                  actionID: step.id, note: "Showcase sample data.",
                  occurredAt: min(time, now.addingTimeInterval(-60)))))
          } catch {
            throw TrackerError.invalid(
              "Showcase step \(step.id) failed: \(error.localizedDescription)")
          }
          time += gap
        }
        return snapshot
      }
      func finish(_ snapshot: ItemSnapshot, at date: Date, impact: String) async throws {
        var done = try await mutate(
          snapshot,
          .correctCompletionTime(date, note: "Showcase sample data.", evidence: .userConfirmed))
        var patch = DetailsPatch()
        patch.fieldValues = [BragDocument.impactField: impact]
        done = try await mutate(done, .edit(patch))
      }

      // Completed work for the stand-up, insights, releases and brag doc.
      let shipped: [(String, String, QARequirement, String, Double)] = [
        (
          "ABC-1350", "Speed up cold start by deferring analytics setup", .required,
          "Cut cold-start time by about 30% on older devices.", 19
        ),
        (
          "ABC-1362", "Fix duplicate push notifications after reinstall", .required,
          "Stopped duplicate pushes that drove a spike in support tickets.", 13
        ),
        (
          "ABC-1371", "Enable the dark mode toggle in production", .notRequired,
          "Rolled out dark mode to every user with a single toggle.", 8
        ),
        (
          "ABC-1379", "Retry failed card payments automatically", .required,
          "Recovered failed payments with a safe automatic retry.", 4
        ),
        (
          "ABC-1384", "Show estimated delivery times on the order screen", .required,
          "Gave customers delivery estimates right on the order screen.", 1.2
        ),
      ]
      for (key, title, qa, impact, daysAgo) in shipped {
        let start = now.addingTimeInterval(-daysAgo * day - 5 * day)
        var item = try await ticket(
          key, title, qa: qa, notes: "Sample shipped work.", repos: ["app", "api"],
          testing: "Covered by regression tests in staging.")
        item = try await advance(item, from: start, every: 0.9 * day)
        try await finish(item, at: now.addingTimeInterval(-daysAgo * day), impact: impact)
      }

      // Personal tasks.
      var jack = try await store.create(
        NewItem(
          kind: .task, title: "Ask Jack about the API rollout",
          notes: "Is the new orders endpoint ready for integration?"),
        source: .desktop, requestID: UUID().uuidString)
      var waitPatch = DetailsPatch()
      waitPatch.waitingOn = "Jack"
      waitPatch.followUpAt = now.addingTimeInterval(-2 * hour)
      jack = try await mutate(jack, .edit(waitPatch))
      let demo = try await store.create(
        NewItem(
          kind: .task, title: "Prepare the sprint review demo",
          notes: "Order history redesign and dark mode rollout."),
        source: .desktop, requestID: UUID().uuidString)
      var demoPatch = DetailsPatch()
      demoPatch.followUpAt = now.addingTimeInterval(day)
      _ = try await mutate(demo, .edit(demoPatch))
      _ = try await store.create(
        NewItem(kind: .task, title: "Review Maria's MR for the profile screen"),
        source: .desktop, requestID: UUID().uuidString)
      // Active tickets at different points in the lifecycle.
      _ = try await ticket(
        "ABC-1440", "Investigate slow image loading on the home feed", qa: .required,
        notes: "Profile image decoding and cache hit rates.", repos: [])

      var banner = try await ticket(
        "ABC-1388", "Localize the loyalty points banner", qa: .required,
        notes: "Adds Spanish, French and German strings.", repos: ["app"],
        testing: "Switch the device language and confirm the banner wraps correctly.")
      banner = try await advance(
        banner, from: now.addingTimeInterval(-8 * day), every: day,
        until: { $0.kind == .mergeMR })
      var ranking = try await ticket(
        "ABC-1431", "Turn on the new search ranking toggle in prod", qa: .notRequired,
        notes: "Config-only change; no QA needed.", repos: ["config"])
      ranking = try await advance(
        ranking, from: now.addingTimeInterval(-5 * hour), every: hour,
        until: { $0.kind == .approvalRequest })
      var biometric = try await ticket(
        "ABC-1420", "Add a biometric sign-in prompt", qa: .required,
        notes: "Offer Face ID / fingerprint after the first password sign-in.", repos: ["app"])
      biometric = try await advance(
        biometric, from: now.addingTimeInterval(-1 * day), every: 2 * hour,
        until: { $0.kind == .implementation })
      var crash = try await ticket(
        "ABC-1398", "Fix crash when rotating during checkout", qa: .required,
        notes: "Payment sheet state was lost on rotation.", repos: ["app", "payments-sdk"],
        testing: "Rotate the device on every checkout step, including 3-D Secure.")
      crash = try await advance(
        crash, from: now.addingTimeInterval(-3 * day), every: 0.6 * day,
        until: { $0.kind == .approveMR })
      if let first = crash.nextStep {
        crash = try await mutate(
          crash,
          .recordFact(
            FactInput(
              actionID: first.id, note: "Showcase sample data.",
              occurredAt: now.addingTimeInterval(-3 * hour))))
      }
      var history = try await ticket(
        "ABC-1412", "Redesign the order history screen", qa: .required,
        notes: "New grouped list with filters and a cleaner empty state.",
        repos: ["app", "design-system"],
        testing:
          "Check grouping by month, the filter sheet, pull to refresh, and the empty state on a new account."
      )
      history = try await advance(
        history, from: now.addingTimeInterval(-6 * day), every: 0.8 * day,
        until: { $0.kind == .qaPassed })
      let library = try await store.library()
      try await store.saveLibrary(referenceSamples(), expected: library.token)
      try await model.load()

      func show(_ page: WorkspacePage, _ selected: ItemSnapshot? = nil, detail: Bool = true) {
        model.page = page
        model.search = ""
        model.kindFilter = "Everything"
        model.selectedID = selected?.id
        model.showsItemDetail = detail
      }
      func theme(_ theme: WorkspaceTheme) {
        UserDefaults.standard.set(theme.rawValue, forKey: "workspace.theme")
      }
      let wide = NSSize(width: 1440, height: 900)
      for (index, name) in [
        WorkspaceTheme.aurora, .classic, .tokyoNight, .gargantua, .dracula, .linen, .nebula,
        .cabin, .catppuccin, .rain, .nord, .bonsai, .skyline, .fireplace,
      ].enumerated() {
        theme(name)
        show(.all, [history, crash, banner, ranking, biometric][index % 5])
        try await capture(model, name: "theme-\(name.rawValue)", folder: folder, size: wide)
      }
      theme(.aurora)
      show(.all, crash)
      try await capture(model, name: "hero", folder: folder, size: wide)
      let pages: [(WorkspacePage, WorkspaceTheme, ItemSnapshot?, String)] = [
        (.summary, .tokyoNight, nil, "standup"),
        (.endOfDay, .catppuccin, nil, "end-of-day"),
        (.insights, .classic, nil, "insights"),
        (.brag, .linen, nil, "brag-doc"),
        (.releases, .nord, nil, "releases"),
        (.archive, .dracula, nil, "completed"),
        (.followUps, .classic, jack, "follow-ups"),
        (.waiting, .gargantua, history, "waiting"),
        (.notes, .bonsai, nil, "notes"),
        (.links, .oneDark, nil, "links"),
      ]
      for (page, look, selected, name) in pages {
        theme(look)
        show(page, selected)
        try await capture(model, name: name, folder: folder, size: wide)
      }
      theme(.classic)
      show(.all, crash)
      if let snapshot = model.selected, let step = snapshot.nextStep {
        model.requestCompletion(snapshot, step: step)
        try await capture(model, name: "confirm-step", folder: folder, size: wide)
        model.completion = nil
        try await Task.sleep(for: .milliseconds(400))
      }
      show(.all, ranking)
      if let snapshot = model.selected, let step = snapshot.nextStep {
        model.requestDraft(snapshot, step: step)
        try await capture(model, name: "message-draft", folder: folder, size: wide)
        model.draft = nil
        try await Task.sleep(for: .milliseconds(400))
      }
      theme(.tokyoNight)
      show(.all, history)
      model.showNewItem = true
      try await capture(model, name: "new-item", folder: folder, size: wide)
      model.showNewItem = false
      try await Task.sleep(for: .milliseconds(400))
      theme(.classic)
      for tab in ["Step", "Paths", "Test drive"] {
        model.workflowEditorTab = tab
        model.showWorkflows = true
        try await capture(
          model, name: "workflow-\(tab.lowercased().replacingOccurrences(of: " ", with: "-"))",
          folder: folder, size: wide)
        model.showWorkflows = false
        try await Task.sleep(for: .milliseconds(400))
      }
      theme(.dracula)
      for pane in ["Appearance", "Work links", "Keyboard shortcuts"] {
        model.settingsPane = pane
        model.showSettings = true
        try await capture(
          model, name: "settings-\(pane.lowercased().replacingOccurrences(of: " ", with: "-"))",
          folder: folder, size: wide)
        model.showSettings = false
        try await Task.sleep(for: .milliseconds(400))
      }
      theme(.aurora)
      show(.all, history)
      try await capture(
        model, name: "compact-aurora", folder: folder, size: NSSize(width: 820, height: 760))
      theme(.classic)
      show(.all, nil, detail: false)
      try await capture(
        model, name: "compact-list", folder: folder, size: NSSize(width: 520, height: 760))
    }

    private static func capture(
      _ model: WorkspaceModel, name: String, folder: URL,
      size: NSSize = NSSize(width: 1360, height: 900), scrollToEnd: Bool? = nil
    ) async throws {
      guard let window = NSApp.windows.first(where: { $0.title == "Ticket Tracker" }),
        let content = window.contentView
      else { throw TrackerError.invalid("The native workspace window did not appear.") }
      window.setContentSize(size)
      try await Task.sleep(for: .milliseconds(700))
      content.layoutSubtreeIfNeeded()
      content.displayIfNeeded()
      guard window.contentMinSize.width <= 420, window.contentMinSize.height <= 360,
        abs(content.bounds.width - size.width) <= 1,
        abs(content.bounds.height - size.height) <= 1
      else {
        throw TrackerError.invalid(
          "Window size mismatch for \(name): requested \(size), actual \(content.bounds.size), native minimum \(window.contentMinSize)."
        )
      }
      let view = window.sheets.first?.contentView ?? content
      guard view.bounds.width <= size.width + 1, view.bounds.height <= size.height + 1 else {
        throw TrackerError.invalid("A sheet exceeded its parent window: \(name).")
      }
      if let scrollToEnd {
        guard let scroll = scrollableView(in: view), let document = scroll.documentView else {
          throw TrackerError.invalid("Scrollable content was not accessible in \(name).")
        }
        let startY =
          document.isFlipped
          ? document.bounds.minY : document.bounds.maxY - scroll.contentView.bounds.height
        let endY =
          document.isFlipped
          ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scrollToEnd ? endY : startY))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(200))
        view.displayIfNeeded()
      }
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw TrackerError.invalid("Could not allocate the native view snapshot.")
      }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw TrackerError.invalid("Could not encode the native view snapshot.")
      }
      try png.write(to: folder.appendingPathComponent("\(name).png"))
      FileHandle.standardError.write(Data("Rendered \(name): \(view.bounds.size)\n".utf8))
    }

    private static func checkTerminal(model: WorkspaceModel, folder: URL) async throws {
      let sessions = TerminalSessions.shared
      let defaults = UserDefaults.standard
      let previous = defaults.string(forKey: TerminalSessions.directoryKey)
      defer { defaults.set(previous, forKey: TerminalSessions.directoryKey) }
      let start = folder.resolvingSymlinksInPath().path
      defaults.set(start, forKey: TerminalSessions.directoryKey)
      sessions.show()
      try await Task.sleep(for: .seconds(2))
      guard sessions.isVisible, let first = sessions.tabs.first, sessions.tabs.count == 1,
        let cwd = sessions.workingDirectory(of: first),
        URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == start
      else {
        throw TrackerError.invalid("The terminal did not start a shell in the chosen folder.")
      }
      try await capture(model, name: "terminal", folder: folder)
      sessions.newTab()
      sessions.isMaximized = true
      try await Task.sleep(for: .seconds(1))
      guard sessions.tabs.count == 2, sessions.selectedID == sessions.tabs.last?.id else {
        throw TrackerError.invalid("A second terminal tab did not open.")
      }
      try await capture(model, name: "terminal-maximized", folder: folder)
      sessions.selectAdjacent(1)
      guard sessions.selectedID == first.id else {
        throw TrackerError.invalid("Terminal tab switching did not wrap around.")
      }
      sessions.isMaximized = false
      try await capture(
        model, name: "terminal-small", folder: folder, size: NSSize(width: 420, height: 360))
      for tab in sessions.tabs { sessions.close(tab, confirm: false) }
      guard sessions.tabs.isEmpty, !sessions.isVisible else {
        throw TrackerError.invalid("Closing every terminal tab did not hide the panel.")
      }
    }

    private static func checkWorkflowEditor(
      model: WorkspaceModel, store: TrackerStore, window: NSWindow, folder: URL
    ) async throws {
      model.showWorkflows = true
      try await capture(
        model, name: "workflow-editor", folder: folder,
        size: NSSize(width: 1280, height: 900))
      guard !window.sheets.isEmpty else {
        throw TrackerError.invalid("Workflow editor did not open.")
      }
      try await capture(
        model, name: "workflow-editor-small", folder: folder,
        size: NSSize(width: 420, height: 640), scrollToEnd: true)
      model.showWorkflows = false
      try await Task.sleep(for: .milliseconds(300))
      for tab in ["Paths", "Test drive"] {
        model.workflowEditorTab = tab
        model.showWorkflows = true
        try await capture(
          model,
          name: "workflow-editor-\(tab.lowercased().replacingOccurrences(of: " ", with: "-"))",
          folder: folder, size: NSSize(width: 1280, height: 900))
        model.showWorkflows = false
        try await Task.sleep(for: .milliseconds(300))
      }
      guard let catalog = model.workflows else {
        throw TrackerError.invalid("The workflow catalog was not loaded.")
      }
      var definition = WorkflowTemplates.personal
      definition.id = "native-ui-workflow"
      definition.name = "Native validation workflow"
      definition.steps[0].owner = "Developer"
      guard
        await model.saveWorkflow(
          definition,
          token: RevisionToken(generation: catalog.generation, version: catalog.catalog.revision),
          reason: "Synthetic native editor publish validation.", makeDefault: false)
      else {
        throw TrackerError.invalid("The native workflow publish handler failed.")
      }
      var input = NewItem(
        kind: .ticket, title: "Native configured ticket",
        jira: "https://jira.example.test/browse/UI-700", qa: .notRequired)
      input.workflowID = definition.id
      guard await model.create(input), let ticket = model.selected,
        ticket.item.workflow?.steps.first?.owner == "Developer",
        let next = ticket.nextStep
      else {
        throw TrackerError.invalid("A new ticket did not capture its selected published workflow.")
      }
      try await capture(
        model, name: "configured-primary-action", folder: folder,
        size: NSSize(width: 1280, height: 800))
      try await capture(
        model, name: "configured-primary-action-small", folder: folder,
        size: NSSize(width: 420, height: 640))
      model.requestCompletion(ticket, step: next)
      guard let confirmation = model.completion, await model.complete(confirmation) else {
        throw TrackerError.invalid("The configured primary completion action failed.")
      }
      var current = try await store.get(ticket.id)
      guard current.item.has(.jiraStart),
        await model.mutate(
          current, .addMR("https://gitlab.example.test/pod/app/-/merge_requests/700"))
      else {
        throw TrackerError.invalid("Configured confirmation or MR attachment failed.")
      }
      current = try await store.get(ticket.id)
      guard
        await model.mutate(
          current, .addWorkspaceMR("https://gitlab.example.test/pod/workspace/-/merge_requests/701")
        )
      else {
        throw TrackerError.invalid("Optional workspace MR attachment failed.")
      }
      model.page = .workspaceMRs
      guard model.visible.contains(where: { $0.id == ticket.id }) else {
        throw TrackerError.invalid(
          "The workspace MR catch-up filter omitted an unmerged workspace MR.")
      }
      try await capture(
        model, name: "workspace-mr-catchup", folder: folder,
        size: NSSize(width: 1280, height: 800))
      current = try await store.get(ticket.id)
      guard
        let mergeStep = current.steps.first(where: { $0.kind == .mergeMR && $0.isOptional != true })
      else {
        throw TrackerError.invalid("The ticket merge date confirmation was unavailable.")
      }
      model.mergeConfirmation = MergeConfirmation(snapshot: current, step: mergeStep)
      try await capture(
        model, name: "actual-merge-date", folder: folder,
        size: NSSize(width: 900, height: 720))
      model.mergeConfirmation = nil
      try await Task.sleep(for: .milliseconds(300))
      guard try await store.get(ticket.id).token == current.token else {
        throw TrackerError.invalid("Opening/cancelling the merge date sheet changed a fact.")
      }
      guard let notice = current.steps.first(where: { $0.id == "merged-notice" }) else {
        throw TrackerError.invalid("The post-merge message was missing.")
      }
      model.requestDraft(current, step: notice)
      try await capture(
        model, name: "merged-message-draft", folder: folder,
        size: NSSize(width: 900, height: 720))
      model.draft = nil
      try await Task.sleep(for: .milliseconds(300))
    }

    private static func checkDraft(
      _ kind: DraftKind, model: WorkspaceModel, window: NSWindow, folder: URL, name: String? = nil
    ) async throws {
      guard let snapshot = model.selected, let step = snapshot.nextStep,
        DraftRequest.kind(for: step) == kind
      else {
        throw TrackerError.invalid("The draft validation ticket was unavailable.")
      }
      model.requestDraft(snapshot, step: step)
      try await capture(model, name: "draft-\(name ?? kind.rawValue)", folder: folder)
      func picker(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl,
          control.segmentCount == 3, control.label(forSegment: 0) == DraftKind.kickoff.label
        {
          return control
        }
        for child in view.subviews {
          if let control = picker(in: child) { return control }
        }
        return nil
      }
      func editor(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView { return editor }
        for child in view.subviews {
          if let editor = editor(in: child) { return editor }
        }
        return nil
      }
      let expected = try Messages.draft(kind, item: snapshot.item, settings: model.settings)
      guard let sheet = window.sheets.first?.contentView,
        let control = picker(in: sheet),
        control.label(forSegment: control.selectedSegment) == kind.label,
        editor(in: sheet)?.string == expected.text
      else { throw TrackerError.invalid("The draft opened with the wrong message: \(kind.label).") }
      model.draft = nil
      try await Task.sleep(for: .milliseconds(300))
    }

    private static func scrollableView(in view: NSView) -> NSScrollView? {
      if let scroll = view as? NSScrollView,
        let document = scroll.documentView,
        document.bounds.height > scroll.contentView.bounds.height + 1
      {
        return scroll
      }
      for child in view.subviews {
        if let scroll = scrollableView(in: child) { return scroll }
      }
      return nil
    }

    private static func showCopilotSettings(_ model: WorkspaceModel) async throws {
      model.settingsPane = "Copilot"
      try await Task.sleep(for: .milliseconds(300))
    }
  }
#endif
