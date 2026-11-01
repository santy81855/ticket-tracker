import Foundation

extension WorkflowCondition {
  public var displayName: String {
    switch self {
    case .always: "Always"
    case .qaRequired: "Only when QA is required"
    case .noQA: "Only when QA is skipped"
    case .retest: "Only for a QE retest"
    }
  }
}
extension WorkflowDestination {
  public var displayName: String {
    switch self {
    case .none: "Nowhere specific"
    case .board: "Jira board"
    case .issue: "Jira issue"
    case .thread: "Ticket Teams thread"
    case .channel: "Teams channel"
    case .mergeRequest: "Merge request"
    case .custom: "Custom link"
    }
  }
}
extension WorkflowFieldType {
  public var displayName: String {
    switch self {
    case .text: "Text"
    case .date: "Date (yyyy-MM-dd)"
    case .url: "Link"
    case .fixVersion: "Fix Version/s"
    }
  }
}
extension ActionKind {
  public var displayName: String {
    switch self {
    case .jiraStart: "Jira start move"
    case .kickoff: "Kickoff thread"
    case .implementation: "Implementation"
    case .approvalRequest: "Approval request"
    case .approveMR: "MR approval"
    case .qaDecision: "QA decision"
    case .jiraValidate: "Validate / merge move"
    case .qaHandoff: "QE handoff"
    case .retestHandoff: "Retest handoff"
    case .qaPassed: "QA passed"
    case .jiraReady: "Ready to deploy move"
    case .mergeMR: "MR merge"
    case .jiraDone: "Jira Done move"
    case .taskDone: "Task completion"
    case .custom: "Custom step"
    }
  }
}

/// Starting points for new custom steps, shared by the editor and the CLI.
public enum WorkflowStepPreset: String, CaseIterable, Codable, Sendable {
  case teamsPost, boardMove, waitOn, askSomeone, recordInfo, checklist

  public var displayName: String {
    switch self {
    case .teamsPost: "Post in the Teams thread"
    case .boardMove: "Move on the Jira board"
    case .waitOn: "Wait on someone"
    case .askSomeone: "Ask someone"
    case .recordInfo: "Record information"
    case .checklist: "Checklist item"
    }
  }
  public var summary: String {
    switch self {
    case .teamsPost: "Drafts a message for the ticket thread; requires the thread link."
    case .boardMove: "A column move with from/to columns and the board link."
    case .waitOn: "Something another person does; you confirm it, with a follow-up nudge."
    case .askSomeone: "A question you send, then a reminder to check for the answer."
    case .recordInfo: "Asks for a value (text, date, link) before the step can be confirmed."
    case .checklist: "A plain reminder you tick off."
    }
  }
  public func rule(id: String = "step-" + UUID().uuidString.prefix(8).lowercased())
    -> WorkflowRule
  {
    var rule = WorkflowRule(id: id, title: displayName)
    switch self {
    case .teamsPost:
      rule.title = "Post an update in the Teams thread"
      rule.destination = .thread
      rule.requiresThread = true
      rule.messageTemplate = "{{ticket}}: "
      rule.detail = "Post in the existing ticket thread. Preparing a draft does not post it."
    case .boardMove:
      rule.title = "Move Jira to Validate / merge"
      rule.destination = .board
      rule.toColumn = "Validate / merge"
      rule.detail = "Move the card on the Jira board, then confirm."
    case .waitOn:
      rule.title = "Wait for confirmation"
      rule.owner = "Someone else"
      rule.isWait = true
      rule.nudgeAfterHours = 24
      rule.detail = "Confirm once it actually happened."
    case .askSomeone:
      rule.title = "Ask about the update"
      rule.destination = .channel
      rule.detail = "Send the question, then confirm it was sent."
    case .recordInfo:
      rule.title = "Record the details"
      var field = WorkflowField()
      field.id = "field-" + UUID().uuidString.prefix(8).lowercased()
      field.label = "Value"
      rule.fields = [field]
      rule.detail = "Save the value in the item details before confirming."
    case .checklist:
      rule.title = "Checklist item"
      rule.detail = "Tick this off when it is done."
    }
    return rule
  }
}

extension WorkflowDefinition {
  /// Stable topological order: keeps the current order except where a step precedes its prerequisite.
  public func orderedByPrerequisites() -> [WorkflowRule] {
    var remaining = steps
    var placed: Set<String> = []
    var result: [WorkflowRule] = []
    let ids = Set(steps.map(\.id))
    while !remaining.isEmpty {
      let index =
        remaining.firstIndex { step in
          step.dependsOn.allSatisfy { placed.contains($0) || !ids.contains($0) }
        } ?? 0
      let step = remaining.remove(at: index)
      placed.insert(step.id)
      result.append(step)
    }
    return result
  }
  public var isInPrerequisiteOrder: Bool { orderedByPrerequisites().map(\.id) == steps.map(\.id) }

  /// Steps that depend on `id`, directly.
  public func dependents(of id: String) -> [WorkflowRule] {
    steps.filter { $0.dependsOn.contains(id) }
  }
}

