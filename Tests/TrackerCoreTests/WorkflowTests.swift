import Foundation
import Testing

@testable import TrackerCore

private func sample(qa: QARequirement = .required) throws -> WorkItem {
  var item = try Workflow.create(
    NewItem(
      kind: .ticket, title: "Improve checkout", jira: "https://jira.example.test/browse/WEB-42",
      qa: qa),
    settings: TrackerSettings()
  )
  var patch = DetailsPatch()
  patch.threadURL = "https://teams.example.test/thread/42"
  patch.testingNotes = "Exercise checkout with a test card."
  item = try Workflow.apply(.edit(patch), to: item, source: .desktop)
  item = try Workflow.apply(
    .addMR("https://gitlab.example.test/pod/app/-/merge_requests/12"), to: item, source: .desktop)
  return item
}

private func record(_ kind: ActionKind, _ item: WorkItem, mrID: String? = nil) throws -> WorkItem {
  try Workflow.apply(
    .record(
      actionID: Workflow.actionID(kind, mrID: mrID), note: "Confirmed in the external system."),
    to: item, source: .desktop)
}

private func throughApprovals(_ original: WorkItem) throws -> WorkItem {
  var item = original
  for action in [ActionKind.jiraStart, .kickoff, .implementation, .approvalRequest] {
    item = try record(action, item)
  }
  for mr in item.mergeRequests { item = try record(.approveMR, item, mrID: mr.id) }
  return item
}

private func completedSummaryTicket(_ key: String, at date: Date) throws -> WorkItem {
  var item = try sample(qa: .notRequired)
  item.jiraKey = key
  item.jiraURL = "https://jira.example.test/browse/\(key)"
  for kind in [ActionKind.jiraStart, .kickoff, .implementation, .approvalRequest] {
    item = try Workflow.apply(
      .record(actionID: kind.rawValue, note: ""), to: item, source: .desktop, now: date)
  }
  for kind in [ActionKind.approveMR, .mergeMR] {
    item = try Workflow.apply(
      .record(actionID: Workflow.actionID(kind, mrID: item.mergeRequests[0].id), note: ""),
      to: item, source: .desktop, now: date)
  }
  return try Workflow.apply(
    .record(actionID: "jiraDone", note: ""), to: item, source: .desktop, now: date)
}

@Test func standupIncludesAllActiveTicketsAndOnlyCompletionsWithin48Hours() throws {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  var active = try throughApprovals(sample())
  active = try record(.jiraValidate, active)
  active = try record(.qaHandoff, active)
  active.waitingOn = "QE team"
  active.updatedAt = now.addingTimeInterval(-30 * 24 * 3600)
  let recent = try completedSummaryTicket("WEB-3", at: now.addingTimeInterval(-3600))
  let boundary = try completedSummaryTicket("WEB-2", at: now.addingTimeInterval(-48 * 3600))
  let older = try completedSummaryTicket("WEB-1", at: now.addingTimeInterval(-48 * 3600 - 1))
  let future = try completedSummaryTicket("WEB-4", at: now.addingTimeInterval(1))
  let task = WorkItem(kind: .task, title: "Ask Jack about the API")
  let completedTask = try Workflow.apply(
    .record(actionID: "taskDone", note: ""), to: task, source: .desktop, now: now)
  let snapshots = [older, task, boundary, active, completedTask, future, recent].map {
    ItemSnapshot(item: $0, generation: "test")
  }
  let summary = StandupSummary(snapshots: snapshots, now: now)
  #expect(summary.activeTickets.map(\.id) == [active.id])
  #expect(summary.recentlyCompleted.map(\.id) == [recent.id, boundary.id])
  #expect(summary.text.contains("QA · Waiting for QE"))
  #expect(summary.text.contains("Confirm QA passed"))
  #expect(summary.text.contains("Waiting on: QE team"))
  #expect(summary.text.contains("1/1 approved, 0/1 merged"))
  #expect(!summary.text.contains(task.title))
  #expect(!summary.text.contains("WEB-1"))
}

