import SwiftUI

enum WorkspaceTheme: String, CaseIterable, Sendable {
  case classic, linen, slate, fireplace, space, gargantua, aurora, skyline, rain, nebula, cabin,
    christmas, bonsai, dracula, nord, oneDark, tokyoNight, catppuccin, gruvbox, solarized

  var title: String {
    switch self {
    case .classic: "Classic"
    case .linen: "Linen"
    case .slate: "Slate"
    case .fireplace: "Cozy fireplace"
    case .space: "Deep space"
    case .gargantua: "Gargantua"
    case .aurora: "Aurora"
    case .skyline: "Night city"
    case .rain: "Rainy window"
    case .nebula: "Nebula"
    case .cabin: "Snowy cabin"
    case .christmas: "Christmas"
    case .bonsai: "Bonsai"
    case .dracula: "Dracula"
    case .nord: "Nord"
    case .oneDark: "One Dark"
    case .tokyoNight: "Tokyo Night"
    case .catppuccin: "Catppuccin Mocha"
    case .gruvbox: "Gruvbox"
    case .solarized: "Solarized Dark"
    }
  }

  var symbol: String {
    switch self {
    case .classic: "circle.lefthalf.filled"
    case .linen: "sun.horizon"
    case .slate: "mountain.2"
    case .fireplace: "flame"
    case .space: "sparkles"
    case .gargantua: "circle.hexagongrid"
    case .aurora: "moon.stars"
    case .skyline: "building.2"
    case .rain: "cloud.rain"
    case .nebula: "sparkles"
    case .cabin: "snowflake"
    case .christmas: "gift"
    case .bonsai: "leaf"
    case .dracula: "drop.halffull"
    case .nord: "snowflake.circle"
    case .oneDark: "chevron.left.forwardslash.chevron.right"
    case .tokyoNight: "moon.haze"
    case .catppuccin: "cup.and.saucer"
    case .gruvbox: "square.stack.3d.down.forward"
    case .solarized: "sun.max"
    }
  }

  var colorScheme: ColorScheme {
    self == .classic || self == .linen ? .light : .dark
  }

  var isAnimated: Bool {
    [
      .fireplace, .space, .gargantua, .aurora, .skyline, .rain, .nebula, .cabin, .christmas,
      .bonsai,
    ]
    .contains(self)
  }

  /// Editor-inspired dark palettes that also recolor the accent.
  var accent: Color? {
    switch self {
    case .dracula: Color(red: 0.741, green: 0.576, blue: 0.976)
    case .nord: Color(red: 0.533, green: 0.753, blue: 0.816)
    case .oneDark: Color(red: 0.380, green: 0.686, blue: 0.937)
    case .tokyoNight: Color(red: 0.478, green: 0.635, blue: 0.969)
    case .catppuccin: Color(red: 0.796, green: 0.651, blue: 0.969)
    case .gruvbox: Color(red: 0.980, green: 0.741, blue: 0.184)
    case .solarized: Color(red: 0.149, green: 0.545, blue: 0.824)
    default: nil
    }
  }

  var isCodePalette: Bool { accent != nil }

  /// Full-screen WebGL scenes.
  var isWebScene: Bool {
    [.gargantua, .aurora, .skyline, .rain, .nebula, .cabin, .christmas, .bonsai].contains(self)
  }

