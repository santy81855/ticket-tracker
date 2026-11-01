import Foundation
import MCP
import Testing
import TrackerCore
import TrackerStore

@testable import TrackerMCP

@Test func workflowCLIValidationPublishingAndExplicitMigrationUseSharedGuards() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "TrackerWorkflowMCP-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try TrackerStore(directory: directory)
  let service = TrackerMCPService(store: store)
  let catalog = try await store.workflows()
  let definition = try JSONDecoder().decode(
    Value.self, from: StoreJSON.encode(WorkflowTemplates.personal))
  #expect(
    await service.call(
      name: "tracker_workflow",
      arguments: [
        "op": .string("validate"),
        "definition": definition,
      ]
    ).isError != true)
  let missingReason = await service.call(
    name: "tracker_workflow",
    arguments: [
      "op": .string("publish"), "definition": definition, "generation": .string(catalog.generation),
      "expected_revision": .int(catalog.catalog.revision), "request_id": .string("no-reason"),
    ])
  #expect(missingReason.isError == true)
  let simulated = await service.call(
    name: "tracker_workflow",
    arguments: [
      "op": .string("simulate"), "definition": definition, "qa": .string("notRequired"),
      "completed": .array([.string("jiraStart"), .string("kickoff")]),
    ])
  #expect(simulated.isError != true)
  #expect("\(simulated.content)".contains("implementation"))
  #expect(
    await service.call(
      name: "tracker_workflow", arguments: ["op": .string("presets"), "preset": .string("waitOn")]
    ).isError != true)
  #expect(
    await service.call(
      name: "tracker_workflow",
      arguments: ["op": .string("simulate"), "definition": definition, "paths": .string("x")]
    ).isError == true)
  let published = await service.call(
    name: "tracker_workflow",
    arguments: [
      "op": .string("publish"), "definition": definition, "generation": .string(catalog.generation),
      "expected_revision": .int(catalog.catalog.revision), "request_id": .string("publish"),
      "reason": .string("User asked for Developer handoff"), "make_default": .bool(true),
    ])
  #expect(published.isError != true)
  let created = try await store.create(
    NewItem(
      kind: .ticket, title: "Configured",
      jira: "https://jira.example.test/browse/APP-8", qa: .notRequired),
    source: .desktop, requestID: "create")
  var args: [String: Value] = [
    "item_id": .string(created.id),
    "generation": .string(created.token.generation),
    "expected_revision": .int(created.token.version),
    "request_id": .string("merge"), "action_id": .string("mergeMR"),
    "note": .string("Verified"), "evidence": .string("verified"),
    "occurred_at": .string("2026-01-01T12:00:00Z"),
  ]
  #expect(await service.call(name: "tracker_record_action", arguments: args).isError == true)
  args["action_id"] = .string("jiraStart")
  args["evidence"] = .string("performed")
  #expect(await service.call(name: "tracker_record_action", arguments: args).isError == true)
}

@Test func toolsRejectBypassFlagsAndReturnSharedState() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "TrackerMCPTests-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try TrackerStore(directory: directory)
  let service = TrackerMCPService(store: store)
  let created = await service.call(
    name: "tracker_create_item",
    arguments: [
      "kind": .string("task"), "title": .string("Ask Jack"), "request_id": .string("create"),
    ])
  #expect(created.isError != true)
  let item = try #require(await store.list().first)
  let denied = await service.call(
    name: "tracker_record_action",
    arguments: [
      "item_id": .string(item.id), "generation": .string(item.token.generation),
      "expected_revision": .int(item.token.version), "request_id": .string("bypass"),
      "action_id": .string("taskDone"), "note": .string("Done"),
      "ignore_prerequisites": .bool(true),
    ])
  #expect(denied.isError == true)
  let done = await service.call(
    name: "tracker_record_action",
    arguments: [
      "item_id": .string(item.id), "generation": .string(item.token.generation),
      "expected_revision": .int(item.token.version), "request_id": .string("done"),
      "action_id": .string("taskDone"), "note": .string("User confirmed they asked Jack."),
    ])
  #expect(done.isError != true)
  #expect(try await store.get(item.id).item.isDone)
}

@Test func invalidTypesAndUnconfirmedNoQAProduceErrors() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "TrackerMCPTests-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: directory) }
  let service = TrackerMCPService(store: try TrackerStore(directory: directory))
  let malformed = await service.call(
    name: "tracker_list_items", arguments: ["limit": .string("many")])
  #expect(malformed.isError == true)
  let noQA = await service.call(
    name: "tracker_create_item",
    arguments: [
      "kind": .string("ticket"), "title": .string("Toggle"),
      "jira": .string("https://jira.example.test/browse/APP-1"), "qa": .string("notRequired"),
      "request_id": .string("create"),
    ])
  #expect(noQA.isError == true)
}
