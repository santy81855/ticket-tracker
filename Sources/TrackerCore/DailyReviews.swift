import Foundation

public struct ReleaseSchedule: Sendable {
  public struct Entry: Identifiable, Sendable {
    public let snapshot: ItemSnapshot
    public let isProjected: Bool
    public var id: String { snapshot.id }
  }

  public struct Release: Identifiable, Sendable {
    public let version: String
    public let date: Date?
    public let entries: [Entry]
    public var id: String { version }
  }

  public let upcoming: [Release]
  public let awaitingMerge: [ItemSnapshot]
  public let recent: [Release]

  public init(
    snapshots: [ItemSnapshot], now: Date = Date(), calendar: Calendar = .current,
    recentDays: Int = 21
  ) {
    var groups: [String: [Entry]] = [:]
    var awaiting: [ItemSnapshot] = []
    for snapshot in snapshots where snapshot.item.kind == .ticket {
      let saved = snapshot.item.fieldValues?["fix-version"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let saved, !saved.isEmpty {
        groups[saved, default: []].append(Entry(snapshot: snapshot, isProjected: false))
      } else if let projected = ConfiguredWorkflow.fixVersion(
        for: snapshot.item, calendar: calendar)
      {
        groups[projected, default: []].append(Entry(snapshot: snapshot, isProjected: true))
      } else if !snapshot.item.isDone {
        awaiting.append(snapshot)
      }
    }
    let today = calendar.startOfDay(for: now)
    let cutoff = calendar.date(byAdding: .day, value: -recentDays, to: today) ?? today
    var upcoming: [Release] = []
    var recent: [Release] = []
    for (version, entries) in groups {
      let date = Self.date(for: version, calendar: calendar)
      let release = Release(
        version: version, date: date,
        entries: entries.sorted {
          $0.snapshot.item.jiraKey.localizedStandardCompare($1.snapshot.item.jiraKey)
            == .orderedAscending
        })
      if let date, date < today {
        if date >= cutoff { recent.append(release) }
      } else {
        upcoming.append(release)
      }
    }
    self.upcoming = upcoming.sorted {
      ($0.date ?? .distantFuture, $0.version) < ($1.date ?? .distantFuture, $1.version)
    }
    self.recent = recent.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    awaitingMerge = awaiting.sorted {
      $0.item.jiraKey.localizedStandardCompare($1.item.jiraKey) == .orderedAscending
    }
  }

  public static func date(for version: String, calendar: Calendar = .current) -> Date? {
    let parts = version.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
  }
}

public struct EndOfDayReview: Sendable {
  public struct Progress: Identifiable, Sendable {
    public let snapshot: ItemSnapshot
    public let steps: [String]
    public let completedItem: Bool
    public var id: String { snapshot.id }
  }

  public let generatedAt: Date
  public let doneToday: [Progress]
  public let onYou: [ItemSnapshot]
  public let waiting: [ItemSnapshot]
  public let dueTomorrow: [ItemSnapshot]

  public init(snapshots: [ItemSnapshot], now: Date = Date(), calendar: Calendar = .current) {
    generatedAt = now
    let today = calendar.startOfDay(for: now)
    let tomorrowEnd =
      calendar.date(byAdding: .day, value: 2, to: today) ?? now.addingTimeInterval(172_800)
    var done: [(Progress, Date)] = []
    for snapshot in snapshots {
      let item = snapshot.item
      // Backfilled items finished on an earlier day are history, not today's progress.
      if item.isDone, let finished = item.completionDate, finished < today { continue }
      let records = item.actions.filter { $0.date >= today && $0.date <= now }
      let titles = snapshot.steps
      var names: [String] = []
      for record in records.sorted(by: { $0.date < $1.date }) {
        let name = titles.first { $0.id == record.id }?.title ?? record.id
        if !names.contains(name) { names.append(name) }
      }
      let finished =
        item.isDone && (item.completionDate.map { $0 >= today && $0 <= now } ?? false)
      if !names.isEmpty || finished {
        let latest = records.map(\.date).max() ?? item.completionDate ?? now
        done.append((Progress(snapshot: snapshot, steps: names, completedItem: finished), latest))
      }
    }
    doneToday = done.sorted { $0.1 > $1.1 }.map(\.0)
    let active = snapshots.filter { !$0.item.isDone }.sorted {
      $0.item.jiraKey.localizedStandardCompare($1.item.jiraKey) == .orderedAscending
    }
    onYou = active.filter(\.hasActionableWork)
    waiting = active.filter { $0.isWaiting && !$0.hasActionableWork }
    dueTomorrow = active.filter { ($0.item.followUpAt ?? .distantFuture) < tomorrowEnd }
      .sorted { ($0.item.followUpAt ?? .distantFuture) < ($1.item.followUpAt ?? .distantFuture) }
  }

  private static func name(_ snapshot: ItemSnapshot) -> String {
    snapshot.item.jiraKey.isEmpty
      ? snapshot.item.title : "\(snapshot.item.jiraKey) - \(snapshot.item.title)"
  }

  public var text: String {
    var lines = [
      "End of day - \(generatedAt.formatted(date: .abbreviated, time: .omitted))", "",
      "Done today",
    ]
    if doneToday.isEmpty { lines.append("Nothing recorded today.") }
    for progress in doneToday {
      lines.append(Self.name(progress.snapshot))
      for step in progress.steps { lines.append("  ✓ \(step)") }
      if progress.completedItem { lines.append("  ✓ Completed") }
    }
    lines += ["", "Still on me"]
    if onYou.isEmpty { lines.append("Nothing.") }
    for snapshot in onYou {
      lines.append(Self.name(snapshot))
      if let step = snapshot.nextStep { lines.append("  Next: \(step.title)") }
    }
    lines += ["", "Waiting on others"]
    if waiting.isEmpty { lines.append("Nothing.") }
    for snapshot in waiting { lines.append("\(Self.name(snapshot)) - \(snapshot.phase)") }
    lines += ["", "Follow-ups by tomorrow"]
    if dueTomorrow.isEmpty { lines.append("Nothing.") }
    for snapshot in dueTomorrow {
      let due = snapshot.item.followUpAt?.formatted(date: .abbreviated, time: .shortened) ?? ""
      lines.append("\(Self.name(snapshot)) - \(due)")
    }
    return lines.joined(separator: "\n")
  }
}
