import Foundation

/// The stages a ticket spends time in, measured from confirmed workflow actions.
public enum CycleStage: String, CaseIterable, Sendable {
  case build, review, qa, merge, release

  public var title: String {
    switch self {
    case .build: "Building"
    case .review: "Pod review"
    case .qa: "QA"
    case .merge: "Waiting to merge"
    case .release: "Merge to done"
    }
  }

  public var waitingOn: String {
    switch self {
    case .build: "You"
    case .review: "Pod"
    case .qa: "QE"
    case .merge: "You"
    case .release: "Release"
    }
  }
}

/// When each milestone happened for one ticket, using the actual time when it was supplied.
public struct TicketTimeline: Sendable {
  public let started: Date
  public var reviewRequested: Date?
  public var approved: Date?
  public var qaHandoff: Date?
  public var qaPassed: Date?
  public var merged: Date?
  public var done: Date?

  public init(item: WorkItem) {
    var first: [ActionKind: Date] = [:]
    var last: [ActionKind: Date] = [:]
    for record in item.actions {
      guard let kind = Self.kind(of: record, in: item) else { continue }
      let date = record.occurredAt ?? record.date
      first[kind] = min(first[kind] ?? date, date)
      last[kind] = max(last[kind] ?? date, date)
    }
    started = first[.jiraStart] ?? first[.kickoff] ?? item.createdAt
    reviewRequested = first[.approvalRequest] ?? first[.implementation]
    approved = last[.approveMR]
    qaHandoff = first[.qaHandoff]
    qaPassed = last[.qaPassed]
    merged = item.allMerged ? last[.mergeMR] : nil
    done = item.completionDate
  }

  static func kind(of record: ActionRecord, in item: WorkItem) -> ActionKind? {
    let base = record.id.split(separator: ":").first.map(String.init) ?? record.id
    if let rule = item.workflow?.steps.first(where: { $0.id == base }) { return rule.kind }
    return ActionKind(rawValue: base)
  }

  /// Seconds spent in each stage that has both a start and an end.
  public var durations: [CycleStage: TimeInterval] {
    var result: [CycleStage: TimeInterval] = [:]
    func add(_ stage: CycleStage, _ from: Date?, _ to: Date?) {
      guard let from, let to, to >= from else { return }
      result[stage] = to.timeIntervalSince(from)
    }
    add(.build, started, reviewRequested)
    add(.review, reviewRequested, approved ?? (qaHandoff == nil ? merged : nil))
    add(.qa, qaHandoff, qaPassed)
    add(.merge, [approved, qaPassed].compactMap { $0 }.max(), merged)
    add(.release, merged, done)
    return result
  }

  /// The stage an unfinished ticket is in right now, and since when.
  public var current: (stage: CycleStage, since: Date)? {
    guard done == nil else { return nil }
    if let merged { return (.release, merged) }
    if let qaPassed { return (.merge, qaPassed) }
    if let qaHandoff { return (.qa, qaHandoff) }
    if let approved { return (.merge, approved) }
    if let reviewRequested { return (.review, reviewRequested) }
    return (.build, started)
  }
}

public struct CycleInsights: Sendable {
  public struct Ticket: Identifiable, Sendable {
    public let snapshot: ItemSnapshot
    public let durations: [CycleStage: TimeInterval]
    public let total: TimeInterval?
    public let rework: Int
    public var id: String { snapshot.id }
    public var slowest: CycleStage? { durations.max { $0.value < $1.value }?.key }
  }

  public struct Open: Identifiable, Sendable {
    public let snapshot: ItemSnapshot
    public let stage: CycleStage
    public let since: Date
    public var id: String { snapshot.id }
  }

  public let finished: [Ticket]
  public let open: [Open]
  /// Median seconds per stage across finished tickets.
  public let medians: [CycleStage: TimeInterval]
  public let medianTotal: TimeInterval?
  public let reworkShare: Double
  /// Tickets whose completion was backfilled; their recorded times are not trustworthy.
  public let excluded: Int

