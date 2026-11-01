import Foundation

public enum TrackerError: Error, LocalizedError, Sendable {
  case invalid(String)
  case blocked([String])
  case notFound
  case conflict
  case storage(String)

  public var errorDescription: String? {
    switch self {
    case .invalid(let message), .storage(let message): message
    case .blocked(let reasons): reasons.joined(separator: "\n")
    case .notFound: "This item no longer exists. Refresh and try again."
    case .conflict: "This item changed in another window or session. Refresh before trying again."
    }
  }
}

public enum ItemKind: String, Codable, CaseIterable, Sendable { case ticket, task }
public enum QARequirement: String, Codable, CaseIterable, Sendable {
  case undecided, required, notRequired
  public var label: String {
    switch self {
    case .undecided: "Decide later"
    case .required: "QA required"
    case .notRequired: "No QA needed"
    }
  }
}
public enum ChangeSource: String, Codable, Sendable { case desktop, copilot }
public enum CompletionState: String, Codable, Sendable { case completed, waived }
public enum StepState: String, Codable, Sendable { case pending, completed, waived, notApplicable }

public enum ActionKind: String, Codable, Sendable {
  case jiraStart, kickoff, implementation, approvalRequest, approveMR, qaDecision
  case jiraValidate, qaHandoff, retestHandoff, qaPassed, jiraReady, mergeMR, jiraDone, taskDone,
    custom

  public var isRoundSpecific: Bool {
    switch self {
    case .implementation, .approvalRequest, .approveMR, .retestHandoff, .qaPassed, .jiraReady: true
    default: false
    }
  }

  public var isExternal: Bool { self != .implementation && self != .qaDecision }
}

public enum MRRole: String, Codable, CaseIterable, Sendable { case ticket, workspace }
public enum FactEvidence: String, Codable, CaseIterable, Sendable {
  case userConfirmed, performed, verified
}
public struct FactInput: Codable, Sendable {
  public var actionID: String
  public var note: String
  public var evidence: FactEvidence
  public var occurredAt: Date?
  public init(
    actionID: String, note: String, evidence: FactEvidence = .userConfirmed, occurredAt: Date? = nil
  ) {
    self.actionID = actionID
    self.note = note
    self.evidence = evidence
    self.occurredAt = occurredAt
  }
}
public struct MergeRequest: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var url: String
  public var classification: MRRole?
  public var role: MRRole { classification ?? .ticket }
  public init(url: String, id: String = UUID().uuidString) {
    self.id = id
    self.url = url
  }
  public var shortName: String {
    guard let url = URL(string: url) else { return "Merge request" }
    let parts = url.pathComponents
    if let position = parts.firstIndex(of: "merge_requests"), position + 1 < parts.count {
      return
        "\(parts.prefix(position).filter { $0 != "/" && $0 != "-" }.last ?? "MR") !\(parts[position + 1])"
    }
    return url.lastPathComponent.isEmpty ? "Merge request" : url.lastPathComponent
  }
}

public struct ActionRecord: Codable, Equatable, Sendable {
  public var id: String
  public var cycle: Int
  public var round: Int
  public var state: CompletionState
  public var source: ChangeSource
  public var note: String
  public var date: Date
  public var previousFollowUpAt: Date? = nil
  public var stepRevision: String? = nil
  public var evidence: FactEvidence? = nil
  public var occurredAt: Date? = nil
  public init(
    id: String, cycle: Int, round: Int, state: CompletionState, source: ChangeSource,
    note: String, date: Date, previousFollowUpAt: Date? = nil, stepRevision: String? = nil,
    evidence: FactEvidence? = nil, occurredAt: Date? = nil
  ) {
    self.id = id
    self.cycle = cycle
    self.round = round
    self.state = state
    self.source = source
    self.note = note
    self.date = date
    self.previousFollowUpAt = previousFollowUpAt
    self.stepRevision = stepRevision
    self.evidence = evidence
    self.occurredAt = occurredAt
  }
}

public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
  public var id: String = UUID().uuidString
  public var title: String
  public var note: String
  public var source: ChangeSource
  public var date: Date
  public init(title: String, note: String, source: ChangeSource, date: Date) {
    self.title = title
    self.note = note
    self.source = source
    self.date = date
  }
}

public struct WorkItem: Codable, Identifiable, Equatable, Sendable {
  public var id: String = UUID().uuidString
  public var kind: ItemKind
  public var title: String
  public var jiraKey: String = ""
  public var jiraURL: String = ""
  public var qa: QARequirement = .undecided
  public var threadURL: String = ""
  public var notes: String = ""
  public var testingNotes: String = ""
  public var testingNotesRound: Int = 0
  public var environment: String = ""
  public var qe: String = ""
  public var waitingOn: String = ""
  public var followUpAt: Date?
  public var mergeRequests: [MergeRequest] = []
  public var actions: [ActionRecord] = []
  public var history: [HistoryEntry] = []
  public var reviewRound: Int = 0
  public var cycle: Int = 0
  public var finding: String = ""
  public var revision: Int = 0
  public var playbookVersion: Int = 1
  public var createdAt: Date = Date()
  public var updatedAt: Date = Date()
  public var completedAt: Date?
  public var workflow: WorkflowDefinition?
  public var fieldValues: [String: String]?
  /// Custom workflow paths the user chose for this item.
  public var paths: [String]?

