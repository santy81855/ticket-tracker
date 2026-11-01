import Foundation
import Testing

@testable import TrackerCore

private let hour: TimeInterval = 3600

private func ticket(_ key: String, qa: QARequirement = .notRequired) throws -> WorkItem {
  var item = try Workflow.create(
    NewItem(
      kind: .ticket, title: "Ticket \(key)", jira: "https://jira.example.test/browse/\(key)", qa: qa
    ),
    settings: TrackerSettings())
  var patch = DetailsPatch()
  patch.threadURL = "https://teams.example.test/thread/\(key)"
  item = try Workflow.apply(.edit(patch), to: item, source: .desktop)
  return try Workflow.apply(
    .addMR("https://gitlab.example.test/pod/app/-/merge_requests/\(key.count)"), to: item,
    source: .desktop)
}

private func step(_ id: String, _ item: WorkItem, at date: Date) throws -> WorkItem {
  try Workflow.apply(.record(actionID: id, note: ""), to: item, source: .desktop, now: date)
}

/// Builds a no-QA ticket whose build, review and merge each take a known number of hours.
private func finished(_ key: String, start: Date) throws -> WorkItem {
  var item = try ticket(key)
  let mr = item.mergeRequests[0].id
  item = try step("jiraStart", item, at: start)
  item = try step("kickoff", item, at: start)
  item = try step("implementation", item, at: start.addingTimeInterval(4 * hour))
  item = try step("approvalRequest", item, at: start.addingTimeInterval(4 * hour))
  item = try step(
    Workflow.actionID(.approveMR, mrID: mr), item, at: start.addingTimeInterval(6 * hour))
  item = try step(
    Workflow.actionID(.mergeMR, mrID: mr), item, at: start.addingTimeInterval(7 * hour))
  return try step("jiraDone", item, at: start.addingTimeInterval(8 * hour))
}

private func snapshots(_ items: [WorkItem]) -> [ItemSnapshot] {
  items.map { ItemSnapshot(item: $0, generation: "test") }
}

@Test func cycleInsightsMeasureStagesAndSkipBackfilledTickets() throws {
  let start = Date(timeIntervalSince1970: 1_800_000_000)
  let measured = try finished("WEB-1", start: start)
  var backfilled = try finished("WEB-2", start: start)
  backfilled = try Workflow.apply(
    .correctCompletionTime(
      start.addingTimeInterval(-30 * 24 * hour), note: "Finished last month.",
      evidence: .userConfirmed),
    to: backfilled, source: .copilot, now: start.addingTimeInterval(9 * hour))

  let insights = CycleInsights(snapshots: snapshots([measured, backfilled]), since: nil)

  #expect(insights.finished.map(\.id) == [measured.id])
  #expect(insights.excluded == 1)
  #expect(insights.medians[.build] == 4 * hour)
  #expect(insights.medians[.review] == 2 * hour)
  #expect(insights.medians[.merge] == hour)
  #expect(insights.medians[.release] == hour)
  #expect(insights.medianTotal == 8 * hour)
}

@Test func endOfDayReviewIgnoresTicketsBackfilledToAnEarlierDay() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
  let now = today.addingTimeInterval(12 * hour)
  let shippedToday = try finished("WEB-1", start: today.addingTimeInterval(60))
  var backfilled = try finished("WEB-2", start: today.addingTimeInterval(60))
  backfilled = try Workflow.apply(
    .correctCompletionTime(
      today.addingTimeInterval(-26 * hour), note: "Yesterday.", evidence: .userConfirmed),
    to: backfilled, source: .copilot, now: now)

  let review = EndOfDayReview(
    snapshots: snapshots([shippedToday, backfilled]), now: now, calendar: calendar)

  #expect(review.doneToday.map(\.id) == [shippedToday.id])
  #expect(review.doneToday.first?.completedItem == true)
  #expect(review.text.contains("WEB-1"))
  #expect(!review.text.contains("WEB-2"))
}

@Test func releaseScheduleSplitsUpcomingRecentAndAwaitingMerge() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5))!
  func saved(_ key: String, _ version: String) throws -> WorkItem {
    var patch = DetailsPatch()
    patch.fieldValues = ["fix-version": version]
    return try Workflow.apply(.edit(patch), to: try ticket(key), source: .desktop)
  }
  let upcoming = try saved("WEB-2", "2026.11.10")
  let alsoUpcoming = try saved("WEB-1", "2026.11.10")
  let recent = try saved("WEB-3", "2026.10.27")
  let stale = try saved("WEB-4", "2026.08.04")
  let unmerged = try ticket("WEB-5")

  let schedule = ReleaseSchedule(
    snapshots: snapshots([upcoming, alsoUpcoming, recent, stale, unmerged]), now: now,
    calendar: calendar)

  #expect(schedule.upcoming.map(\.version) == ["2026.11.10"])
  #expect(schedule.upcoming.first?.entries.map(\.snapshot.item.jiraKey) == ["WEB-1", "WEB-2"])
  #expect(schedule.upcoming.first?.entries.allSatisfy { !$0.isProjected } == true)
  #expect(schedule.recent.map(\.version) == ["2026.10.27"])
  #expect(schedule.awaitingMerge.map(\.id) == [unmerged.id])
}

@Test func finishedTicketsAcceptOnlyBragImpactEdits() throws {
  let item = try finished("WEB-1", start: Date(timeIntervalSince1970: 1_800_000_000))
  var impact = DetailsPatch()
  impact.fieldValues = [BragDocument.impactField: "Cut booking errors by 30%."]
  let updated = try Workflow.apply(.edit(impact), to: item, source: .desktop)
  #expect(updated.fieldValues?[BragDocument.impactField] == "Cut booking errors by 30%.")

  var other = DetailsPatch()
  other.testingNotes = "Changed after done."
  #expect(throws: (any Error).self) { try Workflow.apply(.edit(other), to: item, source: .desktop) }
  var mixed = impact
  mixed.fieldValues?["fix-version"] = "2026.11.10"
  #expect(throws: (any Error).self) { try Workflow.apply(.edit(mixed), to: item, source: .desktop) }
}

@Test func bragDocumentSummarizesShippedWorkWithImpact() throws {
  let start = Date(timeIntervalSince1970: 1_800_000_000)
  var item = try finished("WEB-7", start: start)
  var patch = DetailsPatch()
  patch.fieldValues = [BragDocument.impactField: "Unblocked the holiday launch."]
  item = try Workflow.apply(.edit(patch), to: item, source: .desktop)

  let brag = BragDocument(
    snapshots: snapshots([item]), from: start.addingTimeInterval(-hour),
    to: start.addingTimeInterval(24 * hour))
  let markdown = brag.markdown(title: "Shipped")

  #expect(brag.ticketCount == 1)
  #expect(brag.mergedMRs == 1)
  #expect(markdown.contains("1 tickets shipped · 1 MRs merged"))
  #expect(markdown.contains("- [WEB-7](https://jira.example.test/browse/WEB-7) Ticket WEB-7"))
  #expect(markdown.contains("  - Impact: Unblocked the holiday launch."))
}