  public init(snapshots: [ItemSnapshot], since: Date?) {
    var finished: [Ticket] = []
    var open: [Open] = []
    var excluded = 0
    for snapshot in snapshots where snapshot.item.kind == .ticket {
      let item = snapshot.item
      let timeline = TicketTimeline(item: item)
      if let done = timeline.done {
        guard since.map({ done >= $0 }) ?? true else { continue }
        if let completedAt = item.completedAt,
          item.actions.contains(where: { $0.occurredAt == nil && $0.date > completedAt })
        {
          excluded += 1
          continue
        }
        finished.append(
          Ticket(
            snapshot: snapshot, durations: timeline.durations,
            total: done.timeIntervalSince(timeline.started), rework: item.reviewRound))
      } else if let current = timeline.current {
        open.append(Open(snapshot: snapshot, stage: current.stage, since: current.since))
      }
    }
    self.finished = finished.sorted { ($0.total ?? 0) > ($1.total ?? 0) }
    self.open = open.sorted { $0.since < $1.since }
    var medians: [CycleStage: TimeInterval] = [:]
    for stage in CycleStage.allCases {
      if let value = Self.median(finished.compactMap { $0.durations[stage] }) {
        medians[stage] = value
      }
    }
    self.medians = medians
    medianTotal = Self.median(finished.compactMap(\.total))
    reworkShare =
      finished.isEmpty
      ? 0 : Double(finished.filter { $0.rework > 0 }.count) / Double(finished.count)
    self.excluded = excluded
  }

  static func median(_ values: [TimeInterval]) -> TimeInterval? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  }

  public static func format(_ interval: TimeInterval) -> String {
    let hours = interval / 3600
    if hours < 1 { return "\(max(1, Int(interval / 60)))m" }
    if hours < 48 { return "\(Int(hours.rounded()))h" }
    return String(format: "%.1fd", hours / 24)
  }
}

/// A shareable record of finished work, for reviews and promotion packets.
public struct BragDocument: Sendable {
  public static let impactField = "brag-impact"

  public struct Entry: Identifiable, Sendable {
    public let snapshot: ItemSnapshot
    public let completed: Date
    public var id: String { snapshot.id }
    public var impact: String {
      snapshot.item.fieldValues?[BragDocument.impactField]?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
  }

  public struct Month: Identifiable, Sendable {
    public let title: String
    public let tickets: [Entry]
    public let tasks: [Entry]
    public var id: String { title }
  }

  public let months: [Month]
  public let ticketCount: Int
  public let taskCount: Int
  public let mergedMRs: Int
  public let releases: Int
  public let withoutQA: Int

  public init(
    snapshots: [ItemSnapshot], from start: Date, to end: Date = Date(),
    calendar: Calendar = .current
  ) {
    let entries = snapshots.compactMap { snapshot -> Entry? in
      guard let date = snapshot.item.completionDate, date >= start, date <= end else { return nil }
      return Entry(snapshot: snapshot, completed: date)
    }.sorted { $0.completed > $1.completed }
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.dateFormat = "MMMM yyyy"
    var order: [String] = []
    var grouped: [String: [Entry]] = [:]
    for entry in entries {
      let title = formatter.string(from: entry.completed)
      if grouped[title] == nil { order.append(title) }
      grouped[title, default: []].append(entry)
    }
    months = order.map { title in
      let list = grouped[title] ?? []
      return Month(
        title: title, tickets: list.filter { $0.snapshot.item.kind == .ticket },
        tasks: list.filter { $0.snapshot.item.kind == .task })
    }
    let tickets = entries.filter { $0.snapshot.item.kind == .ticket }
    ticketCount = tickets.count
    taskCount = entries.count - tickets.count
    mergedMRs = tickets.reduce(0) { total, entry in
      total
        + entry.snapshot.item.mergeRequests.filter {
          entry.snapshot.item.has(.mergeMR, mrID: $0.id)
        }.count
    }
    releases = Set(tickets.compactMap { $0.snapshot.item.fieldValues?["fix-version"] }).count
    withoutQA = tickets.filter { $0.snapshot.item.qa == .notRequired }.count
  }

  public func markdown(title: String) -> String {
    var lines = ["# \(title)", ""]
    var summary = ["\(ticketCount) tickets shipped", "\(mergedMRs) MRs merged"]
    if releases > 0 { summary.append("\(releases) releases") }
    if taskCount > 0 { summary.append("\(taskCount) other tasks") }
    lines.append(summary.joined(separator: " · "))
    for month in months {
      lines += ["", "## \(month.title)"]
      for entry in month.tickets {
        let item = entry.snapshot.item
        let key = item.jiraURL.isEmpty ? item.jiraKey : "[\(item.jiraKey)](\(item.jiraURL))"
        var line = "- \(key) \(item.title)"
        if let version = item.fieldValues?["fix-version"], !version.isEmpty {
          line += " (release \(version))"
        }
        lines.append(line)
        if !entry.impact.isEmpty { lines.append("  - Impact: \(entry.impact)") }
      }
      if !month.tasks.isEmpty {
        lines.append("- Also: " + month.tasks.map(\.snapshot.item.title).joined(separator: "; "))
      }
    }
    return lines.joined(separator: "\n")
  }
}
