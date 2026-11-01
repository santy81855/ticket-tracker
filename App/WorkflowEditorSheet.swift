import AppKit
import SwiftUI
import TrackerCore
import TrackerStore
import UniformTypeIdentifiers

private enum EditorTab: String, CaseIterable {
  case step = "Step"
  case paths = "Paths"
  case testDrive = "Test drive"
}

struct WorkflowEditorSheet: View {
  @ObservedObject var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.workspaceSize) private var workspaceSize
  @State private var draft = WorkflowTemplates.personal
  @State private var baseline = WorkflowTemplates.personal
  @State private var selection = WorkflowTemplates.personalID
  @State private var selectedStep = "jiraStart"
  @State private var token: RevisionToken?
  @State private var tab = EditorTab.step
  @State private var confirmingPublish = false
  @State private var confirmingClose = false
  @State private var pendingSelection: String?
  @State private var undoStack: [WorkflowDefinition] = []
  @State private var redoStack: [WorkflowDefinition] = []
  @State private var lastUndoAt = Date.distantPast
  @State private var ignoreNextChange = false
  @State private var dropTarget: String?

  private var validationError: String? {
    do {
      try draft.validate()
      return nil
    } catch { return error.localizedDescription }
  }
  private var warnings: [String] {
    draft.warnings + (model.workflows?.catalog.columnWarnings(for: draft) ?? [])
  }
  private var isDirty: Bool { draft != baseline }
  private var isCompact: Bool { workspaceSize.width < 860 }

  var body: some View {
    VStack(spacing: 0) {
      sheetHeader(
        "Your workflow, your way",
        subtitle:
          "Published versions are immutable. New defaults never silently change existing tickets.")
      inlineError(model.errorMessage)
      toolbar.padding(.horizontal, 22).padding(.bottom, 10)
      Divider()
      if isCompact {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            stepList
            statusPanel
            detailPane
          }.padding(16)
        }
      } else {
        HStack(alignment: .top, spacing: 0) {
          VStack(spacing: 0) {
            ScrollView { stepList.padding(14) }
            Divider()
            statusPanel.padding(12)
          }.frame(width: 360)
          Divider()
          ScrollView { detailPane.padding(20) }
        }
      }
      sheetFooter {
        Button("Close") { requestClose() }.keyboardShortcut(.cancelAction)
        Button("Set default") {
          guard let token, let definition = model.workflows?.catalog.definition(selection) else {
            model.errorMessage = "Select a published workflow first."
            return
          }
          Task { if await model.defaultWorkflow(definition, token: token) { load(selection) } }
        }.disabled(
          token == nil || model.workflows?.catalog.definition(selection) != draft || model.isBusy)
        Spacer()
        if isDirty {
          Text("Unsaved changes").font(.caption).foregroundStyle(Palette.amber)
        }
        Button("Publish version…") { confirmingPublish = true }.buttonStyle(AccentButtonStyle())
          .disabled(validationError != nil || token == nil || model.isBusy)
      }
    }.modifier(WorkspaceSheetFrame(width: 1100, height: 820)).tint(Palette.accent)
      .interactiveDismissDisabled(isDirty)
      .onAppear {
        load(selection)
        tab = EditorTab(rawValue: model.workflowEditorTab) ?? .step
        model.workflowEditorTab = EditorTab.step.rawValue
      }
      .onChange(of: draft) { old, _ in recordUndo(old) }
      .confirmationDialog(
        "Discard unsaved workflow changes?", isPresented: $confirmingClose,
        titleVisibility: .visible
      ) {
        Button("Discard changes", role: .destructive) { dismiss() }
        Button("Keep editing", role: .cancel) {}
      } message: {
        Text("Nothing has been published. Closing now loses these edits.")
      }
      .confirmationDialog(
        "Switch workflows and discard your edits?",
        isPresented: Binding(
          get: { pendingSelection != nil }, set: { if !$0 { pendingSelection = nil } }),
        titleVisibility: .visible
      ) {
        Button("Discard and switch", role: .destructive) {
          if let value = pendingSelection {
            pendingSelection = nil
            selection = value
            load(value)
          }
        }
        Button("Keep editing", role: .cancel) { pendingSelection = nil }
      }
      .sheet(isPresented: $confirmingPublish) {
        PublishWorkflowSheet(model: model, draft: draft, warnings: warnings) { candidate in
          selection = candidate.id
          load(candidate.id)
        } token: {
          token
        }
      }
  }

  // MARK: Toolbar

  private var workflowPicker: some View {
    Picker(
      "Workflow",
      selection: Binding(
        get: { selection },
        set: { value in
          guard value != selection else { return }
          if isDirty && !value.isEmpty {
            pendingSelection = value
          } else {
            selection = value
            load(value)
          }
        })
    ) {
      Text("Unsaved copy").tag("")
      ForEach(model.workflows?.catalog.latest ?? []) {
        Text("\($0.name) · v\($0.version)").tag($0.id)
      }
    }.frame(maxWidth: 340)
  }
  @ViewBuilder private var toolbarActions: some View {
    Button("Duplicate") {
      draft.id = UUID().uuidString
      draft.name += " copy"
      draft.version = 0
      selection = ""
    }.buttonStyle(QuietButtonStyle()).fixedSize()
    Menu("File") {
      Button("Import…", action: importDefinition)
      Button("Export…", action: exportDefinition)
    }.fixedSize()
    Spacer(minLength: 4)
    Button {
      undo()
    } label: {
      Image(systemName: "arrow.uturn.backward")
    }.help("Undo workflow edit").disabled(undoStack.isEmpty)
    Button {
      redo()
    } label: {
      Image(systemName: "arrow.uturn.forward")
    }.help("Redo workflow edit").disabled(redoStack.isEmpty)
  }

  private var toolbar: some View {
    VStack(alignment: .leading, spacing: 10) {
      if isCompact {
        workflowPicker
        HStack(spacing: 8) { toolbarActions }
      } else {
        HStack(spacing: 8) {
          workflowPicker
          toolbarActions
        }
      }
      HStack(spacing: 10) {
        TextField("Workflow name", text: $draft.name).textFieldStyle(.roundedBorder)
        Picker("For", selection: $draft.kind) {
          Text("Jira tickets").tag(ItemKind.ticket)
          Text("Personal tasks").tag(ItemKind.task)
        }.fixedSize().disabled(!selection.isEmpty)
      }
      if let token, token.version != model.workflows?.catalog.revision {
        HStack {
          Label(
            "Workflows changed elsewhere. Reload before publishing; nothing was overwritten.",
            systemImage: "exclamationmark.triangle"
          ).font(.caption).foregroundStyle(Palette.amber)
          Button("Discard edits and reload") { load(selection) }
        }
      }
    }.padding(.top, 2)
  }

  // MARK: Step list

  private var stepList: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("STEPS").font(.system(size: 10, weight: .bold)).tracking(1.2)
          .foregroundStyle(.secondary)
        Text("\(draft.steps.count)/40").font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.tertiary)
        Spacer()
        addStepMenu
      }
      VStack(spacing: 3) {
        ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
          WorkflowStepRow(
            index: index, step: step, relation: relation(of: step),
            outOfOrder: step.dependsOn.contains { id in
              (draft.steps.firstIndex { $0.id == id } ?? -1) > index
            },
            isSelected: step.id == selectedStep, isDropTarget: dropTarget == step.id
          )
          .anchorPreference(key: StepAnchors.self, value: .bounds) { [step.id: $0] }
          .onTapGesture { selectedStep = step.id }
          .draggable(step.id)
          .dropDestination(for: String.self) { items, _ in
            guard let moved = items.first else { return false }
            moveStep(moved, before: step.id)
            return true
          } isTargeted: { targeted in
            if targeted { dropTarget = step.id } else if dropTarget == step.id { dropTarget = nil }
          }
          .contextMenu { rowMenu(step) }
        }
      }
      .padding(.leading, 18)
      .overlayPreferenceValue(StepAnchors.self) { anchors in
        GeometryReader { proxy in connections(anchors: anchors, proxy: proxy) }
      }
      Text(
        "Drag to reorder. Arrows show what the selected step needs first (purple) and what it unlocks (green)."
      )
      .font(.caption2).foregroundStyle(.secondary)
    }
  }

  private var addStepMenu: some View {
    Menu {
      Section("Start from a preset") {
        ForEach(WorkflowStepPreset.allCases, id: \.self) { preset in
          Button {
            addStep(preset.rule())
          } label: {
            Text(preset.displayName)
          }.help(preset.summary)
        }
      }
      Button("Blank step") { addStep(WorkflowRule()) }
    } label: {
      Label("Add step", systemImage: "plus")
    }.fixedSize().disabled(draft.steps.count >= 40)
  }

  @ViewBuilder private func rowMenu(_ step: WorkflowRule) -> some View {
    Button("Move earlier") { shift(step.id, by: -1) }
    Button("Move later") { shift(step.id, by: 1) }
    if step.kind == .custom {
      Button("Duplicate step") {
        var copy = step
        copy.id = "step-" + UUID().uuidString.prefix(8).lowercased()
        copy.title += " copy"
        copy.fields = copy.fields.map {
          var field = $0
          field.id = "field-" + UUID().uuidString.prefix(8).lowercased()
          return field
        }
        insert(copy, after: step.id)
      }.disabled(draft.steps.count >= 40)
    }
    Divider()
    Button("Remove step", role: .destructive) { remove(step.id) }
      .disabled(draft.steps.count <= 1)
  }

  private func relation(of step: WorkflowRule) -> WorkflowStepRow.Relation {
    guard let selected = draft.steps.first(where: { $0.id == selectedStep }) else { return .none }
    if selected.dependsOn.contains(step.id) { return .prerequisite }
    if step.dependsOn.contains(selected.id) { return .dependent }
    return .none
  }

  private func connections(anchors: [String: Anchor<CGRect>], proxy: GeometryProxy) -> some View {
    let selected = draft.steps.first { $0.id == selectedStep }
    return Canvas { context, _ in
      guard let selected, let source = anchors[selected.id].map({ proxy[$0] }) else { return }
      func link(to id: String, color: Color, arrowAtSource: Bool) {
        guard let target = anchors[id].map({ proxy[$0] }) else { return }
        let x = source.minX - 3
        let y1 = source.midY
        let y2 = target.midY
        let bulge = min(16, 6 + abs(y2 - y1) / 18)
        var path = Path()
        path.move(to: CGPoint(x: x, y: y1))
        path.addCurve(
          to: CGPoint(x: x, y: y2), control1: CGPoint(x: x - bulge, y: y1),
          control2: CGPoint(x: x - bulge, y: y2))
        context.stroke(path, with: .color(color.opacity(0.85)), lineWidth: 1.4)
        let tip = CGPoint(x: x, y: arrowAtSource ? y1 : y2)
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: tip.x - 5, y: tip.y - 3.5))
        head.addLine(to: CGPoint(x: tip.x - 5, y: tip.y + 3.5))
        head.closeSubpath()
        context.fill(head, with: .color(color))
      }
      for id in selected.dependsOn { link(to: id, color: Palette.accent, arrowAtSource: true) }
      for step in draft.dependents(of: selected.id) {
        link(to: step.id, color: Palette.green, arrowAtSource: false)
      }
    }.allowsHitTesting(false)
  }

  // MARK: Status

  private var statusPanel: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let validationError {
        Label(validationError, systemImage: "exclamationmark.circle.fill").font(.caption)
          .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      } else {
        Label(
          warnings.isEmpty ? "Ready to publish" : "Valid, with \(warnings.count) note(s)",
          systemImage: "checkmark.circle.fill"
        ).font(.caption.weight(.medium)).foregroundStyle(
          warnings.isEmpty ? Palette.green : Palette.amber)
      }
      ForEach(warnings, id: \.self) {
        Text("• \($0)").font(.caption2).foregroundStyle(Palette.amber)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !draft.isInPrerequisiteOrder {
        Button {
          draft.steps = draft.orderedByPrerequisites()
        } label: {
          Label("Fix order", systemImage: "arrow.up.arrow.down")
        }.buttonStyle(QuietButtonStyle())
          .help("Move each step after the steps it needs, keeping everything else in place.")
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: Detail pane

  private var detailPane: some View {
    VStack(alignment: .leading, spacing: 16) {
      Picker("", selection: $tab) {
        ForEach(EditorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
      switch tab {
      case .step:
        if let index = draft.steps.firstIndex(where: { $0.id == selectedStep }) {
          WorkflowRuleEditor(
            rule: $draft.steps[index], definition: draft,
            columns: model.workflows?.catalog.knownColumns ?? WorkflowCatalog.defaultColumns,
            settings: model.settings)
        } else {
          Text("Select a step on the left.").foregroundStyle(.secondary)
        }
      case .paths:
        WorkflowPathsEditor(definition: $draft)
      case .testDrive:
        WorkflowTestDrive(definition: draft, settings: model.settings)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: Editing helpers

  private func addStep(_ rule: WorkflowRule) {
    var step = rule
    if draft.steps.contains(where: { $0.id == selectedStep }) { step.dependsOn = [selectedStep] }
    insert(step, after: selectedStep)
    tab = .step
  }
  private func insert(_ step: WorkflowRule, after id: String) {
    guard draft.steps.count < 40 else { return }
    let index = draft.steps.firstIndex { $0.id == id }.map { $0 + 1 } ?? draft.steps.endIndex
    draft.steps.insert(step, at: index)
    selectedStep = step.id
  }
  private func remove(_ id: String) {
    guard draft.steps.count > 1 else { return }
    let index = draft.steps.firstIndex { $0.id == id } ?? 0
    draft.steps.removeAll { $0.id == id }
    for i in draft.steps.indices { draft.steps[i].dependsOn.removeAll { $0 == id } }
    selectedStep = draft.steps[min(index, draft.steps.count - 1)].id
  }
  private func shift(_ id: String, by distance: Int) {
    guard let index = draft.steps.firstIndex(where: { $0.id == id }),
      draft.steps.indices.contains(index + distance)
    else { return }
    draft.steps.swapAt(index, index + distance)
  }
  private func moveStep(_ id: String, before target: String) {
    guard id != target, let from = draft.steps.firstIndex(where: { $0.id == id }) else { return }
    let step = draft.steps.remove(at: from)
    let to = draft.steps.firstIndex { $0.id == target } ?? draft.steps.endIndex
    draft.steps.insert(step, at: from <= to ? to + 1 : to)
    selectedStep = id
    dropTarget = nil
  }
  private func recordUndo(_ old: WorkflowDefinition) {
    if ignoreNextChange {
      ignoreNextChange = false
      return
    }
    // Typing produces many changes; group edits made within a second into one undo step.
    if Date().timeIntervalSince(lastUndoAt) > 1 || undoStack.isEmpty {
      undoStack.append(old)
      if undoStack.count > 60 { undoStack.removeFirst() }
    }
    lastUndoAt = Date()
    redoStack.removeAll()
  }
  private func undo() {
    guard let previous = undoStack.popLast() else { return }
    redoStack.append(draft)
    restore(previous)
  }
  private func redo() {
    guard let next = redoStack.popLast() else { return }
    undoStack.append(draft)
    restore(next)
  }
  private func restore(_ value: WorkflowDefinition) {
    ignoreNextChange = true
    draft = value
    lastUndoAt = .distantPast
    if !value.steps.contains(where: { $0.id == selectedStep }) {
      selectedStep = value.steps.first?.id ?? ""
    }
  }
  private func requestClose() {
    if isDirty { confirmingClose = true } else { dismiss() }
  }
  private func load(_ id: String) {
    guard let snapshot = model.workflows else {
      model.errorMessage = "The workflow catalog is not available."
      return
    }
    token = RevisionToken(generation: snapshot.generation, version: snapshot.catalog.revision)
    if let definition = snapshot.catalog.definition(id) {
      replaceDraft(definition)
    }
  }
  private func replaceDraft(_ definition: WorkflowDefinition, dirty: Bool = false) {
    if draft != definition { ignoreNextChange = true }
    draft = definition
    baseline = dirty ? WorkflowDefinition(name: "", kind: definition.kind, steps: []) : definition
    undoStack.removeAll()
    redoStack.removeAll()
    selectedStep = definition.steps.first?.id ?? ""
  }
  private func importDefinition() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 250_000 else {
        throw TrackerError.invalid("Workflow imports must be smaller than 250 KB.")
      }
      let candidate = try StoreJSON.decode(WorkflowDefinition.self, from: Data(contentsOf: url))
      try candidate.validate()
      selection = ""
      replaceDraft(candidate, dirty: true)
    } catch { model.errorMessage = error.localizedDescription }
  }
  private func exportDefinition() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "workflow.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try StoreJSON.encode(draft, pretty: true).write(to: url, options: .atomic) } catch {
      model.errorMessage = error.localizedDescription
    }
  }
}

private struct StepAnchors: PreferenceKey {
  static let defaultValue: [String: Anchor<CGRect>] = [:]
  static func reduce(
    value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]
  ) {
    value.merge(nextValue()) { $1 }
  }
}

private struct WorkflowStepRow: View {
  enum Relation { case none, prerequisite, dependent }
  let index: Int
  let step: WorkflowRule
  let relation: Relation
  let outOfOrder: Bool
  let isSelected: Bool
  let isDropTarget: Bool

  private var symbol: String {
    if step.isWait { return "hourglass" }
    switch step.destination {
    case .board: return "rectangle.3.group"
    case .thread, .channel: return "bubble.left.and.bubble.right"
    case .mergeRequest: return "arrow.triangle.merge"
    case .issue, .custom: return "link"
    case .none: return step.fields.isEmpty ? "checkmark.circle" : "square.and.pencil"
    }
  }
  private var subtitle: String {
    var parts = [step.owner]
    if step.condition != .always { parts.append(step.condition.displayName) }
    if let only = step.onlyPaths, !only.isEmpty {
      parts.append("only: " + only.joined(separator: ", "))
    }
    if let skip = step.skipPaths, !skip.isEmpty {
      parts.append("skip: " + skip.joined(separator: ", "))
    }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    HStack(spacing: 9) {
      Text("\(index + 1)").font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
      Image(systemName: symbol).font(.system(size: 12))
        .foregroundStyle(step.enabled ? Palette.accent : Color.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(step.title).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
          .lineLimit(1).strikethrough(!step.enabled)
          .foregroundStyle(step.enabled ? Color.primary : Color.secondary)
        Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 4)
      if outOfOrder {
        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
          .foregroundStyle(Palette.amber).help("Listed before a step it depends on")
      }
      if !step.enabled {
        badge("Off", .secondary)
      } else if !step.required {
        badge("Optional", .secondary)
      }
      if step.nudgeAfterHours != nil { badge("Nudge", Palette.blue) }
      switch relation {
      case .prerequisite: badge("Needed first", Palette.accent)
      case .dependent: badge("Unlocks", Palette.green)
      case .none: EmptyView()
      }
    }
    .padding(.horizontal, 8).padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 8).fill(
        isSelected ? Palette.accent.opacity(0.14) : Color.primary.opacity(0.035))
    )
    .overlay(alignment: .top) {
      if isDropTarget { Rectangle().fill(Palette.accent).frame(height: 2).offset(y: -2) }
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
  private func badge(_ text: String, _ color: Color) -> some View {
    Text(text).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 5).padding(
      .vertical, 2
    )
    .background(color.opacity(0.14), in: Capsule()).foregroundStyle(color)
  }
}