@Test func summaryCompletionDatesSurviveLegacyDecodingAndIgnoreLaterMetadata() throws {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let date = now.addingTimeInterval(-49 * 3600)
  let completed = try completedSummaryTicket("WEB-1", at: date)
  #expect(completed.completedAt == date)
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  var legacyJSON = try #require(
    JSONSerialization.jsonObject(with: encoder.encode(completed)) as? [String: Any])
  legacyJSON.removeValue(forKey: "completedAt")
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  var legacy = try decoder.decode(
    WorkItem.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
  legacy.updatedAt = now
  #expect(legacy.completedAt == nil)
  #expect(legacy.completionDate == date)
  let summary = StandupSummary(
    snapshots: [ItemSnapshot(item: legacy, generation: "test")], now: now)
  #expect(summary.activeTickets.isEmpty)
  #expect(summary.recentlyCompleted.isEmpty)
}

@Test func summaryFollowsUndoRecompletionAndReopen() throws {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  var item = try completedSummaryTicket("WEB-1", at: now)
  item = try Workflow.apply(
    .correctCompletionTime(
      now.addingTimeInterval(-49 * 3600), note: "User confirmed the original finish time.",
      evidence: .userConfirmed),
    to: item, source: .copilot, now: now)
  item = try Workflow.apply(
    .undo(actionID: "jiraDone", reason: "Accidental confirmation."), to: item, source: .desktop,
    now: now)
  #expect(item.completedAt == nil)
  #expect(item.completionDate == nil)
  var summary = StandupSummary(snapshots: [ItemSnapshot(item: item, generation: "test")], now: now)
  #expect(summary.activeTickets.map(\.id) == [item.id])
  #expect(summary.recentlyCompleted.isEmpty)
  item = try Workflow.apply(
    .record(actionID: "jiraDone", note: ""), to: item, source: .desktop, now: now)
  #expect(item.completionDate == now)
  summary = StandupSummary(snapshots: [ItemSnapshot(item: item, generation: "test")], now: now)
  #expect(summary.activeTickets.isEmpty)
  #expect(summary.recentlyCompleted.map(\.id) == [item.id])
  item = try Workflow.apply(.reopen, to: item, source: .desktop, now: now)
  #expect(item.completedAt == nil)
  summary = StandupSummary(snapshots: [ItemSnapshot(item: item, generation: "test")], now: now)
  #expect(summary.activeTickets.map(\.id) == [item.id])
  #expect(summary.recentlyCompleted.isEmpty)
}

@Test(arguments: [false, true])
func completionTimeCorrectionExcludesBackfilledTicketsAndAuditsActualDate(legacy: Bool) throws {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let actual = now.addingTimeInterval(-7 * 86400)
  var original = try completedSummaryTicket("WEB-1", at: now)
  original.createdAt = now
  if legacy { original.completedAt = nil }
  #expect(
    StandupSummary(snapshots: [ItemSnapshot(item: original, generation: "test")], now: now)
      .recentlyCompleted.map(\.id) == [original.id])
  let reason = "User confirmed the final Teams message was posted a week ago."
  let corrected = try Workflow.apply(
    .correctCompletionTime(actual, note: reason, evidence: .userConfirmed),
    to: original, source: .copilot, now: now)
  #expect(corrected.isDone)
  #expect(corrected.completedAt == actual)
  #expect(corrected.completionDate == actual)
  #expect(actual < corrected.createdAt)
  #expect(corrected.updatedAt == now)
  #expect(corrected.actions == original.actions)
  #expect(corrected.mergeRequests == original.mergeRequests)
  #expect(corrected.history.count == original.history.count + 1)
  let entry = try #require(corrected.history.last)
  #expect(entry.title == "Completion time corrected")
  #expect(entry.source == .copilot)
  #expect(entry.date == now)
  #expect(entry.note.contains(now.ISO8601Format()))
  #expect(entry.note.contains(actual.ISO8601Format()))
  #expect(entry.note.contains("userConfirmed"))
  #expect(entry.note.contains(reason))
  let summary = StandupSummary(
    snapshots: [ItemSnapshot(item: corrected, generation: "test")], now: now)
  #expect(summary.recentlyCompleted.isEmpty)
  #expect(summary.activeTickets.isEmpty)
}

