import SwiftUI
import TrackerCore

struct TicketDetailView: View {
  @ObservedObject var model: WorkspaceModel
  let snapshot: ItemSnapshot
  @State private var tab = "Workflow"
  @State private var editing = false
  @State private var mrURL = ""
  @State private var addingMR = false
  @State private var adoptingWorkflow = false
  @State private var showsActionDetails = false
  @State private var showsSkippedSteps = false
  @State private var prompt: ActionPrompt?

  private var item: WorkItem { snapshot.item }
  private var applicable: [WorkflowStep] { snapshot.steps.filter { $0.state != .notApplicable } }
  private var completed: Int {
    applicable.filter { $0.state == .completed || $0.state == .waived }.count
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        detailHeader
        currentAction
        if item.kind == .ticket { links }
        Picker("Detail section", selection: $tab) {
          Text("Workflow").tag("Workflow")
          Text("Ticket notes").tag("Notes")
          Text("Activity").tag("Activity")
        }.pickerStyle(.segmented).labelsHidden()
        switch tab {
        case "Notes": notes
        case "Activity": activity
        default: checklist
        }
        if !item.isDone { followUp }
      }.padding(.bottom, 20).padding(.trailing, 2)
    }
    .sheet(isPresented: $editing) { EditItemSheet(model: model, snapshot: snapshot) }
    .sheet(item: $model.draft) { request in
      DraftSheet(
        model: model, item: request.item, initialKind: request.kind, actionID: request.actionID)
    }
    .sheet(item: $prompt) { value in
      ActionPromptSheet(model: model, snapshot: value.snapshot, prompt: value)
    }
    .sheet(isPresented: $adoptingWorkflow) {
      WorkflowAdoptionSheet(model: model, snapshot: snapshot)
    }
    .sheet(item: $model.mergeConfirmation) {
      MergeConfirmationSheet(model: model, confirmation: $0)
    }
    .sheet(item: $model.completion) {
      CompletionConfirmationSheet(model: model, confirmation: $0)
    }
    .alert("Add a merge request", isPresented: $addingMR) {
      TextField("https://gitlab…/-/merge_requests/123", text: $mrURL)
      Button("Add ticket MR") {
        let link = mrURL
        Task { if await model.mutate(snapshot, .addMR(link)) { mrURL = "" } }
      }.disabled(item.isDone)
      Button("Add workspace MR") {
        let link = mrURL
        Task { if await model.mutate(snapshot, .addWorkspaceMR(link)) { mrURL = "" } }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Ticket MRs affect review readiness. Workspace MRs are optional and can be merged after completion."
      )
    }
  }

  @ViewBuilder
  private var currentAction: some View {
    if item.isDone {
      Surface {
        VStack(alignment: .leading, spacing: 14) {
          HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 28)).foregroundStyle(
              Palette.green)
            Text("Development complete").font(.system(size: 16, weight: .semibold))
          }
          HStack {
            if let step = Workflow.lastRecordedStep(for: item) {
              Button("Undo last confirmation…") {
                prompt = ActionPrompt(snapshot: snapshot, mode: .undo, step: step)
              }.buttonStyle(QuietButtonStyle())
            }
            Button("Reopen") { Task { await model.mutate(snapshot, .reopen) } }
              .buttonStyle(QuietButtonStyle())
          }
        }
      }
    } else if let next = snapshot.nextStep {
      nextAction(next)
    }
  }

  private var detailHeader: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(item.kind == .ticket ? item.jiraKey : "Personal task")
          .font(.system(size: 20, weight: .bold, design: .monospaced))
          .foregroundStyle(Palette.accent)
        Spacer()
        Button {
          editing = true
        } label: {
          Image(systemName: "slider.horizontal.3")
        }.buttonStyle(.plain).help("Edit item details")
        if item.kind == .ticket && !item.isDone {
          Menu {
            Button(item.isInQA ? "Record QA finding…" : "Record material change…") {
              prompt = ActionPrompt(snapshot: snapshot, mode: .rework)
            }
          } label: {
            Image(systemName: "ellipsis")
          }.menuStyle(.borderlessButton).frame(width: 20)
        }
      }
      Text(item.title).font(.system(size: 20, weight: .semibold, design: .rounded)).fixedSize(
        horizontal: false, vertical: true)
      HStack(alignment: .top, spacing: 10) {
        RoundedRectangle(cornerRadius: 2)
          .fill(snapshot.stageColor)
          .frame(width: 4)
        VStack(alignment: .leading, spacing: 7) {
          Text(snapshot.phase).font(.system(size: 23, weight: .bold, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("ticket-status")
          if item.kind == .ticket {
            Text(item.qa.label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
          }
          if let names = item.workflow?.paths?.filter({ (item.paths ?? []).contains($0.id) })
            .map(\.name), !names.isEmpty
          {
            Label(names.joined(separator: ", "), systemImage: "arrow.triangle.branch")
              .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
          }
        }
        Spacer(minLength: 0)
      }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
    }.padding(.horizontal, 2).padding(.bottom, 2)
  }

  private func nextAction(_ step: WorkflowStep) -> some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack {
        Label(
          step.isWait ? "WAITING" : "NEXT STEP",
          systemImage: step.isWait ? "hourglass" : "sparkles"
        )
        .font(.system(size: 9, weight: .bold)).tracking(1.3).foregroundStyle(Palette.accent)
        Spacer()
        Text("\(completed)/\(applicable.count)").font(
          .system(size: 10, weight: .medium, design: .monospaced)
        ).foregroundStyle(.secondary)
      }
      Text(step.title).font(.system(size: 16, weight: .semibold))
      ForEach(snapshot.nudges) { waiting in
        Label("\(waiting.title): \(waiting.nudge ?? "")", systemImage: "bell.badge")
          .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.amber)
          .fixedSize(horizontal: false, vertical: true)
      }
      DisclosureGroup("Details", isExpanded: $showsActionDetails) {
        Text(step.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
          horizontal: false, vertical: true)
      }.font(.system(size: 11)).foregroundStyle(.secondary)
      RequiredFieldsEditor(model: model, snapshot: snapshot, step: step)
      let needsThread = step.blockers.contains(ThreadLinkField.blocker)
      if needsThread { ThreadLinkField(model: model, snapshot: snapshot) }
      let fieldBlockers = RequiredFieldsEditor.fieldBlockers(for: step, in: item)
        .union(needsThread ? [ThreadLinkField.blocker] : [])
      let otherBlockers = step.blockers.filter { !fieldBlockers.contains($0) }
      if !otherBlockers.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(otherBlockers, id: \.self) {
            Text("• \($0)").font(.system(size: 11)).foregroundStyle(Palette.amber)
          }
        }
      }
      if let owner = step.owner {
        Label(owner, systemImage: "person").font(.caption).foregroundStyle(.secondary)
      }
      actionLinks(step)
      completionButton(step).padding(.vertical, 3)
      GeometryReader { geometry in
        Capsule().fill(Palette.accent.opacity(0.10))
          .overlay(alignment: .leading) {
            Capsule().fill(Palette.accent.opacity(0.65))
              .frame(
                width: geometry.size.width * CGFloat(completed) / CGFloat(max(1, applicable.count)))
          }
      }.frame(height: 3).padding(.top, 2)
      if let previous = Workflow.lastRecordedStep(for: item) {
        Button {
          prompt = ActionPrompt(snapshot: snapshot, mode: .undo, step: previous)
        } label: {
          Label("Undo last confirmation…", systemImage: "arrow.uturn.backward")
        }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
          .help("Undo: \(previous.title)")
      }
    }
    .padding(19).frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.accent.opacity(0.14)))
  }

  private func actionLinks(_ step: WorkflowStep) -> some View {
    HStack(spacing: 8) {
      if step.destination == .board
        || [.jiraStart, .jiraValidate, .jiraReady, .jiraDone].contains(step.kind)
      {
        Button {
          model.openBoard(for: item)
        } label: {
          Label("Open board", systemImage: "rectangle.3.group")
        }.buttonStyle(QuietButtonStyle())
      } else if let link = link(for: step), !link.isEmpty {
        Button {
          model.openLink(link)
        } label: {
          Label(linkLabel(for: step), systemImage: "arrow.up.right")
        }
        .buttonStyle(QuietButtonStyle())
      }
      if DraftRequest.kind(for: step) != nil {
        Button("Prepare message") {
          model.requestDraft(snapshot, step: step)
        }.buttonStyle(QuietButtonStyle())
      }
    }
  }

  @ViewBuilder
  private func completionButton(_ step: WorkflowStep) -> some View {
    if step.kind == .qaDecision {
      Button("Choose QA path") { editing = true }.buttonStyle(AccentButtonStyle())
    } else if step.canRecord {
      Button {
        confirm(step)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill")
          Text(step.kind == .implementation ? "Mark complete" : "Confirm completed")
        }.frame(maxWidth: .infinity)
      }
      .buttonStyle(PrimaryCompletionButtonStyle()).disabled(model.isBusy)
    } else if step.blockers == [ThreadLinkField.blocker] {
      Label("Save the thread link above to confirm", systemImage: "link")
        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
    } else {
      Button("Edit details") { editing = true }.buttonStyle(QuietButtonStyle())
    }
  }

  private var links: some View {
    Surface(padding: 16) {
      VStack(alignment: .leading, spacing: 13) {
        HStack {
          Text("Links").font(.system(size: 15, weight: .semibold))
          Spacer()
          if item.kind == .ticket {
            Button {
              addingMR = true
            } label: {
              Label("Add MR", systemImage: "plus")
            }
            .font(.system(size: 10, weight: .medium)).buttonStyle(.plain).foregroundStyle(
              Palette.accent)
          }
        }
        HStack(spacing: 8) {
          Button {
            model.openLink(item.jiraURL)
          } label: {
            Label("Jira", systemImage: "arrow.up.right.square")
          }
          .buttonStyle(QuietButtonStyle())
          Button {
            if item.threadURL.isEmpty { editing = true } else { model.openLink(item.threadURL) }
          } label: {
            Label(
              item.threadURL.isEmpty ? "Add Teams thread" : "Teams thread",
              systemImage: "bubble.left")
          }
          .buttonStyle(QuietButtonStyle())
          Spacer(minLength: 0)
        }
        ForEach(item.mergeRequests) { mr in
          HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.pull").foregroundStyle(Palette.accent).frame(
              width: 15)
            Button(mr.shortName) { model.openLink(mr.url) }
              .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer()
            Menu(mr.role == .workspace ? "Workspace" : "Ticket") {
              Button("Ticket MR · blocks completion") {
                Task { await model.mutate(snapshot, .classifyMR(id: mr.id, role: .ticket)) }
              }.disabled(item.isDone)
              Button("Workspace MR · optional") {
                Task { await model.mutate(snapshot, .classifyMR(id: mr.id, role: .workspace)) }
              }
            }.font(.system(size: 10)).menuStyle(.borderlessButton).fixedSize()
            if item.has(.mergeMR, mrID: mr.id) {
              StatusPill(text: "Merged", color: Palette.green)
              if item.record(.mergeMR, mrID: mr.id)?.occurredAt == nil,
                let step = snapshot.steps.first(where: { $0.kind == .mergeMR && $0.mrID == mr.id })
              {
                Button("Add merge date") {
                  model.mergeConfirmation = MergeConfirmation(snapshot: snapshot, step: step)
                }
                .font(.caption).buttonStyle(.plain)
              }
            } else if item.has(.approveMR, mrID: mr.id) {
              StatusPill(text: "Approved", color: Palette.green)
            } else {
              Text("Review pending").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(.tertiary)
          }
        }
        if item.mergeRequests.isEmpty {
          Text("No merge requests").font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
      }
    }
  }

  private var checklist: some View {
    let undoID = Workflow.lastRecordedStep(for: item)?.id
    return Surface(padding: 16) {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text("Workflow").font(.system(size: 15, weight: .semibold))
          Spacer()
          if item.kind == .ticket {
            Text("Round \(item.reviewRound + 1)").font(.system(size: 10)).foregroundStyle(.tertiary)
          }
        }.padding(.bottom, 15)
        if !item.isDone {
          HStack {
            Text(item.workflow.map { "\($0.name) · v\($0.version)" } ?? "Original workflow · v1")
              .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Change workflow…") { adoptingWorkflow = true }.buttonStyle(.plain)
              .font(.caption).foregroundStyle(Palette.accent)
          }.padding(.bottom, 12)
        }
        ForEach(snapshot.steps.filter { showsSkippedSteps || $0.state != .notApplicable }) { step in
          HStack(alignment: .top, spacing: 11) {
            Button {
              if step.canRecord { confirm(step) }
            } label: {
              Image(systemName: icon(for: step)).font(.system(size: 16, weight: .light))
                .foregroundStyle(
                  step.state == .completed
                    ? Palette.green
                    : (step.canRecord ? Palette.accent : Color.secondary.opacity(0.45))
                )
                .frame(width: 20, height: 20)
            }.buttonStyle(.plain).disabled(!step.canRecord || model.isBusy)
              .help(
                step.blockers.isEmpty
                  ? "Confirm this action" : step.blockers.joined(separator: "\n"))
            VStack(alignment: .leading, spacing: 4) {
              Text(step.title).font(
                .system(size: 11, weight: step.state == .pending ? .medium : .regular)
              )
              .foregroundStyle(
                step.state == .notApplicable ? Color.secondary.opacity(0.55) : Color.primary
              )
              .strikethrough(step.state == .notApplicable)
              if step.state == .waived {
                Text("Waived with a reason · see activity").font(.system(size: 10)).foregroundStyle(
                  Palette.amber)
              } else if step.state == .notApplicable {
                Text("Not applicable on this path").font(.system(size: 10)).foregroundStyle(
                  .tertiary)
              } else if step.state == .pending, !step.blockers.isEmpty {
                Text(step.blockers.first ?? "").font(.system(size: 10)).foregroundStyle(.tertiary)
                  .fixedSize(horizontal: false, vertical: true)
              } else if step.state == .pending && step.isWait {
                Text(step.nudge ?? "Awaiting confirmation").font(.system(size: 10))
                  .foregroundStyle(step.nudge == nil ? Palette.blue : Palette.amber)
              }
              if step.isOptional == true {
                Text("Optional").font(.caption2).foregroundStyle(
                  .secondary)
              }
            }
            Spacer(minLength: 0)
            if undoID == step.id {
              Button {
                prompt = ActionPrompt(snapshot: snapshot, mode: .undo, step: step)
              } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 11))
              }.buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Undo this confirmation")
                .accessibilityLabel("Undo \(step.title)")
                .disabled(model.isBusy)
            }
            if step.state == .pending && step.kind != .qaDecision {
              Menu {
                if step.canRecord { Button("Confirm completed") { confirm(step) } }
                Button("Record an existing fact…") {
                  if step.kind == .mergeMR {
                    model.mergeConfirmation = MergeConfirmation(snapshot: snapshot, step: step)
                  } else {
                    prompt = ActionPrompt(snapshot: snapshot, mode: .existing, step: step)
                  }
                }
                if [
                  .jiraStart, .kickoff, .approvalRequest, .jiraValidate, .qaHandoff, .retestHandoff,
                  .custom,
                ].contains(step.kind) {
                  Button("Waive this step with a reason…") {
                    prompt = ActionPrompt(snapshot: snapshot, mode: .waive, step: step)
                  }
                }
              } label: {
                Image(systemName: "ellipsis").foregroundStyle(.tertiary)
              }
              .menuStyle(.borderlessButton).frame(width: 16)
            }
          }.padding(.vertical, 9)
        }
        let skipped = snapshot.steps.filter { $0.state == .notApplicable }.count
        if skipped > 0 {
          Button(showsSkippedSteps ? "Hide skipped steps" : "Show \(skipped) skipped steps") {
            showsSkippedSteps.toggle()
          }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).padding(
            .top, 12)
        }
      }
    }
  }

  private var notes: some View {
    Surface {
      VStack(alignment: .leading, spacing: 16) {
        noteSection("Notes", item.notes)
        if item.kind == .ticket {
          Divider()
          noteSection("Testing information", item.testingNotes)
          if item.testingNotesRound != item.reviewRound && !item.testingNotes.isEmpty {
            Label(
              "Refresh these notes for the current changes.", systemImage: "exclamationmark.circle"
            )
            .font(.system(size: 11)).foregroundStyle(Palette.amber)
          }
          noteSection("Environment", item.environment)
          if !item.finding.isEmpty { noteSection("Latest finding / change", item.finding) }
        }
        if !item.isDone { Button("Edit notes") { editing = true }.buttonStyle(QuietButtonStyle()) }
      }
    }
  }

  private func noteSection(_ title: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      SectionLabel(text: title)
      Text(text.isEmpty ? "Nothing added yet." : text).font(.system(size: 12))
        .foregroundStyle(text.isEmpty ? .secondary : .primary).textSelection(.enabled)
    }
  }

  private var activity: some View {
    Surface(padding: 16) {
      VStack(alignment: .leading, spacing: 16) {
        SectionLabel(text: "Activity")
        ForEach(Array(item.history.reversed().prefix(60))) { entry in
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.source == .copilot ? "sparkles" : "circle.fill")
              .font(.system(size: 9)).foregroundStyle(Palette.accent).frame(width: 16).padding(
                .top, 3)
            VStack(alignment: .leading, spacing: 5) {
              Text(entry.title).font(.system(size: 11, weight: .medium))
              if !entry.note.isEmpty {
                Text(entry.note).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(
                  .enabled)
              }
              Text(
                "\(entry.source == .copilot ? "Copilot · recorded" : "You") · \(entry.date.formatted(date: .abbreviated, time: .shortened))"
              )
              .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
          }
        }
      }
    }
  }

  private var followUp: some View {
    HStack(spacing: 8) {
      Image(systemName: "calendar.badge.clock").foregroundStyle(Palette.amber)
      VStack(alignment: .leading, spacing: 3) {
        Text("Follow-up").font(.system(size: 12, weight: .medium))
        Text(
          item.followUpAt.map { $0.formatted(date: .abbreviated, time: .shortened) }
            ?? "No follow-up scheduled"
        )
        .font(.system(size: 10)).foregroundStyle(.secondary)
      }
      Spacer()
      Menu {
        Button("In one hour") { setFollowUp(Date().addingTimeInterval(3600)) }
        Button("Tomorrow morning") {
          let tomorrow =
            Calendar.current.date(byAdding: .day, value: 1, to: Date())
            ?? Date().addingTimeInterval(86400)
          setFollowUp(
            Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow)
        }
        Button("Choose date…") { editing = true }
        if item.followUpAt != nil {
          Divider()
          Button("Remove follow-up") {
            var patch = DetailsPatch()
            patch.clearFollowUp = true
            Task { await model.mutate(snapshot, .edit(patch)) }
          }
        }
      } label: {
        Label("Schedule", systemImage: "plus")
      }.menuStyle(.borderlessButton).fixedSize()
        .font(.system(size: 11)).foregroundStyle(Palette.accent)
    }.padding(16).background(Palette.amber.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
  }

  private func setFollowUp(_ date: Date) {
    var patch = DetailsPatch()
    patch.followUpAt = date
    Task { await model.mutate(snapshot, .edit(patch)) }
  }
  private func confirm(_ step: WorkflowStep) {
    model.requestCompletion(snapshot, step: step)
  }
  private func icon(for step: WorkflowStep) -> String {
    switch step.state {
    case .completed: "checkmark.circle.fill"
    case .waived: "minus.circle"
    case .notApplicable: "circle.dotted"
    case .pending: step.isWait ? "clock" : "circle"
    }
  }
  private func link(for step: WorkflowStep) -> String? {
    if let destination = step.destination {
      switch destination {
      case .board, .none: return nil
      case .issue: return item.jiraURL
      case .channel: return model.settings.teamsChannelURL
      case .thread: return item.threadURL
      case .mergeRequest: return item.mergeRequests.first { $0.id == step.mrID }?.url
      case .custom: return step.destinationURL
      }
    }
    return switch step.kind {
    case .jiraStart, .jiraValidate, .jiraReady, .jiraDone: nil
    case .kickoff: model.settings.teamsChannelURL
    case .approvalRequest, .qaHandoff, .retestHandoff: item.threadURL
    case .mergeMR, .approveMR: item.mergeRequests.first { $0.id == step.mrID }?.url
    default: nil
    }
  }
  private func linkLabel(for step: WorkflowStep) -> String {
    if step.destination == .issue { return "Open Jira" }
    return switch step.kind {
    case .jiraStart, .jiraValidate, .jiraReady, .jiraDone: "Open Jira"
    case .mergeMR, .approveMR: "Open GitLab"
    default: "Open Teams"
    }
  }
}

