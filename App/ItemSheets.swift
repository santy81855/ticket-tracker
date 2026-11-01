import SwiftUI
import TrackerCore

struct NewItemSheet: View {
  @ObservedObject var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var kind: ItemKind = .ticket
  @State private var title = ""
  @State private var jira = ""
  @State private var notes = ""
  @State private var qa: QARequirement = .undecided
  @State private var workflowID = ""
  @State private var hasFollowUp = false
  @State private var followUp = Date().addingTimeInterval(86400)

  var body: some View {
    VStack(spacing: 0) {
      sheetHeader(
        "Make room in your head", subtitle: "Capture the work. We will keep track of the next step."
      )
      inlineError(model.errorMessage)
      Form {
        Section {
          Picker("What are you tracking?", selection: $kind) {
            Text("Jira ticket").tag(ItemKind.ticket)
            Text("Personal task").tag(ItemKind.task)
          }.pickerStyle(.segmented)
          TextField(kind == .ticket ? "Ticket title" : "What do you need to do?", text: $title)
          if kind == .ticket {
            TextField("Jira URL or ticket key", text: $jira)
            Picker("QA path", selection: $qa) {
              ForEach(QARequirement.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Workflow", selection: $workflowID) {
              Text("Workspace default").tag("")
              ForEach(model.workflows?.catalog.latest.filter { $0.kind == kind } ?? []) {
                Text("\($0.name) · v\($0.version)").tag($0.id)
              }
            }
            Text(
              "New items capture this published version. Later workflow edits do not silently change existing items."
            )
            .font(.caption).foregroundStyle(.secondary)
            Text("Not sure yet? Leave it undecided. Approvals are required on both paths.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        Section("A little context") {
          TextEditor(text: $notes).font(.system(size: 12)).frame(height: 90)
        }
        Section {
          Toggle("Schedule a follow-up", isOn: $hasFollowUp)
          if hasFollowUp { DatePicker("When", selection: $followUp) }
        }
      }.formStyle(.grouped)
      sheetFooter {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(kind == .ticket ? "Add ticket" : "Capture task") {
          var input = NewItem(
            kind: kind, title: title, jira: jira, qa: qa, notes: notes,
            followUpAt: hasFollowUp ? followUp : nil)
          input.workflowID = workflowID.isEmpty ? nil : workflowID
          Task { if await model.create(input) { dismiss() } }
        }.buttonStyle(AccentButtonStyle()).disabled(
          title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy
        )
        .keyboardShortcut(.defaultAction)
      }
    }.modifier(WorkspaceSheetFrame(width: 570, height: 590)).tint(Palette.accent)
      .onChange(of: kind) { _, _ in workflowID = "" }
  }
}

struct EditItemSheet: View {
  @ObservedObject var model: WorkspaceModel
  let snapshot: ItemSnapshot
  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var notes: String
  @State private var thread: String
  @State private var testing: String
  @State private var environment: String
  @State private var qe: String
  @State private var waiting: String
  @State private var qa: QARequirement
  @State private var qaReason = ""
  @State private var fieldValues: [String: String]
  @State private var paths: Set<String>
  @State private var hasFollowUp: Bool
  @State private var followUp: Date

  init(model: WorkspaceModel, snapshot: ItemSnapshot) {
    self.model = model
    self.snapshot = snapshot
    _title = State(initialValue: snapshot.item.title)
    _notes = State(initialValue: snapshot.item.notes)
    _thread = State(initialValue: snapshot.item.threadURL)
    _testing = State(initialValue: snapshot.item.testingNotes)
    _environment = State(initialValue: snapshot.item.environment)
    _qe = State(initialValue: snapshot.item.qe)
    _waiting = State(initialValue: snapshot.item.waitingOn)
    _qa = State(initialValue: snapshot.item.qa)
    _fieldValues = State(initialValue: snapshot.item.fieldValues ?? [:])
    _paths = State(initialValue: Set(snapshot.item.paths ?? []))
    _hasFollowUp = State(initialValue: snapshot.item.followUpAt != nil)
    _followUp = State(initialValue: snapshot.item.followUpAt ?? Date().addingTimeInterval(86400))
  }
  var body: some View {
    VStack(spacing: 0) {
      sheetHeader(
        "The details make it easier",
        subtitle: snapshot.item.jiraKey.isEmpty ? "Personal task" : snapshot.item.jiraKey)
      inlineError(model.errorMessage)
      Form {
        Section("Basics") {
          TextField("Title", text: $title)
          if snapshot.item.kind == .ticket {
            TextField("Teams thread URL", text: $thread)
            Picker("QA path", selection: $qa) {
              ForEach(QARequirement.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if qa == .notRequired && snapshot.item.qa != .notRequired {
              TextField("Why is QA not required?", text: $qaReason)
            }
          } else {
            TextField("Waiting on (optional)", text: $waiting)
          }
        }
        if let available = snapshot.item.workflow?.paths, !available.isEmpty {
          Section("Workflow path") {
            ForEach(available) { path in
              Toggle(
                isOn: Binding(
                  get: { paths.contains(path.id) },
                  set: { if $0 { paths.insert(path.id) } else { paths.remove(path.id) } })
              ) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(path.name)
                  if !path.detail.isEmpty {
                    Text(path.detail).font(.caption).foregroundStyle(.secondary)
                  }
                }
              }
            }
            Text(
              "Leave all off for the standard path. Approval, QA and merge safeguards still apply."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
        Section("Notes") { TextEditor(text: $notes).font(.system(size: 12)).frame(height: 70) }
        if let definition = snapshot.item.workflow {
          ForEach(definition.steps.filter { $0.enabled && !$0.fields.isEmpty }) { rule in
            Section(rule.title) {
              ForEach(rule.fields) { field in
                TextField(
                  field.label,
                  text: Binding(
                    get: { fieldValues[field.id] ?? "" },
                    set: { fieldValues[field.id] = $0 }))
                if field.type == .fixVersion {
                  if let value = ConfiguredWorkflow.fixVersion(for: snapshot.item) {
                    Button("Use suggested \(value)") { fieldValues[field.id] = value }
                    Text(
                      "Tuesday strictly after the last ticket MR merge, using this Mac's calendar/time zone. Workspace MRs are excluded."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                  } else {
                    Text(
                      "Record each ticket MR's actual merge date first. Never use the date an older merge was added to the tracker."
                    )
                    .font(.caption).foregroundStyle(Palette.amber)
                  }
                }
              }
            }
          }
        }
        if snapshot.item.kind == .ticket {
          Section("QE handoff / retest") {
            TextField("Environment", text: $environment)
            TextField("QE contact (overrides the default)", text: $qe)
            TextEditor(text: $testing).font(.system(size: 12)).frame(height: 100)
            Text(
              "Saving confirms these testing notes apply to the current changes. Do not invent test results."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
        Section {
          Toggle("Schedule a follow-up", isOn: $hasFollowUp)
          if hasFollowUp { DatePicker("When", selection: $followUp) }
        }
      }.formStyle(.grouped)
      sheetFooter {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Save details") {
          var patch = DetailsPatch()
          patch.title = title
          patch.notes = notes
          patch.threadURL = thread
          patch.testingNotes = testing
          patch.environment = environment
          patch.qe = qe
          patch.waitingOn = waiting
          patch.qa = qa
          patch.qaReason = qaReason
          patch.followUpAt = hasFollowUp ? followUp : nil
          patch.clearFollowUp = !hasFollowUp
          patch.fieldValues = fieldValues
          if snapshot.item.workflow?.paths?.isEmpty == false
            && paths != Set(snapshot.item.paths ?? [])
          {
            patch.paths = paths.sorted()
          }
          Task { if await model.mutate(snapshot, .edit(patch)) { dismiss() } }
        }.buttonStyle(AccentButtonStyle()).disabled(model.isBusy)
      }
    }.modifier(WorkspaceSheetFrame(width: 620, height: 700)).tint(Palette.accent)
  }
}

struct DraftRequest: Identifiable {
  let item: WorkItem
  let kind: DraftKind
  var actionID: String? = nil
  var id: String { actionID ?? kind.rawValue }

  static func kind(for step: WorkflowStep) -> DraftKind? {
    if step.messageTemplate?.isEmpty == false { return .kickoff }
    return switch step.kind {
    case .kickoff: .kickoff
    case .approvalRequest: .approvals
    case .qaHandoff, .retestHandoff: .qa
    default: nil
    }
  }
}

struct DraftSheet: View {
  @ObservedObject var model: WorkspaceModel
  let item: WorkItem
  let actionID: String?
  @Environment(\.dismiss) private var dismiss
  @State private var kind: DraftKind
  @State private var text = ""
  @State private var destination = ""
  @State private var missing: [String] = []
  @State private var draftError: String?

  private var isJiraComment: Bool {
    guard let actionID else { return false }
    return Workflow.steps(for: item).first { $0.id == actionID }?.destination == .issue
  }

  init(model: WorkspaceModel, item: WorkItem, initialKind: DraftKind, actionID: String? = nil) {
    self.model = model
    self.item = item
    self.actionID = actionID
    _kind = State(initialValue: initialKind)
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 5) {
            Text(isJiraComment ? "Jira comment" : "Message draft")
              .font(.system(size: 23, weight: .bold, design: .rounded))
            Text("Draft only. Review before posting.").font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
          if actionID == nil {
            Picker("Message", selection: $kind) {
              ForEach(DraftKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
          }
          if let draftError {
            Label(draftError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
          }
          if !missing.isEmpty {
            Label("Add: \(missing.joined(separator: ", "))", systemImage: "info.circle")
              .font(.system(size: 11)).foregroundStyle(Palette.amber)
          }
          TextEditor(text: $text).font(.system(size: 13)).padding(10).frame(height: 230)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.border))
          Label(
            isJiraComment
              ? "Copying does not post this comment."
              : "Select real @mentions in Teams. Copying does not post the message.",
            systemImage: isJiraComment ? "info.circle" : "at"
          )
          .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(
            horizontal: false, vertical: true)
        }.padding(24)
      }
      sheetFooter {
        Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(isJiraComment ? "Open Jira" : "Open Teams") { model.openLink(destination) }
          .buttonStyle(QuietButtonStyle())
          .disabled(destination.isEmpty)
        Button {
          model.copy(text)
        } label: {
          Label("Copy draft", systemImage: "doc.on.doc")
        }
        .buttonStyle(AccentButtonStyle()).disabled(draftError != nil)
      }
    }.modifier(WorkspaceSheetFrame(width: 640, height: 550)).tint(Palette.accent)
      .onAppear { render() }
      .onChange(of: kind) { _, _ in render() }
  }
  private func render() {
    do {
      let draft =
        try actionID.map { try Messages.draft(actionID: $0, item: item, settings: model.settings) }
        ?? Messages.draft(kind, item: item, settings: model.settings)
      text = draft.text
      destination = draft.destination
      missing = draft.missing
      draftError = nil
    } catch { draftError = error.localizedDescription }
  }
}

func sheetHeader(_ title: String, subtitle: String) -> some View {
  VStack(alignment: .leading, spacing: 7) {
    Text(title).font(.system(size: 22, weight: .bold, design: .rounded))
    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
  }.frame(maxWidth: .infinity, alignment: .leading).padding(26)
}

func sheetFooter<Content: View>(@ViewBuilder content: () -> Content) -> some View {
  HStack { content() }.padding(.horizontal, 26).padding(.vertical, 18)
}

@ViewBuilder
func inlineError(_ message: String?) -> some View {
  if let message {
    Label(message, systemImage: "exclamationmark.circle")
      .font(.system(size: 11)).foregroundStyle(.red)
      .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 26).padding(.bottom, 8)
  }
}

/// Inline entry for a step's required fields (such as Fix Version/s), so the step can move forward
/// without opening the full details sheet.
struct RequiredFieldsEditor: View {
  @ObservedObject var model: WorkspaceModel
  let snapshot: ItemSnapshot
  let step: WorkflowStep
  var onSaved: (() -> Void)? = nil
  @State private var values: [String: String] = [:]

  static func rule(for step: WorkflowStep, in item: WorkItem) -> WorkflowRule? {
    guard step.state == .pending, let definition = item.workflow else { return nil }
    let rule = definition.steps.first { $0.id == (step.ruleID ?? step.id) }
    return rule?.fields.isEmpty == false ? rule : nil
  }

  /// Blockers that the inline fields already explain.
  static func fieldBlockers(for step: WorkflowStep, in item: WorkItem) -> Set<String> {
    guard let rule = rule(for: step, in: item) else { return [] }
    return Set(ConfiguredWorkflow.requiredFieldBlockers(rule, item: item))
  }

  var body: some View {
    if let rule = Self.rule(for: step, in: snapshot.item) {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(rule.fields) { field in fieldRow(field) }
        if dirty(rule) {
          Button {
            Task { await save() }
          } label: {
            Label("Save", systemImage: "square.and.arrow.down")
          }.buttonStyle(QuietButtonStyle()).disabled(model.isBusy)
        }
      }
      .onAppear { prefill(rule) }
      .onChange(of: snapshot.item.fieldValues) { _, _ in prefill(rule) }
    }
  }

  @ViewBuilder
  private func fieldRow(_ field: WorkflowField) -> some View {
    let saved = snapshot.item.fieldValues?[field.id] ?? ""
    let suggestion =
      field.type == .fixVersion ? ConfiguredWorkflow.fixVersion(for: snapshot.item) : nil
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(field.label).font(.system(size: 12, weight: .semibold))
          .frame(minWidth: 90, alignment: .leading)
        TextField(
          placeholder(field),
          text: Binding(get: { values[field.id] ?? "" }, set: { values[field.id] = $0 })
        )
        .textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
        .frame(maxWidth: 220)
        .onSubmit { Task { await save() } }
        if !saved.isEmpty, saved == values[field.id],
          !ConfiguredWorkflow.requiredFieldBlockers(rule(field), item: snapshot.item).contains(
            where: { $0.hasPrefix(field.label) })
        {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
            .help("Saved")
        }
      }
      if field.type == .fixVersion {
        if let suggestion {
          Text("Tuesday after the last merge: \(suggestion)").font(.system(size: 11))
            .foregroundStyle(.secondary)
        } else {
          Text("Record each MR's actual merge time first.").font(.system(size: 11))
            .foregroundStyle(Palette.amber)
        }
      }
    }
  }

  private func rule(_ field: WorkflowField) -> WorkflowRule {
    var rule = WorkflowRule(id: "field", title: field.label)
    rule.fields = [field]
    return rule
  }

  private func placeholder(_ field: WorkflowField) -> String {
    switch field.type {
    case .fixVersion: "2026.11.3"
    case .date: "yyyy-MM-dd"
    case .url: "https://…"
    case .text: field.label
    }
  }

  private func prefill(_ rule: WorkflowRule) {
    for field in rule.fields {
      let saved = snapshot.item.fieldValues?[field.id] ?? ""
      if !saved.isEmpty {
        values[field.id] = saved
      } else if values[field.id]?.isEmpty ?? true, field.type == .fixVersion {
        values[field.id] = ConfiguredWorkflow.fixVersion(for: snapshot.item) ?? ""
      }
    }
  }

  private func dirty(_ rule: WorkflowRule) -> Bool {
    rule.fields.contains { field in
      let value = (values[field.id] ?? "").trimmingCharacters(in: .whitespaces)
      return !value.isEmpty && value != (snapshot.item.fieldValues?[field.id] ?? "")
    }
  }

  private func save() async {
    var patch = DetailsPatch()
    patch.fieldValues = values.mapValues { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.value.isEmpty }
    guard patch.fieldValues?.isEmpty == false else { return }
    if await model.mutate(snapshot, .edit(patch)) { onSaved?() }
  }
}