private struct WorkflowRuleEditor: View {
  @Binding var rule: WorkflowRule
  let definition: WorkflowDefinition
  let columns: [String]
  let settings: TrackerSettings

  private var paths: [WorkflowPath] { definition.paths ?? [] }
  private var isSafeguard: Bool { [.approveMR, .qaPassed, .mergeMR].contains(rule.kind) }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(rule.title.isEmpty ? "Untitled step" : rule.title).font(.title3.weight(.semibold))
          Text(rule.kind == .custom ? "Custom step" : "Built-in: \(rule.kind.displayName)")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Toggle("Enabled", isOn: $rule.enabled)
        Toggle("Required to finish", isOn: $rule.required)
      }
      section("What to do") {
        TextField("Action title", text: $rule.title)
        TextField("Instructions", text: $rule.detail, axis: .vertical).lineLimit(2...5)
        HStack {
          TextField("Who does it", text: $rule.owner)
          Menu("Common") {
            ForEach(["Me", "Pod", "QE", "PO", "Someone else"], id: \.self) { owner in
              Button(owner) { rule.owner = owner }
            }
          }.fixedSize()
        }
        TextField("Status label while this is next (optional)", text: $rule.phase)
      }
      section("When it applies") {
        Picker("Applies", selection: $rule.condition) {
          ForEach(WorkflowCondition.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        if !paths.isEmpty {
          if isSafeguard {
            Text("Safeguard steps always apply regardless of paths.").font(.caption)
              .foregroundStyle(.secondary)
          } else {
            ForEach(paths) { path in
              Picker(path.name, selection: pathRule(path.id)) {
                Text("Applies").tag(PathRule.normal)
                Text("Only on this path").tag(PathRule.only)
                Text("Skip on this path").tag(PathRule.skip)
              }
            }
          }
        }
        Toggle("Require again after material changes / QA fixes", isOn: $rule.repeatOnRework)
      }
      section("Waiting on someone") {
        Toggle("Someone else does this; I confirm it happened", isOn: $rule.isWait)
          .onChange(of: rule.isWait) { _, wait in if !wait { rule.nudgeAfterHours = nil } }
        if rule.isWait {
          Toggle(
            "Nudge me to follow up",
            isOn: Binding(
              get: { rule.nudgeAfterHours != nil },
              set: { rule.nudgeAfterHours = $0 ? 24 : nil }))
          if let hours = rule.nudgeAfterHours {
            Stepper(
              "After \(hours < 48 ? "\(hours) hours" : "\(hours / 24) days") of waiting",
              value: Binding(
                get: { hours },
                set: { rule.nudgeAfterHours = min(720, max(1, $0)) }),
              in: 1...720, step: hours < 24 ? 1 : (hours < 48 ? 4 : 24))
            Text("Counts from when its prerequisites were confirmed. It appears in Follow-ups.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      section("Where it happens") {
        Picker("Opens", selection: $rule.destination) {
          ForEach(WorkflowDestination.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        if rule.destination == .custom { TextField("HTTPS destination URL", text: $rule.url) }
        if rule.destination == .board {
          ColumnField(
            title: "From column", text: $rule.fromColumn, columns: columns, optional: true)
          ColumnField(title: "To column", text: $rule.toColumn, columns: columns, optional: false)
          Text(
            "Board moves always require your confirmation, even when Copilot updates the tracker."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      section("Needs first") {
        let others = definition.steps.filter { $0.id != rule.id }
        let position = definition.steps.firstIndex { $0.id == rule.id } ?? 0
        ForEach(others) { dependency in
          let index = definition.steps.firstIndex { $0.id == dependency.id } ?? 0
          Toggle(
            isOn: Binding(
              get: { rule.dependsOn.contains(dependency.id) },
              set: { enabled in
                if enabled {
                  rule.dependsOn.append(dependency.id)
                } else {
                  rule.dependsOn.removeAll { $0 == dependency.id }
                }
              })
          ) {
            HStack(spacing: 6) {
              Text("\(index + 1). \(dependency.title)")
              if index > position && rule.dependsOn.contains(dependency.id) {
                Text("listed later").font(.caption2).foregroundStyle(Palette.amber)
              }
            }
          }
        }
        Toggle("Require a saved Teams thread link", isOn: $rule.requiresThread)
        Toggle("Require current-round testing notes", isOn: $rule.requiresTesting)
      }
      section("Message") {
        HStack(alignment: .top) {
          TextField("Optional message template", text: $rule.messageTemplate, axis: .vertical)
            .lineLimit(3...8)
          Menu("Insert") {
            ForEach(Self.tokens, id: \.0) { token, label in
              Button("\(label)  {{\(token)}}") { insertToken(token) }
            }
            let fields = definition.steps.flatMap(\.fields)
            if !fields.isEmpty {
              Divider()
              ForEach(fields) { field in
                Button("\(field.label)  {{field:\(field.id)}}") { insertToken("field:\(field.id)") }
              }
            }
          }.fixedSize()
        }
        if !rule.messageTemplate.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text("PREVIEW WITH A SAMPLE TICKET").font(.system(size: 9, weight: .bold)).tracking(1)
              .foregroundStyle(.secondary)
            Text(
              WorkflowSimulator.sampleMessage(
                rule.messageTemplate, definition: definition, settings: settings)
            )
            .font(.system(size: 12)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
          }.padding(10).background(
            Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
        Text("Drafting never marks a message posted.").font(.caption).foregroundStyle(.secondary)
      }
      section("Required information") {
        ForEach($rule.fields) { $field in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              TextField("Label", text: $field.label)
              Picker("Type", selection: $field.type) {
                ForEach(
                  WorkflowFieldType.allCases.filter {
                    definition.kind == .ticket || $0 != .fixVersion
                  }, id: \.self
                ) { Text($0.displayName).tag($0) }
              }.fixedSize()
              Button("Remove") { rule.fields.removeAll { $0.id == field.id } }
            }
            Text("Message token: {{field:\(field.id)}}").font(.caption2).foregroundStyle(
              .secondary
            ).textSelection(.enabled)
          }
        }
        Button("Add required information") {
          var field = WorkflowField()
          field.id = "field-" + UUID().uuidString.prefix(8).lowercased()
          rule.fields.append(field)
        }.disabled(rule.fields.count >= 8)
      }
    }
  }

  static let tokens: [(String, String)] = [
    ("ticket", "Ticket key"), ("title", "Ticket title"), ("jira", "Jira link"),
    ("mrs", "Ticket MR links"), ("pod", "Pod mention"), ("qe", "QE mention"),
    ("testing", "Testing notes"), ("environment", "Environment"),
    ("qa_action", "QA or retest"), ("finding", "QE finding / change"),
  ]

  private enum PathRule: Hashable { case normal, only, skip }
  private func pathRule(_ id: String) -> Binding<PathRule> {
    Binding(
      get: {
        if rule.onlyPaths?.contains(id) == true { return .only }
        if rule.skipPaths?.contains(id) == true { return .skip }
        return .normal
      },
      set: { value in
        var only = (rule.onlyPaths ?? []).filter { $0 != id }
        var skip = (rule.skipPaths ?? []).filter { $0 != id }
        if value == .only { only.append(id) }
        if value == .skip { skip.append(id) }
        rule.onlyPaths = only.isEmpty ? nil : only
        rule.skipPaths = skip.isEmpty ? nil : skip
      })
  }
  private func insertToken(_ token: String) {
    let text = rule.messageTemplate
    let spacer = text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") ? "" : " "
    rule.messageTemplate = text + spacer + "{{\(token)}}"
  }
  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) { content() }.padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      Text(title).font(.system(size: 11, weight: .semibold))
    }
  }
}

private struct ColumnField: View {
  let title: String
  @Binding var text: String
  let columns: [String]
  let optional: Bool
  var body: some View {
    HStack {
      TextField(optional ? "\(title) (optional)" : title, text: $text)
      Menu("Columns") {
        if optional { Button("Any column") { text = "" } }
        ForEach(columns, id: \.self) { column in Button(column) { text = column } }
      }.fixedSize()
    }
  }
}

private struct WorkflowPathsEditor: View {
  @Binding var definition: WorkflowDefinition
  private var paths: [WorkflowPath] { definition.paths ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Paths").font(.title3.weight(.semibold))
      Text(
        "Paths are variations of this workflow, like a toggle-only change that skips the QE handoff. On each step choose Applies, Only on, or Skip on. Pick a ticket's path in its details; the standard path uses no paths. Approval, QA-passed and merge safeguards cannot be skipped."
      )
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      ForEach(paths) { path in
        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              TextField("Path name", text: binding(path.id, \.name))
              Button("Remove", role: .destructive) { remove(path.id) }
            }
            TextField("When to use it (optional)", text: binding(path.id, \.detail))
            let affected = definition.steps.filter {
              ($0.onlyPaths ?? []).contains(path.id) || ($0.skipPaths ?? []).contains(path.id)
            }
            Text(
              affected.isEmpty
                ? "No steps change on this path yet. Select a step and set this path under When it applies."
                : affected.map {
                  "\(($0.skipPaths ?? []).contains(path.id) ? "Skips" : "Only here"): \($0.title)"
                }.joined(separator: "\n")
            ).font(.caption).foregroundStyle(.secondary)
            Text("ID: \(path.id)").font(.caption2).foregroundStyle(.tertiary).textSelection(
              .enabled)
          }.padding(6)
        }
      }
      HStack {
        Button("Add path") { add(name: "New path") }
        if definition.kind == .ticket && !paths.contains(where: { $0.id == "toggle-only" }) {
          Button("Add “Toggle-only change”") {
            add(
              name: "Toggle-only change", id: "toggle-only",
              detail: "Flipping a toggle in staging/prod; no QA handoff.")
            for i in definition.steps.indices
            where [.jiraValidate, .qaHandoff, .retestHandoff].contains(definition.steps[i].kind) {
              definition.steps[i].skipPaths =
                (definition.steps[i].skipPaths ?? []) + ["toggle-only"]
            }
          }
        }
      }.disabled(paths.count >= 10)
    }
  }
  private func binding(_ id: String, _ key: WritableKeyPath<WorkflowPath, String>) -> Binding<
    String
  > {
    Binding(
      get: { paths.first { $0.id == id }?[keyPath: key] ?? "" },
      set: { value in
        guard let index = definition.paths?.firstIndex(where: { $0.id == id }) else { return }
        definition.paths?[index][keyPath: key] = value
      })
  }
  private func add(name: String, id: String? = nil, detail: String = "") {
    var base =
      id
      ?? String(
        name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(30))
    if base.isEmpty { base = "path" }
    var candidate = base
    var n = 2
    while paths.contains(where: { $0.id == candidate }) {
      candidate = "\(base)-\(n)"
      n += 1
    }
    definition.paths = paths + [WorkflowPath(id: candidate, name: name, detail: detail)]
  }
  private func remove(_ id: String) {
    definition.paths = paths.filter { $0.id != id }
    if definition.paths?.isEmpty == true { definition.paths = nil }
    for i in definition.steps.indices {
      definition.steps[i].onlyPaths = definition.steps[i].onlyPaths?.filter { $0 != id }
      definition.steps[i].skipPaths = definition.steps[i].skipPaths?.filter { $0 != id }
      if definition.steps[i].onlyPaths?.isEmpty == true { definition.steps[i].onlyPaths = nil }
      if definition.steps[i].skipPaths?.isEmpty == true { definition.steps[i].skipPaths = nil }
    }
  }
}