@Test func completionTimeCorrectionRequiresCompletedItemPastDateAndReason() throws {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let done = try completedSummaryTicket("WEB-1", at: now)
  let valid = ItemMutation.correctCompletionTime(
    now.addingTimeInterval(-86400), note: "User confirmed the finish time.",
    evidence: .userConfirmed)
  #expect(throws: TrackerError.self) {
    try Workflow.apply(valid, to: sample(), source: .copilot, now: now)
  }
  for date in [
    now.addingTimeInterval(1), Date(timeIntervalSince1970: -.infinity),
    Date(timeIntervalSince1970: .nan),
  ] {
    #expect(throws: TrackerError.self) {
      try Workflow.apply(
        .correctCompletionTime(date, note: "User confirmed.", evidence: .verified),
        to: done, source: .copilot, now: now)
    }
  }
  #expect(throws: TrackerError.self) {
    try Workflow.apply(
      .correctCompletionTime(now, note: " \n ", evidence: .userConfirmed),
      to: done, source: .copilot, now: now)
  }
}

@Test func summaryDatesCompletionAtTheLastGateNotAnEarlierCatchup() throws {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  var item = try throughApprovals(sample(qa: .notRequired))
  item = try Workflow.apply(
    .recordExisting(actionID: "jiraDone", note: "The earlier Jira move is confirmed."),
    to: item, source: .desktop, now: now.addingTimeInterval(-49 * 3600))
  #expect(!item.isDone)
  item = try Workflow.apply(
    .record(actionID: Workflow.actionID(.mergeMR, mrID: item.mergeRequests[0].id), note: ""),
    to: item, source: .desktop, now: now)
  #expect(item.completionDate == now)
  #expect(
    StandupSummary(snapshots: [ItemSnapshot(item: item, generation: "test")], now: now)
      .recentlyCompleted.map(\.id) == [item.id])
}

@Test func fullQAPathPreservesSeparateActions() throws {
  var item = try throughApprovals(sample())
  #expect(!Workflow.mergeBlockers(for: item).isEmpty)
  for action in [ActionKind.jiraValidate, .qaHandoff, .qaPassed, .jiraReady] {
    item = try record(action, item)
  }
  #expect(Workflow.mergeBlockers(for: item).isEmpty)
  item = try record(.mergeMR, item, mrID: item.mergeRequests[0].id)
  #expect(!item.isDone)
  item = try record(.jiraDone, item)
  #expect(item.isDone)
}

@Test func noQAStillRequiresApprovals() throws {
  var item = try sample(qa: .notRequired)
  item = try record(.implementation, item)
  #expect(!Workflow.mergeBlockers(for: item).isEmpty)
  item = try throughApprovals(sample(qa: .notRequired))
  #expect(Workflow.steps(for: item).first { $0.kind == .qaHandoff }?.state == .notApplicable)
  #expect(Workflow.mergeBlockers(for: item).isEmpty)
  item = try record(.mergeMR, item, mrID: item.mergeRequests[0].id)
  item = try record(.jiraDone, item)
  #expect(item.isDone)
}

