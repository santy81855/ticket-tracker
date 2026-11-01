import SwiftUI

struct FireplaceBackdrop: View {
  var body: some View {
    AmbientTimeline { time in FireplaceScene(time: time) }
  }
}

private struct FireplaceScene: View {
  var time: Double

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      ZStack {
        Canvas(rendersAsynchronously: true) { context, canvas in
          let hearth = CGPoint(x: canvas.width * 0.58, y: canvas.height * 1.02)
          let span = max(canvas.width * 0.63, 400)
          let height = min(canvas.height * 0.76, 630)
          let pulse = 0.93 + sin(time * 0.8) * 0.04 + sin(time * 1.7) * 0.03
          context.fill(
            Path(CGRect(origin: .zero, size: canvas)),
            with: .radialGradient(
              Gradient(colors: [
                Color(red: 0.93, green: 0.32, blue: 0.08).opacity(0.36),
                .clear,
              ]),
              center: hearth, startRadius: 0, endRadius: span * pulse))
          context.addFilter(.blur(radius: max(9, canvas.width * 0.012)))
          context.blendMode = .plusLighter
          for index in 0..<18 {
            let seed = Double(index)
            let position = (seed / 17 - 0.5) * span
            let rise = height * (0.38 + 0.31 * sin(seed * 2.7 + 1.4) * sin(seed * 2.7 + 1.4))
            let flicker = 0.9 + sin(time * (1.1 + seed * 0.047) + seed) * 0.11
            let base = CGPoint(x: hearth.x + position, y: hearth.y + 35)
            let width = span * (0.06 + 0.018 * sin(seed + time * 0.4))
            let sway = sin(time * 0.9 + seed * 1.8) * span * 0.035
            let tip = CGPoint(x: base.x + sway, y: base.y - rise * flicker)
            var flame = Path()
            flame.move(to: CGPoint(x: base.x - width, y: base.y))
            flame.addCurve(
              to: tip,
              control1: CGPoint(x: base.x - width * 1.5, y: base.y - rise * 0.37),
              control2: CGPoint(x: tip.x + width * 0.4, y: tip.y + rise * 0.22))
            flame.addCurve(
              to: CGPoint(x: base.x + width, y: base.y),
              control1: CGPoint(x: tip.x + width * 0.1, y: tip.y + rise * 0.36),
              control2: CGPoint(x: base.x + width * 1.7, y: base.y - rise * 0.28))
            flame.closeSubpath()
            context.fill(
              flame,
              with: .linearGradient(
                Gradient(colors: [
                  Color(red: 1, green: 0.72, blue: 0.25).opacity(0.48),
                  Color(red: 0.92, green: 0.27, blue: 0.045).opacity(0.31),
                  Color(red: 0.55, green: 0.13, blue: 0.07).opacity(0),
                ]), startPoint: base, endPoint: tip))
          }
        }
        .opacity(0.82)
        Rectangle().fill(.ultraThinMaterial).opacity(0.36)
        Canvas(rendersAsynchronously: true) { context, canvas in
          for index in 0..<30 {
            let seed = Double(index)
            let cycle = 11 + seed.truncatingRemainder(dividingBy: 7)
            let progress = (time / cycle + seed * 0.618).truncatingRemainder(dividingBy: 1)
            let origin = 0.19 + (seed * 0.381).truncatingRemainder(dividingBy: 0.68)
            let x = canvas.width * origin + sin(time * 0.24 + seed * 2) * 24
            let y = canvas.height * (1.05 - progress * 0.90)
            let fade = sin(progress * .pi) * 0.44
            let radius = 0.7 + seed.truncatingRemainder(dividingBy: 3) * 0.35
            let ember = CGRect(x: x, y: y, width: radius * 2, height: radius * 2)
            context.fill(
              Path(ellipseIn: ember.insetBy(dx: -2, dy: -2)),
              with: .radialGradient(
                Gradient(colors: [.orange.opacity(fade * 0.35), .clear]),
                center: CGPoint(x: x + radius, y: y + radius),
                startRadius: 0, endRadius: radius + 2))
            context.fill(
              Path(ellipseIn: ember),
              with: .color(Color(red: 1, green: 0.67, blue: 0.35).opacity(fade)))
          }
        }
        LinearGradient(
          colors: [.black.opacity(0.12), .clear, .black.opacity(0.16)],
          startPoint: .top, endPoint: .bottom)
      }.frame(width: size.width, height: size.height).clipped()
    }
  }
}
