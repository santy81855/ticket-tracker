import Foundation
import Testing

@testable import TrackerCore

@Test func explicitDependenciesRemainRequiredAndOnlyActualCompletionClearsFollowups() throws {
  var first = WorkflowRule(id: "follow-through", title: "Finish follow-through")
  first.required = false
  var last = WorkflowRule(id: "taskDone", kind: .taskDone, title: "Finish task")
  last.dependsOn = [first.id]
  var definition = WorkflowDefinition(
    name: "Task with dependencies", kind: .task, steps: [first, last])
  definition.version = 1
  var item = WorkItem(kind: .task, title: "Task")
  item.workflow = definition
  item.playbookVersion = 2
  let followUp = Date().addingTimeInterval(3600)
  item.followUpAt = followUp
  item = try Workflow.apply(
    .recordFact(
      FactInput(
        actionID: "taskDone",
        note: "The main task really happened, but follow-through is outstanding.",
        evidence: .performed)),
    to: item, source: .copilot)
  #expect(!item.isDone)
  #expect(item.followUpAt == followUp)
  #expect(Workflow.steps(for: item).first { $0.id == first.id }?.isOptional == false)
  item = try confirmed(first.id, item)
  #expect(item.isDone)
  #expect(item.followUpAt == nil)
  item = try Workflow.apply(
    .undo(actionID: first.id, reason: "Accidental confirmation"), to: item, source: .desktop)
  #expect(!item.isDone)
  #expect(item.followUpAt == followUp)
}

private func configured(_ qa: QARequirement = .required) throws -> WorkItem {
  var item = try Workflow.create(
    NewItem(
      kind: .ticket, title: "Release",
      jira: "https://jira.example.test/browse/APP-3", qa: qa), settings: TrackerSettings())
  item.workflow = WorkflowTemplates.personal
  item.playbookVersion = 2
  item = try Workflow.apply(
    .addMR("https://gitlab.example.test/pod/app/-/merge_requests/1"), to: item, source: .desktop)
  var details = DetailsPatch()
  details.threadURL = "https://teams.example.test/thread/3"
  details.testingNotes = "Exercise the release path"
  return try Workflow.apply(.edit(details), to: item, source: .desktop)
}
private func confirmed(_ id: String, _ item: WorkItem, now: Date = Date()) throws -> WorkItem {
  try Workflow.apply(
    .record(actionID: id, note: "Actually completed."), to: item, source: .desktop, now: now)
}
private func timestamp(_ text: String) throws -> Date {
  try #require(ISO8601DateFormatter().date(from: text))
}

@Test func jiraIssueMessageDraftTargetsTheTicketInsteadOfTeams() throws {
  var item = try configured()
  var definition = try #require(item.workflow)
  var builds = WorkflowRule(id: "jira-builds", title: "Post MR builds to Jira")
  builds.destination = .issue
  builds.condition = .qaRequired
  builds.messageTemplate = "Builds for {{ticket}}"
  definition.steps.append(builds)
  item.workflow = definition

  let draft = try Messages.draft(
    actionID: builds.id, item: item, settings: TrackerSettings())
  #expect(draft.destination == item.jiraURL)
}