@Test func completedApprovalsAdvancePhaseBeforeTheQAHandoff() throws {
  var item = try sample()
  item = try Workflow.apply(
    .addMR("https://gitlab.example.test/pod/api/-/merge_requests/7"), to: item, source: .desktop)
  for kind in [ActionKind.jiraStart, .kickoff, .implementation, .approvalRequest] {
    item = try record(kind, item)
  }
  item = try record(.approveMR, item, mrID: item.mergeRequests[0].id)
  #expect(Workflow.phase(for: item) == "Awaiting approvals")
  item = try record(.approveMR, item, mrID: item.mergeRequests[1].id)
  #expect(Workflow.phase(for: item) == "Ready for QA")
  #expect(ItemSnapshot(item: item, generation: "test").nextStep?.kind == .jiraValidate)
  item = try record(.jiraValidate, item)
  #expect(Workflow.phase(for: item) == "Ready for QA handoff")
  item = try record(.qaHandoff, item)
  #expect(Workflow.phase(for: item) == "QA · Waiting for QE")
}

@Test func undoApprovalKeepsQAHistoryAndRestoresMergeGuards() throws {
  var item = try throughApprovals(sample())
  item = try record(.jiraValidate, item)
  item = try record(.qaHandoff, item)
  item = try Workflow.apply(.rework("QE requested a fix."), to: item, source: .desktop)
  item = try record(.implementation, item)
  item = try record(.approvalRequest, item)
  item = try record(.approveMR, item, mrID: item.mergeRequests[0].id)
  let history = item.history
  let action = Workflow.actionID(.approveMR, mrID: item.mergeRequests[0].id)
  item = try Workflow.apply(
    .undo(actionID: action, reason: "Clicked the approval checkbox by mistake."),
    to: item, source: .desktop)
  #expect(item.isInQA)
  #expect(item.has(.jiraValidate))
  #expect(item.has(.qaHandoff))
  #expect(!item.allApproved)
  #expect(!Workflow.mergeBlockers(for: item).isEmpty)
  #expect(Array(item.history.prefix(history.count)) == history)
  #expect(item.history.last?.title.hasPrefix("Undid confirmation:") == true)
}

@Test func undoOnlyAllowsLatestDesktopConfirmationWithAReason() throws {
  let item = try throughApprovals(sample())
  let last = try #require(Workflow.lastRecordedStep(for: item))
  #expect(throws: TrackerError.self) {
    try Workflow.apply(
      .undo(actionID: "implementation", reason: "An older step"), to: item, source: .desktop)
  }
  #expect(throws: TrackerError.self) {
    try Workflow.apply(.undo(actionID: last.id, reason: ""), to: item, source: .desktop)
  }
  #expect(throws: TrackerError.self) {
    try Workflow.apply(
      .undo(actionID: last.id, reason: "Correct it"), to: item, source: .copilot)
  }
}

@Test func undoCompletionPreservesTheCycleAndRestoresTheFollowUp() throws {
  let followUp = Date(timeIntervalSince1970: 2_000_000_000)
  var task = try Workflow.create(
    NewItem(kind: .task, title: "Ask Jack", followUpAt: followUp), settings: TrackerSettings())
  task = try record(.taskDone, task)
  #expect(task.followUpAt == nil)
  task = try Workflow.apply(
    .undo(actionID: "taskDone", reason: "This was not done."), to: task, source: .desktop)
  #expect(!task.isDone)
  #expect(task.cycle == 0)
  #expect(task.followUpAt == followUp)

  var ticket = try throughApprovals(sample(qa: .notRequired))
  ticket = try record(.mergeMR, ticket, mrID: ticket.mergeRequests[0].id)
  ticket = try record(.jiraDone, ticket)
  ticket = try Workflow.apply(
    .undo(actionID: "jiraDone", reason: "The board has not been moved yet."),
    to: ticket, source: .desktop)
  #expect(!ticket.isDone)
  #expect(ticket.allMerged)
  #expect(ticket.cycle == 0)
  #expect(Workflow.steps(for: ticket).first { $0.kind == .jiraDone }?.canRecord == true)
}