extension WorkflowCatalog {
  public static let defaultColumns = [
    "Implementation in progress", "Validate / merge", "Ready to deploy", "Done",
  ]
  /// Board columns already used anywhere, so new board steps can reuse the exact spelling.
  public var knownColumns: [String] {
    var seen: Set<String> = []
    var result: [String] = []
    let used = latest.flatMap(\.steps).flatMap { [$0.fromColumn, $0.toColumn] }
    for column in Self.defaultColumns + used {
      let trimmed = column.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty && seen.insert(Self.columnKey(trimmed)).inserted {
        result.append(trimmed)
      }
    }
    return result
  }
  static func columnKey(_ column: String) -> String {
    column.lowercased().filter { $0.isLetter || $0.isNumber }
  }
  /// Flags column names that nearly match a known column, which usually means a typo.
  public func columnWarnings(for definition: WorkflowDefinition) -> [String] {
    let known = knownColumns
    var result: [String] = []
    for step in definition.steps where step.enabled {
      for column in [step.fromColumn, step.toColumn] where !column.isEmpty {
        if let match = known.first(where: {
          Self.columnKey($0) == Self.columnKey(column) && $0 != column
        }) {
          result.append("\(step.title) uses \"\(column)\"; the board column is \"\(match)\".")
        }
      }
      if !step.toColumn.isEmpty
        && Self.columnKey(step.fromColumn) == Self.columnKey(step.toColumn)
      {
        result.append("\(step.title) moves a card to the column it is already in.")
      }
    }
    return result
  }
}

public struct WorkflowSimulation: Codable, Sendable {
  public var steps: [WorkflowStep]
  public var phase: String
  public var nextStep: String?
  public var isDone: Bool
  public var messages: [String: String]
}

/// Walks a workflow (draft or published) with a sample ticket, without touching real items.
public enum WorkflowSimulator {
  public static func sampleItem(
    _ definition: WorkflowDefinition, qa: QARequirement = .required, paths: [String] = []
  ) -> WorkItem {
    var item = WorkItem(
      kind: definition.kind, title: definition.kind == .ticket ? "Sample ticket" : "Sample task")
    item.workflow = definition
    item.playbookVersion = 2
    item.paths = paths.isEmpty ? nil : paths
    item.createdAt = Date().addingTimeInterval(-3600)
    if definition.kind == .ticket {
      item.jiraKey = "ABC-123"
      item.jiraURL = "https://jira.example.com/browse/ABC-123"
      item.qa = qa
      item.threadURL = "https://teams.microsoft.com/l/message/sample"
      item.testingNotes = "Sample testing notes"
      item.environment = "staging"
      item.qe = "@QE"
      item.mergeRequests = [MergeRequest(url: "https://gitlab.example.com/app/-/merge_requests/1")]
    }
    var values: [String: String] = [:]
    for field in definition.steps.flatMap(\.fields) {
      switch field.type {
      case .text, .fixVersion: values[field.id] = "sample"
      case .date: values[field.id] = "2026-01-06"
      case .url: values[field.id] = "https://example.com"
      }
    }
    item.fieldValues = values
    return item
  }
  public static func sampleMessage(
    _ template: String, definition: WorkflowDefinition, settings: TrackerSettings
  ) -> String {
    var settings = settings
    if settings.pod.isEmpty { settings.pod = "@pod" }
    let item = sampleItem(definition)
    do {
      return try Messages.render(template, item: item, settings: settings, destination: "").text
    } catch {
      return error.localizedDescription
    }
  }
  /// `completed` lists step IDs (rule IDs; MR steps complete for every sample MR) in the order taken.
  public static func simulate(
    _ definition: WorkflowDefinition, qa: QARequirement = .required, retest: Bool = false,
    paths: [String] = [], completed: [String] = [], settings: TrackerSettings = TrackerSettings(),
    now: Date = Date()
  ) throws -> WorkflowSimulation {
    try definition.validate()
    let known = Set((definition.paths ?? []).map(\.id))
    guard paths.allSatisfy(known.contains) else {
      throw TrackerError.invalid("Choose paths defined by this workflow.")
    }
    var item = sampleItem(definition, qa: qa, paths: paths)
    func add(_ id: String, round: Int) {
      let rule = definition.steps.first { $0.id == id }
      let mrSpecific = rule.map { [.approveMR, .mergeMR].contains($0.kind) } ?? false
      let ids =
        mrSpecific
        ? item.ticketMRs.map {
          rule?.kind == .mergeMR
            ? Workflow.actionID(.mergeMR, mrID: $0.id) : "\(id):\($0.id)"
        } : [id]
      for actionID in ids {
        item.actions.append(
          ActionRecord(
            id: actionID, cycle: 0, round: round, state: .completed, source: .desktop,
            note: "Simulated", date: now, stepRevision: rule?.revision, occurredAt: now))
      }
    }
    if retest, qa == .required,
      let handoff = definition.steps.first(where: { $0.kind == .qaHandoff })
    {
      add(handoff.id, round: 0)
      item.reviewRound = 1
    }
    for id in completed {
      guard definition.steps.contains(where: { $0.id == id }) else {
        throw TrackerError.invalid("Unknown step \(id).")
      }
      add(id, round: item.reviewRound)
    }
    if let value = ConfiguredWorkflow.fixVersion(for: item) {
      for field in definition.steps.flatMap(\.fields) where field.type == .fixVersion {
        item.fieldValues?[field.id] = value
      }
    }
    let steps = ConfiguredWorkflow.steps(for: item)
    let snapshot = ItemSnapshot(item: item, generation: "simulation")
    var messages: [String: String] = [:]
    var renderSettings = settings
    if renderSettings.pod.isEmpty { renderSettings.pod = "@pod" }
    for rule in definition.steps where !rule.messageTemplate.isEmpty {
      messages[rule.id] =
        (try? Messages.render(
          rule.messageTemplate, item: item, settings: renderSettings, destination: ""
        ).text) ?? ""
    }
    return WorkflowSimulation(
      steps: steps, phase: ConfiguredWorkflow.phase(item), nextStep: snapshot.nextStep?.title,
      isDone: ConfiguredWorkflow.isDone(item), messages: messages)
  }
}
