import Foundation

public enum DraftKind: String, Codable, CaseIterable, Sendable {
  case kickoff, approvals, qa
  public var label: String {
    switch self {
    case .kickoff: "Kickoff"
    case .approvals: "Approval request"
    case .qa: "QE handoff / retest"
    }
  }
}

public enum Messages {
  public static func draft(_ kind: DraftKind, item: WorkItem, settings: TrackerSettings) throws
    -> MessageDraft
  {
    guard item.kind == .ticket else {
      throw TrackerError.invalid("Message drafts are for tickets.")
    }
    let template: String
    switch kind {
    case .kickoff: template = settings.kickoffTemplate
    case .approvals: template = settings.approvalTemplate
    case .qa: template = settings.qaTemplate
    }
    return try render(
      template, item: item, settings: settings,
      destination: kind == .kickoff ? settings.teamsChannelURL : item.threadURL)
  }
  public static func draft(actionID: String, item: WorkItem, settings: TrackerSettings) throws
    -> MessageDraft
  {
    guard let step = Workflow.steps(for: item).first(where: { $0.id == actionID }) else {
      throw TrackerError.invalid("Unknown workflow message step.")
    }
    if let template = step.messageTemplate, !template.isEmpty {
      return try render(
        template, item: item, settings: settings,
        destination: step.destination == .channel
          ? settings.teamsChannelURL
          : step.destination == .issue
            ? item.jiraURL
            : step.destination == .custom ? step.destinationURL ?? "" : item.threadURL)
    }
    let kind: DraftKind
    switch step.kind {
    case .kickoff: kind = .kickoff
    case .approvalRequest: kind = .approvals
    case .qaHandoff, .retestHandoff: kind = .qa
    default: throw TrackerError.invalid("This step has no message template.")
    }
    return try draft(kind, item: item, settings: settings)
  }
  public static func render(
    _ template: String, item: WorkItem, settings: TrackerSettings,
    destination: String
  ) throws -> MessageDraft {
    var values = [
      "ticket": item.jiraKey, "title": item.title, "jira": item.jiraURL,
      "mrs": item.ticketMRs.map(\.url).joined(separator: "\n"),
      "pod": settings.pod, "qe": item.qe.isEmpty ? settings.qe : item.qe,
      "testing": item.testingNotes, "environment": item.environment,
      "qa_action": item.needsRetest ? "retesting" : "QA",
      "finding": item.finding.isEmpty ? "" : "Finding / change: \(item.finding)",
    ]
    for field in item.workflow?.steps.flatMap(\.fields) ?? [] {
      values["field:\(field.id)"] = item.fieldValues?[field.id] ?? ""
    }
    let regex = try NSRegularExpression(pattern: #"\{\{([a-z_]+|field:[A-Za-z0-9_-]+)\}\}"#)
    var text = template
    var missing: [String] = []
    let matches = regex.matches(in: template, range: NSRange(template.startIndex..., in: template))
    for match in matches.reversed() {
      guard let nameRange = Range(match.range(at: 1), in: template),
        let fullRange = Range(match.range, in: text)
      else { throw TrackerError.invalid("Invalid message template.") }
      let name = String(template[nameRange])
      guard let value = values[name] else {
        throw TrackerError.invalid("Unknown template field: \(name).")
      }
      if value.isEmpty && name != "finding" {
        missing.append(name)
        text.replaceSubrange(fullRange, with: "[Add \(name)]")
      } else {
        text.replaceSubrange(fullRange, with: value)
      }
    }
    return MessageDraft(
      text: text, missing: Array(Set(missing)).sorted(),
      destination: destination)
  }
}
