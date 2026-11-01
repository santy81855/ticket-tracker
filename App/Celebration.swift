import SwiftUI
import TrackerCore

struct Celebration: Identifiable, Equatable {
  let id = UUID()
  let key: String
  let title: String
  let shippedThisMonth: Int
}

/// Confetti and a short "shipped" card when a ticket reaches Done.
struct CelebrationOverlay: View {
  @ObservedObject var model: WorkspaceModel
  @Environment(\.workspaceTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var cardVisible = false

  var body: some View {
    ZStack {
      if let celebration = model.celebration {
        if !reduceMotion {
          ConfettiBurst(colors: palette).id(celebration.id).allowsHitTesting(false)
        }
        card(celebration)
          .scaleEffect(cardVisible ? 1 : 0.6)
          .opacity(cardVisible ? 1 : 0)
          .onAppear {
            cardVisible = false
            withAnimation(
              reduceMotion
                ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.62)
            ) {
              cardVisible = true
            }
          }
          .id(celebration.id)
          .onTapGesture { model.celebration = nil }
      }
    }
    .animation(.easeOut(duration: 0.3), value: model.celebration)
  }

  private var palette: [Color] {
    switch theme {
    case .gargantua:
      [Palette.gargantuaGold, .orange, .white, Color(red: 1, green: 0.88, blue: 0.6)]
    case .aurora:
      [
        Palette.auroraGreen, Color(red: 0.25, green: 0.85, blue: 0.95),
        Color(red: 0.68, green: 0.45, blue: 1), Color(red: 1, green: 0.5, blue: 0.75), .white,
      ]
    case .skyline:
      [
        Palette.neonPink, Color(red: 0.2, green: 0.9, blue: 1),
        Color(red: 1, green: 0.72, blue: 0.4),
        .white,
      ]
    case .rain:
      [
        Palette.rainAmber, Color(red: 0.4, green: 0.75, blue: 1),
        Color(red: 1, green: 0.4, blue: 0.5), .white,
      ]
    case .nebula:
      [
        Palette.nebulaViolet, Color(red: 0.3, green: 0.6, blue: 1),
        Color(red: 1, green: 0.45, blue: 0.7), .orange, .white,
      ]
    case .cabin:
      [
        Palette.cabinGlow, .white, Color(red: 0.7, green: 0.82, blue: 1),
        Color(red: 0.9, green: 0.25, blue: 0.2),
      ]
    case .christmas:
      [
        Palette.christmasGold, Color(red: 0.78, green: 0.08, blue: 0.1),
        Color(red: 0.2, green: 0.6, blue: 0.3), .white,
      ]
    case .bonsai:
      [
        Palette.bonsaiSage, Color(red: 1, green: 0.72, blue: 0.8),
        Color(red: 0.9, green: 0.4, blue: 0.1), Color(red: 0.85, green: 0.15, blue: 0.1),
      ]
    default: [Palette.accent, Palette.green, Palette.blue, Palette.amber, .pink, .yellow]
    }
  }

  private var sealColor: Color {
    switch theme {
    case .gargantua: Palette.gargantuaGold
    case .aurora: Palette.auroraGreen
    case .skyline: Palette.neonPink
    case .rain: Palette.rainAmber
    case .nebula: Palette.nebulaViolet
    case .cabin: Palette.cabinGlow
    case .christmas: Palette.christmasGold
    case .bonsai: Palette.bonsaiSage
    default: Palette.green
    }
  }

  private func card(_ celebration: Celebration) -> some View {
    VStack(spacing: 10) {
      Image(systemName: "checkmark.seal.fill").font(.system(size: 46))
        .foregroundStyle(
          sealColor
        )
        .symbolEffect(.bounce, value: cardVisible)
      Text("\(celebration.key) is done")
        .font(.system(size: 24, weight: .bold, design: .rounded))
      Text(celebration.title).font(.system(size: 13)).foregroundStyle(.secondary)
        .lineLimit(2).multilineTextAlignment(.center)
      Text(streak(celebration.shippedThisMonth))
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Palette.accent.opacity(0.14), in: Capsule())
        .foregroundStyle(Palette.accent)
        .padding(.top, 4)
    }
    .padding(.horizontal, 34).padding(.vertical, 26)
    .frame(maxWidth: 380)
    .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 22))
    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.primary.opacity(0.12)))
    .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isStaticText)
  }

  private func streak(_ count: Int) -> String {
    switch count {
    case ..<2: "First one this month 🎉"
    default: "\(ordinal(count)) ticket shipped this month 🔥"
    }
  }

  private func ordinal(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .ordinal
    return formatter.string(from: value as NSNumber) ?? "\(value)"
  }
}

private struct ConfettiBurst: View {
  let colors: [Color]
  @State private var start = Date()
  @State private var pieces: [Piece]

  init(colors: [Color]) {
    self.colors = colors
    _pieces = State(initialValue: Self.makePieces())
  }

  private static func makePieces() -> [Piece] {
    (0..<140).map { _ in
      Piece(
        angle: Double.random(in: (-.pi * 0.95)...(-.pi * 0.05)),
        speed: Double.random(in: 0.35...1.0),
        spin: Double.random(in: -12...12),
        size: CGSize(width: Double.random(in: 8...13), height: Double.random(in: 4...7)),
        color: Int.random(in: 0..<64),
        drift: Double.random(in: -3...3),
        circle: Double.random(in: 0...1) < 0.25)
    }
  }

  private struct Piece {
    var angle: Double
    var speed: Double
    var spin: Double
    var size: CGSize
    var color: Int
    var drift: Double
    var circle: Bool
  }

  var body: some View {
    TimelineView(.animation) { context in
      Canvas { canvas, size in
        let t = context.date.timeIntervalSince(start)
        guard t < 3.2 else { return }
        let origin = CGPoint(x: size.width / 2, y: size.height * 0.42)
        for piece in pieces {
          let scale = max(size.height, 320)
          let x = origin.x + cos(piece.angle) * piece.speed * scale * t + piece.drift * t * t * 20
          let y = origin.y + sin(piece.angle) * piece.speed * scale * t + 0.55 * scale * t * t
          let fade = max(0, min(1, (3.2 - t) / 0.8))
          var copy = canvas
          copy.opacity = fade
          copy.translateBy(x: x, y: y)
          copy.rotate(by: .radians(piece.spin * t))
          let rect = CGRect(
            x: -piece.size.width / 2, y: -piece.size.height / 2,
            width: piece.size.width, height: piece.size.height)
          let path =
            piece.circle ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 1.5)
          copy.fill(path, with: .color(colors[piece.color % colors.count]))
        }
      }
    }
  }
}
