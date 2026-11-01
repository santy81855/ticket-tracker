import SwiftUI
import TrackerCore

struct CompletionConfirmation: Identifiable, Sendable {
  let id = UUID()
  let snapshot: ItemSnapshot
  let step: WorkflowStep

  var buttonTitle: String {
    switch step.kind {
    case .taskDone: "Complete task"
    case .implementation: "Mark complete"
    default: "Confirm"
    }
  }

  var summary: String {
    switch step.kind {
    case .jiraStart:
      return "Jira is in Implementation in progress."
    case .kickoff:
      return "The kickoff is posted and the Teams thread is saved."
    case .implementation:
      return snapshot.item.isInQA
        ? "The QA fix is finished. The ticket stays in QA; review and retesting remain separate."
        : "Implementation is finished. Reviews and QA remain separate steps."
    case .approvalRequest:
      return "MR links are posted and pod review is requested."
    case .approveMR:
      return "This MR has the required pod approvals."
    case .qaDecision:
      return "Choose the QA path in item details."
    case .jiraValidate:
      return "Jira is in Validate / merge."
    case .qaHandoff:
      return "The QE has the testing notes and QA handoff."
    case .retestHandoff:
      return "Updated testing notes and the retest request have been sent."
    case .qaPassed:
      return "The QE confirmed the current changes passed testing."
    case .jiraReady:
      return snapshot.item.workflow != nil
        ? "Jira is in Ready to deploy and Fix Version/s are saved."
        : "Jira is in Ready to deploy."
    case .mergeMR:
      return "This MR is already merged in GitLab."
    case .jiraDone:
      return "Jira is in Done."
    case .taskDone:
      return "Completes this task and clears its follow-up."
    case .custom:
      if let owner = step.owner {
        return "Confirm this action has been completed by \(owner)."
      }
      return "Confirm you've already completed this action."
    }
  }

  var scopeNote: String? {
    switch step.kind {
    case .implementation, .taskDone, .qaDecision: nil
    default: "Updates Ticket Tracker only. Jira, Teams and GitLab stay unchanged."
    }
  }
}

struct CompletionConfirmationSheet: View {
  @ObservedObject var model: WorkspaceModel
  let confirmation: CompletionConfirmation
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          HStack {
            Text("CONFIRM STEP")
              .font(.system(size: 10, weight: .semibold)).tracking(1.2)
              .foregroundStyle(.secondary)
            Spacer()
            Text(
              confirmation.snapshot.item.kind == .ticket
                ? confirmation.snapshot.item.jiraKey : "Personal task"
            )
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Palette.accent)
          }
          Text(
            confirmation.step.kind == .taskDone
              ? confirmation.snapshot.item.title : confirmation.step.title
          )
          .font(.system(size: 19, weight: .semibold, design: .rounded))
          .fixedSize(horizontal: false, vertical: true)
          Text(confirmation.summary).font(.system(size: 13))
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          if let note = confirmation.scopeNote {
            Label(note, systemImage: "info.circle")
              .font(.system(size: 11)).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .padding(11).frame(maxWidth: .infinity, alignment: .leading)
              .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
      }
      Divider().opacity(0.4)
      sheetFooter {
        Button("Cancel", role: .cancel) { dismiss() }
          .buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
        Spacer()
        Button(confirmation.buttonTitle) {
          Task { await model.complete(confirmation) }
        }
        .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
        .disabled(model.isBusy)
      }
    }.modifier(WorkspaceSheetFrame(width: 480, height: 300)).tint(Palette.accent)
  }
}
