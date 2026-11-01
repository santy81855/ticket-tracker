import SwiftUI
import TrackerCore

struct ReferenceEditRequest: Identifiable {
  enum Content {
    case note(WorkspaceNote?)
    case link(WorkspaceLink?)
  }
  let id = UUID()
  let snapshot: WorkspaceLibrarySnapshot
  let content: Content
  var isNote: Bool {
    if case .note = content { return true }
    return false
  }
}

struct ReferenceLibraryView: View {
  @ObservedObject var model: WorkspaceModel
  @State private var search = ""
  @State private var deleting: ReferenceEditRequest?

  private var notes: [WorkspaceNote] {
    (model.library?.library.notes ?? [])
      .filter {
        search.isEmpty || "\($0.title) \($0.body)".localizedCaseInsensitiveContains(search)
      }
      .sorted { $0.updatedAt > $1.updatedAt }
  }
  private var links: [WorkspaceLink] {
    (model.library?.library.links ?? [])
      .filter {
        search.isEmpty
          || "\($0.title) \($0.url) \($0.detail)".localizedCaseInsensitiveContains(search)
      }
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField(model.page == .notes ? "Search notes" : "Search links", text: $search)
          .textFieldStyle(.plain)
          .accessibilityIdentifier("reference-search")
        if !search.isEmpty {
          Button {
            search = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
        }
      }.padding(12).modifier(WorkspaceSurface(radius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
      if model.page == .notes ? notes.isEmpty : links.isEmpty {
        ContentUnavailableView {
          Label(
            search.isEmpty
              ? (model.page == .notes ? "A place for your notes" : "Keep useful links close")
              : "No matches",
            systemImage: model.page.symbol)
        } description: {
          Text(
            search.isEmpty
              ? "General reference, separate from your tickets." : "Try another search.")
        } actions: {
          if search.isEmpty {
            Button(model.page == .notes ? "New note" : "Add link") { model.newReference() }
              .buttonStyle(AccentButtonStyle())
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 270), spacing: 16, alignment: .top)],
            alignment: .leading, spacing: 16
          ) {
            if model.page == .notes {
              ForEach(notes) { note in noteCard(note) }
            } else {
              ForEach(links) { link in linkCard(link) }
            }
          }.padding(.trailing, 2).padding(.bottom, 16)
        }
      }
    }
    .id(model.page)
    .onChange(of: model.page) { _, _ in search = "" }
    .alert(
      deleting?.isNote == true ? "Delete this note?" : "Delete this link?",
      isPresented: Binding(
        get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      presenting: deleting
    ) { request in
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        var value = request.snapshot.library
        switch request.content {
        case .note(let note): value.notes.removeAll { $0.id == note?.id }
        case .link(let link): value.links.removeAll { $0.id == link?.id }
        }
        Task { await model.saveLibrary(value, expected: request.snapshot.token) }
      }
    } message: { _ in
      Text("This removes it from your workspace.")
    }
  }

  private func noteCard(_ note: WorkspaceNote) -> some View {
    Surface(padding: 20) {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "note.text").font(.system(size: 18)).foregroundStyle(Palette.amber)
          Text(note.title).font(.system(size: 17, weight: .semibold)).lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
          referenceMenu(.note(note))
        }
        Text(note.body.isEmpty ? "Empty note" : note.body)
          .font(.system(size: 13)).foregroundStyle(.secondary)
          .lineSpacing(5).lineLimit(7).frame(
            maxWidth: .infinity, minHeight: 110, alignment: .topLeading
          )
          .textSelection(.enabled)
        Divider()
        HStack {
          Text(note.updatedAt.formatted(date: .abbreviated, time: .omitted))
            .font(.system(size: 11)).foregroundStyle(.secondary)
          Spacer()
          Button {
            model.copy(note.body, message: "Note copied")
          } label: {
            Image(systemName: "doc.on.doc")
          }
          .buttonStyle(.plain).help("Copy note").accessibilityLabel("Copy \(note.title)")
          Button("Open note") { edit(.note(note)) }.buttonStyle(QuietButtonStyle())
            .accessibilityIdentifier("open-note-\(note.id)")
        }
      }
    }
  }

  private func linkCard(_ link: WorkspaceLink) -> some View {
    Surface(padding: 20) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "link").font(.system(size: 18)).foregroundStyle(Palette.accent)
          Text(link.title).font(.system(size: 17, weight: .semibold)).lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
          referenceMenu(.link(link))
        }
        Text(URL(string: link.url)?.host ?? link.url)
          .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent).lineLimit(1)
        if !link.detail.isEmpty {
          Text(link.detail).font(.system(size: 13)).foregroundStyle(.secondary)
            .lineSpacing(4).lineLimit(3)
        }
        Text(link.url).font(.system(size: 11)).foregroundStyle(.secondary)
          .lineLimit(2).textSelection(.enabled).help(link.url)
        HStack {
          Button {
            model.copy(link.url, message: "Link copied")
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
          }
          .buttonStyle(QuietButtonStyle())
          Spacer()
          Button {
            model.openLink(link.url)
          } label: {
            Label("Open", systemImage: "arrow.up.right")
          }
          .buttonStyle(AccentButtonStyle())
        }
      }
    }
  }

  private func referenceMenu(_ content: ReferenceEditRequest.Content) -> some View {
    Menu {
      Button("Edit") { edit(content) }
      Button("Delete…", role: .destructive) {
        guard let snapshot = model.library else {
          model.errorMessage = "Notes and links are not available. Refresh the workspace."
          return
        }
        deleting = ReferenceEditRequest(snapshot: snapshot, content: content)
      }
    } label: {
      Image(systemName: "ellipsis").frame(width: 20, height: 20)
    }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More options")
  }

  private func edit(_ content: ReferenceEditRequest.Content) {
    guard let snapshot = model.library else {
      model.errorMessage = "Notes and links are not available. Refresh the workspace."
      return
    }
    let current: ReferenceEditRequest.Content
    switch content {
    case .note(let note):
      guard let saved = snapshot.library.notes.first(where: { $0.id == note?.id }) else {
        model.errorMessage = "This note no longer exists. Refresh the workspace."
        return
      }
      current = .note(saved)
    case .link(let link):
      guard let saved = snapshot.library.links.first(where: { $0.id == link?.id }) else {
        model.errorMessage = "This link no longer exists. Refresh the workspace."
        return
      }
      current = .link(saved)
    }
    model.referenceEditor = ReferenceEditRequest(snapshot: snapshot, content: current)
  }
}

