import Foundation

public enum Workflow {
  public static func actionID(_ kind: ActionKind, mrID: String? = nil) -> String {
    mrID.map { "\(kind.rawValue):\($0)" } ?? kind.rawValue
  }

  public static func steps(for item: WorkItem) -> [WorkflowStep] {
    if item.workflow != nil { return ConfiguredWorkflow.steps(for: item) }
    func needs(_ test: Bool, _ message: String) -> [String] { test ? [] : [message] }
    func step(
      _ kind: ActionKind, _ title: String, _ detail: String, _ symbol: String,
      blockers: [String] = [], wait: Bool = false, mr: MergeRequest? = nil, applicable: Bool = true
    ) -> WorkflowStep {
      let record = item.record(kind, mrID: mr?.id)
      let state: StepState =
        !applicable
        ? .notApplicable : record.map { $0.state == .waived ? .waived : .completed } ?? .pending
      return WorkflowStep(
        id: actionID(kind, mrID: mr?.id), kind: kind, title: title, detail: detail, symbol: symbol,
        state: state, blockers: blockers, isWait: wait, mrID: mr?.id
      )
    }
    if item.kind == .task {
      return [step(.taskDone, "Complete task", "Mark this task as finished.", "checkmark")]
    }
    let hasThread = !item.threadURL.isEmpty
    let initial =
      needs(item.has(.jiraStart), "Confirm Jira is in Implementation in progress.")
      + needs(item.has(.kickoff), "Post and confirm the kickoff thread.")
    let implementation = needs(
      item.has(.implementation),
      item.isInQA ? "Complete the requested fix." : "Finish implementation.")
    let mrLinks = needs(!item.ticketMRs.isEmpty, "Add at least one ticket merge request.")
    let approvals = needs(
      item.allApproved, "Record the required pod approvals for every current MR.")
    let testing = needs(
      !item.testingNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && item.testingNotesRound == item.reviewRound,
      "Save testing notes for the current changes (or explain why none apply)."
    )
    let thread = needs(hasThread, "Save the Teams thread link.")
    let qaApplies = item.qa == .required
    var result = [
      step(
        .jiraStart, "Move Jira to implementation", "Confirm Implementation in progress in Jira.",
        "rectangle.3.group"),
      step(
        .kickoff, "Post the kickoff thread",
        "Announce the ticket in your Teams channel, then save its thread link.",
        "bubble.left.and.bubble.right",
        blockers: needs(item.has(.jiraStart), "Confirm the Jira implementation move.") + thread),
      step(
        .implementation, item.isInQA ? "Complete the QA fix" : "Finish implementation",
        item.isInQA ? item.finding : "Prepare the changes and associated merge requests.", "hammer"),
      step(
        .approvalRequest, "Request pod approvals",
        "Post the MR links and mention the pod in the existing Teams thread.", "person.2",
        blockers: initial + implementation + mrLinks + thread),
    ]
    for mr in item.ticketMRs {
      result.append(
        step(
          .approveMR, "Confirm approval: \(mr.shortName)",
          "Record that the required approvals were received.", "checkmark.shield",
          blockers: needs(item.has(.approvalRequest), "Post the current approval request first."),
          wait: true, mr: mr,
          applicable: !item.has(.mergeMR, mrID: mr.id)))
    }
    if item.qa == .undecided {
      result.append(
        step(
          .qaDecision, "Decide whether QA is needed", "Choose the QA path in ticket details.",
          "arrow.triangle.branch",
          blockers: ["Choose QA required or No QA needed in ticket details."]))
    }
    result += [
      step(
        .jiraValidate, "Move Jira to Validate / merge",
        "Confirm the board move before the QE handoff.", "rectangle.3.group",
        blockers: initial + implementation + approvals, applicable: qaApplies),
      step(
        .qaHandoff, "Send the QE handoff",
        "Post testing notes and select the actual QE mention in the Teams thread.", "paperplane",
        blockers: needs(item.has(.jiraValidate), "Confirm Jira is in Validate / merge.") + approvals
          + implementation + thread + testing,
        applicable: qaApplies),
    ]
    let retest = item.needsRetest
    if retest {
      result.append(
        step(
          .retestHandoff, "Send the fix for QE retest",
          "Update the existing thread with the fix and current testing notes.", "arrow.clockwise",
          blockers: implementation + approvals + thread + testing, applicable: qaApplies))
    }
    let handoff = needs(
      item.has(retest ? .retestHandoff : .qaHandoff),
      retest ? "Post the retest update to the QE." : "Post the QE handoff.")
    result += [
      step(
        .qaPassed, "Confirm QA passed", "The QE must confirm the current changes pass testing.",
        "checkmark.seal",
        blockers: handoff + implementation + approvals, wait: true, applicable: qaApplies),
      step(
        .jiraReady, "Confirm QE moved Jira to Ready to deploy",
        "This board move belongs to the QE. Record it after it happens.", "shippingbox",
        blockers: needs(item.has(.qaPassed), "Confirm QA passed for the current changes."),
        wait: true, applicable: qaApplies),
    ]
    let mergeBlockers = mergeBlockers(for: item)
    for mr in item.ticketMRs {
      result.append(
        step(
          .mergeMR, "Merge \(mr.shortName)", "Merge in GitLab, then confirm it here.",
          "arrow.triangle.merge",
          blockers: mergeBlockers, mr: mr))
    }
    result.append(
      step(
        .jiraDone, "Move Jira to Done", "Confirm the final board move. Your work is complete.",
        "flag.checkered",
        blockers: mergeBlockers + needs(item.allMerged, "Confirm all relevant MRs are merged.")))
    return result + ConfiguredWorkflow.workspaceSteps(for: item)
  }