struct ActionPrompt: Identifiable {
  enum Mode { case rework, waive, existing, undo }
  var id = UUID()
  let snapshot: ItemSnapshot
  var mode: Mode
  var step: WorkflowStep?
}

private struct ActionPromptSheet: View {
  @ObservedObject var model: WorkspaceModel
  let snapshot: ItemSnapshot
  let prompt: ActionPrompt
  @State private var note = ""
  @Environment(\.dismiss) private var dismiss

  private var title: String {
    switch prompt.mode {
    case .rework: snapshot.item.isInQA ? "Record a QA finding" : "Record material changes"
    case .waive: "Make an explicit exception"
    case .existing: "Record an existing fact"
    case .undo: "Undo a confirmation"
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text(title).font(.system(size: 22, weight: .bold, design: .rounded))
          Text(description).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
            horizontal: false, vertical: true)
          if let step = prompt.step { Text(step.title).font(.system(size: 13, weight: .semibold)) }
          TextEditor(text: $note).font(.system(size: 13)).padding(8).frame(height: 130)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
        }.padding(24)
      }
      sheetFooter {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(prompt.mode == .undo ? "Undo confirmation" : "Save record") {
          let mutation: ItemMutation
          switch prompt.mode {
          case .rework: mutation = .rework(note)
          case .waive:
            guard let step = prompt.step else { return }
            mutation = .waive(actionID: step.id, reason: note)
          case .existing:
            guard let step = prompt.step else { return }
            mutation = .recordExisting(actionID: step.id, note: note)
          case .undo:
            guard let step = prompt.step else {
              model.errorMessage = "The confirmation to undo is missing."
              return
            }
            mutation = .undo(actionID: step.id, reason: note)
          }
          Task { if await model.mutate(snapshot, mutation) { dismiss() } }
        }.buttonStyle(AccentButtonStyle()).disabled(
          note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
      }
    }.modifier(WorkspaceSheetFrame(width: 500, height: 440)).tint(Palette.accent)
  }
  private var description: String {
    switch prompt.mode {
    case .rework:
      snapshot.item.isInQA
        ? "The ticket stays under QA. Describe the issue; current approvals and QA readiness reset so the fix and retest can be tracked."
        : "Describe the changes. Current review readiness resets, and the previous history stays intact."
    case .waive:
      "This does not mark the action done. The exception and your reason will remain visible in history."
    case .existing:
      "Record something that actually happened outside the normal order. Missing earlier actions remain open. Explain what you verified."
    case .undo:
      "Returns the most recent confirmation to pending in this tracker. It does not reverse anything in Jira, Teams, or GitLab. Earlier history is preserved. Explain what was marked by mistake."
    }
  }
}

/// Lets the user paste the Teams thread link right on the step that needs it.
private struct ThreadLinkField: View {
  static let blocker = "Save the Teams thread link."
  @ObservedObject var model: WorkspaceModel
  let snapshot: ItemSnapshot
  @State private var link = ""

  var body: some View {
    HStack(spacing: 8) {
      Text("Thread link").font(.system(size: 12, weight: .semibold))
      TextField("Paste the Teams thread link", text: $link)
        .textFieldStyle(.roundedBorder).font(.system(size: 12))
        .onSubmit { Task { await save() } }
      Button("Save") { Task { await save() } }
        .buttonStyle(QuietButtonStyle())
        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy)
    }
  }

  private func save() async {
    let value = link.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    var patch = DetailsPatch()
    patch.threadURL = value
    if await model.mutate(snapshot, .edit(patch)) { link = "" }
  }
}
