import Foundation
import MCP
import TrackerCore
import TrackerStore

public enum TrackerCLI {
  public static let operations = [
    "health": "tracker_health",
    "list": "tracker_list_items",
    "get": "tracker_get_item",
    "create": "tracker_create_item",
    "update": "tracker_update_details",
    "add-mr": "tracker_add_mr",
    "record": "tracker_record_action",
    "set-completion-time": "tracker_set_completion_time",
    "check": "tracker_check_transition",
    "draft": "tracker_get_message_draft",
    "workflow": "tracker_workflow",
    "open-file": "tracker_open_file",
  ]

  public struct Response: Sendable {
    public var text: String
    public var isError: Bool
  }

  public static func catalog() throws -> String {
    struct Definition: Encodable {
      var command: String
      var description: String
      var inputSchema: Value
    }
    let definitions = try operations.keys.sorted().map { command in
      guard let tool = TrackerMCPService.tools.first(where: { $0.name == operations[command] })
      else { throw TrackerError.invalid("Missing operation definition for \(command).") }
      return Definition(
        command: command, description: tool.description ?? "", inputSchema: tool.inputSchema)
    }
    return String(decoding: try StoreJSON.encode(definitions, pretty: true), as: UTF8.self)
  }

  public static func execute(_ arguments: [String], store: TrackerStore) async throws -> Response {
    guard let command = arguments.first, let operation = operations[command] else {
      throw TrackerError.invalid("Unknown CLI operation. Run ticket-tracker commands.")
    }
    let options = Array(arguments.dropFirst())
    let maximumBytes = 1_048_576
    let input: Data
    if options.isEmpty {
      input = Data("{}".utf8)
    } else if options.count == 2, options[0] == "--json" {
      input = Data(options[1].utf8)
    } else if options == ["--stdin"] {
      var data = Data()
      while let chunk = try FileHandle.standardInput.read(
        upToCount: min(65_536, maximumBytes + 1 - data.count)), !chunk.isEmpty
      {
        data.append(chunk)
        guard data.count <= maximumBytes else {
          throw TrackerError.invalid("CLI arguments must not exceed 1 MiB.")
        }
      }
      input = data
    } else {
      throw TrackerError.invalid(
        "Use <command> [--json '<JSON object>' | --stdin]. Run ticket-tracker commands for schemas."
      )
    }
    guard input.count <= maximumBytes else {
      throw TrackerError.invalid("CLI arguments must not exceed 1 MiB.")
    }
    let values: [String: Value]
    do {
      values = try JSONDecoder().decode([String: Value].self, from: input)
    } catch let error as DecodingError {
      throw TrackerError.invalid("Arguments must be a JSON object: \(error.localizedDescription)")
    }
    let response = await TrackerMCPService(store: store).call(name: operation, arguments: values)
    guard response.content.count == 1, case .text(let text, _, _) = response.content[0] else {
      throw TrackerError.invalid("The operation returned an unsupported response.")
    }
    return Response(text: text, isError: response.isError == true)
  }
}