private struct WorkflowTestDrive: View {
  let definition: WorkflowDefinition
  let settings: TrackerSettings
  @State private var qa = QARequirement.required
  @State private var retest = false
  @State private var paths: Set<String> = []
  @State private var completed: [String] = []

  private var simulation: Result<WorkflowSimulation, Error> {
    Result {
      try WorkflowSimulator.simulate(
        definition, qa: qa, retest: retest,
        paths: paths.filter { id in definition.paths?.contains { $0.id == id } == true }.sorted(),
        completed: completed.filter { id in definition.steps.contains { $0.id == id } },
        settings: settings)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Test drive").font(.title3.weight(.semibold))
      Text(
        "Walk a sample ticket through this draft. Click a step to pretend it happened. Nothing is saved, posted or moved."
      ).font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 14) {
        if definition.kind == .ticket {
          Picker("QA", selection: $qa) {
            Text("QA required").tag(QARequirement.required)
            Text("No QA").tag(QARequirement.notRequired)
            Text("Undecided").tag(QARequirement.undecided)
          }.pickerStyle(.segmented).fixedSize()
          Toggle("QE retest round", isOn: $retest).disabled(qa != .required)
        }
        Spacer()
        Button("Reset") { completed.removeAll() }.disabled(completed.isEmpty)
      }
      if let available = definition.paths, !available.isEmpty {
        HStack {
          Text("Paths:").font(.caption).foregroundStyle(.secondary)
          ForEach(available) { path in
            Toggle(
              path.name,
              isOn: Binding(
                get: { paths.contains(path.id) },
                set: { if $0 { paths.insert(path.id) } else { paths.remove(path.id) } })
            ).toggleStyle(.button)
          }
        }
      }
      switch simulation {
      case .failure(let error):
        Label(error.localizedDescription, systemImage: "exclamationmark.circle")
          .foregroundStyle(.red)
      case .success(let result):
        HStack {
          Label(
            result.isDone ? "Finished" : "Status: \(result.phase)",
            systemImage: result.isDone ? "checkmark.seal.fill" : "flag"
          ).font(.callout.weight(.semibold))
            .foregroundStyle(result.isDone ? Palette.green : Palette.accent)
          Spacer()
          if let next = result.nextStep, !result.isDone {
            Text("Next: \(next)").font(.caption).foregroundStyle(.secondary)
          }
        }
        VStack(spacing: 4) {
          ForEach(result.steps) { step in
            row(step, message: step.ruleID.flatMap { result.messages[$0] })
          }
        }
      }
    }
  }

  private func row(_ step: WorkflowStep, message: String?) -> some View {
    let ruleID = step.ruleID ?? step.id
    let done = step.state == .completed || step.state == .waived
    return Button {
      if done {
        completed.removeAll { $0 == ruleID }
      } else if step.canRecord {
        completed.append(ruleID)
      }
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(
          systemName: done
            ? "checkmark.circle.fill"
            : step.state == .notApplicable
              ? "minus.circle" : step.canRecord ? "circle" : "lock.circle"
        )
        .foregroundStyle(
          done ? Palette.green : step.canRecord ? Palette.accent : Color.secondary.opacity(0.6))
        VStack(alignment: .leading, spacing: 2) {
          Text(step.title).font(.system(size: 12, weight: step.canRecord ? .semibold : .regular))
            .strikethrough(step.state == .notApplicable)
            .foregroundStyle(step.state == .notApplicable ? Color.secondary : Color.primary)
          if step.state == .notApplicable {
            Text("Skipped on this path").font(.caption2).foregroundStyle(.tertiary)
          } else if !done, let blocker = step.blockers.first {
            Text(blocker).font(.caption2).foregroundStyle(.secondary)
          }
          if let message, !message.isEmpty, step.state != .notApplicable {
            Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
              .padding(.top, 2)
          }
        }
        Spacer()
        Text(step.owner ?? "Me").font(.caption2).foregroundStyle(.secondary)
        if step.isOptional == true {
          Text("optional").font(.caption2).foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 10).padding(.vertical, 7)
      .background(
        step.canRecord ? Palette.accent.opacity(0.07) : Color.primary.opacity(0.03),
        in: RoundedRectangle(cornerRadius: 8)
      )
      .contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(!done && !step.canRecord)
  }
}

