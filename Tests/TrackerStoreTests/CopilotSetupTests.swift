import Foundation
import Testing
import TrackerCore

@testable import TrackerStore

@Test func copilotSetupPreservesExistingContentAndIsIdempotent() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "CopilotSetupTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let configURL = directory.appendingPathComponent("mcp-config.json")
  let instructionsURL = directory.appendingPathComponent("copilot-instructions.md")
  try Data(#"{"otherSetting":true,"mcpServers":{"existing":{"command":"keep-me"}}}"#.utf8).write(
    to: configURL)
  try Data("Keep these project conventions.\n".utf8).write(to: instructionsURL)
  let helper = URL(fileURLWithPath: "/usr/bin/true")
  let plan = try CopilotSetup.prepare(home: directory, executable: helper)
  let backup = try CopilotSetup.install(plan)
  #expect(
    FileManager.default.fileExists(atPath: backup.appendingPathComponent("mcp-config.json").path))
  let object = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
  let servers = try #require(object["mcpServers"] as? [String: Any])
  #expect(servers["existing"] != nil)
  #expect(object["otherSetting"] as? Bool == true)
  let second = try CopilotSetup.prepare(home: directory, executable: helper)
  _ = try CopilotSetup.install(second)
  let text = try String(contentsOf: instructionsURL, encoding: .utf8)
  #expect(text.hasPrefix("Keep these project conventions."))
  #expect(text.components(separatedBy: "<!-- ticket-tracker:start -->").count == 2)
}

@Test func setupRefusesConflictsAndChangedFiles() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "CopilotSetupTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let config = directory.appendingPathComponent("mcp-config.json")
  try Data(#"{"mcpServers":{"ticket-tracker":{"command":"/different/tool"}}}"#.utf8).write(
    to: config)
  #expect(throws: TrackerError.self) {
    try CopilotSetup.prepare(home: directory, executable: URL(fileURLWithPath: "/usr/bin/true"))
  }
  try Data(#"{"mcpServers":{}}"#.utf8).write(to: config)
  let plan = try CopilotSetup.prepare(
    home: directory, executable: URL(fileURLWithPath: "/usr/bin/true"))
  try Data(#"{"mcpServers":{},"newSetting":1}"#.utf8).write(to: config)
  #expect(throws: TrackerError.self) { try CopilotSetup.install(plan) }
}

@Test func cliSetupReplacesOnlyTrackerInstructionsAndPreservesMCPBytes() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "CopilotCLISetupTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let helper = URL(fileURLWithPath: "/usr/bin/true")
  let config = directory.appendingPathComponent("mcp-config.json")
  let instructions = directory.appendingPathComponent("copilot-instructions.md")
  try Data("Keep this introduction.\n".utf8).write(to: instructions)
  _ = try CopilotSetup.install(CopilotSetup.prepare(home: directory, executable: helper))
  let originalConfig = try Data(contentsOf: config)
  let plan = try CopilotSetup.prepare(home: directory, executable: helper, mode: .cli)
  #expect(plan.configuration == nil)
  let backup = try CopilotSetup.install(plan)
  #expect(try Data(contentsOf: config) == originalConfig)
  #expect(try Data(contentsOf: backup.appendingPathComponent("mcp-config.json")) == originalConfig)
  let text = try String(contentsOf: instructions, encoding: .utf8)
  #expect(text.hasPrefix("Keep this introduction."))
  #expect(text.contains("organization-permitted local Ticket Tracker CLI"))
  #expect(text.contains("'/usr/bin/true'"))
  #expect(text.contains("op \"simulate\"") && text.contains("never choose a path"))
  #expect(text.components(separatedBy: "<!-- ticket-tracker:start -->").count == 2)
  let repeated = try CopilotSetup.prepare(home: directory, executable: helper, mode: .cli)
  #expect(repeated.instructions == plan.instructions)
}

@Test func cliSetupDoesNotCreateOrParseAnUnchangedMCPConfiguration() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "CopilotCLISetupTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let helper = URL(fileURLWithPath: "/usr/bin/true")
  let config = directory.appendingPathComponent("mcp-config.json")
  _ = try CopilotSetup.install(
    CopilotSetup.prepare(home: directory, executable: helper, mode: .cli))
  #expect(!FileManager.default.fileExists(atPath: config.path))
  let unmanagedBytes = Data("Leave this file exactly as it is.\n".utf8)
  try unmanagedBytes.write(to: config)
  _ = try CopilotSetup.install(
    CopilotSetup.prepare(home: directory, executable: helper, mode: .cli))
  #expect(try Data(contentsOf: config) == unmanagedBytes)
}
