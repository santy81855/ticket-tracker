import Foundation
import GRDB
import Testing
import TrackerCore

@testable import TrackerStore

@Test func workspaceLibraryPersistsIndependentlyAndRejectsStaleEdits() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "WorkspaceLibrary-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: directory) }
  let first = try TrackerStore(directory: directory)
  let second = try TrackerStore(directory: directory)
  let initial = try await first.library()
  var value = initial.library
  value.notes = [WorkspaceNote(title: "General notes", body: "Not tied to a ticket.")]
  value.links = [WorkspaceLink(title: "Handbook", url: "https://example.test/handbook")]
  try await first.saveLibrary(value, expected: initial.token)
  let reloaded = try await second.workspaceSnapshot()
  #expect(reloaded.items.isEmpty)
  #expect(reloaded.library.library.notes.first?.body == "Not tied to a ticket.")
  #expect(reloaded.library.library.links == value.links)
  await #expect(throws: TrackerError.self) {
    try await second.saveLibrary(WorkspaceLibrary(), expected: initial.token)
  }
  var settings = try await second.settings()
  settings.pod = "Updated preferences"
  try await second.saveSettings(settings)
  #expect(try await first.library().library.notes.count == 1)
  var edited = reloaded.library.library
  edited.notes[0].body = "Edited"
  edited.links = []
  try await second.saveLibrary(edited, expected: reloaded.library.token)
  let restarted = try TrackerStore(directory: directory)
  #expect(try await restarted.library().library.notes.first?.body == "Edited")
  #expect(try await restarted.library().library.links.isEmpty == true)
}

@Test func workspaceLibraryExportRestoreAndInvalidLinksAreAtomic() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "WorkspaceLibraryRestore-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try TrackerStore(directory: directory)
  let initial = try await store.library()
  var value = initial.library
  value.notes = [WorkspaceNote(title: "Keep", body: "General reference")]
  value.links = [WorkspaceLink(title: "Docs", url: "https://example.test/docs")]
  try await store.saveLibrary(value, expected: initial.token)
  let saved = try await store.library()
  let data = try await store.exportData()
  var invalid = saved.library
  invalid.links[0].url = "javascript:alert(1)"
  await #expect(throws: TrackerError.self) {
    try await store.saveLibrary(invalid, expected: saved.token)
  }
  #expect(try await store.library().library == saved.library)
  try await store.restore(data)
  let restored = try await store.library()
  #expect(restored.library == saved.library)
  #expect(restored.token.generation != saved.token.generation)
  await #expect(throws: TrackerError.self) {
    try await store.saveLibrary(saved.library, expected: saved.token)
  }
  try await store.restore(
    StoreJSON.encode(BackupDocument(exportedAt: Date(), settings: TrackerSettings(), items: [])))
  #expect(try await store.library().library.notes.isEmpty == true)
  #expect(try await store.library().library.links.isEmpty == true)
}

@Test func workspaceLibrarySchemaUpgradePreservesTicketsAndCreatesPortableBackup() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "WorkspaceLibraryUpgrade-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: directory) }
  let initial = try TrackerStore(directory: directory)
  let ticket = try await initial.create(
    NewItem(kind: .task, title: "Keep this task"), source: .desktop, requestID: "task")
  let database = try DatabaseQueue(path: directory.appendingPathComponent("tracker.sqlite").path)
  try await database.write { db in
    try db.execute(sql: "DROP TABLE workspace_library; UPDATE store_meta SET schema_version = 2")
  }
  let upgraded = try TrackerStore(directory: directory)
  #expect(try await upgraded.get(ticket.id).token == ticket.token)
  #expect(try await upgraded.library().library.notes.isEmpty == true)
  let backups = try FileManager.default.contentsOfDirectory(
    at: directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
  let backup = try #require(
    backups.first {
      $0.lastPathComponent.hasPrefix("before-schema-3-") && $0.pathExtension == "sqlite"
    })
  var configuration = Configuration()
  configuration.readonly = true
  let readOnly = try DatabaseQueue(path: backup.path, configuration: configuration)
  let backupState = try await readOnly.read { db in
    (
      try Int.fetchOne(db, sql: "SELECT schema_version FROM store_meta"),
      try String.fetchOne(db, sql: "SELECT id FROM items")
    )
  }
  #expect(backupState.0 == 2)
  #expect(backupState.1 == ticket.id)
}
