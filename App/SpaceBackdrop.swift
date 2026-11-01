import SwiftUI

struct SpaceBackdrop: View {
  var body: some View {
    AmbientTimeline { time in
      Canvas(rendersAsynchronously: true) { context, size in
        drawNebula(in: &context, size: size, time: time)
        drawStars(in: &context, size: size, time: time)
        drawPlanet(in: &context, size: size, time: time)
        drawMeteors(in: &context, size: size, time: time)
      }
    }
  }

  private func drawNebula(in context: inout GraphicsContext, size: CGSize, time: Double) {
    var haze = context
    haze.blendMode = .screen
    haze.addFilter(.blur(radius: 40))
    for index in 0..<6 {
      let seed = Double(index)
      let center = CGPoint(
        x: size.width * (0.18 + seed * 0.13 + sin(time * 0.11 + seed) * 0.09),
        y: size.height * (0.35 + sin(seed * 1.3 + time * 0.08) * 0.24))
      let color =
        index.isMultiple(of: 2)
        ? Color(red: 0.36, green: 0.23, blue: 0.72)
        : Color(red: 0.07, green: 0.40, blue: 0.59)
      let pulse = 0.86 + sin(time * 0.23 + seed * 1.7) * 0.14
      let radius = max(size.width, size.height) * (0.31 + seed * 0.025) * pulse
      haze.fill(
        Path(
          ellipseIn: CGRect(
            x: center.x - radius, y: center.y - radius * 0.65,
            width: radius * 2, height: radius * 1.3)),
        with: .radialGradient(
          Gradient(colors: [color.opacity(0.22 * pulse), color.opacity(0.05), .clear]),
          center: center, startRadius: 0, endRadius: radius))
    }
    for index in 0..<3 {
      let offset = Double(index) * 0.11
      var veil = Path()
      veil.move(to: CGPoint(x: -size.width * 0.2, y: size.height * (0.7 + offset)))
      veil.addCurve(
        to: CGPoint(x: size.width * 1.15, y: size.height * (0.1 + offset)),
        control1: CGPoint(x: size.width * 0.3, y: size.height * (0.65 + sin(time * 0.1) * 0.12)),
        control2: CGPoint(x: size.width * 0.62, y: size.height * (0.04 + offset)))
      haze.stroke(
        veil,
        with: .linearGradient(
          Gradient(colors: [.clear, .purple.opacity(0.11), .cyan.opacity(0.06), .clear]),
          startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height * 0.5)),
        lineWidth: 55 + Double(index) * 30)
    }
  }

  private func drawStars(in context: inout GraphicsContext, size: CGSize, time: Double) {
    let count = min(240, max(85, Int(size.width * size.height / 5000)))
    for index in 0..<count {
      let seed = Double(index + 1)
      let depth = (seed * 0.754877).truncatingRemainder(dividingBy: 1)
      let x =
        size.width
        * (seed * 0.618034 + time * (0.0014 + depth * 0.0016)).truncatingRemainder(dividingBy: 1)
      let y =
        size.height * (seed * 0.414214).truncatingRemainder(dividingBy: 1)
        + cos(time * 0.06 + seed * 2) * (3 + depth * 9)
      let radius = 0.35 + depth * 0.8
      let edge = min(1, max(0, min(x, size.width - x) / 18))
      let alpha =
        (0.25 + depth * 0.40)
        * (0.72 + sin(time * (0.4 + depth) + seed) * 0.28) * edge
      let point = CGPoint(x: x, y: y)
      let color = index.isMultiple(of: 4) ? Color(red: 0.63, green: 0.79, blue: 1) : .white
      if index.isMultiple(of: 37) {
        context.fill(
          Path(ellipseIn: CGRect(x: x - 7, y: y - 7, width: 14, height: 14)),
          with: .radialGradient(
            Gradient(colors: [color.opacity(alpha * 0.25), .clear]),
            center: point, startRadius: 0, endRadius: 7))
        var rays = Path()
        rays.move(to: CGPoint(x: x - 3.5, y: y))
        rays.addLine(to: CGPoint(x: x + 3.5, y: y))
        rays.move(to: CGPoint(x: x, y: y - 3.5))
        rays.addLine(to: CGPoint(x: x, y: y + 3.5))
        context.stroke(rays, with: .color(color.opacity(alpha * 0.35)), lineWidth: 0.6)
      }
      context.fill(
        Path(
          ellipseIn: CGRect(
            x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
        with: .color(color.opacity(alpha)))
    }
  }

  private func drawPlanet(in context: inout GraphicsContext, size: CGSize, time: Double) {
    let radius = min(max(size.width * 0.29, 160), size.height * 0.72)
    let center = CGPoint(x: size.width * 0.86, y: size.height * 1.08)
    let body = Path(
      ellipseIn: CGRect(
        x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    let light = CGPoint(
      x: center.x - radius * (0.45 + sin(time * 0.08) * 0.09),
      y: center.y - radius * 0.85)
    var atmosphere = context
    atmosphere.addFilter(.blur(radius: 10))
    atmosphere.stroke(
      body,
      with: .linearGradient(
        Gradient(colors: [.cyan.opacity(0.29), .blue.opacity(0.1), .clear]),
        startPoint: light, endPoint: center),
      lineWidth: 9)
    var orbit = Path()
    orbit.addEllipse(
      in: CGRect(
        x: -radius * 1.8, y: -radius * 0.35,
        width: radius * 3.6, height: radius * 0.7))
    orbit = orbit.applying(
      CGAffineTransform(rotationAngle: -0.3)
        .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
    context.stroke(
      orbit,
      with: .linearGradient(
        Gradient(colors: [.clear, .cyan.opacity(0.09), .purple.opacity(0.14), .clear]),
        startPoint: CGPoint(x: center.x - radius, y: center.y - radius * 0.3),
        endPoint: CGPoint(x: center.x + radius, y: center.y)),
      lineWidth: 0.8)
    context.fill(
      body,
      with: .radialGradient(
        Gradient(stops: [
          .init(color: Color(red: 0.13, green: 0.22, blue: 0.32), location: 0),
          .init(color: Color(red: 0.035, green: 0.055, blue: 0.10), location: 0.45),
          .init(color: Color(red: 0.018, green: 0.024, blue: 0.055), location: 1),
        ]), center: light, startRadius: 0, endRadius: radius * 1.8))
    context.stroke(
      body,
      with: .linearGradient(
        Gradient(colors: [.cyan.opacity(0.34), .blue.opacity(0.08), .clear]),
        startPoint: light, endPoint: center),
      lineWidth: 0.8)
  }

  private func drawMeteors(in context: inout GraphicsContext, size: CGSize, time: Double) {
    for index in 0..<2 {
      let phase = (time + Double(index) * 11).truncatingRemainder(
        dividingBy: 23 + Double(index) * 14)
      guard phase < 0.85 else { continue }
      let progress = phase / 0.85
      let head = CGPoint(
        x: size.width * (0.2 + progress * 0.35 + Double(index) * 0.2),
        y: size.height * (0.08 + progress * 0.28))
      let tail = CGPoint(x: head.x - 75, y: head.y - 35)
      let opacity = sin(progress * .pi) * 0.38
      var trail = Path()
      trail.move(to: tail)
      trail.addLine(to: head)
      context.stroke(
        trail,
        with: .linearGradient(
          Gradient(colors: [.clear, .white.opacity(opacity)]),
          startPoint: tail, endPoint: head), lineWidth: 1)
    }
  }
}
