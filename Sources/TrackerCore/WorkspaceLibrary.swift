import Foundation

public struct WorkspaceNote: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public var body: String
  public var updatedAt: Date

  public init(
    id: String = UUID().uuidString, title: String, body: String, updatedAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.body = body
    self.updatedAt = updatedAt
  }
}

public struct WorkspaceLink: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public var url: String
  public var detail: String

  public init(
    id: String = UUID().uuidString, title: String, url: String, detail: String = ""
  ) {
    self.id = id
    self.title = title
    self.url = url
    self.detail = detail
  }
}

public struct WorkspaceLibrary: Codable, Equatable, Sendable {
  public var revision = 0
  public var notes: [WorkspaceNote] = []
  public var links: [WorkspaceLink] = []

  public init() {}

  public func validate() throws {
    guard revision >= 0, notes.count <= 1000, links.count <= 1000,
      Set(notes.map(\.id)).count == notes.count,
      Set(links.map(\.id)).count == links.count
    else { throw TrackerError.invalid("Notes and links must have unique IDs and valid limits.") }
    for note in notes {
      guard !note.id.isEmpty,
        !note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        note.title.count <= 160, note.body.count <= 200_000
      else {
        throw TrackerError.invalid("Use a note title up to 160 characters and a shorter body.")
      }
    }
    for link in links {
      guard !link.id.isEmpty,
        !link.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        link.title.count <= 160, link.detail.count <= 1000
      else {
        throw TrackerError.invalid(
          "Use a link title up to 160 characters and a shorter description.")
      }
      _ = try Workflow.validatedLink(link.url)
    }
  }
}

public struct WorkspaceLibrarySnapshot: Sendable {
  public var library: WorkspaceLibrary
  public var token: RevisionToken

  public init(library: WorkspaceLibrary, generation: String) {
    self.library = library
    self.token = RevisionToken(generation: generation, version: library.revision)
  }
}
