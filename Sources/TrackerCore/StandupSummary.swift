import Foundation

public struct StandupSummary: Sendable {
  public let generatedAt: Date
  public let activeTickets: [ItemSnapshot]
  public let recentlyCompleted: [ItemSnapshot]

  public init(snapshots: [ItemSnapshot], now: Date = Date()) {
    generatedAt = now
    let cutoff = now.addingTimeInterval(-48 * 60 * 60)
    var active: [ItemSnapshot] = []
    var completed: [(snapshot: ItemSnapshot, date: Date)] = []
    for snapshot in snapshots where snapshot.item.kind == .ticket {
      if !snapshot.item.isDone {
        active.append(snapshot)
      } else if let date = snapshot.item.completionDate, date >= cutoff, date <= now {
        completed.append((snapshot, date))
      }
    }
    activeTickets = active.sorted {
      let order = $0.item.jiraKey.localizedStandardCompare($1.item.jiraKey)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
    recentlyCompleted = completed.sorted {
      $0.date == $1.date ? $0.snapshot.id < $1.snapshot.id : $0.date > $1.date
    }.map(\.snapshot)
  }

  public static func mrProgress(for item: WorkItem) -> String? {
    guard !item.mergeRequests.isEmpty else { return nil }
    let approved = item.ticketMRs.filter {
      item.has(.approveMR, mrID: $0.id) || item.has(.mergeMR, mrID: $0.id)
    }.count
    let merged = item.ticketMRs.filter { item.has(.mergeMR, mrID: $0.id) }.count
    let total = item.ticketMRs.count
    let workspaceMerged = item.workspaceMRs.filter { item.has(.mergeMR, mrID: $0.id) }.count
    let optional =
      item.workspaceMRs.isEmpty
      ? "" : " · Workspace: \(workspaceMerged)/\(item.workspaceMRs.count) merged (optional)"
    return "MRs: \(approved)/\(total) approved, \(merged)/\(total) merged" + optional
  }

  public var text: String {
    var lines = [
      "Stand-up summary - \(generatedAt.formatted(date: .abbreviated, time: .omitted))",
      "",
      "Active tickets (\(activeTickets.count))",
    ]
    if activeTickets.isEmpty { lines.append("No active tickets.") }
    for snapshot in activeTickets {
      let item = snapshot.item
      lines.append("\(item.jiraKey) - \(item.title)")
      lines.append("  Status: \(snapshot.phase)")
      if let step = snapshot.nextStep {
        lines.append("  \(step.isWait ? "Waiting for" : "Next"): \(step.title)")
        if !step.blockers.isEmpty {
          lines.append("  Prerequisites: \(step.blockers.joined(separator: " "))")
        }
      }
      if !item.waitingOn.isEmpty { lines.append("  Waiting on: \(item.waitingOn)") }
      if let progress = Self.mrProgress(for: item) { lines.append("  \(progress)") }
    }
    lines += ["", "Completed in the last 48 hours (\(recentlyCompleted.count))"]
    if recentlyCompleted.isEmpty { lines.append("No recently completed tickets.") }
    for snapshot in recentlyCompleted {
      lines.append("\(snapshot.item.jiraKey) - \(snapshot.item.title)")
      if let date = snapshot.item.completionDate {
        lines.append(
          "  Completed: \(date.formatted(date: .abbreviated, time: .shortened))")
      }
    }
    return lines.joined(separator: "\n")
  }
}