struct ReferenceEditorSheet: View {
  @ObservedObject var model: WorkspaceModel
  let request: ReferenceEditRequest
  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var text: String
  @State private var url: String

  init(model: WorkspaceModel, request: ReferenceEditRequest) {
    self.model = model
    self.request = request
    switch request.content {
    case .note(let note):
      _title = State(initialValue: note?.title ?? "")
      _text = State(initialValue: note?.body ?? "")
      _url = State(initialValue: "")
    case .link(let link):
      _title = State(initialValue: link?.title ?? "")
      _text = State(initialValue: link?.detail ?? "")
      _url = State(initialValue: link?.url ?? "")
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          HStack {
            Label(
              request.isNote ? "Workspace note" : "Workspace link",
              systemImage: request.isNote ? "note.text" : "link"
            ).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
          }
          TextField("Title", text: $title).textFieldStyle(.plain)
            .font(.system(size: 25, weight: .semibold, design: .rounded))
            .accessibilityLabel("Title").accessibilityIdentifier("reference-title")
          Divider()
          if !request.isNote {
            TextField("https://", text: $url).textFieldStyle(.roundedBorder)
              .accessibilityLabel("Link URL").accessibilityIdentifier("reference-url")
          }
          TextEditor(text: $text).font(.system(size: 14)).lineSpacing(6)
            .scrollContentBackground(.hidden).padding(10)
            .frame(minHeight: request.isNote ? 260 : 100)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
            .accessibilityLabel(request.isNote ? "Note" : "Description")
            .accessibilityIdentifier("reference-body")
          if !request.isNote {
            Text("Description (optional)").font(.caption).foregroundStyle(.secondary)
          }
          inlineError(model.errorMessage)
        }.padding(26)
      }
      Divider()
      sheetFooter {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(request.isNote ? "Save note" : "Save link") { save() }
          .buttonStyle(AccentButtonStyle()).keyboardShortcut("s", modifiers: .command)
          .disabled(
            model.isBusy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || (!request.isNote && url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          )
          .accessibilityIdentifier("save-reference")
      }
    }.modifier(WorkspaceSheetFrame(width: 660, height: request.isNote ? 560 : 450))
      .tint(Palette.accent)
      .interactiveDismissDisabled()
  }

  private func save() {
    var value = request.snapshot.library
    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    switch request.content {
    case .note(let existing):
      let note = WorkspaceNote(
        id: existing?.id ?? UUID().uuidString, title: cleanTitle, body: text)
      if let index = value.notes.firstIndex(where: { $0.id == note.id }) {
        value.notes[index] = note
      } else {
        value.notes.append(note)
      }
    case .link(let existing):
      let link = WorkspaceLink(
        id: existing?.id ?? UUID().uuidString, title: cleanTitle,
        url: url.trimmingCharacters(in: .whitespacesAndNewlines), detail: text)
      if let index = value.links.firstIndex(where: { $0.id == link.id }) {
        value.links[index] = link
      } else {
        value.links.append(link)
      }
    }
    Task {
      if await model.saveLibrary(value, expected: request.snapshot.token) { dismiss() }
    }
  }
}
