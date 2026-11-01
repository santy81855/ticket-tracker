import SwiftUI

/// A small floating breathing companion: 5 seconds in, 5 seconds out.
/// It uses one fixed palette so it looks the same on every theme.
struct BreathingGuide: View {
  var compact = false
  @AppStorage("workspace.breathingGuide") private var breathing = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var startedAt = Date.now.timeIntervalSinceReferenceDate
  @State private var hovered = false

  private static let phase: Double = 5
  private static let glow = Color(red: 0.55, green: 0.86, blue: 0.95)
  private static let core = Color(red: 0.72, green: 0.66, blue: 1.0)

  var body: some View {
    // Reduce Motion keeps the orb still; only the text and countdown change.
    TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30)) { timeline in
      let elapsed = max(0, timeline.date.timeIntervalSinceReferenceDate - startedAt)
      let inhaling = elapsed.truncatingRemainder(dividingBy: Self.phase * 2) < Self.phase
      let progress = elapsed.truncatingRemainder(dividingBy: Self.phase) / Self.phase
      let fullness = reduceMotion ? 0.6 : (1 - cos(elapsed * .pi / Self.phase)) / 2
      let remaining = Int(ceil(Self.phase - elapsed.truncatingRemainder(dividingBy: Self.phase)))
      let breaths = Int(elapsed / (Self.phase * 2))
      HStack(spacing: 12) {
        orb(fullness: fullness, progress: progress, inhaling: inhaling)
        if !compact {
          VStack(alignment: .leading, spacing: 2) {
            Text(inhaling ? "Breathe in" : "Breathe out")
              .font(.system(size: 12, weight: .semibold))
              .contentTransition(.opacity)
              .animation(.easeInOut(duration: 0.6), value: inhaling)
            Text(
              breaths == 0
                ? "\(remaining)s"
                : "\(remaining)s · \(breaths) breath\(breaths == 1 ? "" : "s")"
            )
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
          }
          .frame(width: 92, alignment: .leading)
        }
      }
      .padding(.leading, 8).padding(.trailing, compact ? 8 : 14).padding(.vertical, 8)
      .foregroundStyle(.white.opacity(0.92))
      .background(.ultraThinMaterial, in: Capsule())
      .background(Color(red: 0.05, green: 0.06, blue: 0.10).opacity(0.55), in: Capsule())
      .overlay(Capsule().strokeBorder(.white.opacity(0.10)))
      .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
      .overlay(alignment: .topTrailing) {
        if hovered {
          Button {
            breathing = false
          } label: {
            Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
              .frame(width: 16, height: 16)
              .background(Color(white: 0.2), in: Circle())
              .overlay(Circle().strokeBorder(.white.opacity(0.15)))
          }
          .buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
          .offset(x: 4, y: -4)
          .help("Hide the breathing guide")
        }
      }
      .environment(\.colorScheme, .dark)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Breathing guide")
      .accessibilityValue(inhaling ? "Breathe in" : "Breathe out")
    }
    .onHover { hovered = $0 }
    .animation(.easeOut(duration: 0.15), value: hovered)
  }

  private func orb(fullness: Double, progress: Double, inhaling: Bool) -> some View {
    ZStack {
      Circle().stroke(.white.opacity(0.08), lineWidth: 2)
      Circle()
        .trim(from: 0, to: progress)
        .stroke(
          Self.glow.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
      Circle()
        .fill(
          RadialGradient(
            colors: [.white.opacity(0.95), Self.core, Self.glow.opacity(0.35)],
            center: UnitPoint(x: 0.38, y: 0.35), startRadius: 0, endRadius: 15)
        )
        .frame(width: 12 + fullness * 16, height: 12 + fullness * 16)
        .shadow(color: Self.glow.opacity(0.35 + fullness * 0.45), radius: 4 + fullness * 8)
    }
    .frame(width: 38, height: 38)
  }
}