@Test func configuredQAReleaseUsesLastActualTicketMergeAndRequiresMergedMessage() throws {
  let recorded = try timestamp("2026-11-12T12:00:00Z")
  var item = try configured()
  item = try Workflow.apply(
    .addMR("https://gitlab.example.test/pod/service/-/merge_requests/2"), to: item, source: .desktop
  )
  for id in ["jiraStart", "kickoff", "implementation", "approvalRequest"] {
    item = try confirmed(id, item)
  }
  for mr in item.ticketMRs { item = try confirmed("approveMR:\(mr.id)", item) }
  for id in ["jiraValidate", "qaHandoff", "qaPassed"] { item = try confirmed(id, item) }
  #expect(!Workflow.steps(for: item).first { $0.kind == .jiraReady }!.canRecord)
  let round = item.reviewRound
  item = try Workflow.apply(
    .addWorkspaceMR("https://gitlab.example.test/pod/workspace/-/merge_requests/9"), to: item,
    source: .desktop)
  #expect(item.reviewRound == round)
  for (index, mr) in item.ticketMRs.enumerated() {
    item = try Workflow.apply(
      .recordFact(
        FactInput(
          actionID: "mergeMR:\(mr.id)",
          note: "GitLab merge succeeded.", evidence: .performed,
          occurredAt: timestamp(index == 0 ? "2026-10-22T12:00:00Z" : "2026-10-29T12:00:00Z"))),
      to: item, source: .copilot, now: recorded)
  }
  #expect(ConfiguredWorkflow.fixVersion(for: item) == "2026.11.3")
  #expect(!item.isDone)
  #expect(throws: TrackerError.self) { try confirmed("jiraReady", item) }
  var details = DetailsPatch()
  details.fieldValues = ["fix-version": "2026.11.3"]
  item = try Workflow.apply(.edit(details), to: item, source: .desktop, now: recorded)
  item = try confirmed("jiraReady", item, now: recorded)
  #expect(!item.isDone)
  let draft = try Messages.draft(actionID: "merged-notice", item: item, settings: TrackerSettings())
  #expect(draft.text == "merged")
  #expect(!item.isDone)
  item = try confirmed("merged-notice", item, now: recorded)
  #expect(item.isDone)
  #expect(item.completedAt == recorded)
  let actualCompletion = try timestamp("2026-11-05T12:00:00Z")
  let actions = item.actions
  item = try Workflow.apply(
    .correctCompletionTime(
      actualCompletion, note: "Verified when the final merged message was posted.",
      evidence: .verified),
    to: item, source: .copilot, now: recorded)
  #expect(item.actions == actions)
  #expect(item.completedAt == actualCompletion)
  #expect(ConfiguredWorkflow.fixVersion(for: item) == "2026.11.3")
  let workspace = try #require(item.workspaceMRs.first)
  item = try Workflow.apply(
    .recordFact(
      FactInput(
        actionID: "mergeMR:\(workspace.id)",
        note: "Later workspace merge verified.", evidence: .verified,
        occurredAt: timestamp("2026-11-17T12:00:00Z"))),
    to: item, source: .copilot, now: recorded.addingTimeInterval(7 * 86400))
  #expect(item.isDone)
  #expect(item.completedAt == actualCompletion)
  #expect(ConfiguredWorkflow.fixVersion(for: item) == "2026.11.3")
  #expect(
    StandupSummary(
      snapshots: [ItemSnapshot(item: item, generation: "test")],
      now: recorded.addingTimeInterval(7 * 86400)
    ).recentlyCompleted.isEmpty)
}
@Test func verifiedMergeFactsPreserveMissingObligationsAndBoardMovesNeedUserEvidence() throws {
  var item = try configured(.notRequired)
  let id = "mergeMR:\(item.ticketMRs[0].id)"
  #expect(throws: TrackerError.self) {
    try Workflow.apply(
      .recordFact(FactInput(actionID: id, note: "Verified", evidence: .verified)),
      to: item, source: .copilot)
  }
  item = try Workflow.apply(
    .recordFact(
      FactInput(
        actionID: id, note: "Verified GitLab merged_at",
        evidence: .verified, occurredAt: Date().addingTimeInterval(-3600))), to: item,
    source: .copilot)
  #expect(item.allMerged)
  #expect(!item.isDone)
  #expect(!Workflow.mergeBlockers(for: item).isEmpty)
  #expect(Workflow.steps(for: item).first { $0.kind == .kickoff }?.state == .pending)
  #expect(throws: TrackerError.self) {
    try Workflow.apply(
      .recordFact(
        FactInput(
          actionID: "jiraStart", note: "Agent inferred the board move",
          evidence: .performed)), to: item, source: .copilot)
  }
}
@Test func noQAPathSkipsQAColumnsButNotApprovalsOrMergedAnnouncement() throws {
  var item = try configured(.notRequired)
  for id in [
    "jiraStart", "kickoff", "implementation", "approvalRequest",
    "approveMR:\(item.ticketMRs[0].id)",
  ] {
    item = try confirmed(id, item)
  }
  #expect(Workflow.mergeBlockers(for: item).isEmpty)
  item = try Workflow.apply(
    .recordFact(
      FactInput(
        actionID: "mergeMR:\(item.ticketMRs[0].id)",
        note: "Merged", evidence: .performed, occurredAt: Date().addingTimeInterval(-1))), to: item,
    source: .copilot)
  #expect(!item.isDone)
  item = try confirmed("merged-notice", item)
  #expect(item.isDone)
  #expect(!item.has(.jiraDone))
}
@Test func configuredReworkKeepsInitialQAHandoffButRequiresReapprovalAndRetesting() throws {
  var item = try configured()
  for id in [
    "jiraStart", "kickoff", "implementation", "approvalRequest",
    "approveMR:\(item.ticketMRs[0].id)", "jiraValidate", "qaHandoff",
  ] {
    item = try confirmed(id, item)
  }
  item = try Workflow.apply(.rework("QE found an issue"), to: item, source: .desktop)
  #expect(item.isInQA && item.needsRetest)
  #expect(!item.has(.implementation))
  #expect(!item.allApproved)
  #expect(item.has(.jiraValidate))
  #expect(Workflow.steps(for: item).first { $0.kind == .retestHandoff }?.state == .pending)
  #expect(!Workflow.mergeBlockers(for: item).isEmpty)
}
@Test func workflowValidationRejectsCyclesAndUnknownMessageTokens() throws {
  var definition = WorkflowTemplates.personal
  definition.steps[0].dependsOn = ["mergeMR"]
  #expect(throws: TrackerError.self) { try definition.validate() }
  definition = WorkflowTemplates.personal
  definition.steps[0].messageTemplate = "{{made_up_token}}"
  #expect(throws: TrackerError.self) { try definition.validate() }
}
@Test func explicitMigrationPreservesFactsButChangedOwnershipBecomesPending() throws {
  var item = try configured(.notRequired)
  item = try confirmed("jiraStart", item)
  item = try Workflow.apply(
    .recordFact(
      FactInput(
        actionID: "mergeMR:\(item.ticketMRs[0].id)",
        note: "Verified existing merge", evidence: .verified,
        occurredAt: Date().addingTimeInterval(-1))),
    to: item, source: .copilot)
  var changed = WorkflowTemplates.personal
  changed.version = 2
  changed.steps[0].owner = "Release coordinator"
  let migrated = try ConfiguredWorkflow.migrate(item, to: changed)
  #expect(migrated.allMerged)
  #expect(!migrated.has(.jiraStart))
  #expect(migrated.history == item.history)
  #expect(migrated.actions.count == item.actions.count)
}
@Test func tuesdayMergeUsesFollowingTuesdayAndLegacyWorkspaceCatchupPreservesCompletion() throws {
  var item = try configured(.notRequired)
  item = try Workflow.apply(
    .recordFact(
      FactInput(
        actionID: "mergeMR:\(item.ticketMRs[0].id)",
        note: "Merged on Tuesday", evidence: .verified,
        occurredAt: timestamp("2026-10-27T12:00:00Z"))), to: item, source: .copilot)
  #expect(ConfiguredWorkflow.fixVersion(for: item) == "2026.11.3")
  item.workflow = nil
  item.playbookVersion = 1
  for id in ["jiraStart", "kickoff", "implementation", "approvalRequest", "jiraDone"] {
    item = try confirmed(id, item)
  }
  item.completedAt = nil
  let originalDate = item.completionDate
  item = try Workflow.apply(
    .addWorkspaceMR("https://gitlab.example.test/pod/workspace/-/merge_requests/77"),
    to: item, source: .desktop)
  #expect(item.isDone)
  #expect(item.completedAt == originalDate)
  #expect(Workflow.steps(for: item).contains { $0.isOptional == true && $0.state == .pending })
}

