import SwiftUI
import TrackerCore

struct StandupSummaryView: View {
  @ObservedObject var model: WorkspaceModel

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { _ in
      let summary = model.standupSummary
      VStack(alignment: .leading, spacing: 14) {
        ViewThatFits(in: .horizontal) {
          HStack {
            caption(summary)
            Spacer(minLength: 12)
            copyButton
          }
          VStack(alignment: .leading, spacing: 10) {
            caption(summary)
            copyButton
          }
        }
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            sectionTitle("Active tickets", count: summary.activeTickets.count, symbol: "ticket")
            if summary.activeTickets.isEmpty {
              empty("No active tickets. A little breathing room.")
            }
            ForEach(summary.activeTickets) { snapshot in
              ticket(snapshot, completed: false)
            }
            sectionTitle(
              "Completed in the last 48 hours", count: summary.recentlyCompleted.count,
              symbol: "checkmark.circle"
            ).padding(.top, 14)
            if summary.recentlyCompleted.isEmpty {
              empty("Recently completed tickets will appear here for two days.")
            }
            ForEach(summary.recentlyCompleted) { snapshot in
              ticket(snapshot, completed: true)
            }
            Text("Based on confirmations recorded here, not live Jira or Teams activity.")
              .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 8)
          }.padding(.bottom, 12)
        }
      }
    }
    .accessibilityIdentifier("standup-summary")
  }

  private func caption(_ summary: StandupSummary) -> some View {
    Text(
      "\(summary.activeTickets.count) active, \(summary.recentlyCompleted.count) recently completed"
    ).font(.system(size: 12)).foregroundStyle(.secondary)
  }

  private var copyButton: some View {
    Button {
      model.copy(model.standupSummary.text, message: "Stand-up summary copied")
    } label: {
      Label("Copy summary", systemImage: "doc.on.doc")
    }
    .buttonStyle(QuietButtonStyle())
    .help("Copy ticket statuses, next actions, and recent completions as plain text.")
    .accessibilityIdentifier("copy-standup-summary")
  }

  private func sectionTitle(_ title: String, count: Int, symbol: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: symbol).foregroundStyle(Palette.accent)
      Text(title).fontWeight(.semibold)
      Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
    }.font(.system(size: 12)).accessibilityAddTraits(.isHeader)
  }

  private func empty(_ text: String) -> some View {
    Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
      .padding(18).frame(maxWidth: .infinity, alignment: .leading)
      .modifier(WorkspaceSurface(radius: 12))
  }

  private func ticket(_ snapshot: ItemSnapshot, completed: Bool) -> some View {
    Surface(padding: 16) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          VStack(alignment: .leading, spacing: 5) {
            Text(snapshot.item.jiraKey)
              .font(.system(size: 10, weight: .semibold, design: .monospaced))
              .foregroundStyle(Palette.accent)
            Text(snapshot.item.title).font(.system(size: 14, weight: .semibold))
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
          Button {
            model.reveal(snapshot.id)
          } label: {
            Image(systemName: "arrow.up.right")
          }.buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Open \(snapshot.item.jiraKey)")
            .accessibilityLabel("Open \(snapshot.item.jiraKey)")
        }
        Label(
          completed ? "Completed" : snapshot.phase,
          systemImage: completed ? "checkmark.circle" : snapshot.isWaiting ? "hourglass" : "circle"
        ).font(.system(size: 11, weight: .medium))
          .foregroundStyle(completed ? Palette.green : Palette.accent)
        if completed, let date = snapshot.item.completionDate {
          Text(date.formatted(date: .abbreviated, time: .shortened))
            .font(.system(size: 11)).foregroundStyle(.secondary)
        } else if let step = snapshot.nextStep {
          Text("\(step.isWait ? "Waiting for" : "Next"): \(step.title)")
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          if !step.blockers.isEmpty {
            Text("Prerequisites: \(step.blockers.joined(separator: " "))")
              .font(.system(size: 11)).foregroundStyle(Palette.amber)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        if !completed && !snapshot.item.waitingOn.isEmpty {
          Text("Waiting on: \(snapshot.item.waitingOn)")
            .font(.system(size: 11)).foregroundStyle(Palette.amber)
            .fixedSize(horizontal: false, vertical: true)
        }
        if !completed, let progress = StandupSummary.mrProgress(for: snapshot.item) {
          Text(progress).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
  }
}