  public init(kind: ItemKind, title: String) {
    self.kind = kind
    self.title = title
  }

  public func record(_ kind: ActionKind, mrID: String? = nil) -> ActionRecord? {
    if kind != .mergeMR, let workflow {
      guard let rule = workflow.steps.first(where: { $0.kind == kind }) else { return nil }
      return record(stepID: rule.id, mrID: mrID)
    }
    let key = Workflow.actionID(kind, mrID: mrID)
    return actions.last {
      $0.id == key
        && (kind == .mergeMR || $0.cycle == cycle)
        && (!kind.isRoundSpecific || $0.round == reviewRound)
    }
  }
  public func record(stepID: String, mrID: String? = nil) -> ActionRecord? {
    guard let rule = workflow?.steps.first(where: { $0.id == stepID }) else { return nil }
    if rule.kind == .mergeMR { return record(.mergeMR, mrID: mrID) }
    let id = mrID.map { "\(stepID):\($0)" } ?? stepID
    return actions.last {
      $0.id == id && $0.cycle == cycle && $0.stepRevision == rule.revision
        && (!rule.repeatOnRework || $0.round == reviewRound)
    }
  }
  public func has(_ kind: ActionKind, mrID: String? = nil) -> Bool {
    record(kind, mrID: mrID) != nil
  }
  public func record(for step: WorkflowStep) -> ActionRecord? {
    if let id = step.ruleID { return record(stepID: id, mrID: step.mrID) }
    return record(step.kind, mrID: step.mrID)
  }
  public var isDone: Bool {
    if workflow != nil { return ConfiguredWorkflow.isDone(self) }
    if kind == .task { return has(.taskDone) }
    return has(.jiraDone) && allMerged && Workflow.mergeBlockers(for: self).isEmpty
  }
  public var completionDate: Date? {
    guard isDone else { return nil }
    if let completedAt { return completedAt }
    return Workflow.steps(for: self)
      .filter { $0.isOptional != true && ($0.state == .completed || $0.state == .waived) }
      .compactMap { record(for: $0)?.date }.max()
  }
  public var isInQA: Bool { kind == .ticket && qa == .required && has(.qaHandoff) }
  public var needsRetest: Bool {
    guard let handoff = record(.qaHandoff) else { return false }
    return reviewRound > handoff.round
  }
  public var allApproved: Bool {
    !ticketMRs.isEmpty
      && ticketMRs.allSatisfy { has(.mergeMR, mrID: $0.id) || has(.approveMR, mrID: $0.id) }
  }
  public var allMerged: Bool {
    !ticketMRs.isEmpty && ticketMRs.allSatisfy { has(.mergeMR, mrID: $0.id) }
  }
  public var ticketMRs: [MergeRequest] { mergeRequests.filter { $0.role == .ticket } }
  public var workspaceMRs: [MergeRequest] { mergeRequests.filter { $0.role == .workspace } }
  public var identity: String? {
    guard kind == .ticket, let host = URL(string: jiraURL)?.host else { return nil }
    return "\(host.lowercased())/\(jiraKey.uppercased())"
  }
}

public struct WorkflowStep: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var kind: ActionKind
  public var title: String
  public var detail: String
  public var symbol: String
  public var state: StepState
  public var blockers: [String]
  public var isWait: Bool
  public var mrID: String?
  public var ruleID: String? = nil
  public var owner: String? = nil
  public var isOptional: Bool? = nil
  public var destination: WorkflowDestination? = nil
  public var destinationURL: String? = nil
  public var messageTemplate: String? = nil
  /// Follow-up reminder for a wait step that has waited longer than its configured nudge.
  public var nudge: String? = nil
  public var canRecord: Bool { state == .pending && blockers.isEmpty && kind != .qaDecision }
}

public struct RevisionToken: Codable, Equatable, Sendable {
  public var generation: String
  public var version: Int
  public init(generation: String, version: Int) {
    self.generation = generation
    self.version = version
  }
}