@Test func customPathsSkipStepsButNeverSafeguards() throws {
  var definition = WorkflowTemplates.personal
  definition.paths = [WorkflowPath(id: "toggle-only", name: "Toggle-only change")]
  let handoff = try #require(definition.steps.firstIndex { $0.kind == .qaHandoff })
  definition.steps[handoff].skipPaths = ["toggle-only"]
  try definition.validate()
  var item = try configured()
  item.workflow = definition
  #expect(Workflow.steps(for: item).first { $0.id == "qaHandoff" }?.state == .pending)
  var patch = DetailsPatch()
  patch.paths = ["toggle-only"]
  item = try Workflow.apply(.edit(patch), to: item, source: .copilot)
  #expect(item.paths == ["toggle-only"])
  #expect(Workflow.steps(for: item).first { $0.id == "qaHandoff" }?.state == .notApplicable)
  patch.paths = ["unknown"]
  #expect(throws: TrackerError.self) {
    try Workflow.apply(.edit(patch), to: item, source: .copilot)
  }
  var unsafe = definition
  let merge = try #require(unsafe.steps.firstIndex { $0.kind == .mergeMR })
  unsafe.steps[merge].skipPaths = ["toggle-only"]
  #expect(throws: TrackerError.self) { try unsafe.validate() }
}