  var colors: [Color] {
    switch self {
    case .classic:
      [Palette.canvas, Palette.canvas]
    case .linen:
      [Color(red: 0.98, green: 0.96, blue: 0.92), Color(red: 0.91, green: 0.86, blue: 0.80)]
    case .slate:
      [Color(red: 0.08, green: 0.13, blue: 0.19), Color(red: 0.16, green: 0.23, blue: 0.28)]
    case .fireplace:
      [Color(red: 0.10, green: 0.08, blue: 0.09), Color(red: 0.20, green: 0.10, blue: 0.07)]
    case .space:
      [Color(red: 0.025, green: 0.035, blue: 0.085), Color(red: 0.065, green: 0.045, blue: 0.13)]
    case .gargantua:
      [Color(red: 0.008, green: 0.008, blue: 0.020), Color(red: 0.025, green: 0.020, blue: 0.018)]
    case .aurora:
      [Color(red: 0.010, green: 0.020, blue: 0.040), Color(red: 0.012, green: 0.035, blue: 0.045)]
    case .skyline:
      [Color(red: 0.015, green: 0.015, blue: 0.040), Color(red: 0.045, green: 0.025, blue: 0.055)]
    case .rain:
      [Color(red: 0.020, green: 0.020, blue: 0.040), Color(red: 0.050, green: 0.035, blue: 0.040)]
    case .nebula:
      [Color(red: 0.012, green: 0.012, blue: 0.035), Color(red: 0.050, green: 0.020, blue: 0.060)]
    case .cabin:
      [Color(red: 0.020, green: 0.030, blue: 0.070), Color(red: 0.060, green: 0.070, blue: 0.110)]
    case .christmas:
      [Color(red: 0.040, green: 0.016, blue: 0.012), Color(red: 0.020, green: 0.040, blue: 0.025)]
    case .bonsai:
      [Color(red: 0.035, green: 0.030, blue: 0.025), Color(red: 0.050, green: 0.055, blue: 0.040)]
    case .dracula:
      [Color(red: 0.157, green: 0.165, blue: 0.212), Color(red: 0.204, green: 0.216, blue: 0.275)]
    case .nord:
      [Color(red: 0.180, green: 0.204, blue: 0.251), Color(red: 0.231, green: 0.259, blue: 0.322)]
    case .oneDark:
      [Color(red: 0.129, green: 0.145, blue: 0.169), Color(red: 0.157, green: 0.173, blue: 0.204)]
    case .tokyoNight:
      [Color(red: 0.102, green: 0.106, blue: 0.149), Color(red: 0.141, green: 0.157, blue: 0.231)]
    case .catppuccin:
      [Color(red: 0.094, green: 0.094, blue: 0.145), Color(red: 0.118, green: 0.118, blue: 0.180)]
    case .gruvbox:
      [Color(red: 0.157, green: 0.157, blue: 0.157), Color(red: 0.196, green: 0.188, blue: 0.184)]
    case .solarized:
      [Color(red: 0.000, green: 0.169, blue: 0.212), Color(red: 0.027, green: 0.212, blue: 0.259)]
    }
  }
}

private struct WorkspaceThemeKey: EnvironmentKey {
  static let defaultValue = WorkspaceTheme.classic
}

extension EnvironmentValues {
  var workspaceTheme: WorkspaceTheme {
    get { self[WorkspaceThemeKey.self] }
    set { self[WorkspaceThemeKey.self] = newValue }
  }
}

struct WorkspaceThemePicker: View {
  var compact = false
  @AppStorage("workspace.theme") private var theme = WorkspaceTheme.classic
  @AppStorage("workspace.animations") private var animations = true
  @AppStorage("workspace.breathingGuide") private var breathing = false
  @AppStorage("workspace.celebrations") private var celebrations = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 7) {
      Menu {
        Section("Light") {
          ForEach([WorkspaceTheme.classic, .linen], id: \.self) { option in
            themeButton(option)
          }
        }
        Section("Dark") {
          ForEach(
            [WorkspaceTheme.slate] + WorkspaceTheme.allCases.filter(\.isCodePalette), id: \.self
          ) {
            option in
            themeButton(option)
          }
        }
        Section("Animated") {
          ForEach(WorkspaceTheme.allCases.filter(\.isAnimated), id: \.self) {
            option in
            themeButton(option)
          }
        }
        if theme.isAnimated {
          Divider()
          Toggle("Animate background", isOn: $animations).disabled(reduceMotion)
          if reduceMotion { Text("Animation paused by Reduce Motion") }
        }
        Divider()
        Toggle("Celebrate finished tickets", isOn: $celebrations)
      } label: {
        HStack(spacing: 7) {
          Image(systemName: theme.symbol)
          if !compact { Text(theme.title).font(.system(size: 11, weight: .medium)) }
          Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }.padding(.horizontal, compact ? 9 : 12).frame(height: 32)
      }.menuStyle(.borderlessButton).fixedSize()
        .tint(.primary)
        .background(.primary.opacity(0.035), in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.06)))
        .accessibilityLabel("Workspace theme")
        .accessibilityValue(theme.title)
        .help("Choose a workspace theme")
      Toggle(isOn: $breathing) {
        Image(systemName: "wind").font(.system(size: 16))
          .frame(width: 32, height: 32).contentShape(Circle())
      }.toggleStyle(.button).buttonStyle(.plain)
        .foregroundStyle(breathing ? Palette.accent : .secondary)
        .background(
          breathing ? Palette.accent.opacity(0.10) : .primary.opacity(0.035), in: Circle()
        )
        .overlay(Circle().strokeBorder(.primary.opacity(0.06)))
        .accessibilityLabel("Breathing guide")
        .accessibilityHint("Five seconds to breathe in, five seconds to breathe out.")
        .help("Show or hide the breathing guide · 5 seconds in, 5 seconds out")
    }
  }

  private func themeButton(_ option: WorkspaceTheme) -> some View {
    Button {
      theme = option
    } label: {
      Label(option.title, systemImage: theme == option ? "checkmark" : option.symbol)
    }
  }
}