public struct ItemSnapshot: Codable, Identifiable, Equatable, Sendable {
  public var item: WorkItem
  public var token: RevisionToken
  public var steps: [WorkflowStep] { Workflow.steps(for: item) }
  public var phase: String { Workflow.phase(for: item) }
  public var nextStep: WorkflowStep? {
    guard !item.isDone else { return nil }
    let pending = steps.filter { $0.state == .pending && $0.isOptional != true }
    return pending.first { $0.canRecord && !$0.isWait }
      ?? pending.first { $0.canRecord }
      ?? pending.first
  }
  public var isWaiting: Bool {
    if item.kind == .task { return !item.waitingOn.isEmpty && !item.isDone }
    return steps.contains { $0.state == .pending && $0.isWait && $0.blockers.isEmpty }
  }
  public var hasActionableWork: Bool {
    guard !item.isDone else { return false }
    if item.kind == .task {
      return !isWaiting || (item.followUpAt.map { $0 <= Date() } ?? false)
    }
    return !isWaiting || steps.contains { ($0.canRecord && !$0.isWait) || $0.nudge != nil }
  }
  public var nudges: [WorkflowStep] { item.isDone ? [] : steps.filter { $0.nudge != nil } }
  public var id: String { item.id }
  public init(item: WorkItem, generation: String) {
    self.item = item
    self.token = RevisionToken(generation: generation, version: item.revision)
  }
}

public struct TrackerSettings: Codable, Equatable, Sendable {
  public var jiraBaseURL: String = ""
  public var jiraBoardURL: String = ""
  public var gitlabHost: String = ""
  public var teamsChannelURL: String = ""
  public var pod: String = ""
  public var qe: String = ""
  public var kickoffTemplate: String = "Starting implementation on {{ticket}}: {{title}}\n{{jira}}"
  public var approvalTemplate: String = "{{pod}} - could you review {{ticket}}?\n{{mrs}}\n{{jira}}"
  public var qaTemplate: String =
    "{{qe}} - {{ticket}} is ready for {{qa_action}}.\n{{mrs}}\n\nTesting notes:\n{{testing}}\nEnvironment: {{environment}}\n{{finding}}\n{{jira}}"
  public init() {}

  private enum CodingKeys: String, CodingKey {
    case jiraBaseURL, jiraBoardURL, gitlabHost, teamsChannelURL, pod, qe
    case kickoffTemplate, approvalTemplate, qaTemplate
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    jiraBaseURL = try values.decode(String.self, forKey: .jiraBaseURL)
    jiraBoardURL =
      try values.decodeIfPresent(String.self, forKey: .jiraBoardURL)
      ?? TrackerSettings().jiraBoardURL
    gitlabHost = try values.decode(String.self, forKey: .gitlabHost)
    teamsChannelURL = try values.decode(String.self, forKey: .teamsChannelURL)
    pod = try values.decode(String.self, forKey: .pod)
    qe = try values.decode(String.self, forKey: .qe)
    kickoffTemplate = try values.decode(String.self, forKey: .kickoffTemplate)
    approvalTemplate = try values.decode(String.self, forKey: .approvalTemplate)
    qaTemplate = try values.decode(String.self, forKey: .qaTemplate)
  }
}

public struct NewItem: Codable, Sendable {
  public var workflowID: String?
  public var kind: ItemKind
  public var title: String
  public var jira: String
  public var qa: QARequirement
  public var notes: String
  public var followUpAt: Date?
  public init(
    kind: ItemKind, title: String, jira: String = "", qa: QARequirement = .undecided,
    notes: String = "", followUpAt: Date? = nil
  ) {
    self.kind = kind
    self.title = title
    self.jira = jira
    self.qa = qa
    self.notes = notes
    self.followUpAt = followUpAt
  }
}

public struct DetailsPatch: Codable, Sendable {
  public var fieldValues: [String: String]?
  public var title: String?
  public var notes: String?
  public var threadURL: String?
  public var testingNotes: String?
  public var environment: String?
  public var qe: String?
  public var waitingOn: String?
  public var qa: QARequirement?
  public var qaReason: String?
  public var followUpAt: Date?
  public var clearFollowUp: Bool = false
  /// Replaces the item's chosen custom workflow paths.
  public var paths: [String]?
  public init() {}

  var onlyChangesImpact: Bool {
    var rest = self
    rest.fieldValues = nil
    return fieldValues?.keys.sorted() == [BragDocument.impactField] && rest.isEmpty
  }
  private var isEmpty: Bool {
    title == nil && notes == nil && threadURL == nil && testingNotes == nil && environment == nil
      && qe == nil && waitingOn == nil && qa == nil && qaReason == nil && followUpAt == nil
      && !clearFollowUp && paths == nil
  }
}

public enum ItemMutation: Codable, Sendable {
  case edit(DetailsPatch)
  case addMR(String)
  case addWorkspaceMR(String)
  case classifyMR(id: String, role: MRRole)
  case recordFact(FactInput)
  case correctCompletionTime(Date, note: String, evidence: FactEvidence)
  case adoptWorkflow(WorkflowDefinition, reason: String)
  case record(actionID: String, note: String)
  case recordExisting(actionID: String, note: String)
  case undo(actionID: String, reason: String)
  case rework(String)
  case waive(actionID: String, reason: String)
  case reopen
}

public struct MessageDraft: Codable, Sendable {
  public var text: String
  public var missing: [String]
  public var destination: String
}