private struct PublishWorkflowSheet: View {
  @ObservedObject var model: WorkspaceModel
  let draft: WorkflowDefinition
  let warnings: [String]
  let onPublished: (WorkflowDefinition) -> Void
  let token: () -> RevisionToken?
  @Environment(\.dismiss) private var dismiss
  @State private var reason = ""
  @State private var makeDefault = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Publish \(draft.name)").font(.title3.weight(.semibold))
      TextField("Why are you changing this workflow?", text: $reason)
      Toggle(
        "Make this the default for new \(draft.kind == .ticket ? "tickets" : "tasks")",
        isOn: $makeDefault)
      if !warnings.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(warnings, id: \.self) {
            Text("• \($0)").font(.caption).foregroundStyle(Palette.amber)
          }
        }
      }
      Text(
        "Existing items keep their workflow until you choose Change workflow on that item and review its migration preview. This changes tracker guidance only, not Jira, Teams, or GitLab."
      ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Publish") {
          guard let token = token() else {
            model.errorMessage = "Reload the workflow catalog."
            return
          }
          let candidate = draft
          Task {
            if await model.saveWorkflow(
              candidate, token: token, reason: reason, makeDefault: makeDefault)
            {
              dismiss()
              onPublished(candidate)
            }
          }
        }.buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
          .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
      }
    }.padding(22).frame(width: 460)
  }
}

