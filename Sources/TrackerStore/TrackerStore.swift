import CryptoKit
import Darwin
import Foundation
import GRDB
import TrackerCore

private final class StoreLock: Sendable {
  let descriptor: Int32
  init(url: URL) throws {
    descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw TrackerError.storage("Cannot open the store maintenance lock.")
    }
  }
  deinit { Darwin.close(descriptor) }
  func access<T>(exclusive: Bool = false, wait: Bool = false, _ body: () throws -> T) throws -> T {
    let deadline = Date().addingTimeInterval(wait ? 5 : 0)
    while flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
      guard wait && Date() < deadline else {
        throw TrackerError.storage(
          "The tracker is being restored or maintained. Retry after it finishes.")
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
  }
}

public struct BackupDocument: Codable, Sendable {
  public var formatVersion: Int = 1
  public var exportedAt: Date
  public var settings: TrackerSettings
  public var items: [WorkItem]
  public var workflows: WorkflowCatalog? = nil
  public var library: WorkspaceLibrary? = nil
}

public enum StoreJSON {
  public static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting =
      pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
    return try encoder.encode(value)
  }
  public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
  }
}

public actor TrackerStore {
  public let directory: URL
  private let database: DatabaseQueue
  private let maintenance: StoreLock
  public static let schemaVersion = 3

  public static func defaultDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/TicketTracker", isDirectory: true)
  }

  public init(directory: URL = TrackerStore.defaultDirectory()) throws {
    self.directory = directory
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    maintenance = try StoreLock(url: directory.appendingPathComponent("maintenance.lock"))
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
    let databaseURL = directory.appendingPathComponent("tracker.sqlite")
    database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
    try maintenance.access(exclusive: true, wait: true) {
      let previousSchema = try database.read { db -> Int? in
        guard try db.tableExists("store_meta") else { return nil }
        return try Int.fetchOne(db, sql: "SELECT schema_version FROM store_meta WHERE id = 1")
      }
      if let previousSchema, (1..<Self.schemaVersion).contains(previousSchema) {
        let folder = directory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(
          at: folder, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(
          "before-schema-\(Self.schemaVersion)-\(UUID().uuidString).sqlite")
        let backup = try DatabaseQueue(path: url.path)
        try database.backup(to: backup)
        try Self.finishBackupJournal(backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      }
      try database.writeWithoutTransaction { db in
        try db.execute(sql: "PRAGMA journal_mode = WAL")
      }
      try database.write { db in
        try db.execute(
          sql: """
            CREATE TABLE IF NOT EXISTS store_meta (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                schema_version INTEGER NOT NULL,
                generation TEXT NOT NULL
            )
            """)
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM store_meta WHERE id = 1") {
          let version: Int = row["schema_version"]
          guard (1...Self.schemaVersion).contains(version) else {
            throw TrackerError.storage(
              "Database schema \(version) is not supported by this app/helper. Use matching versions; your data has not been replaced."
            )
          }
          if version < Self.schemaVersion {
            try db.execute(
              sql: "UPDATE store_meta SET schema_version = ? WHERE id = 1",
              arguments: [Self.schemaVersion])
          }
        } else {
          try db.execute(
            sql: "INSERT INTO store_meta VALUES (1, ?, ?)",
            arguments: [Self.schemaVersion, UUID().uuidString])
        }
        try db.execute(
          sql: """
            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY, identity TEXT UNIQUE, jira_key TEXT NOT NULL,
                updated_at DOUBLE NOT NULL, payload BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS items_jira_key ON items(jira_key);
            CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY CHECK (id = 1), payload BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS receipts (
                id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, payload BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS workflow_catalog (id INTEGER PRIMARY KEY CHECK(id = 1), payload BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS workflow_receipts (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS workspace_library (id INTEGER PRIMARY KEY CHECK(id = 1), payload BLOB NOT NULL);
            """)
      }
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
  }

  public func generation() throws -> String {
    try maintenance.access { try database.read { try storeGeneration($0) } }
  }

  public func dataVersion() throws -> Int {
    try maintenance.access {
      try database.read { db in
        guard let version = try Int.fetchOne(db, sql: "PRAGMA data_version") else {
          throw TrackerError.storage("Cannot read the database change version.")
        }
        return version
      }
    }
  }

  public func list(limit: Int = 2000) throws -> [ItemSnapshot] {
    guard (1...5000).contains(limit) else {
      throw TrackerError.invalid("List limit must be between 1 and 5000.")
    }
    return try maintenance.access {
      try database.read { db in
        let generation = try storeGeneration(db)
        return try Data.fetchAll(
          db, sql: "SELECT payload FROM items ORDER BY updated_at DESC, id LIMIT ?",
          arguments: [limit]
        )
        .map {
          ItemSnapshot(item: try StoreJSON.decode(WorkItem.self, from: $0), generation: generation)
        }
      }
    }
  }

  public func workspaceSnapshot() throws -> (
    items: [ItemSnapshot], settings: TrackerSettings, workflows: WorkflowCatalogSnapshot,
    library: WorkspaceLibrarySnapshot, dataVersion: Int
  ) {
    try maintenance.access {
      try database.read { db in
        guard let version = try Int.fetchOne(db, sql: "PRAGMA data_version") else {
          throw TrackerError.storage("Cannot read the database change version.")
        }
        let generation = try storeGeneration(db)
        let items = try Data.fetchAll(
          db, sql: "SELECT payload FROM items ORDER BY updated_at DESC, id"
        ).map {
          ItemSnapshot(item: try StoreJSON.decode(WorkItem.self, from: $0), generation: generation)
        }
        return (
          items, try readSettings(db),
          WorkflowCatalogSnapshot(catalog: try readWorkflows(db), generation: generation),
          WorkspaceLibrarySnapshot(library: try readLibrary(db), generation: generation), version
        )
      }
    }
  }

  public func get(_ identifier: String) throws -> ItemSnapshot {
    try maintenance.access {
      try database.read { db in
        let rows = try Data.fetchAll(
          db, sql: "SELECT payload FROM items WHERE id = ? OR jira_key = ?",
          arguments: [identifier, identifier.uppercased()])
        guard let data = rows.first else { throw TrackerError.notFound }
        guard rows.count == 1 else {
          throw TrackerError.invalid(
            "This Jira key exists on multiple hosts. Use the tracker item ID.")
        }
        return ItemSnapshot(
          item: try StoreJSON.decode(WorkItem.self, from: data), generation: try storeGeneration(db)
        )
      }
    }
  }

  public func settings() throws -> TrackerSettings {
    try maintenance.access { try database.read { try readSettings($0) } }
  }

  public func saveSettings(_ settings: TrackerSettings) throws {
    try validateSettings(settings)
    try maintenance.access {
      try database.write { db in
        _ = try storeGeneration(db)
        try db.execute(
          sql: "INSERT OR REPLACE INTO settings VALUES (1, ?)",
          arguments: [try StoreJSON.encode(settings)])
      }
    }
  }

  public func library() throws -> WorkspaceLibrarySnapshot {
    try maintenance.access {
      try database.read {
        WorkspaceLibrarySnapshot(
          library: try readLibrary($0), generation: try storeGeneration($0))
      }
    }
  }

  public func saveLibrary(_ value: WorkspaceLibrary, expected: RevisionToken) throws {
    try value.validate()
    try maintenance.access {
      try database.write { db in
        guard try storeGeneration(db) == expected.generation,
          try readLibrary(db).revision == expected.version
        else { throw TrackerError.conflict }
        var saved = value
        saved.revision = expected.version + 1
        let data = try StoreJSON.encode(saved)
        guard data.count <= 4_000_000 else {
          throw TrackerError.invalid("Notes and links exceed the 4 MB safety limit.")
        }
        try db.execute(
          sql: "INSERT OR REPLACE INTO workspace_library VALUES (1, ?)", arguments: [data])
      }
    }
  }

  public func create(_ input: NewItem, source: ChangeSource, requestID: String) throws
    -> ItemSnapshot
  {
    let fingerprint = try fingerprint(input, source: source)
    return try maintenance.access {
      try database.write { db in
        if let cached = try receipt(requestID, fingerprint: fingerprint, db: db) { return cached }
        let generation = try storeGeneration(db)
        var item = try Workflow.create(input, settings: readSettings(db))
        let catalog = try readWorkflows(db)
        let workflowID =
          input.workflowID
          ?? (input.kind == .ticket ? catalog.defaultTicketID : catalog.defaultTaskID)
        guard let definition = catalog.definition(workflowID), definition.kind == input.kind else {
          throw TrackerError.invalid("Choose a published workflow for this item type.")
        }
        if !(definition.version == 1
          && [WorkflowTemplates.legacyID, WorkflowTemplates.taskID].contains(definition.id))
        {
          item.workflow = definition
          item.playbookVersion = 2
          try Workflow.validate(item)
        }
        if let identity = item.identity,
          let data = try Data.fetchOne(
            db, sql: "SELECT payload FROM items WHERE identity = ?", arguments: [identity])
        {
          let existing = ItemSnapshot(
            item: try StoreJSON.decode(WorkItem.self, from: data), generation: generation)
          try saveReceipt(requestID, fingerprint: fingerprint, snapshot: existing, db: db)
          return existing
        }
        item.revision = 1
        item.history.append(
          HistoryEntry(
            title: item.kind == .ticket ? "Ticket added" : "Task added",
            note: source == .copilot ? "Created through Copilot." : "",
            source: source, date: Date()))
        try write(item, db: db)
        let result = ItemSnapshot(item: item, generation: generation)
        try saveReceipt(requestID, fingerprint: fingerprint, snapshot: result, db: db)
        return result
      }
    }
  }

  public func mutate(
    _ id: String, expected: RevisionToken, mutation: ItemMutation,
    source: ChangeSource, requestID: String
  ) throws -> ItemSnapshot {
    struct Request: Encodable {
      var id: String
      var expected: RevisionToken
      var mutation: ItemMutation
    }
    let fingerprint = try fingerprint(
      Request(id: id, expected: expected, mutation: mutation), source: source)
    return try maintenance.access {
      try database.write { db in
        if let cached = try receipt(requestID, fingerprint: fingerprint, db: db) { return cached }
        let generation = try storeGeneration(db)
        guard expected.generation == generation else { throw TrackerError.conflict }
        guard
          let data = try Data.fetchOne(
            db, sql: "SELECT payload FROM items WHERE id = ?", arguments: [id])
        else {
          throw TrackerError.notFound
        }
        let original = try StoreJSON.decode(WorkItem.self, from: data)
        guard original.revision == expected.version else { throw TrackerError.conflict }
        if case .adoptWorkflow(let definition, _) = mutation {
          guard
            try readWorkflows(db).definition(definition.id, version: definition.version)
              == definition
          else {
            throw TrackerError.invalid("Only an exact published workflow version can be applied.")
          }
        }
        var item = try Workflow.apply(mutation, to: original, source: source)
        item.revision = original.revision + 1
        try write(item, db: db)
        let result = ItemSnapshot(item: item, generation: generation)
        try saveReceipt(requestID, fingerprint: fingerprint, snapshot: result, db: db)
        return result
      }
    }
  }

  public func exportData() throws -> Data {
    try maintenance.access {
      try database.read { db in
        _ = try storeGeneration(db)
        let items = try Data.fetchAll(db, sql: "SELECT payload FROM items ORDER BY id")
          .map { try StoreJSON.decode(WorkItem.self, from: $0) }
        return try StoreJSON.encode(
          BackupDocument(
            formatVersion: 3, exportedAt: Date(), settings: readSettings(db), items: items,
            workflows: readWorkflows(db), library: readLibrary(db)), pretty: true
        )
      }
    }
  }

  public func previewRestore(_ data: Data) throws -> BackupDocument {
    guard data.count <= 25_000_000 else {
      throw TrackerError.invalid("The export exceeds the 25 MB import limit.")
    }
    let document = try StoreJSON.decode(BackupDocument.self, from: data)
    guard (1...3).contains(document.formatVersion) else {
      throw TrackerError.invalid("Unsupported export format.")
    }
    try validateSettings(document.settings)
    guard Set(document.items.map(\.id)).count == document.items.count,
      Set(document.items.compactMap(\.identity)).count
        == document.items.compactMap(\.identity).count
    else {
      throw TrackerError.invalid("The export contains duplicate item IDs or Jira identities.")
    }
    for item in document.items { try Workflow.validate(item) }
    try (document.workflows ?? WorkflowCatalog()).validate()
    try (document.library ?? WorkspaceLibrary()).validate()
    return document
  }

  public func restore(_ data: Data) throws {
    let document = try previewRestore(data)
    try maintenance.access(exclusive: true) {
      _ = try makeBackup(prefix: "before-restore")
      try database.write { db in
        _ = try storeGeneration(db)
        try db.execute(
          sql: "DELETE FROM items; DELETE FROM receipts; DELETE FROM workflow_receipts")
        for item in document.items { try write(item, db: db) }
        try db.execute(
          sql: "INSERT OR REPLACE INTO settings VALUES (1, ?)",
          arguments: [try StoreJSON.encode(document.settings)])
        try db.execute(
          sql: "INSERT OR REPLACE INTO workflow_catalog VALUES (1, ?)",
          arguments: [try StoreJSON.encode(document.workflows ?? WorkflowCatalog())])
        try db.execute(
          sql: "INSERT OR REPLACE INTO workspace_library VALUES (1, ?)",
          arguments: [try StoreJSON.encode(document.library ?? WorkspaceLibrary())])
        try db.execute(
          sql: "UPDATE store_meta SET generation = ? WHERE id = 1", arguments: [UUID().uuidString])
      }
    }
  }

  public func dailyBackup(now: Date = Date()) throws {
    try maintenance.access(exclusive: true, wait: true) {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyy-MM-dd"
      let name = "daily-\(formatter.string(from: now)).sqlite"
      let folder = directory.appendingPathComponent("Backups", isDirectory: true)
      if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
        _ = try makeBackup(filename: name)
      }
      let backups = try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil
      )
      .filter { $0.lastPathComponent.hasPrefix("daily-") && $0.pathExtension == "sqlite" }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
      for old in backups.dropFirst(7) { try FileManager.default.removeItem(at: old) }
    }
  }

  private func makeBackup(prefix: String = "backup", filename: String? = nil) throws -> URL {
    let folder = directory.appendingPathComponent("Backups", isDirectory: true)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = folder.appendingPathComponent(filename ?? "\(prefix)-\(UUID().uuidString).sqlite")
    let destination = try DatabaseQueue(path: url.path)
    try database.backup(to: destination)
    try Self.finishBackupJournal(destination)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
  }

  private func storeGeneration(_ db: Database) throws -> String {
    guard
      let row = try Row.fetchOne(
        db, sql: "SELECT schema_version, generation FROM store_meta WHERE id = 1"),
      row["schema_version"] as Int == Self.schemaVersion
    else {
      throw TrackerError.storage(
        "The app and helper have incompatible database versions. Install matching versions.")
    }
    return row["generation"]
  }

  private static func finishBackupJournal(_ backup: DatabaseQueue) throws {
    try backup.writeWithoutTransaction { db in
      guard try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE") == "delete" else {
        throw TrackerError.storage("Could not make a self-contained SQLite backup.")
      }
    }
  }

  private func readSettings(_ db: Database) throws -> TrackerSettings {
    guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM settings WHERE id = 1") else {
      return TrackerSettings()
    }
    return try StoreJSON.decode(TrackerSettings.self, from: data)
  }
  private func readLibrary(_ db: Database) throws -> WorkspaceLibrary {
    guard
      let data = try Data.fetchOne(db, sql: "SELECT payload FROM workspace_library WHERE id = 1")
    else { return WorkspaceLibrary() }
    return try StoreJSON.decode(WorkspaceLibrary.self, from: data)
  }
  private func readWorkflows(_ db: Database) throws -> WorkflowCatalog {
    guard
      let data = try Data.fetchOne(db, sql: "SELECT payload FROM workflow_catalog WHERE id = 1")
    else {
      return WorkflowCatalog()
    }
    return try StoreJSON.decode(WorkflowCatalog.self, from: data)
  }
  public func workflows() throws -> WorkflowCatalogSnapshot {
    try maintenance.access {
      try database.read {
        WorkflowCatalogSnapshot(
          catalog: try readWorkflows($0), generation: try storeGeneration($0))
      }
    }
  }
  public func changeWorkflows(
    _ mutation: WorkflowCatalogMutation, expected: RevisionToken,
    source: ChangeSource, requestID: String
  ) throws -> WorkflowCatalogSnapshot {
    struct Request: Encodable {
      var mutation: WorkflowCatalogMutation
      var expected: RevisionToken
    }
    let fingerprint = try fingerprint(
      Request(mutation: mutation, expected: expected), source: source)
    guard !requestID.isEmpty, requestID.count <= 200 else {
      throw TrackerError.invalid("A request ID of 1-200 characters is required.")
    }
    return try maintenance.access {
      try database.write { db in
        let generation = try storeGeneration(db)
        if let row = try Row.fetchOne(
          db, sql: "SELECT fingerprint,payload FROM workflow_receipts WHERE id = ?",
          arguments: [requestID])
        {
          guard row["fingerprint"] as String == fingerprint else {
            throw TrackerError.invalid("This request ID belongs to a different workflow change.")
          }
          return try StoreJSON.decode(WorkflowCatalogSnapshot.self, from: row["payload"])
        }
        var catalog = try readWorkflows(db)
        guard expected.generation == generation, expected.version == catalog.revision else {
          throw TrackerError.conflict
        }
        let id: String
        let setDefault: Bool
        let reason: String
        switch mutation {
        case .publish(var definition, let explanation, let makeDefault):
          reason = explanation
          guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            reason.count <= 4000
          else {
            throw TrackerError.invalid("Describe the explicit user-requested workflow change.")
          }
          try definition.validate()
          let previous = catalog.definition(definition.id)
          if let previous, previous.kind != definition.kind {
            throw TrackerError.invalid("Duplicate a workflow to change its item type.")
          }
          for i in definition.steps.indices {
            if let old = previous?.steps.first(where: { $0.id == definition.steps[i].id }) {
              definition.steps[i].revision =
                definition.steps[i].keepsCompletions(of: old) ? old.revision : UUID().uuidString
            } else {
              definition.steps[i].revision = UUID().uuidString
            }
          }
          definition.version = (previous?.version ?? 0) + 1
          definition.publishedAt = Date()
          definition.publicationReason = reason
          definition.publishedBy = source
          catalog.definitions.append(definition)
          id = definition.id
          setDefault = makeDefault
        case .setDefault(let requested, let explanation):
          reason = explanation
          guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrackerError.invalid("Describe the user-requested default change.")
          }
          id = requested
          setDefault = true
        }
        guard let chosen = catalog.definition(id) else {
          throw TrackerError.invalid("Unknown workflow.")
        }
        if setDefault {
          if chosen.kind == .ticket {
            catalog.defaultTicketID = id
          } else {
            catalog.defaultTaskID = id
          }
        }
        catalog.revision += 1
        var audit = catalog.history ?? []
        audit.append(
          HistoryEntry(
            title: setDefault
              ? "Workflow published/default changed: \(chosen.name)"
              : "Workflow published: \(chosen.name)",
            note: reason, source: source, date: Date()))
        catalog.history = Array(audit.suffix(200))
        try catalog.validate()
        let data = try StoreJSON.encode(catalog)
        guard data.count <= 2_000_000 else {
          throw TrackerError.invalid("Workflow catalog exceeds its 2 MB safety limit.")
        }
        try db.execute(
          sql: "INSERT OR REPLACE INTO workflow_catalog VALUES (1, ?)", arguments: [data])
        let result = WorkflowCatalogSnapshot(
          catalog: try StoreJSON.decode(WorkflowCatalog.self, from: data), generation: generation)
        try db.execute(
          sql: "INSERT INTO workflow_receipts VALUES (?, ?, ?)",
          arguments: [requestID, fingerprint, try StoreJSON.encode(result)])
        return result
      }
    }
  }
  private func validateSettings(_ settings: TrackerSettings) throws {
    for link in [
      settings.jiraBaseURL, settings.jiraBoardURL, settings.gitlabHost, settings.teamsChannelURL,
    ] {
      _ = try Workflow.validatedLink(link, allowEmpty: true)
    }
    guard
      [settings.kickoffTemplate, settings.approvalTemplate, settings.qaTemplate].allSatisfy({
        $0.count <= 20_000
      })
    else {
      throw TrackerError.invalid("A message template is too long.")
    }
    let probe = WorkItem(kind: .ticket, title: "Template validation")
    for kind in DraftKind.allCases { _ = try Messages.draft(kind, item: probe, settings: settings) }
  }

  private func write(_ item: WorkItem, db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO items (id, identity, jira_key, updated_at, payload) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET identity = excluded.identity, jira_key = excluded.jira_key,
            updated_at = excluded.updated_at, payload = excluded.payload
        """,
      arguments: [
        item.id, item.identity, item.jiraKey, item.updatedAt.timeIntervalSince1970,
        try StoreJSON.encode(item),
      ])
  }

  private func fingerprint<T: Encodable>(_ value: T, source: ChangeSource) throws -> String {
    let data = try StoreJSON.encode(value) + Data(source.rawValue.utf8)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func receipt(_ id: String, fingerprint: String, db: Database) throws -> ItemSnapshot? {
    guard !id.isEmpty, id.count <= 200 else {
      throw TrackerError.invalid("A request ID of 1–200 characters is required.")
    }
    guard
      let row = try Row.fetchOne(
        db, sql: "SELECT fingerprint, payload FROM receipts WHERE id = ?", arguments: [id])
    else {
      return nil
    }
    guard row["fingerprint"] as String == fingerprint else {
      throw TrackerError.invalid("This request ID was already used for a different operation.")
    }
    return try StoreJSON.decode(ItemSnapshot.self, from: row["payload"])
  }

  private func saveReceipt(_ id: String, fingerprint: String, snapshot: ItemSnapshot, db: Database)
    throws
  {
    try db.execute(
      sql: "INSERT INTO receipts VALUES (?, ?, ?)",
      arguments: [id, fingerprint, try StoreJSON.encode(snapshot)])
  }
}
