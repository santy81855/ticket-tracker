import SwiftUI
import TrackerCore
import TrackerStore

struct WorkspaceView: View {
  @ObservedObject var model: WorkspaceModel
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.workspaceTheme) private var theme
  @Environment(\.openWindow) private var openWindow
  @AppStorage("workspace.breathingGuide") private var breathing = false
  @AppStorage("terminal.height") private var terminalHeight = 320.0
  @ObservedObject private var terminal = TerminalSessions.shared
  @ObservedObject private var browser = BrowserModel.shared

  var body: some View {
    GeometryReader { geometry in
      let hasSidebar = geometry.size.width >= 1120
      HStack(spacing: 0) {
        if hasSidebar {
          sidebar(height: geometry.size.height).frame(width: 220)
          Divider().opacity(0.5)
        }
        let fillsWithTerminal =
          terminal.isVisible
          && (terminal.isMaximized || geometry.size.width < 900 || geometry.size.height < 500)
        let terminalRange = 120.0...max(120, Double(geometry.size.height) - 200)
        let panelHeight = min(
          max(terminalHeight, terminalRange.lowerBound), terminalRange.upperBound)
        VStack(spacing: 0) {
          if !fillsWithTerminal {
            workspace(
              size: CGSize(
                width: geometry.size.width,
                height: geometry.size.height - (terminal.isVisible ? panelHeight + 28 : 0)),
              hasSidebar: hasSidebar
            )
            .background {
              if geometry.size.width < 900 {
                RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
                  .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.14)))
                  .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                  .padding(6)
              }
            }
          }
          if terminal.isVisible {
            if !fillsWithTerminal {
              TerminalResizeHandle(height: $terminalHeight, range: terminalRange)
            }
            TerminalPanel(
              sessions: terminal,
              canMaximize: geometry.size.width >= 900 && geometry.size.height >= 500,
              resize: fillsWithTerminal ? nil : ($terminalHeight, terminalRange)
            )
            .frame(height: fillsWithTerminal ? nil : panelHeight)
            .frame(maxHeight: fillsWithTerminal ? .infinity : nil)
            statusFooter.padding(.horizontal, 12).frame(height: 22)
              .background(Color(nsColor: TerminalSessions.chrome))
              .environment(\.colorScheme, .dark)
          }
        }
      }
      .sheet(isPresented: $model.showNewItem) { NewItemSheet(model: model) }
      .sheet(isPresented: $model.showSettings) { SettingsSheet(model: model) }
      .sheet(isPresented: $model.showWorkflows) { WorkflowEditorSheet(model: model) }
      .sheet(item: $model.referenceEditor) { ReferenceEditorSheet(model: model, request: $0) }
      .environment(\.workspaceSize, geometry.size)
      .overlay(alignment: .bottomLeading) {
        if breathing && (hasSidebar || !terminal.isVisible) {
          BreathingGuide(compact: !hasSidebar)
            .padding(.leading, hasSidebar ? 18 : 14).padding(.bottom, hasSidebar ? 66 : 14)
            .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
        }
      }
      .animation(.spring(duration: 0.4), value: breathing)
    }
    .background { WorkspaceBackdrop() }
    .tint(theme.accent ?? Palette.accent)
    .overlay {
      if browser.isVisible { BrowserPanel(model: model).transition(.opacity) }
    }
    .animation(.easeOut(duration: 0.15), value: browser.isVisible)
    .overlay { CelebrationOverlay(model: model) }
    .overlay(alignment: .bottom) {
      if let toast = model.toast {
        Label(toast, systemImage: "checkmark.circle.fill")
          .font(.system(size: 12, weight: .medium)).padding(.horizontal, 18).padding(.vertical, 12)
          .background(.regularMaterial, in: Capsule()).shadow(
            color: .black.opacity(0.10), radius: 15, y: 5
          )
          .padding(.bottom, 20).transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.18), value: model.toast)
    .alert(
      "Couldn't complete that action",
      isPresented: Binding(
        get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
    .onAppear {
      QuickSwitcher.shared.configure(model: model) { openWindow(id: "workspace") }
      BrowserModel.showWorkspace = { openWindow(id: "workspace") }
      if !model.isUISmoke || model.isThemePreview { QuickSwitcher.shared.registerShortcut() }
    }
    .onChange(of: model.search) { _, _ in selectVisible() }
    .onChange(of: model.kindFilter) { _, _ in selectVisible() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      Task { await model.refreshOSStatus() }
    }
  }

  private func workspace(size: CGSize, hasSidebar: Bool) -> some View {
    let compact = size.width < 900
    let dense = compact || size.height < 600
    let showingDetail =
      !model.page.isReport && compact && model.showsItemDetail && model.selected != nil
    return VStack(alignment: .leading, spacing: dense ? 12 : 22) {
      if !hasSidebar { compactNavigation(compact: size.width < 600) }
      if model.isThemePreview {
        Label("Design preview · Sample data only", systemImage: "paintpalette")
          .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
      }
      if !showingDetail {
        header(dense: dense, showsNewButton: hasSidebar)
        if size.height >= 560 && !model.page.isReport && !model.page.isLibrary
          && model.page != .archive && model.page != .workspaceMRs
        {
          metrics(compact: dense)
        }
      }
      if let failure = model.storageFailure {
        ContentUnavailableView {
          Label(
            "Your workspace needs attention", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
          Text(
            "\(failure)\n\nYour database has not been reset. Local backups are in \(TrackerStore.defaultDirectory().appendingPathComponent("Backups").path). Close this app and connected helper sessions before recovering a damaged database."
          )
        } actions: {
          Button("Try Again") { Task { await model.retryStorage() } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if model.page == .summary {
        StandupSummaryView(model: model)
      } else if model.page == .releases {
        ReleaseScheduleView(model: model)
      } else if model.page == .endOfDay {
        EndOfDayReviewView(model: model)
      } else if model.page == .insights {
        InsightsView(model: model)
      } else if model.page == .brag {
        BragDocView(model: model)
      } else if model.page.isLibrary {
        ReferenceLibraryView(model: model)
      } else {
        if model.page == .workspaceMRs {
          Picker("Workspace MR status", selection: $model.workspaceMRFilter) {
            Text("Unmerged").tag("Unmerged")
            Text("All merged").tag("Merged")
            Text("All").tag("All")
          }.pickerStyle(.segmented)
        }
        content(compact: compact)
      }
    }.padding(.horizontal, dense ? 16 : 30).padding(.top, hasSidebar && !dense ? 40 : 12)
      .padding(.bottom, dense ? 12 : 24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func navigate(to page: WorkspacePage) {
    model.page = page
    model.showsItemDetail = false
    selectVisible()
  }

  private func compactNavigation(compact: Bool) -> some View {
    HStack {
      Menu {
        ForEach(WorkspacePage.sidebarGroups, id: \.title) { group in
          Section(group.title) {
            ForEach(group.pages) { page in
              Button {
                navigate(to: page)
              } label: {
                Label(page.navigationTitle, systemImage: page.symbol)
              }
            }
          }
        }
      } label: {
        Label(model.page.sidebarPage.navigationTitle, systemImage: model.page.sidebarPage.symbol)
          .font(.system(size: 12, weight: .semibold))
      }.menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("Workspace navigation")
      Spacer(minLength: 8)
      WorkspaceThemePicker(compact: compact)
      browserButton
      terminalButton
      workflowEditorButton
      Button {
        model.showSettings = true
      } label: {
        Image(systemName: "gearshape").frame(width: 28, height: 32).contentShape(Rectangle())
      }.buttonStyle(.plain).help("Workspace settings")
      Button {
        if model.page.isLibrary { model.newReference() } else { model.showNewItem = true }
      } label: {
        Label(newButtonTitle, systemImage: "plus")
      }.buttonStyle(AccentButtonStyle()).disabled(model.storageFailure != nil)
    }
  }

  private func selectVisible() {
    if !model.visible.contains(where: { $0.id == model.selectedID }) {
      model.selectedID = model.visible.first?.id
    }
  }

  private func sidebar(height: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 11) {
            Image(systemName: "ticket.fill").font(.system(size: 23, weight: .medium))
              .foregroundStyle(.white).frame(width: 42, height: 42)
              .background(
                LinearGradient(
                  colors: [Palette.accent, Palette.blue], startPoint: .topLeading,
                  endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 2) {
              Text("Ticket Tracker").font(.system(size: 15, weight: .bold))
            }
          }.padding(.top, 48).padding(.bottom, 38).padding(.horizontal, 20)
          ForEach(WorkspacePage.sidebarGroups, id: \.title) { group in
            SectionLabel(text: group.title).padding(.horizontal, 23).padding(.bottom, 6)
            ForEach(group.pages) { page in sidebarRow(page) }
            Spacer().frame(height: 18)
          }
        }
      }
      Spacer()
      Divider().padding(.horizontal, 18)
      HStack {
        Circle().fill(model.storageFailure == nil ? Palette.green : .orange).frame(
          width: 6, height: 6)
        Text(model.storageFailure == nil ? "Local workspace" : "Storage needs attention")
          .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        Spacer()
        Button {
          model.showSettings = true
        } label: {
          Image(systemName: "gearshape").font(.system(size: 14))
        }
        .buttonStyle(.plain).help("Workspace settings")
      }.padding(20)
    }
    .background(colorScheme == .dark ? Color.black.opacity(0.12) : Color.white.opacity(0.6))
  }

  private func sidebarRow(_ page: WorkspacePage) -> some View {
    let isCurrent = model.page.sidebarPage == page
    return Button {
      navigate(to: page)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: page.symbol).font(.system(size: 13, weight: .medium)).frame(width: 20)
        Text(page.navigationTitle).font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
        Spacer()
        if page == .all && model.hasOverdueFollowUp {
          Circle().fill(Palette.amber).frame(width: 7, height: 7)
            .help("A follow-up is due")
        }
      }.foregroundStyle(isCurrent ? Palette.accent : Color.primary.opacity(0.75))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
          isCurrent ? Palette.accent.opacity(0.10) : .clear,
          in: RoundedRectangle(cornerRadius: 9)
        )
        .contentShape(Rectangle())
    }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 2)
  }

  private func header(dense: Bool, showsNewButton: Bool) -> some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 7) {
        if !dense {
          Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
            .font(.system(size: 10, weight: .semibold)).tracking(1.7).foregroundStyle(.secondary)
        }
        Text(model.page.sidebarPage.rawValue).font(
          .system(size: dense ? 23 : 29, weight: .bold, design: .rounded))
      }
      Spacer(minLength: 20)
      if showsNewButton {
        WorkspaceThemePicker()
        browserButton
        terminalButton
        workflowEditorButton
        Button {
          if model.page.isLibrary { model.newReference() } else { model.showNewItem = true }
        } label: {
          Label(newButtonTitle, systemImage: "plus")
        }
        .buttonStyle(AccentButtonStyle()).disabled(model.storageFailure != nil)
        .keyboardShortcut("n")
      }
    }
  }

  private var browserButton: some View {
    Button {
      browser.isVisible.toggle()
    } label: {
      Image(systemName: "globe")
        .font(.system(size: 14, weight: .medium)).frame(width: 30, height: 32)
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
      .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
      .help("Jira browser (⇧⌘B)").accessibilityLabel("Jira browser")
  }

  private var terminalButton: some View {
    Button {
      terminal.toggle()
    } label: {
      Image(systemName: "apple.terminal")
        .font(.system(size: 14, weight: .medium)).frame(width: 30, height: 32)
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
      .foregroundStyle(terminal.isVisible ? Palette.accent : .primary)
      .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
      .help("Terminal (⌘J)").accessibilityLabel("Terminal")
  }

  private var workflowEditorButton: some View {
    Button {
      model.showWorkflows = true
    } label: {
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: 14, weight: .medium)).frame(width: 26, height: 32)
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
      .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
      .help("Workflow editor").accessibilityLabel("Workflow editor")
  }

  private var newButtonTitle: String {
    switch model.page {
    case .notes: "New note"
    case .links: "Add link"
    default: "New item"
    }
  }

  private func metrics(compact: Bool) -> some View {
    HStack(spacing: compact ? 8 : 14) {
      metric(.next, value: model.actionCount, color: Palette.accent, compact: compact)
      metric(.waiting, value: model.waitingCount, color: Palette.blue, compact: compact)
      metric(.followUps, value: model.dueCount, color: Palette.amber, compact: compact)
    }
  }

  private func metric(_ filter: WorkspacePage, value: Int, color: Color, compact: Bool)
    -> some View
  {
    let selected = model.page == filter
    return Button {
      navigate(to: selected ? .all : filter)
    } label: {
      MetricCard(
        title: filter == .followUps ? "Follow-ups due" : filter.rawValue, value: value,
        symbol: filter.symbol, color: color, compact: compact, selected: selected)
    }.buttonStyle(.plain)
      .help(selected ? "Show all tickets and tasks" : "Show only \(filter.rawValue.lowercased())")
  }

  private func content(compact: Bool) -> some View {
    VStack(spacing: 15) {
      if compact && model.showsItemDetail && model.selected != nil {
        HStack {
          Button {
            model.showsItemDetail = false
          } label: {
            Label("Back to items", systemImage: "chevron.left")
          }.buttonStyle(.plain).foregroundStyle(Palette.accent)
            .accessibilityIdentifier("back-to-items")
          Spacer()
        }
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 14) {
            searchField
            kindPicker.frame(width: 240)
          }
          VStack(spacing: 10) {
            searchField
            kindPicker
          }
        }
      }
      if model.visible.isEmpty {
        emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if !model.visible.isEmpty {
        HStack(alignment: .top, spacing: compact ? 0 : 20) {
          if !compact || !model.showsItemDetail || model.selected == nil {
            itemList
              .frame(
                minWidth: compact ? 0 : 250, idealWidth: compact ? nil : 300,
                maxWidth: compact ? .infinity : 330)
          }
          if !compact || model.showsItemDetail {
            if let selected = model.selected {
              TicketDetailView(model: model, snapshot: selected)
                .id(selected.id).frame(maxWidth: .infinity)
                .onAppear { if !compact { model.showsItemDetail = true } }
            } else if !compact {
              ContentUnavailableView(
                "Select an item", systemImage: "cursorarrow.click",
                description: Text("Its next steps will appear here.")
              ).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
        }
      }
      if !terminal.isVisible { statusFooter }
    }
  }

  private var statusFooter: some View {
    HStack(spacing: 6) {
      Image(systemName: "internaldrive").font(.system(size: 9))
      Text("Saved on this Mac").font(.system(size: 10))
      Spacer()
      Text("\(model.visible.count) \(model.visible.count == 1 ? "item" : "items")").font(
        .system(size: 10, design: .monospaced))
    }.foregroundStyle(.tertiary)
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
      TextField("Find a ticket or task…", text: $model.search)
        .textFieldStyle(.plain).font(.system(size: 12))
    }.padding(11).frame(minWidth: 180)
      .modifier(WorkspaceSurface(radius: 9))
      .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.border))
  }

  private var kindPicker: some View {
    Picker("Item type", selection: $model.kindFilter) {
      ForEach(["Everything", "Tickets", "Tasks"], id: \.self) { Text($0) }
    }.pickerStyle(.segmented).labelsHidden()
  }

  private var itemList: some View {
    ScrollView {
      LazyVStack(spacing: 10) {
        ForEach(model.visible) { snapshot in
          ItemCard(snapshot: snapshot, selected: model.selectedID == snapshot.id) {
            model.selectedID = snapshot.id
            model.showsItemDetail = true
          }
        }
      }.padding(.bottom, 10)
    }
  }

  private var emptyState: some View {
    ScrollView {
      VStack(spacing: 16) {
        ZStack {
          Circle().fill(Palette.accent.opacity(0.06)).frame(width: 112, height: 112)
          Circle().fill(Palette.accent.opacity(0.07)).frame(width: 82, height: 82)
          Image(systemName: model.page == .waiting ? "hourglass" : "square.stack.3d.up")
            .font(.system(size: 33, weight: .light)).foregroundStyle(Palette.accent)
        }.padding(.bottom, 5)
        Text(model.search.isEmpty ? emptyTitle : "No matches just yet").font(
          .system(size: 21, weight: .semibold, design: .rounded))
        Text(model.search.isEmpty ? emptyDescription : "Try another ticket key, title, or note.")
          .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
          .lineSpacing(5)
        if model.page != .archive && model.search.isEmpty {
          Button {
            model.showNewItem = true
          } label: {
            Label("Capture something", systemImage: "plus")
          }
          .buttonStyle(AccentButtonStyle()).padding(.top, 5)
        }
      }.padding(30).frame(maxWidth: .infinity)
    }
  }
  private var emptyTitle: String {
    switch model.page {
    case .waiting: "Nothing holding you up"
    case .followUps: "Nothing to chase"
    case .next: "Nothing needs you right now"
    case .archive: "Good work will live here"
    default: "A clear head starts here"
    }
  }
  private var emptyDescription: String {
    switch model.page {
    case .waiting: "Approval and QA waits will appear here.\nFor now, the next move is yours."
    case .followUps: "Add a follow-up date to a ticket or task.\nWe will keep it on your radar."
    case .archive: "Finished tickets and tasks stay here,\nwith their history intact."
    default: "Add a ticket or a small task.\nWe will help you remember everything around it."
    }
  }
}