struct WorkflowAdoptionSheet: View {
  @ObservedObject var model: WorkspaceModel
  let snapshot: ItemSnapshot
  @Environment(\.dismiss) private var dismiss
  @State private var workflowID = ""
  private var target: WorkflowDefinition? { model.workflows?.catalog.definition(workflowID) }
  private var preview: String {
    do {
      guard let target else { return "Choose a published workflow." }
      return try ConfiguredWorkflow.migrationPreview(snapshot.item, to: target).joined(
        separator: "\n\n")
    } catch { return error.localizedDescription }
  }
  var body: some View {
    VStack(spacing: 0) {
      sheetHeader(
        "Review this ticket's new workflow",
        subtitle: "Nothing changes until you explicitly apply it.")
      inlineError(model.errorMessage)
      Picker("Workflow", selection: $workflowID) {
        Text("Choose…").tag("")
        ForEach(model.workflows?.catalog.latest.filter { $0.kind == snapshot.item.kind } ?? []) {
          Text("\($0.name) · v\($0.version)").tag($0.id)
        }
      }.padding(.horizontal, 26)
      ScrollView {
        Text(preview).frame(maxWidth: .infinity, alignment: .leading).padding(26).textSelection(
          .enabled)
      }
      sheetFooter {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Apply reviewed workflow") {
          guard let target else {
            model.errorMessage = "Choose a workflow first."
            return
          }
          Task {
            if await model.mutate(
              snapshot,
              .adoptWorkflow(
                target,
                reason:
                  "Explicitly applied after reviewing the workflow migration in the desktop app."))
            {
              dismiss()
            }
          }
        }.buttonStyle(AccentButtonStyle()).disabled(target == nil || model.isBusy)
      }
    }.modifier(WorkspaceSheetFrame(width: 650, height: 620)).tint(Palette.accent)
  }
}

