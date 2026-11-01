import AppKit
import ServiceManagement
import SwiftUI
import TrackerCore
import TrackerStore

struct SettingsSheet: View {
  @ObservedObject var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var settings: TrackerSettings
  @State private var tab = "General"
  @State private var template: DraftKind = .kickoff
  @State private var setupPreview: CopilotSetupPlan?
  @State private var setupMode = CopilotSetupMode.cli
  @State private var copilotHome = CopilotSetup.effectiveHome().path
  @State private var connected = false
  @AppStorage(TerminalSessions.directoryKey) private var terminalDirectory = ""

  init(model: WorkspaceModel) {
    self.model = model
    _settings = State(initialValue: model.settings)
    _pane = State(initialValue: model.settingsPane.flatMap(Pane.init(rawValue:)) ?? .links)
  }
  @AppStorage("workspace.theme") private var theme = WorkspaceTheme.classic
  @AppStorage("workspace.animations") private var animations = true
  @AppStorage("workspace.breathingGuide") private var breathing = false
  @AppStorage("workspace.celebrations") private var celebrations = true
  @Environment(\.workspaceSize) private var workspaceSize
  @State private var browserCleared = false

  private enum Pane: String, CaseIterable, Identifiable {
    case links = "Work links"
    case people = "People"
    case messages = "Message templates"
    case appearance = "Appearance"
    case tools = "Terminal & browser"
    case mac = "Notifications & startup"
    case copilot = "Copilot"
    case data = "Data & backups"
    case shortcuts = "Keyboard shortcuts"
    var id: String { rawValue }

    var symbol: String {
      switch self {
      case .links: "link"
      case .people: "person.2"
      case .messages: "text.bubble"
      case .appearance: "paintpalette"
      case .tools: "apple.terminal"
      case .mac: "bell.badge"
      case .copilot: "sparkles"
      case .data: "externaldrive"
      case .shortcuts: "keyboard"
      }
    }

    var detail: String {
      switch self {
      case .links: "Where action buttons and the in-app browser take you."
      case .people: "Names used to fill in Teams message drafts."
      case .messages: "The wording of kickoff, approval, and QA drafts."
      case .appearance: "Themes, motion, and small touches. Changes apply right away."
      case .tools: "The built-in terminal (⌘J) and Jira browser (⇧⌘B). Changes apply right away."
      case .mac: "Reminders and opening the app when you log in."
      case .copilot: "Let Copilot sessions read and update the tracker."
      case .data: "Where your workspace lives, exports, and restores."
      case .shortcuts: "Everything you can do from the keyboard."
      }
    }

    /// Panes whose fields are saved with the Save button.
    var needsSave: Bool { [.links, .people, .messages].contains(self) }
  }

  @State private var pane: Pane

