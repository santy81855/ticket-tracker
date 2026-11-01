import SwiftUI
import TrackerCore

struct ReleaseScheduleView: View {
  @ObservedObject var model: WorkspaceModel

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let schedule = model.releaseSchedule
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 22) {
          if schedule.upcoming.isEmpty && schedule.awaitingMerge.isEmpty
            && schedule.recent.isEmpty
          {
            ReviewEmpty(text: "Merged tickets will be grouped by Fix Version here.")
          }
          ForEach(schedule.upcoming) { release in
            releaseCard(release, now: context.date, past: false)
          }
          if !schedule.awaitingMerge.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
              ReviewHeading(title: "Not merged yet", symbol: "arrow.triangle.merge")
              ForEach(schedule.awaitingMerge) { snapshot in
                ReviewTicketRow(model: model, snapshot: snapshot) {
                  Text(snapshot.phase).foregroundStyle(snapshot.stageColor)
                }
              }
            }
          }
          if !schedule.recent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              ReviewHeading(title: "Recently released", symbol: "clock.arrow.circlepath")
              ForEach(schedule.recent) { release in
                releaseCard(release, now: context.date, past: true)
              }
            }.opacity(0.75)
          }
        }.padding(.bottom, 16)
      }
    }.accessibilityIdentifier("release-schedule")
  }

  private func releaseCard(_ release: ReleaseSchedule.Release, now: Date, past: Bool) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Image(systemName: past ? "checkmark.seal" : "shippingbox.fill")
          .foregroundStyle(past ? Palette.green : Palette.accent)
        Text(release.version).font(.system(size: 20, weight: .bold, design: .monospaced))
        if let date = release.date {
          Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        Spacer()
        if !past, let date = release.date {
          Text(countdown(to: date, now: now))
            .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Palette.accent.opacity(0.12), in: Capsule())
            .foregroundStyle(Palette.accent)
        }
      }
      ForEach(release.entries) { entry in
        ReviewTicketRow(model: model, snapshot: entry.snapshot) {
          HStack(spacing: 8) {
            Text(entry.snapshot.item.isDone ? "Done" : entry.snapshot.phase)
              .foregroundStyle(entry.snapshot.stageColor)
            if entry.isProjected {
              Text("Fix Version not saved in Jira").foregroundStyle(Palette.amber)
            }
          }
        }
      }
    }
  }

  private func countdown(to date: Date, now: Date) -> String {
    let calendar = Calendar.current
    let days =
      calendar.dateComponents(
        [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
      ).day ?? 0
    switch days {
    case ..<1: return "Today"
    case 1: return "Tomorrow"
    default: return "In \(days) days"
    }
  }
}

struct EndOfDayReviewView: View {
  @ObservedObject var model: WorkspaceModel

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { _ in
      let review = model.endOfDayReview
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Spacer()
          Button {
            model.copy(review.text, message: "End-of-day review copied")
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
          }.buttonStyle(QuietButtonStyle())
        }
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 22) {
            section("Done today", symbol: "checkmark.circle", color: Palette.green) {
              if review.doneToday.isEmpty { ReviewEmpty(text: "Nothing recorded yet today.") }
              ForEach(review.doneToday) { progress in
                ReviewTicketRow(model: model, snapshot: progress.snapshot) {
                  VStack(alignment: .leading, spacing: 3) {
                    ForEach(progress.steps, id: \.self) { step in
                      Label(step, systemImage: "checkmark").foregroundStyle(.secondary)
                    }
                    if progress.completedItem {
                      Label("Completed", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Palette.green)
                    }
                  }
                }
              }
            }
            section("Still on you", symbol: "bolt", color: Palette.accent) {
              if review.onYou.isEmpty { ReviewEmpty(text: "Nothing is waiting on you.") }
              ForEach(review.onYou) { snapshot in
                ReviewTicketRow(model: model, snapshot: snapshot) {
                  Text(snapshot.nextStep.map { "Next: \($0.title)" } ?? snapshot.phase)
                    .foregroundStyle(snapshot.stageColor)
                }
              }
            }
            section("Waiting on others", symbol: "hourglass", color: Palette.blue) {
              if review.waiting.isEmpty { ReviewEmpty(text: "Nothing is waiting on others.") }
              ForEach(review.waiting) { snapshot in
                ReviewTicketRow(model: model, snapshot: snapshot) {
                  Text(snapshot.phase).foregroundStyle(snapshot.stageColor)
                }
              }
            }
            section("Follow-ups by tomorrow", symbol: "calendar", color: Palette.amber) {
              if review.dueTomorrow.isEmpty { ReviewEmpty(text: "No follow-ups due.") }
              ForEach(review.dueTomorrow) { snapshot in
                ReviewTicketRow(model: model, snapshot: snapshot) {
                  Text(
                    snapshot.item.followUpAt?.formatted(.relative(presentation: .named)) ?? ""
                  ).foregroundStyle(Palette.amber)
                }
              }
            }
          }.padding(.bottom, 16)
        }
      }
    }.accessibilityIdentifier("end-of-day-review")
  }

  private func section<Content: View>(
    _ title: String, symbol: String, color: Color, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ReviewHeading(title: title, symbol: symbol, color: color)
      content()
    }
  }
}

struct ReviewHeading: View {
  var title: String
  var symbol: String
  var color: Color = Palette.accent
  var body: some View {
    Label(title, systemImage: symbol).font(.system(size: 14, weight: .semibold))
      .foregroundStyle(color).accessibilityAddTraits(.isHeader)
  }
}

struct ReviewEmpty: View {
  var text: String
  var body: some View {
    Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
      .padding(14).frame(maxWidth: .infinity, alignment: .leading)
      .modifier(WorkspaceSurface(radius: 12))
  }
}

struct ReviewTicketRow<Detail: View>: View {
  @ObservedObject var model: WorkspaceModel
  var snapshot: ItemSnapshot
  @ViewBuilder var detail: Detail

  var body: some View {
    Button {
      model.reveal(snapshot.id)
    } label: {
      HStack(alignment: .top, spacing: 14) {
        RoundedRectangle(cornerRadius: 2).fill(snapshot.stageColor).frame(width: 5)
        VStack(alignment: .leading, spacing: 5) {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(snapshot.item.kind == .ticket ? snapshot.item.jiraKey : "TASK")
              .font(
                .system(
                  size: snapshot.item.kind == .ticket ? 15 : 11, weight: .bold,
                  design: .monospaced))
            Text(snapshot.item.title).font(.system(size: 13)).foregroundStyle(.secondary)
              .lineLimit(1)
          }
          detail.font(.system(size: 12, weight: .medium))
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
          .padding(.top, 3)
      }.padding(.vertical, 12).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(WorkspaceSurface(radius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.border))
        .contentShape(Rectangle())
    }.buttonStyle(.plain).help(
      "Open \(snapshot.item.jiraKey.isEmpty ? "task" : snapshot.item.jiraKey)")
  }
}