struct MergeConfirmation: Identifiable {
  let id = UUID()
  let snapshot: ItemSnapshot
  let step: WorkflowStep
}
struct MergeConfirmationSheet: View {
  @ObservedObject var model: WorkspaceModel
  let confirmation: MergeConfirmation
  @Environment(\.dismiss) private var dismiss
  @State private var occurredAt = Date()
  @State private var confirmedDate = false
  var body: some View {
    VStack(spacing: 0) {
      sheetHeader("Record the actual merge", subtitle: confirmation.step.title)
      inlineError(model.errorMessage)
      Form {
        Text(
          "This records a merge that already happened; it does not merge anything in GitLab. For an older merge, change the date to GitLab's actual merged_at."
        )
        DatePicker("Actually merged at", selection: $occurredAt, in: ...Date())
        Toggle("I checked this is the actual merge date", isOn: $confirmedDate)
        Text(
          "Fix Version/s uses the Tuesday after the last ticket MR merge, never the date you recorded it here. Workspace MRs do not affect that calculation."
        )
        .font(.caption).foregroundStyle(.secondary)
      }.formStyle(.grouped)
      sheetFooter {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Record merged") {
          Task {
            if await model.mutate(
              confirmation.snapshot,
              .recordFact(
                FactInput(
                  actionID: confirmation.step.id,
                  note:
                    "User confirmed the MR is merged and checked the actual GitLab merge timestamp.",
                  occurredAt: occurredAt)))
            {
              dismiss()
            }
          }
        }.buttonStyle(AccentButtonStyle()).disabled(!confirmedDate || model.isBusy)
      }
    }.modifier(WorkspaceSheetFrame(width: 620, height: 460)).tint(Palette.accent)
  }
}