@Test func overdueWaitStepsNudgeOnlyAfterTheirThreshold() throws {
  var definition = WorkflowTemplates.personal
  let approval = try #require(definition.steps.firstIndex { $0.kind == .approveMR })
  definition.steps[approval].nudgeAfterHours = 4
  var item = try configured()
  item.workflow = definition
  for id in ["jiraStart", "kickoff", "implementation"] { item = try confirmed(id, item) }
  let requested = Date().addingTimeInterval(-5 * 3600)
  item = try confirmed("approvalRequest", item, now: requested)
  let snapshot = ItemSnapshot(item: item, generation: "test")
  #expect(snapshot.nudges.count == 1)
  #expect(snapshot.nudges.first?.nudge?.contains("Pod") == true)
  #expect(snapshot.hasActionableWork)
  definition.steps[approval].nudgeAfterHours = 8
  item.workflow = definition
  #expect(ItemSnapshot(item: item, generation: "test").nudges.isEmpty)
  definition.steps[0].nudgeAfterHours = 2
  #expect(throws: TrackerError.self) { try definition.validate() }
}

@Test func authoringHelpersOrderColumnsAndSimulate() throws {
  var definition = WorkflowTemplates.personal
  definition.steps.swapAt(0, 1)
  #expect(definition.warnings.contains { $0.contains("listed before its prerequisite") })
  #expect(!definition.isInPrerequisiteOrder)
  definition.steps = definition.orderedByPrerequisites()
  #expect(definition.steps.prefix(2).map(\.id) == ["jiraStart", "kickoff"])
  #expect(definition.isInPrerequisiteOrder)
  definition.steps[0].toColumn = "implementation in Progress"
  #expect(WorkflowCatalog().columnWarnings(for: definition).count == 1)
  let noQA = try WorkflowSimulator.simulate(
    WorkflowTemplates.personal, qa: .notRequired,
    completed: ["jiraStart", "kickoff", "implementation", "approvalRequest", "approveMR"])
  #expect(noQA.steps.first { $0.id == "qaHandoff" }?.state == .notApplicable)
  #expect(noQA.nextStep?.contains("Merge") == true)
  let all = WorkflowTemplates.personal.steps.map(\.id).filter {
    !["jiraValidate", "qaHandoff", "retestHandoff", "qaPassed"].contains($0)
  }
  #expect(
    try WorkflowSimulator.simulate(WorkflowTemplates.personal, qa: .notRequired, completed: all)
      .isDone)
  for preset in WorkflowStepPreset.allCases {
    var withPreset = WorkflowTemplates.personal
    withPreset.steps.append(preset.rule())
    try withPreset.validate()
  }
}
