import Foundation
import Testing
import TrackerCore

@testable import TrackerStore

@Test func publishedCatalogIsRetrySafeConflictCheckedAndNeverSilentlyMigratesTickets() async throws
{
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "WorkflowCatalog-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try TrackerStore(directory: directory)
  let external = try TrackerStore(directory: directory)
  let before = try await store.create(
    NewItem(
      kind: .ticket, title: "Existing",
      jira: "https://jira.example.test/browse/APP-1"), source: .desktop, requestID: "existing")
  let catalog = try await store.workflows()
  let token = RevisionToken(generation: catalog.generation, version: catalog.catalog.revision)
  var definition = WorkflowTemplates.personal
  definition.steps[0].owner = "Developer"
  let mutation = WorkflowCatalogMutation.publish(
    definition, reason: "User requested their personal workflow", makeDefault: true)
  let published = try await store.changeWorkflows(
    mutation, expected: token, source: .copilot, requestID: "publish")
  let retry = try await external.changeWorkflows(
    mutation, expected: token, source: .copilot, requestID: "publish")
  #expect(published.catalog == retry.catalog)
  #expect(published.catalog.definition(definition.id)?.version == 2)
  #expect(published.catalog.history?.last?.source == .copilot)
  await #expect(throws: TrackerError.self) {
    try await external.changeWorkflows(
      mutation, expected: token, source: .copilot, requestID: "stale")
  }
  #expect(try await store.get(before.id).item.workflow == nil)
  let after = try await external.create(
    NewItem(
      kind: .ticket, title: "New",
      jira: "https://jira.example.test/browse/APP-2"), source: .desktop, requestID: "new")
  #expect(after.item.workflow?.id == definition.id)
  #expect(after.item.workflow?.version == 2)
  let backup = try await store.exportData()
  let decoded = try await store.previewRestore(backup)
  #expect(decoded.workflows?.defaultTicketID == definition.id)
  try await store.restore(backup)
  #expect(try await store.workflows().catalog == published.catalog)
  #expect(try await store.get(after.id).item.workflow == after.item.workflow)
  await #expect(throws: TrackerError.self) {
    try await external.changeWorkflows(
      mutation, expected: token, source: .copilot, requestID: "after-restore")
  }
}

@Test func itemAdoptionRequiresAnExactPublishedDefinitionAndPreservesCurrentToken() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "WorkflowAdoption-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try TrackerStore(directory: directory)
  let item = try await store.create(
    NewItem(
      kind: .ticket, title: "Existing",
      jira: "https://jira.example.test/browse/APP-1"), source: .desktop, requestID: "existing")
  var forged = WorkflowTemplates.personal
  forged.steps[0].owner = "Unpublished change"
  await #expect(throws: TrackerError.self) {
    try await store.mutate(
      item.id, expected: item.token, mutation: .adoptWorkflow(forged, reason: "Requested"),
      source: .copilot, requestID: "forged")
  }
  let migrated = try await store.mutate(
    item.id, expected: item.token,
    mutation: .adoptWorkflow(WorkflowTemplates.personal, reason: "User reviewed migration"),
    source: .copilot, requestID: "adopt")
  #expect(migrated.item.workflow == WorkflowTemplates.personal)
  #expect(migrated.item.revision == item.item.revision + 1)
  #expect(migrated.item.history.count == item.item.history.count + 1)
}
