#if DEBUG
  import AppKit
  import WebKit

  @MainActor
  enum GargantuaValidation {
    static func validate(window: NSWindow, folder: URL) async throws {
      guard Bundle.main.bundleIdentifier == "com.tickettracker.local.validation" else {
        throw Failure("Run Gargantua validation only in the isolated native UI-validation app.")
      }
      let defaults = UserDefaults.standard
      let originalTheme = defaults.string(forKey: "workspace.theme")
      let originalAnimation = defaults.object(forKey: "workspace.animations")
      defer {
        defaults.set(originalTheme, forKey: "workspace.theme")
        if let originalAnimation {
          defaults.set(originalAnimation, forKey: "workspace.animations")
        } else {
          defaults.removeObject(forKey: "workspace.animations")
        }
        window.orderFront(nil)
      }
      defaults.set(WorkspaceTheme.gargantua.rawValue, forKey: "workspace.theme")
      defaults.set(true, forKey: "workspace.animations")
      window.orderFront(nil)
      let host = try await waitForHost(in: window)
      guard !host.webView.acceptsFirstResponder, host.hitTest(.zero) == nil else {
        throw Failure("The Gargantua background can intercept native input.")
      }
      let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      if reducedMotion {
        try await waitUntil(host) { $0.paused }
      } else {
        window.resignKey()
        try await waitUntil(host) { !$0.paused }
        let first = try await state(host)
        try await waitUntil(host) { $0.frames >= first.frames + 3 && $0.time > first.time }
      }

      defaults.set(false, forKey: "workspace.animations")
      try await waitUntil(host) { $0.paused }
      let paused = try await state(host)
      try await Task.sleep(for: .milliseconds(500))
      guard try await state(host) == paused else {
        throw Failure("The native animation toggle did not freeze the Gargantua clock.")
      }

      let firstFrame = try await captureFrame(host, time: 12)
      guard firstFrame.litPixels > 100, firstFrame.width > 100, firstFrame.height > 100 else {
        throw Failure("Gargantua rendered an empty or undersized image.")
      }
      let firstImage = try await snapshot(host, name: "gargantua-frame-12", folder: folder)
      let repeatedFrame = try await captureFrame(host, time: 12)
      let repeatedImage = try await snapshot(
        host, name: "gargantua-frame-12-repeat", folder: folder)
      guard firstFrame == repeatedFrame, firstImage == repeatedImage else {
        throw Failure("Identical paused Gargantua times produced different frames.")
      }
      let secondFrame = try await captureFrame(host, time: 16)
      let secondImage = try await snapshot(host, name: "gargantua-frame-16", folder: folder)
      guard firstFrame.signature != secondFrame.signature, firstImage != secondImage else {
        throw Failure("The real WebKit Gargantua frames did not change with renderer time.")
      }
      let frozenImage = try await snapshot(host, name: "gargantua-paused-first", folder: folder)
      try await Task.sleep(for: .milliseconds(500))
      let stillFrozenImage = try await snapshot(
        host, name: "gargantua-paused-second", folder: folder)
      guard frozenImage == stillFrozenImage else {
        throw Failure("The paused Gargantua compositor kept changing.")
      }

      if !reducedMotion {
        defaults.set(true, forKey: "workspace.animations")
        try await waitUntil(host) { !$0.paused }
        window.orderOut(nil)
        try await waitUntil(host) { $0.paused }
        let hidden = try await state(host)
        try await Task.sleep(for: .milliseconds(500))
        guard try await state(host) == hidden else {
          throw Failure("An occluded Gargantua window continued rendering.")
        }
        window.orderFront(nil)
        try await waitUntil(host) { !$0.paused && $0.frames > hidden.frames }
      }
      print(
        "PASS: native Gargantua WebKit renderer, deterministic bright/changing frames, static paused snapshots, native motion toggle, visible-unfocused motion, and window visibility gating."
      )
    }

    private struct Failure: LocalizedError {
      let message: String
      init(_ message: String) { self.message = message }
      var errorDescription: String? { message }
    }

    private struct State: Equatable {
      let frames: Int
      let paused: Bool
      let time: Double
    }

    private struct Frame: Equatable {
      let signature: UInt32
      let litPixels: Int
      let width: Int
      let height: Int
    }

    private static func waitForHost(in window: NSWindow) async throws -> GargantuaCanvasHost {
      func find(_ view: NSView) -> GargantuaCanvasHost? {
        if let host = view as? GargantuaCanvasHost, host.scene == .gargantua { return host }
        return view.subviews.lazy.compactMap(find).first
      }
      for _ in 0..<200 {
        if let root = window.contentView, let host = find(root) {
          if let error = host.rendererError { throw Failure(error) }
          if host.rendererReady { return host }
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw Failure("The actual workspace did not attach a ready Gargantua WebKit canvas.")
    }

    private static func state(_ host: GargantuaCanvasHost) async throws -> State {
      if let error = host.rendererError { throw Failure(error) }
      let value = try await host.webView.evaluateJavaScript(
        "({ frames: window.__gargantua.frames, paused: window.__gargantua.paused, time: window.__gargantua.time })"
      )
      guard let result = value as? [String: Any],
        let frames = result["frames"] as? Int, let paused = result["paused"] as? Bool,
        let time = result["time"] as? Double
      else { throw Failure("The renderer did not return valid native motion diagnostics.") }
      return State(frames: frames, paused: paused, time: time)
    }

    private static func waitUntil(
      _ host: GargantuaCanvasHost, predicate: (State) -> Bool
    ) async throws {
      for _ in 0..<100 {
        if try await predicate(state(host)) { return }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw Failure("The native Gargantua motion bridge did not reach its expected state.")
    }

    private static func captureFrame(_ host: GargantuaCanvasHost, time: Int) async throws -> Frame {
      let value = try await host.webView.evaluateJavaScript(
        "window.__gargantua.captureFrame(\(time))")
      guard let result = value as? [String: Any],
        let signature = result["signature"] as? NSNumber,
        let litPixels = result["litPixels"] as? Int,
        let width = result["width"] as? Int, let height = result["height"] as? Int
      else { throw Failure("The actual WebGL pixel capture failed.") }
      return Frame(
        signature: signature.uint32Value, litPixels: litPixels, width: width, height: height)
    }

    private static func snapshot(
      _ host: GargantuaCanvasHost, name: String, folder: URL
    ) async throws -> Data {
      try await Task.sleep(for: .milliseconds(100))
      let image = try await host.webView.takeSnapshot(configuration: nil)
      guard let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
      else { throw Failure("The real WebKit canvas snapshot could not be encoded.") }
      try png.write(to: folder.appendingPathComponent("\(name).png"))
      return png
    }
  }
#endif