@Test func boardLinksSelectTheCurrentIssueAndPreserveBoardParameters() throws {
  let url = try Workflow.jiraBoardLink(
    "https://jira.example.test/secure/RapidBoard.jspa?rapidView=42&selectedIssue=OLD-1&quickFilter=7#board",
    issueKey: "ABC-42")
  let parts = try #require(URLComponents(string: url))
  #expect(parts.path == "/secure/RapidBoard.jspa")
  #expect(parts.queryItems?.first { $0.name == "rapidView" }?.value == "42")
  #expect(parts.queryItems?.first { $0.name == "quickFilter" }?.value == "7")
  #expect(parts.queryItems?.filter { $0.name == "selectedIssue" }.map(\.value) == ["ABC-42"])
  #expect(parts.fragment == "board")
}

@Test func olderSettingsGainTheBoardWithoutLosingExistingPreferences() throws {
  var settings = TrackerSettings()
  settings.pod = "Existing pod"
  settings.qaTemplate = "Existing QA template"
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
  object.removeValue(forKey: "jiraBoardURL")
  let restored = try JSONDecoder().decode(
    TrackerSettings.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(restored.jiraBoardURL == settings.jiraBoardURL)
  #expect(restored.pod == settings.pod)
  #expect(restored.qaTemplate == settings.qaTemplate)
}

@Test func qaFixStaysInQAAndNeedsFreshRetest() throws {
  var item = try throughApprovals(sample())
  item = try record(.jiraValidate, item)
  item = try record(.qaHandoff, item)
  item = try record(.qaPassed, item)
  item = try Workflow.apply(.rework("Checkout fails for a saved card."), to: item, source: .copilot)
  #expect(item.isInQA)
  #expect(item.has(.jiraValidate))
  #expect(item.has(.kickoff))
  #expect(!item.has(.qaPassed))
  #expect(!item.allApproved)
  #expect(Workflow.phase(for: item) == "QA · Fix requested")
  item = try record(.implementation, item)
  item = try record(.approvalRequest, item)
  item = try record(.approveMR, item, mrID: item.mergeRequests[0].id)
  #expect(Workflow.steps(for: item).first { $0.kind == .retestHandoff }?.blockers.isEmpty == false)
  var patch = DetailsPatch()
  patch.testingNotes = "Retest saved-card checkout."
  item = try Workflow.apply(.edit(patch), to: item, source: .desktop)
  item = try record(.retestHandoff, item)
  item = try record(.qaPassed, item)
  item = try record(.jiraReady, item)
  #expect(item.isInQA)
  #expect(Workflow.mergeBlockers(for: item).isEmpty)
}

@Test func preQAReviewRoundDoesNotInventRetest() throws {
  var item = try sample()
  item = try Workflow.apply(.rework("Review changes before QA."), to: item, source: .desktop)
  item = try throughApprovals(item)
  var patch = DetailsPatch()
  patch.testingNotes = "Current-round test notes."
  item = try Workflow.apply(.edit(patch), to: item, source: .desktop)
  item = try record(.jiraValidate, item)
  item = try record(.qaHandoff, item)
  #expect(!item.needsRetest)
  #expect(!Workflow.steps(for: item).contains { $0.kind == .retestHandoff })
}

@Test func partialApprovalAndMergeDoNotPass() throws {
  var item = try sample(qa: .notRequired)
  item = try Workflow.apply(
    .addMR("https://gitlab.example.test/pod/api/-/merge_requests/7"), to: item, source: .desktop)
  for action in [ActionKind.jiraStart, .kickoff, .implementation, .approvalRequest] {
    item = try record(action, item)
  }
  item = try record(.approveMR, item, mrID: item.mergeRequests[0].id)
  #expect(!item.allApproved)
  #expect(!Workflow.mergeBlockers(for: item).isEmpty)
  item = try record(.approveMR, item, mrID: item.mergeRequests[1].id)
  item = try record(.mergeMR, item, mrID: item.mergeRequests[0].id)
  #expect(!item.allMerged)
  #expect(throws: TrackerError.self) { try record(.jiraDone, item) }
}

@Test func unknownQAAndMissedKickoffRemainBlockers() throws {
  var item = try sample(qa: .undecided)
  item = try record(.implementation, item)
  #expect(!item.has(.kickoff))
  #expect(throws: TrackerError.self) { try record(.approvalRequest, item) }
  #expect(Workflow.mergeBlockers(for: item).contains { $0.contains("Decide whether QA") })
}

@Test func existingDoneFactDoesNotHideMissingActions() throws {
  let original = try sample()
  let item = try Workflow.apply(
    .recordExisting(actionID: "jiraDone", note: "The Jira board is already Done."),
    to: original, source: .desktop)
  #expect(item.has(.jiraDone))
  #expect(!item.isDone)
  #expect(Workflow.phase(for: item) == "Needs reconciliation")
  #expect(Workflow.steps(for: item).contains { $0.kind == .kickoff && $0.state == .pending })
}

@Test func agentsCannotWaiveOrInventExternalCompletion() throws {
  let item = try sample()
  #expect(throws: TrackerError.self) {
    try Workflow.apply(.record(actionID: "jiraStart", note: ""), to: item, source: .copilot)
  }
  #expect(throws: TrackerError.self) {
    try Workflow.apply(.waive(actionID: "kickoff", reason: "Skip"), to: item, source: .copilot)
  }
  #expect(throws: TrackerError.self) {
    try Workflow.apply(
      .recordExisting(actionID: "jiraDone", note: "Already done"), to: item, source: .copilot)
  }
}