  var body: some View {
    let narrow = workspaceSize.width < 760 || workspaceSize.height < 560
    return VStack(spacing: 0) {
      inlineError(model.errorMessage)
      HStack(spacing: 0) {
        if !narrow {
          sidebar.frame(width: 215)
          Divider()
        }
        VStack(alignment: .leading, spacing: 0) {
          if narrow {
            Picker("Settings section", selection: $pane) {
              ForEach(Pane.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
            }.labelsHidden().padding([.horizontal, .top], 16)
          }
          VStack(alignment: .leading, spacing: 4) {
            Text(pane.rawValue).font(.system(size: 20, weight: .bold, design: .rounded))
            Text(pane.detail).font(.system(size: 12)).foregroundStyle(.secondary)
          }.padding(.horizontal, 26).padding(.top, narrow ? 12 : 24).padding(.bottom, 4)
          Group {
            switch pane {
            case .links: links
            case .people: people
            case .messages: messages
            case .appearance: appearance
            case .tools: tools
            case .mac: mac
            case .copilot: copilot
            case .data: data
            case .shortcuts: shortcuts
            }
          }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
      }.frame(minHeight: 0, maxHeight: .infinity).clipped()
      Divider()
      sheetFooter {
        if pane.needsSave {
          Text("Links, people, and templates save together.").font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        Spacer()
        if settings == model.settings {
          Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            .buttonStyle(AccentButtonStyle())
        } else {
          Button("Discard changes") { dismiss() }.keyboardShortcut(.cancelAction)
          Button("Save changes") {
            Task { if await model.saveSettings(settings) { dismiss() } }
          }.buttonStyle(AccentButtonStyle()).disabled(model.isBusy)
            .keyboardShortcut(.defaultAction)
        }
      }.layoutPriority(1)
    }.modifier(WorkspaceSheetFrame(width: 900, height: 680)).tint(Palette.accent)
      .onReceive(model.$settingsPane.compactMap { $0.flatMap(Pane.init(rawValue:)) }) {
        pane = $0
        model.settingsPane = nil
      }
      .sheet(
        isPresented: Binding(get: { setupPreview != nil }, set: { if !$0 { setupPreview = nil } })
      ) {
        if let plan = setupPreview { connectionPreview(plan) }
      }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Settings").font(.system(size: 13, weight: .bold)).padding(.horizontal, 10)
        .padding(.bottom, 10)
      ScrollView { sidebarItems }.scrollIndicators(.never)
      Text("Ticket Tracker \(appVersion)").font(.system(size: 10)).foregroundStyle(.tertiary)
        .padding(.horizontal, 10).padding(.top, 6)
    }.padding(14).frame(maxHeight: .infinity, alignment: .top)
      .background(.primary.opacity(0.025))
  }

  private var sidebarItems: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Pane.allCases) { option in
        let selected = option == pane
        Button {
          pane = option
        } label: {
          HStack(spacing: 9) {
            Image(systemName: option.symbol).font(.system(size: 12, weight: .medium))
              .frame(width: 20)
            Text(option.rawValue).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 10).frame(height: 30)
          .foregroundStyle(selected ? Palette.accent : .primary)
          .background(
            RoundedRectangle(cornerRadius: 7).fill(selected ? Palette.accent.opacity(0.13) : .clear)
          )
          .contentShape(Rectangle())
        }.buttonStyle(.plain)
        if option == .messages || option == .mac { Divider().padding(.vertical, 6) }
      }
    }
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  }

  private func linkField(_ title: String, _ text: Binding<String>, prompt: String, help: String)
    -> some View
  {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        TextField(title, text: text, prompt: Text(prompt))
        Button("Open") {
          if let url = URL(string: text.wrappedValue), url.scheme != nil {
            NSWorkspace.shared.open(url)
          }
        }.disabled(URL(string: text.wrappedValue)?.scheme == nil)
          .help("Test this link in your default browser")
      }
      Text(help).font(.caption).foregroundStyle(.secondary)
    }
  }

  private var links: some View {
    Form {
      Section("Jira") {
        linkField(
          "Kanban board", $settings.jiraBoardURL, prompt: "https://jira.example.com/…",
          help: "Board-move steps and the in-app browser's Board button open this.")
        linkField(
          "Jira base URL", $settings.jiraBaseURL, prompt: "https://your-team.atlassian.net",
          help: "Used to build ticket links from keys like ABC-1298.")
      }
      Section("Code & chat") {
        linkField(
          "GitLab", $settings.gitlabHost, prompt: "https://gitlab.example.com",
          help: "Lets the tracker recognize your merge request links.")
        linkField(
          "Teams channel", $settings.teamsChannelURL, prompt: "https://teams.microsoft.com/…",
          help: "Where kickoff threads get posted.")
      }
    }.formStyle(.grouped)
  }

  private var people: some View {
    Form {
      Section {
        TextField("Pod / team", text: $settings.pod, prompt: Text("@my-pod"))
        TextField("Default QE", text: $settings.qe, prompt: Text("@qe-name"))
      } footer: {
        Text(
          "These fill {{pod}} and {{qe}} in message drafts. Pick the real @mentions when you post in Teams."
        ).font(.caption).foregroundStyle(.secondary)
      }
    }.formStyle(.grouped)
  }

  private var appearance: some View {
    Form {
      Section("Theme") {
        themeGrid("Light", [.classic, .linen])
        themeGrid("Dark", [.slate] + WorkspaceTheme.allCases.filter(\.isCodePalette))
        themeGrid("Animated", WorkspaceTheme.allCases.filter(\.isAnimated))
      }
      Section("Touches") {
        Toggle("Animate the background", isOn: $animations)
        Toggle("Show the breathing guide", isOn: $breathing)
        Toggle("Celebrate finished tickets", isOn: $celebrations)
      }
    }.formStyle(.grouped)
  }

  private func themeGrid(_ title: String, _ options: [WorkspaceTheme]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)], spacing: 8) {
        ForEach(options, id: \.self) { option in
          let selected = option == theme
          Button {
            theme = option
          } label: {
            VStack(alignment: .leading, spacing: 6) {
              ZStack(alignment: .bottomTrailing) {
                LinearGradient(
                  colors: option.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(option.accent ?? Palette.stage).frame(width: 10, height: 10)
                  .padding(6)
              }.frame(height: 42).clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.1)))
              Label(option.title, systemImage: option.symbol).font(.system(size: 11))
                .lineLimit(1)
            }
            .padding(6)
            .background(
              RoundedRectangle(cornerRadius: 9).strokeBorder(
                selected ? Palette.accent : .clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
        }
      }
    }.padding(.vertical, 4)
  }

  private var tools: some View {
    Form {
      Section("Terminal") {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("New tabs start in")
            Text((TerminalSessions.startDirectory() as NSString).abbreviatingWithTildeInPath)
              .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
              .id(terminalDirectory)
          }
          Spacer()
          if !terminalDirectory.isEmpty {
            Button("Use Home") { terminalDirectory = "" }
          }
          Button("Choose…") { chooseTerminalFolder() }
        }
        Text("Uses your login shell, so copilot and your usual setup are available.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Jira browser") {
        LabeledContent("Home page") {
          Text(settings.jiraBoardURL.isEmpty ? "Not set" : settings.jiraBoardURL)
            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
        }
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Saved logins and site data")
            Text(
              browserCleared
                ? "Cleared. You'll sign in again next time."
                : "Kept between launches so you stay signed in."
            ).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Sign out everywhere") {
            BrowserModel.shared.clearSiteData()
            browserCleared = true
          }
        }
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Trusted certificates")
            Text("Issuers you approved from the browser's certificate warning.")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Forget") { BrowserModel.shared.forgetTrustedCertificates() }
        }
      }
    }.formStyle(.grouped)
  }

  private var mac: some View {
    Form {
      Section {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Follow-up notifications")
            Text(model.notificationStatus).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Enable…") { Task { await model.requestNotifications() } }
        }
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Open at login")
            Text(model.loginStatus).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Toggle(
            "Open at login",
            isOn: Binding(
              get: { model.loginStatus == "On" },
              set: { enabled in Task { await model.setLogin(enabled) } })
          ).labelsHidden()
        }
      } footer: {
        Text(
          "Closing the window keeps reminders running from the menu bar. Quitting pauses them until the app opens again."
        ).font(.caption).foregroundStyle(.secondary)
      }
    }.formStyle(.grouped)
  }

  private var shortcuts: some View {
    let rows: [(String, String)] = [
      ("⌘N", "New item"), ("⌘K", "Quick switcher"), ("⌘,", "Settings"),
      ("⌘J", "Show or hide the terminal"), ("⇧⌘B", "Show or hide the Jira browser"),
      ("⌘T", "New tab in the open terminal or browser"),
      ("⇧⌘] / ⇧⌘[", "Next or previous tab"), ("⌘1 – ⌘9", "Jump to a tab"),
      ("⇧⌘↩", "Maximize or restore the terminal"),
    ]
    return Form {
      Section {
        ForEach(rows, id: \.0) { row in
          LabeledContent(row.1) {
            Text(row.0).font(.system(size: 12, weight: .medium, design: .monospaced))
              .padding(.horizontal, 7).padding(.vertical, 2)
              .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
          }
        }
      }
    }.formStyle(.grouped)
  }

  private func chooseTerminalFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Use Folder"
    panel.message = "Choose where new terminal tabs start."
    panel.directoryURL = URL(fileURLWithPath: TerminalSessions.startDirectory())
    if panel.runModal() == .OK, let url = panel.url { terminalDirectory = url.path }
  }

  private var messages: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Picker("Template", selection: $template) {
          ForEach(DraftKind.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        TextEditor(text: templateBinding).font(.system(size: 12, design: .monospaced)).padding(10)
          .frame(height: 220)
          .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
        Text(
          "Fields: {{ticket}}, {{title}}, {{jira}}, {{mrs}}, {{pod}}, {{qe}}, {{testing}}, {{environment}}, {{qa_action}}, {{finding}}"
        )
        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(
          .enabled)
        Text("Missing values stay visible as placeholders. Nothing is posted automatically.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }.padding(.horizontal, 26).padding(.vertical, 16)
    }
  }
  private var templateBinding: Binding<String> {
    switch template {
    case .kickoff: $settings.kickoffTemplate
    case .approvals: $settings.approvalTemplate
    case .qa: $settings.qaTemplate
    }
  }

  private var assistantInstructions: some View {
    let text = CopilotSetup.instructions(
      mode: setupMode,
      executable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ticket-tracker"))
    return Surface {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("Instructions for your AI assistant", systemImage: "text.quote")
            .font(.system(size: 13, weight: .semibold))
          Spacer()
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
          }
        }
        Text(
          "Copilot setup below adds this to ~/.copilot/copilot-instructions.md for you. For other assistants, paste it into their personal or project instructions file (for example AGENTS.md, CLAUDE.md, or Cursor rules). It follows the Local CLI / MCP choice above."
        )
        .font(.system(size: 11)).foregroundStyle(.secondary)
        ScrollView {
          Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .frame(height: 180)
        .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.05)))
      }
    }
  }

  private var copilot: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Surface {
          HStack(alignment: .top, spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 25)).foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 8) {
              Text("One workflow. Both of you.").font(
                .system(size: 18, weight: .semibold, design: .rounded))
              Text(
                "With an approved connection, Copilot can read next actions, save MR links and notes, and check handoff prerequisites—even when this window is closed."
              )
              .font(.system(size: 12)).foregroundStyle(.secondary)
            }
          }
        }
        TextField("Copilot home", text: $copilotHome).textFieldStyle(.roundedBorder)
        Picker("Connection", selection: $setupMode) {
          Text("Local CLI").tag(CopilotSetupMode.cli)
          Text("MCP").tag(CopilotSetupMode.mcp)
        }.pickerStyle(.segmented)
        Text(
          "Defaults to COPILOT_HOME when inherited, otherwise ~/.copilot. Confirm this matches the CLI you use."
        )
        .font(.system(size: 11)).foregroundStyle(.secondary)
        assistantInstructions
        Label("No setup changes happen until you review and confirm.", systemImage: "lock")
          .font(.system(size: 12)).foregroundStyle(Palette.green)
        Button(connected ? "Review connection again" : "Review Copilot setup") {
          do {
            guard copilotHome.hasPrefix("/") else {
              throw TrackerError.invalid("Use an absolute Copilot home path.")
            }
            setupPreview = try CopilotSetup.prepare(
              home: URL(fileURLWithPath: copilotHome, isDirectory: true),
              executable: Bundle.main.bundleURL.appendingPathComponent(
                "Contents/MacOS/ticket-tracker"), mode: setupMode
            )
          } catch { model.errorMessage = error.localizedDescription }
        }.buttonStyle(AccentButtonStyle())
        Text(
          "Use only an organization-permitted connection. CLI setup adds scoped instructions without changing MCP configuration. MCP setup also adds the server; organization policies may filter it. Both preserve unrelated content and back up originals. No automatic tool permissions are granted."
        )
        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
        Text(
          "Local storage is not a promise of local-only AI processing: tool responses become part of Copilot's context under your company's policies."
        )
        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
      }.padding(.horizontal, 26).padding(.vertical, 16)
    }
  }

  private func connectionPreview(_ plan: CopilotSetupPlan) -> some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Review the connection").font(.system(size: 22, weight: .bold, design: .rounded))
          Text("These files will be updated, with originals backed up first:").font(
            .system(size: 12)
          )
          .foregroundStyle(.secondary)
          Text(
            (plan.configuration == nil ? "" : "\(plan.home.path)/mcp-config.json\n")
              + "\(plan.home.path)/copilot-instructions.md"
          )
          .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
          VStack(alignment: .leading, spacing: 18) {
            if let configuration = plan.configuration {
              SectionLabel(text: "Resulting MCP configuration")
              Text(String(decoding: configuration, as: UTF8.self))
            } else {
              Text("MCP configuration will not be changed.")
            }
            SectionLabel(text: "Tracker instructions added")
            Text(plan.trackerInstructions)
          }.font(.system(size: 11, design: .monospaced)).frame(
            maxWidth: .infinity, alignment: .leading
          ).textSelection(.enabled).padding(12).background(
            Palette.canvas, in: RoundedRectangle(cornerRadius: 10))
        }.padding(.horizontal, 26).padding(.vertical, 16)
      }
      sheetFooter {
        Button("Cancel") { setupPreview = nil }
        Spacer()
        Button("Confirm connection") {
          do {
            let backup = try CopilotSetup.install(plan)
            connected = true
            setupPreview = nil
            model.notify(
              plan.mode == .cli
                ? "CLI instructions saved. Verify tracker health in a new session."
                : "MCP setup saved. Verify the connection with /mcp.")
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: backup.path)
          } catch { model.errorMessage = error.localizedDescription }
        }.buttonStyle(AccentButtonStyle())
      }
    }.modifier(WorkspaceSheetFrame(width: 700, height: 650))
  }

  private var data: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Surface {
          VStack(alignment: .leading, spacing: 10) {
            Label("Stored on this Mac", systemImage: "internaldrive").font(
              .system(size: 15, weight: .semibold))
            Text(TrackerStore.defaultDirectory().path).font(.system(size: 11, design: .monospaced))
              .textSelection(.enabled)
            Text(
              "The live database is kept outside Documents/OneDrive. Up to seven consistent daily backups are retained locally."
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
          }
        }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) { dataActions }
          VStack(alignment: .leading, spacing: 12) { dataActions }
        }
        Text(
          "Exports include work context and history. Choose a company-approved location. Restore replaces the current workspace after confirmation and makes a backup first."
        )
        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
        Text(
          "Ticket Tracker \(appVersion) · Local personal edition\nNo account. No paid Apple membership. No development server."
        )
        .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 10)
      }.padding(.horizontal, 26).padding(.vertical, 16)
    }
  }

  @ViewBuilder
  private var dataActions: some View {
    Button {
      Task { await model.exportWorkspace() }
    } label: {
      Label("Export workspace", systemImage: "square.and.arrow.up")
    }.buttonStyle(QuietButtonStyle()).fixedSize()
    Button {
      Task { await model.restoreWorkspace() }
    } label: {
      Label("Restore export…", systemImage: "arrow.counterclockwise")
    }.buttonStyle(QuietButtonStyle()).fixedSize()
  }
}