  public static func mergeBlockers(for item: WorkItem) -> [String] {
    if item.workflow != nil { return ConfiguredWorkflow.mergeBlockers(item) }
    var reasons: [String] = []
    func require(_ value: Bool, _ reason: String) { if !value { reasons.append(reason) } }
    require(item.has(.jiraStart), "Confirm Jira was moved to implementation.")
    require(item.has(.kickoff), "Confirm the kickoff thread was posted.")
    require(item.has(.implementation), "Complete the current implementation or fix.")
    require(item.has(.approvalRequest), "Confirm the current approval request was posted.")
    require(item.allApproved, "Confirm required approvals for every current MR.")
    require(item.qa != .undecided, "Decide whether QA is required.")
    if item.qa == .required {
      require(item.has(.jiraValidate), "Confirm Jira is in Validate / merge.")
      require(item.has(.qaHandoff), "Confirm the QE handoff was posted.")
      if item.needsRetest {
        require(item.has(.retestHandoff), "Confirm the fix/retest update was posted.")
      }
      require(item.has(.qaPassed), "Confirm the QE passed the current changes.")
      require(item.has(.jiraReady), "Confirm the QE moved Jira to Ready to deploy.")
    }
    return reasons
  }

  public static func lastRecordedStep(for item: WorkItem) -> WorkflowStep? {
    let current = steps(for: item)
    for record in item.actions.reversed() {
      if let step = current.first(where: { $0.id == record.id }),
        step.state == .completed || step.state == .waived,
        item.record(for: step) == record
      {
        return step
      }
    }
    return nil
  }

  public static func phase(for item: WorkItem) -> String {
    if item.workflow != nil { return ConfiguredWorkflow.phase(item) }
    if item.isDone { return "Done" }
    if item.kind == .task {
      return item.waitingOn.isEmpty ? "Personal task" : "Waiting on \(item.waitingOn)"
    }
    if item.has(.jiraDone) { return "Needs reconciliation" }
    if item.isInQA {
      if mergeBlockers(for: item).isEmpty { return "Ready to merge" }
      if !item.has(.implementation) { return "QA · Fix requested" }
      if !item.allApproved { return "QA · Awaiting approvals" }
      if item.needsRetest && !item.has(.retestHandoff) { return "QA · Fix ready for retest" }
      return "QA · Waiting for QE"
    }
    if item.qa == .notRequired && mergeBlockers(for: item).isEmpty { return "Ready to merge" }
    if item.has(.approvalRequest) {
      if !item.allApproved { return "Awaiting approvals" }
      switch item.qa {
      case .required: return item.has(.jiraValidate) ? "Ready for QA handoff" : "Ready for QA"
      case .undecided: return "QA decision needed"
      case .notRequired: return "Review complete"
      }
    }
    if item.has(.implementation) { return "Ready for review" }
    return "Implementation"
  }

  public static func create(_ input: NewItem, settings: TrackerSettings) throws -> WorkItem {
    var item = WorkItem(
      kind: input.kind, title: input.title.trimmingCharacters(in: .whitespacesAndNewlines))
    item.qa = input.qa
    item.notes = input.notes
    item.followUpAt = input.followUpAt
    if input.kind == .ticket {
      let jira = try jiraIdentity(input.jira, baseURL: settings.jiraBaseURL)
      item.jiraURL = jira.url
      item.jiraKey = jira.key
    }
    try validate(item)
    return item
  }

