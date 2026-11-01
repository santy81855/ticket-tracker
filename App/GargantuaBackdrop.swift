import AppKit
import SwiftUI
import WebKit

/// A bundled WebGL scene: resource folder, JavaScript global, and message handler share one name.
struct WebScene: Equatable {
  let name: String
  let title: String

  static let gargantua = WebScene(name: "gargantua", title: "Gargantua")
  static let aurora = WebScene(name: "aurora", title: "Aurora")
  static let skyline = WebScene(name: "skyline", title: "Skyline")
  static let rain = WebScene(name: "rain", title: "Rainy window")
  static let nebula = WebScene(name: "nebula", title: "Nebula")
  static let cabin = WebScene(name: "cabin", title: "Snowy cabin")
  static let xmas = WebScene(name: "xmas", title: "Christmas")
  static let bonsai = WebScene(name: "bonsai", title: "Bonsai")

  var directory: String { name.prefix(1).uppercased() + name.dropFirst() }
  var api: String { "window.__\(name)" }
}

struct GargantuaBackdrop: View {
  var scene: WebScene = .gargantua
  @AppStorage("workspace.animations") private var animations = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var rendererError: String?

  var body: some View {
    ZStack(alignment: .bottom) {
      GargantuaCanvas(
        scene: scene,
        animating: animations && !reduceMotion,
        rendererError: $rendererError)
      if let rendererError {
        VStack(alignment: .leading, spacing: 6) {
          Label("\(scene.title) renderer unavailable", systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 13, weight: .semibold))
          Text(rendererError).font(.system(size: 11)).textSelection(.disabled)
        }
        .foregroundStyle(Color.white)
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .background(
          scene == .gargantua
            ? Color(red: 0.26, green: 0.10, blue: 0.05) : Color(red: 0.06, green: 0.08, blue: 0.14),
          in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 12).strokeBorder(
            scene == .gargantua ? Palette.gargantuaGold : Color.white.opacity(0.5))
        )
        .padding(20)
      }
    }.allowsHitTesting(false)
  }
}

private struct GargantuaCanvas: NSViewRepresentable {
  var scene: WebScene
  var animating: Bool
  @Binding var rendererError: String?

  func makeNSView(context: Context) -> GargantuaCanvasHost {
    let host = GargantuaCanvasHost(scene: scene)
    host.onFailure = { error in
      DispatchQueue.main.async { rendererError = error }
    }
    host.setAnimationEnabled(animating)
    host.loadRenderer()
    return host
  }

  func updateNSView(_ host: GargantuaCanvasHost, context: Context) {
    host.setAnimationEnabled(animating)
  }

  static func dismantleNSView(_ host: GargantuaCanvasHost, coordinator: ()) {
    host.shutdown()
  }
}

@MainActor
final class GargantuaCanvasHost: NSView, WKNavigationDelegate {
  let scene: WebScene
  let webView: WKWebView
  var onFailure: ((String) -> Void)?
  private(set) var rendererReady = false
  private(set) var rendererError: String?
  private var animationEnabled = false
  private var appliedMotion: Bool?
  private var breathingEnabled = false
  private var appliedBreathing: Bool?
  private var stopped = false
  private let relay = GargantuaMessageRelay()

  init(scene: WebScene = .gargantua) {
    self.scene = scene
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    webView = GargantuaWebView(frame: .zero, configuration: configuration)
    super.init(frame: .zero)
    relay.owner = self
    configuration.userContentController.add(relay, name: scene.name)
    webView.navigationDelegate = self
    webView.setAccessibilityElement(false)
    webView.setValue(false, forKey: "drawsBackground")
    addSubview(webView)
    webView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: trailingAnchor),
      webView.topAnchor.constraint(equalTo: topAnchor),
      webView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { nil }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var acceptsFirstResponder: Bool { false }

  func loadRenderer() {
    guard
      let resource = Bundle.module.url(
        forResource: "index", withExtension: "html", subdirectory: scene.directory)
    else {
      fail("The bundled \(scene.title) canvas resources are missing.")
      return
    }
    webView.loadFileURL(resource, allowingReadAccessTo: resource.deletingLastPathComponent())
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self)
    if let window {
      for name in [
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification,
      ] {
        NotificationCenter.default.addObserver(
          self, selector: #selector(visibilityChanged), name: name, object: window)
      }
      for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
        NotificationCenter.default.addObserver(
          self, selector: #selector(visibilityChanged), name: name, object: NSApp)
      }
    }
    synchronizeMotion()
  }

  func setAnimationEnabled(_ enabled: Bool) {
    animationEnabled = enabled
    synchronizeMotion()
  }

  /// The scene itself pulses (disk glow or aurora swell) instead of drawing a ring over it.
  func setBreathing(_ enabled: Bool) {
    breathingEnabled = enabled
    synchronizeBreathing()
  }

  private func synchronizeBreathing() {
    guard rendererReady, !stopped, appliedBreathing != breathingEnabled else { return }
    appliedBreathing = breathingEnabled
    webView.evaluateJavaScript(
      "\(scene.api).setBreathing(\(breathingEnabled ? "true" : "false"))"
    ) { [weak self] _, error in
      if let error { self?.fail(error.localizedDescription) }
    }
  }

  @objc private func visibilityChanged() { synchronizeMotion() }

  private func synchronizeMotion() {
    guard rendererReady, !stopped else { return }
    let visible =
      window.map { $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? false
    let shouldAnimate = animationEnabled && visible && !NSApp.isHidden
    guard appliedMotion != shouldAnimate else { return }
    appliedMotion = shouldAnimate
    webView.evaluateJavaScript(
      "\(scene.api).setNativeMotion(\(shouldAnimate ? "true" : "false"))"
    ) { [weak self] _, error in
      if let error { self?.fail(error.localizedDescription) }
    }
  }

  fileprivate func receive(_ body: Any) {
    guard !stopped, let message = body as? [String: Any],
      let status = message["status"] as? String
    else { return }
    if status == "ready" {
      rendererReady = true
      synchronizeBreathing()
      synchronizeMotion()
    } else if status == "error" {
      fail(message["error"] as? String ?? "An unknown graphics error occurred.")
    }
  }

  private func fail(_ message: String) {
    guard !stopped, rendererError == nil else { return }
    rendererError = message
    rendererReady = false
    onFailure?(message)
    NSLog("%@ renderer unavailable: %@", scene.title, message)
  }

  func shutdown() {
    guard !stopped else { return }
    webView.evaluateJavaScript("\(scene.api)?.stop()")
    stopped = true
    NotificationCenter.default.removeObserver(self)
    webView.configuration.userContentController.removeScriptMessageHandler(forName: scene.name)
    webView.navigationDelegate = nil
    webView.stopLoading()
    relay.owner = nil
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    fail(error.localizedDescription)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    webView.evaluateJavaScript("\(scene.api)?.status ?? 'missing'") {
      [weak self] value, error in
      if let error {
        self?.fail(error.localizedDescription)
      } else if value as? String != "ready" {
        self?.fail(
          "The bundled canvas did not finish starting. Select another theme and try again.")
      }
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    fail(error.localizedDescription)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    fail(
      "The graphics process stopped. Select another theme and return to \(scene.title) to restart it."
    )
  }
}

private final class GargantuaWebView: WKWebView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var acceptsFirstResponder: Bool { false }
}

@MainActor
private final class GargantuaMessageRelay: NSObject, WKScriptMessageHandler {
  weak var owner: GargantuaCanvasHost?

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    owner?.receive(message.body)
  }
}