struct AmbientTimeline<Content: View>: View {
  @AppStorage("workspace.animations") private var animations = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var windowVisible = true
  @ViewBuilder var content: (TimeInterval) -> Content

  var body: some View {
    TimelineView(
      .animation(
        minimumInterval: 1.0 / 30,
        paused: !animations || reduceMotion || !windowVisible)
    ) { timeline in
      content(reduceMotion || !animations ? 12 : timeline.date.timeIntervalSinceReferenceDate)
    }
    .onAppear {
      if let window = NSApp.windows.first(where: { $0.title.hasPrefix("Ticket Tracker") }) {
        windowVisible = window.occlusionState.contains(.visible) && !window.isMiniaturized
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
    ) { notification in
      guard let window = notification.object as? NSWindow,
        window.title.hasPrefix("Ticket Tracker")
      else { return }
      windowVisible = window.occlusionState.contains(.visible) && !window.isMiniaturized
    }
  }
}

struct WorkspaceBackdrop: View {
  @Environment(\.workspaceTheme) private var theme

  var body: some View {
    ZStack {
      LinearGradient(
        colors: theme.colors,
        startPoint: .topLeading, endPoint: .bottomTrailing)
      switch theme {
      case .fireplace: FireplaceBackdrop()
      case .space: SpaceBackdrop()
      case .gargantua: GargantuaBackdrop()
      case .aurora: GargantuaBackdrop(scene: .aurora)
      case .skyline: GargantuaBackdrop(scene: .skyline)
      case .rain: GargantuaBackdrop(scene: .rain)
      case .nebula: GargantuaBackdrop(scene: .nebula)
      case .cabin: GargantuaBackdrop(scene: .cabin)
      case .christmas: GargantuaBackdrop(scene: .xmas)
      case .bonsai: GargantuaBackdrop(scene: .bonsai)
      default: EmptyView()
      }
    }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
  }
}

/// Card and sheet background: glass over the theme, solid when Reduce Transparency is on.
struct WorkspaceSurface: ViewModifier {
  var radius: CGFloat
  @Environment(\.workspaceTheme) private var theme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    content.background {
      if theme == .classic || reduceTransparency {
        shape.fill(solid)
      } else {
        shape.fill(.ultraThinMaterial).overlay(shape.fill(veil))
      }
    }
  }

  private var solid: Color {
    switch theme.colorScheme {
    case .dark: Color(red: 0.10, green: 0.11, blue: 0.15)
    default: theme == .linen ? Color(red: 0.995, green: 0.985, blue: 0.965) : Palette.surface
    }
  }

  private var veil: Color {
    switch theme {
    case .linen: Color.white.opacity(0.68)
    case .slate: Color(red: 0.16, green: 0.20, blue: 0.27).opacity(0.4)
    default: Color(red: 0.12, green: 0.12, blue: 0.16).opacity(theme.isWebScene ? 0.6 : 0.42)
    }
  }
}
