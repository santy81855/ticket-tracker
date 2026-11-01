import SwiftUI
import TrackerCore

private enum InsightsPeriod: String, CaseIterable, Identifiable {
  case month = "30 days"
  case quarter = "90 days"
  case all = "All time"
  var id: String { rawValue }
  var since: Date? {
    switch self {
    case .month: Calendar.current.date(byAdding: .day, value: -30, to: Date())
    case .quarter: Calendar.current.date(byAdding: .day, value: -90, to: Date())
    case .all: nil
    }
  }
}

extension CycleStage {
  fileprivate var color: Color {
    switch self {
    case .build: Palette.stage
    case .review: Color(red: 0.62, green: 0.40, blue: 0.86)
    case .qa: Palette.blue
    case .merge: Palette.amber
    case .release: Palette.green
    }
  }
}

struct InsightsView: View {
  @ObservedObject var model: WorkspaceModel
  @AppStorage("insights.period") private var period = InsightsPeriod.quarter

  var body: some View {
    let insights = CycleInsights(snapshots: model.snapshots, since: period.since)
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 22) {
        HStack {
          Picker("Period", selection: $period) {
            ForEach(InsightsPeriod.allCases) { Text($0.rawValue).tag($0) }
          }.pickerStyle(.segmented).labelsHidden().fixedSize()
          Spacer()
        }
        if insights.finished.isEmpty && insights.open.isEmpty {
          ReviewEmpty(text: "Finish a few tickets and you'll see where the time goes.")
        } else {
          headline(insights)
          if !insights.medians.isEmpty { stages(insights) }
          if !insights.open.isEmpty { open(insights) }
          if !insights.finished.isEmpty { finished(insights) }
          if insights.excluded > 0 {
            Text(
              "\(insights.excluded) backfilled ticket\(insights.excluded == 1 ? "" : "s") left out because their times were entered after the fact."
            ).font(.system(size: 11)).foregroundStyle(.secondary)
          }
        }
      }.padding(.bottom, 16)
    }.accessibilityIdentifier("insights")
  }

  private func headline(_ insights: CycleInsights) -> some View {
    let bottleneck = insights.medians.max { $0.value < $1.value }
    return HStack(spacing: 12) {
      stat(
        insights.medianTotal.map(CycleInsights.format) ?? "–", "Typical start → done",
        symbol: "timer")
      if let bottleneck {
        stat(
          bottleneck.key.title, "Biggest wait · \(CycleInsights.format(bottleneck.value))",
          symbol: "tortoise", color: bottleneck.key.color)
      }
      stat(
        "\(Int((insights.reworkShare * 100).rounded()))%", "Needed rework",
        symbol: "arrow.uturn.backward")
      stat("\(insights.finished.count)", "Tickets finished", symbol: "checkmark.seal")
    }
  }

  private func stat(_ value: String, _ label: String, symbol: String, color: Color = Palette.accent)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      Image(systemName: symbol).foregroundStyle(color)
      Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).lineLimit(1)
        .minimumScaleFactor(0.7)
      Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
      .modifier(WorkspaceSurface(radius: 12))
  }

  private func stages(_ insights: CycleInsights) -> some View {
    let longest = insights.medians.values.max() ?? 1
    return VStack(alignment: .leading, spacing: 12) {
      ReviewHeading(title: "Where the time goes", symbol: "chart.bar.xaxis")
      Text("Median time per stage").font(.system(size: 11)).foregroundStyle(.secondary)
      VStack(spacing: 10) {
        ForEach(CycleStage.allCases, id: \.self) { stage in
          if let value = insights.medians[stage] {
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 1) {
                Text(stage.title).font(.system(size: 13, weight: .semibold))
                Text("on \(stage.waitingOn)").font(.system(size: 10)).foregroundStyle(.secondary)
              }.frame(width: 130, alignment: .leading)
              GeometryReader { geometry in
                Capsule().fill(stage.color.opacity(0.85))
                  .frame(width: max(6, geometry.size.width * value / longest))
              }.frame(height: 10)
              Text(CycleInsights.format(value))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(width: 56, alignment: .trailing)
            }
          }
        }
      }.padding(16).modifier(WorkspaceSurface(radius: 12))
    }
  }

  private func open(_ insights: CycleInsights) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ReviewHeading(title: "In flight", symbol: "airplane", color: Palette.blue)
      ForEach(insights.open) { entry in
        let elapsed = Date().timeIntervalSince(entry.since)
        let typical = insights.medians[entry.stage]
        let slow = typical.map { elapsed > $0 * 1.5 && elapsed > 4 * 3600 } ?? false
        ReviewTicketRow(model: model, snapshot: entry.snapshot) {
          HStack(spacing: 8) {
            Text("\(entry.stage.title) for \(CycleInsights.format(elapsed))")
              .foregroundStyle(entry.stage.color)
            if slow, let typical {
              Label(
                "Usually \(CycleInsights.format(typical))", systemImage: "exclamationmark.circle"
              )
              .foregroundStyle(Palette.amber)
            }
          }
        }
      }
    }
  }

  private func finished(_ insights: CycleInsights) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ReviewHeading(title: "Finished tickets", symbol: "checkmark.seal", color: Palette.green)
      HStack(spacing: 14) {
        ForEach(CycleStage.allCases, id: \.self) { stage in
          Label {
            Text(stage.title)
          } icon: {
            Circle().fill(stage.color).frame(width: 7, height: 7)
          }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }
      ForEach(insights.finished) { ticket in
        ReviewTicketRow(model: model, snapshot: ticket.snapshot) {
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
              Text(ticket.total.map(CycleInsights.format) ?? "–")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
              if let slowest = ticket.slowest, let value = ticket.durations[slowest] {
                Text("Longest: \(slowest.title) \(CycleInsights.format(value))")
                  .foregroundStyle(.secondary)
              }
              if ticket.rework > 0 {
                Text("\(ticket.rework) rework round\(ticket.rework == 1 ? "" : "s")")
                  .foregroundStyle(Palette.amber)
              }
            }
            stageBar(ticket.durations)
          }
        }
      }
    }
  }

  private func stageBar(_ durations: [CycleStage: TimeInterval]) -> some View {
    let total = durations.values.reduce(0, +)
    return GeometryReader { geometry in
      HStack(spacing: 2) {
        ForEach(CycleStage.allCases, id: \.self) { stage in
          if let value = durations[stage], total > 0 {
            RoundedRectangle(cornerRadius: 2).fill(stage.color.opacity(0.85))
              .frame(width: max(3, (geometry.size.width - 8) * value / total))
              .help("\(stage.title): \(CycleInsights.format(value))")
          }
        }
      }
    }.frame(height: 6).frame(maxWidth: 360)
  }
}

