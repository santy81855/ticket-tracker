import Foundation
import TrackerMCP
import TrackerStore

@main
struct TrackerAgent {
  static func main() async {
    do {
      let command = CommandLine.arguments.dropFirst().first ?? "--help"
      if command == "--help" || command == "-h" {
        print(
          """
          Ticket Tracker 0.5.0

          Usage: ticket-tracker <command> [--json '<JSON object>' | --stdin]

          health, list, get, create, update, add-mr, record, check, draft, workflow
                        Read/write the shared workspace using validated operations.
          set-completion-time
                        Correct a completed item's actual finish time with evidence.
          commands      Print all operation descriptions and JSON input schemas.
          mcp           Serve local MCP tools over stdio (no web server).
          doctor        Report store readiness as JSON.
          setup-copilot [--mode mcp|cli] [--confirm]
                        Preview personal setup; --confirm installs with backups.
          --version     Print the version.

          Results are JSON on stdout. Operation failures are JSON on stderr with
          exit status 1; command/JSON/storage errors use stderr and exit status 1.
          Prefer --stdin for work context; --json arguments may appear in process lists.
          TICKET_TRACKER_DATA_DIR overrides the data directory for isolated tests.
          """
        )
        return
      }
      if command == "commands" {
        guard CommandLine.arguments.count == 2 else {
          throw NSError(
            domain: "TicketTracker", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "commands does not accept arguments."])
        }
        print(try TrackerCLI.catalog())
        return
      }
      if command == "--version" {
        print("0.5.0")
        return
      }
      if command == "setup-copilot" {
        var arguments = Array(CommandLine.arguments.dropFirst(2))
        var mode = CopilotSetupMode.mcp
        var confirmed = false
        var hasMode = false
        while !arguments.isEmpty {
          let argument = arguments.removeFirst()
          if argument == "--confirm", !confirmed {
            confirmed = true
          } else if argument == "--mode", !hasMode, let value = arguments.first,
            let selected = CopilotSetupMode(rawValue: value)
          {
            mode = selected
            hasMode = true
            arguments.removeFirst()
          } else {
            throw NSError(
              domain: "TicketTracker", code: 1,
              userInfo: [
                NSLocalizedDescriptionKey: "Use setup-copilot [--mode mcp|cli] [--confirm]."
              ])
          }
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
          .standardizedFileURL.resolvingSymlinksInPath()
        let plan = try CopilotSetup.prepare(
          home: CopilotSetup.effectiveHome(), executable: executable, mode: mode)
        print("Personal Copilot setup: \(plan.home.path)")
        print(
          mode == .cli
            ? "Updates only a scoped block in copilot-instructions.md. MCP configuration is unchanged."
            : "Updates mcp-config.json and a scoped block in copilot-instructions.md.")
        print("Use only an organization-permitted integration. No automatic tool permissions.")
        print("\n\(plan.trackerInstructions)\n")
        if confirmed {
          let backup = try CopilotSetup.install(plan)
          print(
            mode == .cli
              ? "Saved CLI instructions. Verify tracker health in a new session."
              : "Saved MCP setup. Verify with /mcp; organization policies still apply.")
          print("Original files backed up to \(backup.path)")
        } else {
          print("No files changed. Run again with --confirm to install.")
        }
        return
      }
      guard command == "mcp" || command == "doctor" || TrackerCLI.operations[command] != nil else {
        throw NSError(
          domain: "TicketTracker", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Unknown command. Run ticket-tracker --help."])
      }
      let directory =
        ProcessInfo.processInfo.environment["TICKET_TRACKER_DATA_DIR"].map {
          URL(fileURLWithPath: $0, isDirectory: true)
        }
        ?? TrackerStore.defaultDirectory()
      let store = try TrackerStore(directory: directory)
      try await store.dailyBackup()
      if command == "mcp" {
        try await TrackerMCPService.serve(store: store)
      } else if command == "doctor" {
        struct Health: Encodable {
          var version = "0.5.0"
          var directory: String
          var generation: String
          var itemCount: Int
        }
        let health = try await Health(
          directory: directory.path, generation: store.generation(),
          itemCount: store.list(limit: 5000).count)
        print(String(decoding: try StoreJSON.encode(health, pretty: true), as: UTF8.self))
      } else {
        let response = try await TrackerCLI.execute(
          Array(CommandLine.arguments.dropFirst()), store: store)
        let output = response.isError ? FileHandle.standardError : FileHandle.standardOutput
        try output.write(contentsOf: Data((response.text + "\n").utf8))
        if response.isError { exit(1) }
      }
    } catch {
      FileHandle.standardError.write(Data("Ticket Tracker: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
}