  public static func apply(
    _ mutation: ItemMutation, to original: WorkItem, source: ChangeSource, now: Date = Date()
  ) throws -> WorkItem {
    var item = original
    let wasDone = original.isDone
    if wasDone && item.completedAt == nil { item.completedAt = original.completionDate }
    var eventTitle = ""
    var eventNote = ""
    if item.isDone {
      switch mutation {
      case .reopen, .undo, .addWorkspaceMR, .correctCompletionTime: break
      case .classifyMR(_, let role) where role == .workspace: break
      // The brag-doc impact note describes finished work, so it stays editable.
      case .edit(let patch) where patch.onlyChangesImpact: break
      case .record(let id, _), .recordExisting(let id, _):
        guard original.workspaceMRs.contains(where: { actionID(.mergeMR, mrID: $0.id) == id })
        else {
          throw TrackerError.invalid("Only workspace MR catch-up can be recorded after completion.")
        }
      case .recordFact(let fact):
        guard
          original.workspaceMRs.contains(where: { actionID(.mergeMR, mrID: $0.id) == fact.actionID }
          )
        else {
          throw TrackerError.invalid("Only workspace MR catch-up can be recorded after completion.")
        }
      default: throw TrackerError.invalid("Reopen this completed item before changing it.")
      }
    }
    switch mutation {
    case .correctCompletionTime(let date, let note, let evidence):
      guard wasDone else {
        throw TrackerError.invalid("Only completed items have a completion time to correct.")
      }
      guard date.timeIntervalSince1970.isFinite, date <= now else {
        throw TrackerError.invalid(
          "The actual completion time must be valid and not in the future.")
      }
      let reason = note.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !reason.isEmpty else {
        throw TrackerError.invalid("Explain how the actual completion time is known.")
      }
      let previous = original.completionDate?.ISO8601Format() ?? "not recorded"
      item.completedAt = date
      eventTitle = "Completion time corrected"
      eventNote = """
        Previous: \(previous). Actual completion: \(date.ISO8601Format()).
        Evidence: \(evidence.rawValue).
        \(reason)
        """
    case .edit(let patch):
      if let values = patch.fieldValues {
        guard values.count <= 100,
          values.allSatisfy({ !$0.key.isEmpty && $0.key.count <= 100 && $0.value.count <= 4000 })
        else {
          throw TrackerError.invalid("Workflow field values are too large.")
        }
        item.fieldValues = (item.fieldValues ?? [:]).merging(values) { _, value in value }
      }
      if let value = patch.title {
        item.title = value.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if let value = patch.notes { item.notes = value }
      if let value = patch.threadURL { item.threadURL = try validatedLink(value, allowEmpty: true) }
      if let value = patch.testingNotes {
        item.testingNotes = value
        item.testingNotesRound = item.reviewRound
      }
      if let value = patch.environment { item.environment = value }
      if let value = patch.qe { item.qe = value }
      if let value = patch.waitingOn { item.waitingOn = value }
      if patch.clearFollowUp {
        item.followUpAt = nil
      } else if let value = patch.followUpAt {
        item.followUpAt = value
      }
      if let requested = patch.paths {
        let chosen = Array(Set(requested)).sorted()
        let known = Set((item.workflow?.paths ?? []).map(\.id))
        guard chosen.allSatisfy(known.contains) else {
          throw TrackerError.invalid("Choose paths defined by this item's workflow.")
        }
        if chosen != (item.paths ?? []).sorted() {
          item.paths = chosen.isEmpty ? nil : chosen
          let names = (item.workflow?.paths ?? []).filter { chosen.contains($0.id) }.map(\.name)
          eventNote = names.isEmpty ? "Standard path" : "Paths: " + names.joined(separator: ", ")
        }
      }
      if let qa = patch.qa, qa != item.qa {
        if qa == .notRequired
          && (patch.qaReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          throw TrackerError.invalid("Include your explicit reason for not requiring QA.")
        }
        item.qa = qa
        eventNote = [eventNote, patch.qaReason ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
      }
      eventTitle = "Details updated"
    case .addMR(let link), .addWorkspaceMR(let link):
      let role: MRRole
      if case .addWorkspaceMR = mutation { role = .workspace } else { role = .ticket }
      guard item.kind == .ticket else {
        throw TrackerError.invalid("Personal tasks do not have merge requests.")
      }
      let url = try validatedMRLink(link)
      guard !item.mergeRequests.contains(where: { $0.url == url }) else { return item }
      guard item.mergeRequests.count < 20 else {
        throw TrackerError.invalid("A ticket supports up to 20 MRs.")
      }
      if role == .ticket && (item.has(.approvalRequest) || item.isInQA) {
        item.reviewRound += 1
        item.testingNotesRound = -1
      }
      var mr = MergeRequest(url: url)
      mr.classification = role
      item.mergeRequests.append(mr)
      eventTitle = role == .workspace ? "Optional workspace MR added" : "Merge request added"
      eventNote = url
    case .classifyMR(let id, let role):
      guard let index = item.mergeRequests.firstIndex(where: { $0.id == id }) else {
        throw TrackerError.invalid("Unknown MR.")
      }
      if role == .ticket && item.mergeRequests[index].role == .workspace {
        guard !wasDone else {
          throw TrackerError.invalid("Reopen before adding a ticket-blocking MR.")
        }
        item.reviewRound += 1
        item.testingNotesRound = -1
      }
      item.mergeRequests[index].classification = role
      eventTitle = "MR classified as \(role.rawValue)"
      eventNote = item.mergeRequests[index].url
    case .adoptWorkflow(let definition, let reason):
      guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw TrackerError.invalid("Explain the user-requested workflow migration.")
      }
      item = try ConfiguredWorkflow.migrate(item, to: definition)
      eventTitle = "Applied \(definition.name) v\(definition.version)"
      eventNote = reason
    case .record, .recordExisting, .recordFact:
      let actionID: String
      let note: String
      let catchUp: Bool
      let evidence: FactEvidence
      let occurredAt: Date?
      switch mutation {
      case .record(let id, let text):
        actionID = id
        note = text
        catchUp = false
        evidence = .userConfirmed
        occurredAt = nil
      case .recordExisting(let id, let text):
        actionID = id
        note = text
        catchUp = true
        evidence = .userConfirmed
        occurredAt = nil
      case .recordFact(let fact):
        actionID = fact.actionID
        note = fact.note
        evidence = fact.evidence
        occurredAt = fact.occurredAt
        catchUp = true
      default: throw TrackerError.invalid("Invalid fact request.")
      }
      if case .recordExisting = mutation, source != .desktop {
        throw TrackerError.invalid(
          "Use an evidenced fact to report an already-performed action.")
      }
      guard let step = steps(for: item).first(where: { $0.id == actionID }) else {
        throw TrackerError.invalid("Unknown workflow action.")
      }
      guard step.kind != .qaDecision else {
        throw TrackerError.invalid("Choose QA in ticket details.")
      }
      let isBoard =
        step.destination == .board
        || [.jiraStart, .jiraValidate, .jiraReady, .jiraDone].contains(step.kind)
      if isBoard && evidence != .userConfirmed {
        throw TrackerError.invalid("Jira column moves require explicit user confirmation.")
      }
      if let occurredAt, occurredAt > now.addingTimeInterval(300) {
        throw TrackerError.invalid("The actual event time cannot be in the future.")
      }
      if step.kind == .mergeMR {
        guard let id = step.mrID, item.mergeRequests.contains(where: { $0.id == id }) else {
          throw TrackerError.invalid("Choose an actual MR, not an aggregate placeholder.")
        }
        if item.workflow != nil && occurredAt == nil
          && item.ticketMRs.contains(where: { $0.id == id })
        {
          throw TrackerError.invalid(
            "Provide the actual merged_at timestamp. Do not substitute the tracker recording time for an older merge."
          )
        }
      }
      let enrichingMerge =
        step.kind == .mergeMR && step.state == .completed
        && occurredAt != nil && item.record(for: step)?.occurredAt == nil
      guard step.state == .pending || enrichingMerge else {
        throw TrackerError.invalid("This action is already recorded or not applicable.")
      }
      if !catchUp && !enrichingMerge && !step.blockers.isEmpty {
        throw TrackerError.blocked(step.blockers)
      }
      if let rule = item.workflow?.steps.first(where: { $0.id == step.ruleID }) {
        let fields = ConfiguredWorkflow.metadataBlockers(rule, item: item)
        if !fields.isEmpty { throw TrackerError.blocked(fields) }
      }
      if (source == .copilot && step.kind.isExternal) || catchUp {
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw TrackerError.invalid(
            "Include evidence of the action performed/verified, or the user's explicit report.")
        }
      }
      item.actions.append(
        ActionRecord(
          id: actionID, cycle: item.cycle, round: item.reviewRound, state: .completed,
          source: source, note: note, date: now,
          previousFollowUpAt: item.workflow == nil
            && (step.kind == .jiraDone || step.kind == .taskDone)
            ? item.followUpAt : nil,
          stepRevision: item.workflow?.steps.first(where: { $0.id == step.ruleID })?.revision,
          evidence: evidence, occurredAt: occurredAt
        ))
      eventTitle = step.title
      eventNote = catchUp ? "Reported existing state. \(note)" : note
      if item.workflow == nil && (step.kind == .jiraDone || step.kind == .taskDone) {
        item.followUpAt = nil
      }
    case .undo(let actionID, let reason):
      guard source == .desktop else {
        throw TrackerError.invalid("Undoing a confirmation is a desktop-only correction.")
      }
      guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw TrackerError.invalid("Explain why this confirmation is being undone.")
      }
      guard let step = lastRecordedStep(for: item), step.id == actionID,
        let record = item.record(for: step),
        let index = item.actions.lastIndex(of: record)
      else {
        throw TrackerError.invalid("Only the most recent current confirmation can be undone.")
      }
      item.actions.remove(at: index)
      if wasDone || (item.workflow == nil && (step.kind == .jiraDone || step.kind == .taskDone)) {
        item.followUpAt = record.previousFollowUpAt
      }
      eventTitle = "Undid confirmation: \(step.title)"
      eventNote = "\(reason)\nTracker correction only; no external action was reversed."
    case .rework(let note):
      guard item.kind == .ticket else {
        throw TrackerError.invalid("Only tickets have review rounds.")
      }
      guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw TrackerError.invalid("Describe the finding or material change.")
      }
      item.reviewRound += 1
      item.finding = note
      item.testingNotesRound = -1
      eventTitle =
        item.isInQA ? "QA finding recorded · ticket stays in QA" : "Implementation changes recorded"
      eventNote = note
    case .waive(let actionID, let reason):
      guard source == .desktop else {
        throw TrackerError.invalid("Only the desktop user can waive a step.")
      }
      guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw TrackerError.invalid("Explain why this requirement is being waived.")
      }
      let procedural: Set<ActionKind> = [
        .jiraStart, .kickoff, .approvalRequest, .jiraValidate, .qaHandoff, .retestHandoff,
      ]
      guard let step = steps(for: item).first(where: { $0.id == actionID }),
        step.state == .pending, procedural.contains(step.kind) || step.kind == .custom
      else {
        throw TrackerError.invalid(
          "Only pending procedural handoff steps can be waived. Approval, QA, merge, and Done facts must be recorded."
        )
      }
      item.actions.append(
        ActionRecord(
          id: actionID, cycle: item.cycle, round: item.reviewRound, state: .waived,
          source: source, note: reason, date: now,
          stepRevision: item.workflow?.steps.first(where: { $0.id == step.ruleID })?.revision
        ))
      eventTitle = "Waived: \(step.title)"
      eventNote = reason
    case .reopen:
      guard item.isDone else { throw TrackerError.invalid("This item is already open.") }
      item.cycle += 1
      item.reviewRound += 1
      item.finding = ""
      item.testingNotesRound = -1
      eventTitle = "Item reopened"
    }
    try validate(item)
    if wasDone && !item.isDone {
      switch mutation {
      case .reopen, .undo: break
      default:
        throw TrackerError.invalid(
          "This change would reopen a completed ticket. Reopen it explicitly first.")
      }
    }
    if item.isDone {
      if !wasDone {
        item.completedAt = now
        if item.actions.count > original.actions.count {
          item.actions[item.actions.count - 1].previousFollowUpAt = original.followUpAt
        }
        item.followUpAt = nil
      }
    } else {
      item.completedAt = nil
    }
    item.updatedAt = now
    item.history.append(HistoryEntry(title: eventTitle, note: eventNote, source: source, date: now))
    return item
  }

  public static func validate(_ item: WorkItem) throws {
    guard !item.title.isEmpty, item.title.count <= 240 else {
      throw TrackerError.invalid("Use a title between 1 and 240 characters.")
    }
    guard (1...2).contains(item.playbookVersion), item.revision >= 0, item.cycle >= 0,
      item.reviewRound >= 0, (item.playbookVersion == 1) == (item.workflow == nil)
    else {
      throw TrackerError.invalid("Unsupported or invalid item version.")
    }
    if let definition = item.workflow {
      guard item.playbookVersion == 2, definition.kind == item.kind else {
        throw TrackerError.invalid("The captured workflow does not match this item.")
      }
      try definition.validate()
    }
    guard item.notes.count <= 100_000, item.testingNotes.count <= 100_000,
      item.finding.count <= 20_000,
      item.environment.count <= 1_000, item.qe.count <= 1_000, item.waitingOn.count <= 1_000
    else {
      throw TrackerError.invalid("One of the text fields is too long.")
    }
    guard (item.paths ?? []).count <= 10, (item.paths ?? []).allSatisfy({ $0.count <= 40 }) else {
      throw TrackerError.invalid("Too many workflow paths.")
    }
    if item.kind == .ticket {
      _ = try jiraIdentity(item.jiraURL, baseURL: "")
      guard !item.jiraKey.isEmpty else { throw TrackerError.invalid("A Jira key is required.") }
    }
    _ = try validatedLink(item.threadURL, allowEmpty: true)
    guard item.mergeRequests.count <= 20,
      Set(item.mergeRequests.map(\.id)).count == item.mergeRequests.count,
      Set(item.mergeRequests.map(\.url)).count == item.mergeRequests.count
    else {
      throw TrackerError.invalid("Invalid or duplicate merge requests.")
    }
    for mr in item.mergeRequests { _ = try validatedMRLink(mr.url) }
  }

  public static func validatedMRLink(_ text: String) throws -> String {
    let link = try validatedLink(text)
    guard var parts = URLComponents(string: link) else {
      throw TrackerError.invalid("Invalid MR URL.")
    }
    let segments = parts.path.split(separator: "/")
    guard let index = segments.firstIndex(of: "merge_requests"), index > 0,
      segments.indices.contains(index + 1), !segments[index + 1].isEmpty,
      segments[index + 1].allSatisfy(\.isNumber)
    else {
      throw TrackerError.invalid("Use a GitLab MR link ending in /merge_requests/123.")
    }
    parts.path = "/" + segments.prefix(index + 2).joined(separator: "/")
    parts.query = nil
    parts.fragment = nil
    guard let canonical = parts.url?.absoluteString else {
      throw TrackerError.invalid("Invalid MR URL.")
    }
    return canonical
  }

  public static func validatedLink(_ text: String, allowEmpty: Bool = false) throws -> String {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if allowEmpty && value.isEmpty { return "" }
    guard var parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
      let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil
    else {
      throw TrackerError.invalid("Use a full HTTPS URL without embedded credentials.")
    }
    parts.scheme = "https"
    parts.host = host.lowercased()
    if parts.path.hasSuffix("/") { parts.path.removeLast() }
    guard let canonical = parts.url?.absoluteString else {
      throw TrackerError.invalid("Invalid URL.")
    }
    return canonical
  }

  public static func jiraBoardLink(_ boardURL: String, issueKey: String) throws -> String {
    let validated = try validatedLink(boardURL)
    guard var parts = URLComponents(string: validated), let host = parts.host else {
      throw TrackerError.invalid("Set a valid Kanban board URL in workspace settings.")
    }
    let key = try jiraIdentity(issueKey, baseURL: "https://\(host)").key
    var query = (parts.queryItems ?? []).filter { $0.name.lowercased() != "selectedissue" }
    query.append(URLQueryItem(name: "selectedIssue", value: key))
    parts.queryItems = query
    guard let result = parts.url?.absoluteString else {
      throw TrackerError.invalid("The Kanban board URL could not be constructed.")
    }
    return result
  }

  public static func jiraIdentity(_ input: String, baseURL: String) throws -> (
    key: String, url: String
  ) {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let key: String
    let link: String
    if value.lowercased().hasPrefix("https://") {
      link = try validatedLink(value)
      guard let component = URL(string: link)?.lastPathComponent else {
        throw TrackerError.invalid("Missing Jira key.")
      }
      key = component.uppercased()
    } else {
      key = value.uppercased()
      let base = try validatedLink(baseURL)
      link = "\(base)/browse/\(key)"
    }
    guard key.range(of: #"^[A-Z][A-Z0-9_]*-[0-9]+$"#, options: .regularExpression) != nil else {
      throw TrackerError.invalid("Use a Jira ticket URL or key such as PROJ-123.")
    }
    return (key, link)
  }
}
