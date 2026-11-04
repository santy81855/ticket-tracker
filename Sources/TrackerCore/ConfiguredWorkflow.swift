import Foundation

public enum ConfiguredWorkflow {
  public static func applies(_ rule: WorkflowRule, to item: WorkItem) -> Bool {
    guard rule.enabled else { return false }
    let chosen = Set(item.paths ?? [])
    if let only = rule.onlyPaths, !only.isEmpty, chosen.isDisjoint(with: only) { return false }
    if let skip = rule.skipPaths, !chosen.isDisjoint(with: skip) { return false }
    switch rule.condition {
    case .always: return true
    case .qaRequired: return item.qa == .required
    case .noQA: return item.qa == .notRequired
    case .retest: return item.qa == .required && item.needsRetest
    }
  }
  public static func actualMergeDate(_ item: WorkItem) -> Date? {
    guard !item.ticketMRs.isEmpty, item.allMerged else { return nil }
    let dates = item.ticketMRs.compactMap { item.record(.mergeMR, mrID: $0.id)?.occurredAt }
    return dates.count == item.ticketMRs.count ? dates.max() : nil
  }
  public static func fixVersion(for item: WorkItem, calendar: Calendar = .current) -> String? {
    guard let date = actualMergeDate(item) else { return nil }
    var calendar = calendar
    calendar.locale = Locale(identifier: "en_US_POSIX")
    let day = calendar.startOfDay(for: date)
    let weekday = calendar.component(.weekday, from: day)
    let distance = (3 - weekday + 7) % 7
    guard let tuesday = calendar.date(byAdding: .day, value: distance == 0 ? 7 : distance, to: day)
    else { return nil }
    let parts = calendar.dateComponents([.year, .month, .day], from: tuesday)
    guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
    return "\(year).\(month).\(day)"
  }
  private static func recordsSatisfied(_ rule: WorkflowRule, item: WorkItem) -> Bool {
    if !applies(rule, to: item) { return true }
    if [.approveMR, .mergeMR].contains(rule.kind) {
      return !item.ticketMRs.isEmpty
        && item.ticketMRs.allSatisfy {
          (rule.kind == .approveMR && item.has(.mergeMR, mrID: $0.id))
            || item.record(stepID: rule.id, mrID: $0.id) != nil
        }
    }
    return item.record(stepID: rule.id) != nil
  }
  public static func blockers(_ rule: WorkflowRule, item: WorkItem) -> [String] {
    guard let definition = item.workflow else { return ["The workflow definition is missing."] }
    var reasons: [String] = []
    var visited: Set<String> = []
    func visit(_ id: String) {
      guard visited.insert(id).inserted else { return }
      guard let dependency = definition.steps.first(where: { $0.id == id }) else {
        reasons.append("Missing workflow prerequisite \(id).")
        return
      }
      guard applies(dependency, to: item) else { return }
      if !recordsSatisfied(dependency, item: item) {
        reasons.append("Complete: \(dependency.title).")
      }
      for id in dependency.dependsOn { visit(id) }
    }
    for id in rule.dependsOn { visit(id) }
    if [.approveMR, .mergeMR, .approvalRequest].contains(rule.kind), item.ticketMRs.isEmpty {
      reasons.append("Add at least one ticket MR. Workspace MRs do not count as ticket MRs.")
    }
    if [.mergeMR, .jiraReady].contains(rule.kind), item.qa == .undecided,
      definition.steps.contains(where: { $0.enabled && $0.condition != .always })
    {
      reasons.append("Decide whether QA is required.")
    }
    return reasons + metadataBlockers(rule, item: item)
  }
  public static func metadataBlockers(_ rule: WorkflowRule, item: WorkItem) -> [String] {
    var reasons: [String] = []
    if rule.requiresThread && item.threadURL.isEmpty {
      reasons.append("Save the Teams thread link.")
    }
    if rule.requiresTesting
      && (item.testingNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || item.testingNotesRound != item.reviewRound)
    {
      reasons.append("Save testing notes for the current changes.")
    }
    return reasons + requiredFieldBlockers(rule, item: item)
  }
  public static func requiredFieldBlockers(_ rule: WorkflowRule, item: WorkItem) -> [String] {
    var reasons: [String] = []
    for field in rule.fields {
      let value = item.fieldValues?[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if value.isEmpty {
        reasons.append("Save \(field.label).")
        continue
      }
      if field.type == .fixVersion {
        if let expected = fixVersion(for: item) {
          if value != expected {
            reasons.append("\(field.label) must be \(expected), based on the last ticket MR merge.")
          }
        } else {
          reasons.append(
            "Record the actual merge date for every ticket MR before setting Fix Version/s.")
        }
      }
      if field.type == .url, (try? Workflow.validatedLink(value)) == nil {
        reasons.append("\(field.label) must be an HTTPS URL.")
      }
      if field.type == .date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        if formatter.date(from: value) == nil {
          reasons.append("\(field.label) must use yyyy-MM-dd.")
        }
      }
    }
    return reasons
  }
  /// When a pending, unblocked wait step has waited past its nudge threshold, returns the reminder.
  public static func nudge(
    _ rule: WorkflowRule, item: WorkItem, blockers: [String], state: StepState, now: Date = Date()
  ) -> String? {
    guard let hours = rule.nudgeAfterHours, rule.isWait, state == .pending, blockers.isEmpty
    else { return nil }
    let since =
      rule.dependsOn.compactMap { id -> Date? in
        if let record = item.record(stepID: id) { return record.date }
        return item.ticketMRs.compactMap { item.record(stepID: id, mrID: $0.id)?.date }.max()
      }.max() ?? item.createdAt
    let waited = now.timeIntervalSince(since)
    guard waited >= Double(hours) * 3600 else { return nil }
    let elapsed =
      waited >= 172_800 ? "\(Int(waited / 86_400)) days" : "\(Int(waited / 3600)) hours"
    return "Waiting on \(rule.owner) for \(elapsed). Time to follow up."
  }
  public static func steps(for item: WorkItem) -> [WorkflowStep] {
    guard let definition = item.workflow else { return [] }
    var blocking: Set<String> = []
    func include(_ rule: WorkflowRule) {
      guard applies(rule, to: item), blocking.insert(rule.id).inserted else { return }
      for dependency in rule.dependsOn {
        if let parent = definition.steps.first(where: { $0.id == dependency }) { include(parent) }
      }
    }
    for rule in definition.steps where rule.required { include(rule) }
    var result: [WorkflowStep] = []
    for rule in definition.steps {
      let applicable = applies(rule, to: item)
      let requests: [MergeRequest?] =
        [.approveMR, .mergeMR].contains(rule.kind)
        ? (item.ticketMRs.isEmpty ? [nil] : item.ticketMRs.map { Optional($0) }) : [nil]
      for mr in requests {
        let record = item.record(stepID: rule.id, mrID: mr?.id)
        let skip =
          !applicable
          || (rule.kind == .approveMR && mr.map { item.has(.mergeMR, mrID: $0.id) } == true)
        let state: StepState =
          skip
          ? .notApplicable : record.map { $0.state == .waived ? .waived : .completed } ?? .pending
        var title = rule.title
        if let mr { title += ": \(mr.shortName)" }
        var detail = rule.detail
        if !rule.fromColumn.isEmpty || !rule.toColumn.isEmpty {
          detail +=
            "\n\(rule.owner): \(rule.fromColumn.isEmpty ? "Current column" : rule.fromColumn) → \(rule.toColumn)."
        }
        let reasons = blockers(rule, item: item)
        var step = WorkflowStep(
          id: mr.map { "\(rule.id):\($0.id)" } ?? rule.id,
          kind: rule.kind, title: title, detail: detail,
          symbol: rule.destination == .board
            ? "rectangle.3.group" : rule.isWait ? "hourglass" : "checkmark.circle",
          state: state, blockers: reasons, isWait: rule.isWait, mrID: mr?.id,
          ruleID: rule.id, owner: rule.owner, isOptional: !blocking.contains(rule.id),
          destination: rule.destination, destinationURL: rule.url,
          messageTemplate: rule.messageTemplate)
        step.inputBlockers = metadataBlockers(rule, item: item)
        step.nudge = nudge(rule, item: item, blockers: reasons, state: state)
        result.append(step)
      }
    }
    if item.kind == .ticket && item.qa == .undecided
      && definition.steps.contains(where: { $0.enabled && $0.condition != .always })
    {
      result.append(
        WorkflowStep(
          id: "qaDecision", kind: .qaDecision, title: "Choose the QA path",
          detail: "Decide whether this ticket needs QA.", symbol: "arrow.triangle.branch",
          state: .pending, blockers: ["Choose QA in ticket details."], isWait: false, mrID: nil))
    }
    return result + workspaceSteps(for: item)
  }
  public static func workspaceSteps(for item: WorkItem) -> [WorkflowStep] {
    item.workspaceMRs.map { mr in
      WorkflowStep(
        id: Workflow.actionID(.mergeMR, mrID: mr.id), kind: .mergeMR,
        title: "Workspace MR: \(mr.shortName)",
        detail: "Optional catch-up. This never blocks ticket completion.",
        symbol: "arrow.triangle.merge",
        state: item.has(.mergeMR, mrID: mr.id) ? .completed : .pending,
        blockers: [], isWait: false, mrID: mr.id, isOptional: true, destination: .mergeRequest)
    }
  }
  public static func isDone(_ item: WorkItem) -> Bool {
    let required = steps(for: item).filter { $0.isOptional != true && $0.state != .notApplicable }
    return !required.isEmpty
      && required.allSatisfy {
        $0.state == .waived || ($0.state == .completed && $0.blockers.isEmpty)
      }
  }
  public static func mergeBlockers(_ item: WorkItem) -> [String] {
    guard let rule = item.workflow?.steps.first(where: { $0.kind == .mergeMR && $0.enabled }) else {
      return ["This workflow does not define a merge action."]
    }
    return blockers(rule, item: item)
  }
  public static func phase(_ item: WorkItem) -> String {
    if isDone(item) { return "Development complete" }
    let pending = steps(for: item).filter { $0.state == .pending && $0.isOptional != true }
    guard
      let next = pending.first(where: { $0.isActionable && !$0.isWait }) ?? pending.first(
        where: \.canRecord) ?? pending.first
    else {
      return "Needs attention"
    }
    let rule = item.workflow?.steps.first { $0.id == next.ruleID }
    if let phase = rule?.phase, !phase.isEmpty { return phase }
    return next.isWait ? "Waiting for \(next.owner ?? "confirmation")" : next.title
  }
  public static func migrationPreview(_ item: WorkItem, to target: WorkflowDefinition) throws
    -> [String]
  {
    try target.validate()
    guard target.kind == item.kind else {
      throw TrackerError.invalid("Choose a workflow for this item type.")
    }
    var probe = try migrate(item, to: target)
    probe.completedAt = nil
    var lines = [
      "Apply \(target.name) v\(target.version). Existing history and real merge facts remain."
    ]
    for step in steps(for: probe) where step.state == .pending && step.isOptional != true {
      lines.append("Still required: \(step.title)")
    }
    if probe.isDone {
      lines.append("This change completes your work without moving Jira or posting messages.")
    }
    return lines
  }
  public static func migrate(_ original: WorkItem, to target: WorkflowDefinition) throws -> WorkItem
  {
    guard !original.isDone else {
      throw TrackerError.invalid(
        "Completed tickets keep their workflow. Workspace MR catch-up does not require migration.")
    }
    try target.validate()
    guard target.kind == original.kind else {
      throw TrackerError.invalid("The workflow type does not match.")
    }
    let previous =
      original.workflow
      ?? (original.kind == .ticket ? WorkflowTemplates.legacyTicket : WorkflowTemplates.task)
    var item = original
    for i in item.actions.indices {
      if item.actions[i].id.hasPrefix("mergeMR:") { continue }
      let id = String(item.actions[i].id.split(separator: ":")[0])
      guard let old = previous.steps.first(where: { $0.id == id }),
        let new = target.steps.first(where: { $0.id == id })
      else { continue }
      if new.keepsCompletions(of: old) {
        item.actions[i].stepRevision = new.revision
      } else {
        item.actions[i].stepRevision = "inactive-\(UUID().uuidString)"
      }
    }
    item.workflow = target
    item.playbookVersion = 2
    return item
  }
}
