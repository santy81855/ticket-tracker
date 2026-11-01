import Foundation
import Testing
import TrackerCore

@testable import TrackerStore

private func temporaryStore() throws -> (TrackerStore, URL) {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "TicketTrackerTests-\(UUID().uuidString)")
  return (try TrackerStore(directory: directory), directory)
}

@Test func workspaceSnapshotDoesNotDropOldActiveTicketsAtTheListLimit() async throws {
  let (store, directory) = try temporaryStore()
  defer { try? FileManager.default.removeItem(at: directory) }
  var ticket = try Workflow.create(
    NewItem(kind: .ticket, title: "Still active", jira: "https://jira.example.test/browse/APP-1"),
    settings: TrackerSettings())
  ticket.updatedAt = Date().addingTimeInterval(-30 * 24 * 3600)
  let tasks = (0..<2001).map { WorkItem(kind: .task, title: "Newer task \($0)") }
  var settings = TrackerSettings()
  settings.pod = "Test pod"
  try await store.restore(
    StoreJSON.encode(
      BackupDocument(exportedAt: Date(), settings: settings, items: tasks + [ticket])))
  #expect(try await store.list().contains { $0.id == ticket.id } == false)
  let workspace = try await store.workspaceSnapshot()
  #expect(workspace.items.count == 2002)
  #expect(workspace.settings.pod == settings.pod)
  #expect(Set(workspace.items.map(\.token.generation)).count == 1)
  #expect(StandupSummary(snapshots: workspace.items).activeTickets.map(\.id) == [ticket.id])
}

@Test func completionTimestampPersistsAndWorkspaceReloadSeesExternalChanges() async throws {
  let (store, directory) = try temporaryStore()
  defer { try? FileManager.default.removeItem(at: directory) }
  let created = try await store.create(
    NewItem(kind: .task, title: "Follow up"), source: .desktop, requestID: "create")
  let initial = try await store.workspaceSnapshot()
  let external = try TrackerStore(directory: directory)
  _ = try await external.mutate(
    created.id, expected: created.token, mutation: .record(actionID: "taskDone", note: ""),
    source: .desktop, requestID: "done")
  let changed = try await store.workspaceSnapshot()
  #expect(changed.dataVersion != initial.dataVersion)
  let persisted = try #require(changed.items.first)
  #expect(persisted.item.completedAt != nil)
  #expect(persisted.item.completionDate == persisted.item.completedAt)
  _ = try await external.mutate(
    persisted.id, expected: persisted.token, mutation: .reopen, source: .desktop,
    requestID: "reopen")
  let reopened = try await store.workspaceSnapshot()
  #expect(reopened.items.first?.item.completedAt == nil)
  #expect(reopened.items.first?.item.isDone == false)
}

@Test func persistenceDuplicatesAndRetryReceipts() async throws {
  let (store, directory) = try temporaryStore()
  defer { try? FileManager.default.removeItem(at: directory) }
  let input = NewItem(kind: .ticket, title: "Test", jira: "https://jira.example.test/browse/APP-1")
  let first = try await store.create(input, source: .copilot, requestID: "create")
  let retry = try await store.create(input, source: .copilot, requestID: "create")
  let duplicate = try await store.create(input, source: .desktop, requestID: "duplicate")
  #expect(first.id == retry.id)
  #expect(first.id == duplicate.id)
  let restarted = try TrackerStore(directory: directory)
  #expect(try await restarted.list().count == 1)
  var patch = DetailsPatch()
  patch.notes = "Saved notes."
  let changed = try await store.mutate(
    first.id, expected: first.token, mutation: .edit(patch), source: .copilot, requestID: "edit")
  let same = try await store.mutate(
    first.id, expected: first.token, mutation: .edit(patch), source: .copilot, requestID: "edit")
  #expect(changed.item.revision == same.item.revision)
  #expect(try await restarted.get(first.id).item.notes == "Saved notes.")
}

