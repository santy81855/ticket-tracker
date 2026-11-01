import Foundation

public enum WorkflowCondition: String, Codable, CaseIterable, Sendable {
  case always, qaRequired, noQA, retest
}
public enum WorkflowDestination: String, Codable, CaseIterable, Sendable {
  case none, board, issue, thread, channel, mergeRequest, custom
}
public enum WorkflowFieldType: String, Codable, CaseIterable, Sendable {
  case text, date, url, fixVersion
}
public struct WorkflowField: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID().uuidString
  public var label = "Required information"
  public var type: WorkflowFieldType = .text
  public init() {}
}
public struct WorkflowRule: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var revision = "builtin-1"
  public var kind: ActionKind
  public var title: String
  public var detail = ""
  public var owner = "Me"
  public var phase = ""
  public var enabled = true
  public var required = true
  public var isWait = false
  public var repeatOnRework = false
  public var condition: WorkflowCondition = .always
  public var dependsOn: [String] = []
  public var fromColumn = ""
  public var toColumn = ""
  public var destination: WorkflowDestination = .none
  public var url = ""
  public var messageTemplate = ""
  public var requiresThread = false
  public var requiresTesting = false
  public var fields: [WorkflowField] = []
  /// When set, the step applies only to items on at least one of these custom paths.
  public var onlyPaths: [String]?
  /// The step does not apply to items on any of these custom paths.
  public var skipPaths: [String]?
  /// For wait steps: remind the user to follow up after this many hours of waiting.
  public var nudgeAfterHours: Int?
  public init(
    id: String = UUID().uuidString, kind: ActionKind = .custom, title: String = "New step"
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    repeatOnRework = kind.isRoundSpecific
  }
  /// Whether completions recorded against `old` still count; reminders alone never invalidate them.
  public func keepsCompletions(of old: WorkflowRule) -> Bool {
    var probe = self
    probe.revision = old.revision
    probe.nudgeAfterHours = old.nudgeAfterHours
    return probe == old
  }
}
public struct WorkflowPath: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var detail = ""
  public init(id: String, name: String, detail: String = "") {
    self.id = id
    self.name = name
    self.detail = detail
  }
}
public struct WorkflowDefinition: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var kind: ItemKind
  public var version = 0
  public var steps: [WorkflowRule]
  public var publishedAt: Date?
  public var publicationReason = ""
  public var publishedBy: ChangeSource = .desktop
  /// Optional custom paths (e.g. "Toggle-only change") that items can opt into.
  public var paths: [WorkflowPath]?
  public init(id: String = UUID().uuidString, name: String, kind: ItemKind, steps: [WorkflowRule]) {
    self.id = id
    self.name = name
    self.kind = kind
    self.steps = steps
  }
  public func validate() throws {
    guard !id.isEmpty, id.count <= 100,
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      name.count <= 120, (1...40).contains(steps.count), version >= 0
    else { throw TrackerError.invalid("A workflow needs a name and 1-40 steps.") }
    let ids = Set(steps.map(\.id))
    guard ids.count == steps.count, steps.contains(where: { $0.enabled && $0.required }) else {
      throw TrackerError.invalid(
        "Use unique step IDs and at least one enabled completion requirement.")
    }
    let builtins = steps.filter { $0.kind != .custom }.map(\.kind)
    guard Set(builtins).count == builtins.count else {
      throw TrackerError.invalid(
        "A built-in action can appear only once; use custom steps for additional actions.")
    }
    guard Set(steps.flatMap(\.fields).map(\.id)).count == steps.flatMap(\.fields).count else {
      throw TrackerError.invalid("Required fields must have unique IDs.")
    }
    let pathIDs = (paths ?? []).map(\.id)
    guard pathIDs.count <= 10, Set(pathIDs).count == pathIDs.count,
      (paths ?? []).allSatisfy({
        $0.id.range(of: #"^[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) != nil
          && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && $0.name.count <= 80 && $0.detail.count <= 500
      })
    else {
      throw TrackerError.invalid(
        "Use up to 10 paths with unique lowercase IDs (letters, digits, hyphens) and a name.")
    }
    for step in steps {
      guard !step.id.isEmpty, step.id.count <= 100, !step.id.contains(":"),
        !step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        step.title.count <= 240, step.detail.count <= 2000, step.owner.count <= 120,
        step.phase.count <= 120, step.fromColumn.count <= 120, step.toColumn.count <= 120,
        step.messageTemplate.count <= 4000, step.fields.count <= 8,
        step.dependsOn.allSatisfy({ ids.contains($0) && $0 != step.id })
      else {
        throw TrackerError.invalid("Invalid step fields or missing/self-referencing prerequisites.")
      }
      if step.kind != .custom && step.id != step.kind.rawValue {
        throw TrackerError.invalid("Built-in action IDs must remain stable.")
      }
      guard step.kind != .qaDecision else {
        throw TrackerError.invalid(
          "QA selection is managed automatically; use a QA condition instead.")
      }
      if kind == .task && [.approveMR, .mergeMR, .qaPassed, .jiraReady].contains(step.kind) {
        throw TrackerError.invalid("MR and QA actions belong to ticket workflows.")
      }
      _ = try Workflow.validatedLink(step.url, allowEmpty: true)
      guard !step.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        step.destination != .board
          || !step.toColumn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw TrackerError.invalid(
          "Every step needs an owner; board moves also need a destination column.")
      }
      let stepPaths = (step.onlyPaths ?? []) + (step.skipPaths ?? [])
      guard stepPaths.allSatisfy(pathIDs.contains) else {
        throw TrackerError.invalid("\(step.title) refers to a path that does not exist.")
      }
      if !stepPaths.isEmpty && [.approveMR, .qaPassed, .mergeMR].contains(step.kind) {
        throw TrackerError.invalid(
          "Paths cannot skip the \(step.kind.displayName) safeguard. Use the QA condition instead.")
      }
      if let hours = step.nudgeAfterHours {
        guard step.isWait, (1...720).contains(hours) else {
          throw TrackerError.invalid("Follow-up nudges are for wait steps, after 1-720 hours.")
        }
      }
      if step.destination == .custom && step.url.isEmpty {
        throw TrackerError.invalid("Enter the custom destination URL.")
      }
      for field in step.fields {
        guard field.id.range(of: #"^[A-Za-z0-9_-]{1,100}$"#, options: .regularExpression) != nil,
          !field.label.isEmpty,
          field.label.count <= 120, kind == .ticket || field.type != .fixVersion
        else { throw TrackerError.invalid("Invalid required field.") }
      }
      var probe = WorkItem(kind: kind, title: "Template validation")
      probe.workflow = self
      _ = try Messages.render(
        step.messageTemplate, item: probe, settings: TrackerSettings(), destination: "")
    }
    var visited: Set<String> = []
    var visiting: Set<String> = []
    func visit(_ id: String) throws {
      guard !visiting.contains(id) else {
        throw TrackerError.invalid("Workflow prerequisites contain a cycle.")
      }
      if visited.contains(id) { return }
      guard let step = steps.first(where: { $0.id == id }) else {
        throw TrackerError.invalid("A prerequisite does not exist.")
      }
      visiting.insert(id)
      for dependency in step.dependsOn { try visit(dependency) }
      visiting.remove(id)
      visited.insert(id)
    }
    for step in steps { try visit(step.id) }
  }
  public var warnings: [String] {
    var result: [String] = []
    if kind == .ticket {
      for kind in [ActionKind.approveMR, .qaPassed, .mergeMR] {
        if !steps.contains(where: { $0.kind == kind && $0.enabled && $0.required }) {
          result.append("This workflow does not require the \(kind.displayName) safeguard.")
        }
      }
    }
    for (index, step) in steps.enumerated() where step.enabled {
      for dependency in step.dependsOn {
        guard let parent = steps.firstIndex(where: { $0.id == dependency }) else { continue }
        if !steps[parent].enabled {
          result.append("\(step.title) skips its disabled prerequisite \(steps[parent].title).")
        } else if parent > index {
          result.append(
            "\(step.title) is listed before its prerequisite \(steps[parent].title). Use Fix order."
          )
        }
      }
      if !step.required && steps.contains(where: { $0.enabled && $0.dependsOn.contains(step.id) }) {
        result.append(
          "\(step.title) is optional by itself but can block steps that explicitly depend on it.")
      }
    }
    return result
  }
}
public struct WorkflowCatalog: Codable, Equatable, Sendable {
  public var history: [HistoryEntry]?
  public var revision = 0
  public var definitions: [WorkflowDefinition] = [
    WorkflowTemplates.legacyTicket, WorkflowTemplates.personal, WorkflowTemplates.task,
  ]
  public var defaultTicketID = WorkflowTemplates.legacyID
  public var defaultTaskID = WorkflowTemplates.taskID
  public init() {}
  public var latest: [WorkflowDefinition] {
    Dictionary(grouping: definitions, by: \.id).values.compactMap {
      $0.max { $0.version < $1.version }
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  public func definition(_ id: String, version: Int? = nil) -> WorkflowDefinition? {
    definitions.filter { $0.id == id && (version == nil || $0.version == version) }
      .max { $0.version < $1.version }
  }
  public func validate() throws {
    guard revision >= 0, definitions.count <= 200,
      Set(definitions.map { "\($0.id):\($0.version)" }).count == definitions.count,
      definition(defaultTicketID)?.kind == .ticket, definition(defaultTaskID)?.kind == .task
    else { throw TrackerError.invalid("Invalid workflow catalog or defaults.") }
    for definition in definitions { try definition.validate() }
  }
}
public struct WorkflowCatalogSnapshot: Codable, Sendable {
  public var catalog: WorkflowCatalog
  public var generation: String
  public init(catalog: WorkflowCatalog, generation: String) {
    self.catalog = catalog
    self.generation = generation
  }
}
public enum WorkflowCatalogMutation: Codable, Sendable {
  case publish(WorkflowDefinition, reason: String, makeDefault: Bool)
  case setDefault(id: String, reason: String)
}
public enum WorkflowTemplates {
  public static let legacyID = "original-ticket"
  public static let personalID = "developer-handoff"
  public static let taskID = "personal-task"
  public static var legacyTicket: WorkflowDefinition {
    func rule(
      _ kind: ActionKind, _ title: String, _ dependencies: [String] = [],
      condition: WorkflowCondition = .always, destination: WorkflowDestination = .none,
      owner: String = "Me", wait: Bool = false
    ) -> WorkflowRule {
      var r = WorkflowRule(id: kind.rawValue, kind: kind, title: title)
      r.dependsOn = dependencies
      r.condition = condition
      r.destination = destination
      r.owner = owner
      r.isWait = wait
      return r
    }
    var steps = [
      rule(.jiraStart, "Move Jira to implementation", destination: .board),
      rule(.kickoff, "Post the kickoff thread", ["jiraStart"], destination: .channel),
      rule(.implementation, "Finish implementation"),
      rule(
        .approvalRequest, "Request pod approvals", ["jiraStart", "kickoff", "implementation"],
        destination: .thread),
      rule(
        .approveMR, "Confirm approval", ["approvalRequest"], destination: .mergeRequest,
        owner: "Pod", wait: true),
      rule(
        .jiraValidate, "Move Jira to Validate / merge", ["implementation", "approveMR"],
        condition: .qaRequired, destination: .board),
      rule(
        .qaHandoff, "Send the QE handoff", ["jiraValidate", "approveMR", "implementation"],
        condition: .qaRequired, destination: .thread),
      rule(
        .retestHandoff, "Send the fix for QE retest", ["implementation", "approveMR", "qaHandoff"],
        condition: .retest, destination: .thread),
      rule(
        .qaPassed, "Confirm QA passed",
        ["qaHandoff", "retestHandoff", "implementation", "approveMR"], condition: .qaRequired,
        owner: "QE", wait: true),
      rule(
        .jiraReady, "Confirm QE moved Jira to Ready to deploy", ["qaPassed"],
        condition: .qaRequired, destination: .board, owner: "QE", wait: true),
      rule(
        .mergeMR, "Merge MR",
        [
          "jiraStart", "kickoff", "implementation", "approvalRequest", "approveMR", "qaHandoff",
          "retestHandoff", "qaPassed", "jiraReady",
        ], destination: .mergeRequest),
      rule(.jiraDone, "Move Jira to Done", ["mergeMR"], destination: .board),
    ]
    for i in steps.indices {
      steps[i].detail = steps[i].title + ". Record only what actually happened."
      steps[i].requiresThread = [.kickoff, .approvalRequest, .qaHandoff, .retestHandoff].contains(
        steps[i].kind)
      steps[i].requiresTesting = [.qaHandoff, .retestHandoff].contains(steps[i].kind)
    }
    steps[0].toColumn = "Implementation in progress"
    steps[5].fromColumn = "Implementation in progress"
    steps[5].toColumn = "Validate / merge"
    steps[9].fromColumn = "Validate / merge"
    steps[9].toColumn = "Ready to deploy"
    steps[11].toColumn = "Done"
    var result = WorkflowDefinition(
      id: legacyID, name: "Original ticket workflow", kind: .ticket, steps: steps)
    result.version = 1
    return result
  }
  public static var personal: WorkflowDefinition {
    var result = legacyTicket
    result.id = personalID
    result.name = "Developer handoff"
    result.steps.removeAll { $0.kind == .jiraDone }
    if let i = result.steps.firstIndex(where: { $0.kind == .mergeMR }) {
      result.steps[i].dependsOn.removeAll { $0 == "jiraReady" }
    }
    if let i = result.steps.firstIndex(where: { $0.kind == .jiraReady }) {
      var ready = result.steps.remove(at: i)
      ready.title = "Move Jira to Ready to deploy and set Fix Version/s"
      ready.detail =
        "After merging ticket MRs, set Fix Version/s to the Tuesday after the last ticket MR merge date, then confirm the board move. The PO owns subsequent Jira work."
      ready.owner = "Me"
      ready.isWait = false
      ready.dependsOn = ["mergeMR", "qaPassed"]
      var field = WorkflowField()
      field.id = "fix-version"
      field.label = "Fix Version/s"
      field.type = .fixVersion
      ready.fields = [field]
      result.steps.append(ready)
    }
    var merged = WorkflowRule(id: "merged-notice", title: "Post \"merged\" in the Teams thread")
    merged.dependsOn = ["mergeMR"]
    merged.destination = .thread
    merged.requiresThread = true
    merged.messageTemplate = "merged"
    merged.detail = "Post merged in the existing ticket thread. Preparing a draft does not post it."
    result.steps.append(merged)
    return result
  }
  public static var task: WorkflowDefinition {
    var r = WorkflowRule(id: "taskDone", kind: .taskDone, title: "Complete task")
    r.detail = "Finish this personal task."
    var result = WorkflowDefinition(id: taskID, name: "Personal task", kind: .task, steps: [r])
    result.version = 1
    return result
  }
}