@Test func plainTaskNeedsNoTicketMetadata() throws {
  var item = try Workflow.create(
    NewItem(kind: .task, title: "Ask Jack for an update"), settings: TrackerSettings())
  item = try record(.taskDone, item)
  #expect(item.isDone)
  item = try Workflow.apply(.reopen, to: item, source: .desktop)
  #expect(!item.isDone)
}

@Test func waitingTaskBecomesActionableAtItsFollowUp() throws {
  var item = try Workflow.create(
    NewItem(kind: .task, title: "Ask Jack"), settings: TrackerSettings())
  var patch = DetailsPatch()
  patch.waitingOn = "Jack"
  item = try Workflow.apply(.edit(patch), to: item, source: .desktop)
  #expect(ItemSnapshot(item: item, generation: "test").isWaiting)
  #expect(!ItemSnapshot(item: item, generation: "test").hasActionableWork)
  patch.followUpAt = Date(timeIntervalSince1970: 1)
  item = try Workflow.apply(.edit(patch), to: item, source: .desktop)
  #expect(ItemSnapshot(item: item, generation: "test").hasActionableWork)
}

@Test func draftShowsMissingInformationAndDoesNotMutate() throws {
  let item = try sample()
  let draft = try Messages.draft(.qa, item: item, settings: TrackerSettings())
  #expect(draft.missing.contains("qe"))
  #expect(draft.text.contains("[Add qe]"))
  #expect(!item.has(.qaHandoff))
}

@Test func rejectsUnsafeURLsAndMalformedTicketKeys() throws {
  #expect(throws: TrackerError.self) { try Workflow.validatedLink("javascript:alert(1)") }
  #expect(throws: TrackerError.self) {
    try Workflow.validatedLink("https://user:secret@example.test")
  }
  #expect(throws: TrackerError.self) {
    try Workflow.jiraIdentity("not-a-ticket", baseURL: "https://jira.example.test")
  }
  #expect(throws: TrackerError.self) {
    try Workflow.validatedMRLink("https://gitlab.example.test/pod/app")
  }
  #expect(
    try Workflow.validatedMRLink(
      "https://gitlab.example.test/pod/app/-/merge_requests/12/diffs?view=parallel#note")
      == "https://gitlab.example.test/pod/app/-/merge_requests/12")
}