private struct MetricCard: View {
  var title: String
  var value: Int
  var symbol: String
  var color: Color
  var compact = false
  var selected = false
  var body: some View {
    Surface(padding: compact ? 10 : 17) {
      HStack(spacing: compact ? 8 : 14) {
        Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(color)
          .frame(width: compact ? 20 : 42, height: compact ? 30 : 42).background(
            color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 4) {
          Text("\(value)").font(
            .system(size: compact ? 20 : 25, weight: .semibold, design: .rounded)
          )
          .monospacedDigit()
          Text(title).font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        if selected {
          Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(color)
        }
      }
    }
    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(color, lineWidth: selected ? 2 : 0))
    .contentShape(Rectangle())
  }
}

private struct ItemCard: View {
  var snapshot: ItemSnapshot
  var selected: Bool
  var select: () -> Void
  var body: some View {
    Button(action: select) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Label(
            snapshot.item.kind == .ticket ? snapshot.item.jiraKey : "PERSONAL TASK",
            systemImage: snapshot.item.kind == .ticket ? "ticket" : "checklist"
          )
          .font(
            .system(
              size: snapshot.item.kind == .ticket ? 19 : 12, weight: .bold, design: .monospaced)
          )
          .foregroundStyle(selected ? snapshot.stageColor : .primary)
          Spacer()
          if snapshot.item.isDone {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
          } else if snapshot.isWaiting {
            Image(systemName: "hourglass").foregroundStyle(Palette.blue)
          }
        }
        Text(snapshot.item.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
          .multilineTextAlignment(.leading)
        Label(
          snapshot.phase,
          systemImage: snapshot.item.isDone
            ? "checkmark.circle.fill" : (snapshot.isWaiting ? "hourglass" : "circle.fill")
        )
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(snapshot.stageColor)
        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
        if !snapshot.item.isDone, let next = snapshot.nextStep,
          !next.isWait && next.title != snapshot.phase
        {
          HStack(alignment: .top, spacing: 7) {
            Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).padding(.top, 2)
            Text(next.title).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.leading)
          }.foregroundStyle(.secondary)
        }
        if let due = snapshot.item.followUpAt, !snapshot.item.isDone {
          Label(due.formatted(.relative(presentation: .named)), systemImage: "calendar")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(due < Date() ? Palette.amber : .secondary)
        }
      }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
        .background(
          snapshot.stageColor.opacity(selected ? 0.09 : 0.035),
          in: RoundedRectangle(cornerRadius: 14)
        )
        .modifier(WorkspaceSurface(radius: 14))
        .overlay(alignment: .leading) {
          RoundedRectangle(cornerRadius: 2).fill(snapshot.stageColor.opacity(selected ? 0.9 : 0.55))
            .frame(width: 4).padding(.vertical, 16)
        }
        .overlay(
          RoundedRectangle(cornerRadius: 14).strokeBorder(
            snapshot.stageColor.opacity(selected ? 0.55 : 0.18),
            lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
}

struct MenuBarView: View {
  @ObservedObject var model: WorkspaceModel
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    Text("YOUR WORKSPACE").font(.caption)
    Text("\(model.active.count) active · \(model.waitingCount) waiting")
    Divider()
    ForEach(Array(model.active.prefix(5))) { snapshot in
      Button(
        "\(snapshot.item.jiraKey.isEmpty ? "Task" : snapshot.item.jiraKey) · \(snapshot.item.title)"
      ) {
        model.reveal(snapshot.id)
        openWindow(id: "workspace")
        NSApp.activate(ignoringOtherApps: true)
      }
    }
    Divider()
    Button("Quick Find…  \(QuickSwitcher.shared.shortcutLabel)") { QuickSwitcher.shared.show() }
    Button("Open Workspace") {
      openWindow(id: "workspace")
      NSApp.activate(ignoringOtherApps: true)
    }
    Button("New Item") {
      openWindow(id: "workspace")
      NSApp.activate(ignoringOtherApps: true)
      model.showNewItem = true
    }
    Button("Settings…") {
      openWindow(id: "workspace")
      NSApp.activate(ignoringOtherApps: true)
      model.showSettings = true
    }
    Divider()
    Button("Quit Ticket Tracker") { NSApp.terminate(nil) }.keyboardShortcut("q")
  }
}
