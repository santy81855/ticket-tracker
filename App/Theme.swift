import SwiftUI
import TrackerCore

private struct WorkspaceSizeKey: EnvironmentKey {
  static let defaultValue = CGSize(width: 1360, height: 900)
}

extension EnvironmentValues {
  var workspaceSize: CGSize {
    get { self[WorkspaceSizeKey.self] }
    set { self[WorkspaceSizeKey.self] = newValue }
  }
}

struct WorkspaceSheetFrame: ViewModifier {
  var width: CGFloat
  var height: CGFloat
  @Environment(\.workspaceSize) private var workspaceSize

  func body(content: Content) -> some View {
    content.frame(
      width: min(width, workspaceSize.width - 32),
      height: min(height, workspaceSize.height - 32)
    ).modifier(WorkspaceSurface(radius: 0))
  }
}

enum Palette {
  /// The current theme's accent. Ticket-stage colors use `stage` so they never change.
  static var accent: Color {
    let raw = UserDefaults.standard.string(forKey: "workspace.theme") ?? ""
    return WorkspaceTheme(rawValue: raw)?.accent ?? stage
  }
  static let stage = Color(red: 0.39, green: 0.35, blue: 0.88)
  static let gargantuaGold = Color(red: 0.90, green: 0.76, blue: 0.54)
  static let auroraGreen = Color(red: 0.42, green: 0.93, blue: 0.74)
  static let rainAmber = Color(red: 1.0, green: 0.74, blue: 0.42)
  static let nebulaViolet = Color(red: 0.80, green: 0.58, blue: 1.0)
  static let cabinGlow = Color(red: 1.0, green: 0.66, blue: 0.36)
  static let christmasGold = Color(red: 1.0, green: 0.74, blue: 0.40)
  static let bonsaiSage = Color(red: 0.66, green: 0.82, blue: 0.56)
  static let neonPink = Color(red: 1.0, green: 0.45, blue: 0.74)
  static let green = Color(red: 0.12, green: 0.61, blue: 0.44)
  static let amber = Color(red: 0.77, green: 0.47, blue: 0.12)
  static let blue = Color(red: 0.23, green: 0.49, blue: 0.83)
  static let canvas = Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.14, alpha: 1)
        : NSColor(calibratedRed: 0.965, green: 0.967, blue: 0.984, alpha: 1)
    })
  static let surface = Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.19, alpha: 1) : .white
    })
  static let border = Color.primary.opacity(0.07)
}

extension ItemSnapshot {
  var stageColor: Color {
    guard item.kind == .ticket else { return .secondary }
    if item.isDone { return Palette.green }
    if item.isInQA && !item.has(.qaPassed) { return Palette.blue }
    guard let step = nextStep else { return .secondary }
    if step.destination == .issue && item.qa == .required { return Palette.blue }
    switch step.kind {
    case .approvalRequest, .approveMR: return Palette.amber
    case .jiraValidate, .qaHandoff, .retestHandoff, .qaPassed: return Palette.blue
    case .mergeMR, .jiraReady, .jiraDone: return Palette.green
    default: return item.allMerged ? Palette.green : Palette.stage
    }
  }
}

struct Surface<Content: View>: View {
  var padding: CGFloat = 20
  @ViewBuilder var content: Content
  var body: some View {
    content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
      .modifier(WorkspaceSurface(radius: 18))
      .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.border))
  }
}

struct StatusPill: View {
  var text: String
  var color: Color = Palette.accent
  var symbol: String?
  var body: some View {
    HStack(spacing: 5) {
      if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
      Text(text).font(.system(size: 11, weight: .semibold))
    }
    .foregroundStyle(color).padding(.horizontal, 9).padding(.vertical, 5)
    .background(color.opacity(0.10), in: Capsule())
  }
}

struct AccentButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 12, weight: .semibold))
      .foregroundStyle(.white).padding(.horizontal, 15).padding(.vertical, 10)
      .background(
        Palette.accent.opacity(configuration.isPressed ? 0.75 : 1),
        in: RoundedRectangle(cornerRadius: 10))
  }
}

struct PrimaryCompletionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    CompletionButton(configuration: configuration)
  }

  private struct CompletionButton: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.workspaceTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    private var tint: Color {
      switch theme {
      case .gargantua: Palette.gargantuaGold
      case .aurora: Palette.auroraGreen
      case .skyline: Palette.neonPink
      case .rain: Palette.rainAmber
      case .nebula: Palette.nebulaViolet
      case .cabin: Palette.cabinGlow
      case .christmas: Palette.christmasGold
      case .bonsai: Palette.bonsaiSage
      default: Palette.accent
      }
    }

    private var label: Color {
      switch theme {
      case .gargantua: Color(red: 0.15, green: 0.105, blue: 0.055)
      case .aurora: Color(red: 0.02, green: 0.16, blue: 0.13)
      case .skyline: Color(red: 0.22, green: 0.02, blue: 0.11)
      case .rain: Color(red: 0.22, green: 0.12, blue: 0.02)
      case .nebula: Color(red: 0.16, green: 0.04, blue: 0.26)
      case .cabin: Color(red: 0.24, green: 0.10, blue: 0.02)
      case .christmas: Color(red: 0.26, green: 0.06, blue: 0.03)
      case .bonsai: Color(red: 0.08, green: 0.17, blue: 0.06)
      default: .white
      }
    }

    var body: some View {
      configuration.label
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(label)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background {
          RoundedRectangle(cornerRadius: 12)
            .fill(
              LinearGradient(
                colors: [tint, tint.opacity(theme.isWebScene ? 0.82 : 0.92)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(configuration.isPressed ? 0 : (hovered ? 0.12 : 0)))
            }
        }
        .overlay {
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(.white.opacity(configuration.isPressed ? 0.10 : 0.26))
        }
        .overlay {
          RoundedRectangle(cornerRadius: 15)
            .stroke(tint.opacity(isFocused ? 0.95 : 0), lineWidth: 3)
            .padding(-3)
        }
        .shadow(color: tint.opacity(isEnabled && hovered ? 0.20 : 0.07), radius: 10, y: 3)
        .brightness(configuration.isPressed ? -0.10 : 0)
        .opacity(isEnabled ? 1 : 0.42)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovered = $0 && isEnabled }
        .animation(
          reduceMotion ? nil : .easeOut(duration: 0.12),
          value: hovered || configuration.isPressed)
    }
  }
}

struct QuietButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 12, weight: .medium))
      .padding(.horizontal, 12).padding(.vertical, 9)
      .background(
        Color.primary.opacity(configuration.isPressed ? 0.10 : 0.045),
        in: RoundedRectangle(cornerRadius: 9))
  }
}

struct SectionLabel: View {
  var text: String
  var body: some View {
    Text(text.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1.6).foregroundStyle(
      .secondary)
  }
}