@Test func independentConnectionsRejectStaleWrites() async throws {
  let (first, directory) = try temporaryStore()
  defer { try? FileManager.default.removeItem(at: directory) }
  let second = try TrackerStore(directory: directory)
  let item = try await first.create(
    NewItem(kind: .task, title: "Follow up"), source: .desktop, requestID: UUID().uuidString)
  var one = DetailsPatch()
  one.notes = "One"
  var two = DetailsPatch()
  two.notes = "Two"
  _ = try await first.mutate(
    item.id, expected: item.token, mutation: .edit(one), source: .desktop, requestID: "first")
  await #expect(throws: TrackerError.self) {
    try await second.mutate(
      item.id, expected: item.token, mutation: .edit(two), source: .copilot, requestID: "second")
  }
  #expect(try await second.get(item.id).item.notes == "One")
}

@Test func exportRestoreChangesGenerationAndPreservesHistory() async throws {
  let (store, directory) = try temporaryStore()
  defer { try? FileManager.default.removeItem(at: directory) }
  let item = try await store.create(
    NewItem(kind: .task, title: "Preserved"), source: .desktop, requestID: "create")
  let data = try await store.exportData()
  _ = try await store.create(
    NewItem(kind: .task, title: "Remove on restore"), source: .desktop, requestID: "later")
  try await store.restore(data)
  #expect(try await store.list().count == 1)
  let restored = try await store.get(item.id)
  #expect(restored.item.history.count == 1)
  #expect(restored.token.generation != item.token.generation)
  await #expect(throws: TrackerError.self) {
    try await store.mutate(
      item.id, expected: item.token, mutation: .record(actionID: "taskDone", note: ""),
      source: .desktop, requestID: "stale")
  }
  let backups = try FileManager.default.contentsOfDirectory(
    atPath: directory.appendingPathComponent("Backups").path)
  #expect(backups.contains { $0.hasPrefix("before-restore-") })
}

@Test func invalidMutationIsAtomicAndRequestIDsCannotBeReused() async throws {
  let (store, directory) = try temporaryStore()
  defer { try? FileManager.default.removeItem(at: directory) }
  let item = try await store.create(
    NewItem(kind: .task, title: "Keep me"), source: .desktop, requestID: "unique")
  var patch = DetailsPatch()
  patch.title = ""
  await #expect(throws: TrackerError.self) {
    try await store.mutate(
      item.id, expected: item.token, mutation: .edit(patch), source: .desktop, requestID: "invalid")
  }

  #expect(try await store.get(item.id).item.revision == 1)
  await #expect(throws: TrackerError.self) {
    try await store.create(
      NewItem(kind: .task, title: "Different"), source: .desktop, requestID: "unique")
  }
}

@Test func confirmationUndoPersistsAndRetriesWithoutDuplicatingHistory() async throws {
  let (store, directory) = try temporaryStore()
  defer { try? FileManager.default.removeItem(at: directory) }
  var item = try await store.create(
    NewItem(kind: .task, title: "Ask Jack"), source: .desktop, requestID: "create")
  item = try await store.mutate(
    item.id, expected: item.token, mutation: .record(actionID: "taskDone", note: "Clicked done."),
    source: .desktop, requestID: "done")
  let mutation = ItemMutation.undo(actionID: "taskDone", reason: "Not finished yet.")
  let undone = try await store.mutate(
    item.id, expected: item.token, mutation: mutation, source: .desktop, requestID: "undo")
  let retry = try await store.mutate(
    item.id, expected: item.token, mutation: mutation, source: .desktop, requestID: "undo")
  let restarted = try TrackerStore(directory: directory)
  let persisted = try await restarted.get(item.id)
  #expect(!persisted.item.isDone)
  #expect(persisted.item.history == retry.item.history)
  #expect(persisted.item.history.last?.id == undone.item.history.last?.id)
  #expect(retry.token == undone.token)
  #expect(retry.item.history.count == 3)
}
