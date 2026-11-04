import Foundation
import TrackerCore

/// Shows a local file in the Ticket Tracker app's built-in viewer by asking macOS to open it
/// with the app bundle that contains this helper.
public enum FileOpener {
  public static let bundleIdentifier = "com.tickettracker.local"

  public struct Result: Encodable, Sendable {
    public var opened: String
    public var app: String
  }

  public typealias Launcher = @Sendable (_ arguments: [String]) throws -> Void

  public static func open(
    path: String, executable: URL = currentExecutable(), launch: Launcher = runOpen
  ) throws -> Result {
    let expanded = (path as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/") else {
      throw TrackerError.invalid("Use an absolute file path.")
    }
    let file = URL(fileURLWithPath: expanded).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
      throw TrackerError.invalid("No file exists at \(file.path).")
    }
    guard !isDirectory.boolValue else {
      throw TrackerError.invalid("\(file.path) is a folder. Choose a file inside it.")
    }
    guard FileManager.default.isReadableFile(atPath: file.path) else {
      throw TrackerError.invalid("\(file.path) is not readable.")
    }
    let app = appBundle(containing: executable)
    let target = app.map { ["-a", $0.path] } ?? ["-b", bundleIdentifier]
    try launch(target + [file.path])
    return Result(opened: file.path, app: app?.path ?? bundleIdentifier)
  }

  public static func currentExecutable() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
  }

  static func appBundle(containing executable: URL) -> URL? {
    var url = executable
    while url.pathComponents.count > 1 {
      url.deleteLastPathComponent()
      if url.pathExtension == "app" { return url }
    }
    return nil
  }

  public static func runOpen(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = arguments
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let message = String(
        decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      throw TrackerError.invalid(
        "Ticket Tracker couldn't be opened. \(message.isEmpty ? "Is the app installed?" : message)")
    }
  }
}