private enum BragPeriod: String, CaseIterable, Identifiable {
  case week = "This week"
  case month = "This month"
  case quarter = "This quarter"
  case half = "6 months"
  case year = "This year"
  var id: String { rawValue }
  var start: Date {
    let calendar = Calendar.current
    let now = Date()
    switch self {
    case .week: return calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
    case .month: return calendar.dateInterval(of: .month, for: now)?.start ?? now
    case .quarter: return calendar.dateInterval(of: .quarter, for: now)?.start ?? now
    case .half: return calendar.date(byAdding: .month, value: -6, to: now) ?? now
    case .year: return calendar.dateInterval(of: .year, for: now)?.start ?? now
    }
  }
}

struct BragDocView: View {
  @ObservedObject var model: WorkspaceModel
  @AppStorage("brag.period") private var period = BragPeriod.quarter

  var body: some View {
    let doc = BragDocument(snapshots: model.snapshots, from: period.start)
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Picker("Period", selection: $period) {
          ForEach(BragPeriod.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().fixedSize()
        Spacer()
        Button {
          model.copy(
            doc.markdown(title: "What I shipped · \(period.rawValue.lowercased())"),
            message: "Brag doc copied as Markdown")
        } label: {
          Label("Copy Markdown", systemImage: "doc.on.doc")
        }.buttonStyle(QuietButtonStyle()).disabled(doc.months.isEmpty)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 22) {
          HStack(spacing: 12) {
            stat(doc.ticketCount, "Tickets shipped", symbol: "shippingbox.fill")
            stat(doc.mergedMRs, "MRs merged", symbol: "arrow.triangle.merge")
            stat(doc.releases, "Releases", symbol: "tag")
            stat(doc.taskCount, "Other tasks", symbol: "checklist")
          }
          if doc.months.isEmpty {
            ReviewEmpty(text: "Nothing finished in this period yet.")
          } else {
            Label(
              "Add a line of impact to each ticket. It's what turns a list into a story.",
              systemImage: "lightbulb"
            ).font(.system(size: 12)).foregroundStyle(.secondary)
          }
          ForEach(doc.months) { month in
            VStack(alignment: .leading, spacing: 10) {
              ReviewHeading(title: month.title, symbol: "calendar")
              ForEach(month.tickets) { entry in BragTicketRow(model: model, entry: entry) }
              if !month.tasks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                  Text("ALSO").font(.system(size: 10, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(.secondary)
                  ForEach(month.tasks) { entry in
                    Label(entry.snapshot.item.title, systemImage: "checkmark")
                      .font(.system(size: 12))
                  }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                  .modifier(WorkspaceSurface(radius: 12))
              }
            }
          }
        }.padding(.bottom, 16)
      }
    }.accessibilityIdentifier("brag-doc")
  }

  private func stat(_ value: Int, _ label: String, symbol: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Image(systemName: symbol).foregroundStyle(Palette.accent)
      Text("\(value)").font(.system(size: 24, weight: .bold, design: .rounded))
      Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
      .modifier(WorkspaceSurface(radius: 12))
  }
}

private struct BragTicketRow: View {
  @ObservedObject var model: WorkspaceModel
  let entry: BragDocument.Entry
  @State private var impact = ""
  @FocusState private var editing: Bool

  var body: some View {
    let item = entry.snapshot.item
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Button(item.jiraKey) { model.reveal(entry.snapshot.id) }
          .buttonStyle(.plain).font(.system(size: 15, weight: .bold, design: .monospaced))
        Text(item.title).font(.system(size: 13)).lineLimit(1)
        Spacer()
        if let version = item.fieldValues?["fix-version"], !version.isEmpty {
          Text(version).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
        Text(entry.completed.formatted(.dateTime.month(.abbreviated).day()))
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        Image(systemName: "sparkle").font(.system(size: 11))
          .foregroundStyle(impact.isEmpty ? Color.secondary : Palette.amber)
        TextField("Impact: who it helped, what it unblocked, what it fixed…", text: $impact)
          .textFieldStyle(.plain).font(.system(size: 12)).focused($editing)
          .onSubmit { save() }
        if impact != entry.impact {
          Button("Save") { save() }.buttonStyle(QuietButtonStyle())
        }
      }.padding(.horizontal, 10).padding(.vertical, 7)
        .background(
          Color.primary.opacity(editing ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 8))
    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
      .modifier(WorkspaceSurface(radius: 12))
      .onAppear { impact = entry.impact }
      .onChange(of: editing) { _, focused in if !focused { save() } }
  }

  private func save() {
    let value = impact.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value != entry.impact else { return }
    var patch = DetailsPatch()
    patch.fieldValues = [BragDocument.impactField: value]
    Task { _ = await model.mutate(entry.snapshot, .edit(patch)) }
  }
}
