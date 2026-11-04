import AppKit
import SwiftUI
import TrackerCore
import UniformTypeIdentifiers
import WebKit

/// Renders local text and Markdown files for the in-app browser. Markdown is parsed by the
/// bundled marked.js with raw HTML escaped, so a document can't run its own scripts.
enum DocumentViewer {
  enum Kind { case markdown, text, native }

  struct Document {
    var url: URL
    var kind: Kind
    var text = ""
    var modified: Date?
  }

  static let maximumBytes = 5_000_000
  private static let markdownExtensions: Set = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]

  static func modified(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }

  static func load(_ url: URL) throws -> Document {
    let values = try url.resourceValues(forKeys: [
      .isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey,
    ])
    guard values.isDirectory != true else {
      throw TrackerError.invalid("\(url.lastPathComponent) is a folder. Choose a file inside it.")
    }
    let modified = values.contentModificationDate
    if let type = values.contentType, type.conforms(to: .pdf) || type.conforms(to: .image) {
      return Document(url: url, kind: .native, modified: modified)
    }
    guard (values.fileSize ?? 0) <= maximumBytes else {
      throw TrackerError.invalid("\(url.lastPathComponent) is larger than 5 MB.")
    }
    let data = try Data(contentsOf: url)
    guard !data.prefix(8192).contains(0), let text = String(data: data, encoding: .utf8) else {
      throw TrackerError.invalid(
        "\(url.lastPathComponent) isn't a text file. The viewer shows text, Markdown, PDFs and images."
      )
    }
    let isMarkdown =
      markdownExtensions.contains(url.pathExtension.lowercased())
      || values.contentType?.conforms(to: UTType("net.daringfireball.markdown") ?? .plainText)
        == true && url.pathExtension.lowercased() != "txt"
    return Document(
      url: url, kind: isMarkdown ? .markdown : .text, text: text, modified: modified)
  }

  static func page(_ document: Document) -> String {
    """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src https: data: ttdoc:">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>\(escape(document.url.lastPathComponent))</title>
    <style>\(style)</style>
    <script>\(markedSource)</script>
    </head><body><main id="doc"></main><script>
    const esc = s => s.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'})[c]);
    if (window.marked) marked.use({ gfm: true, renderer: { html(token) { return esc(token.text); } } });
    window.ttRender = (text, markdown) => {
      const y = window.scrollY, doc = document.getElementById('doc');
      if (markdown && window.marked) {
        doc.className = 'markdown';
        doc.innerHTML = marked.parse(text);
        for (const a of doc.querySelectorAll('a[href]')) {
          const href = a.getAttribute('href');
          if (/^[a-z][a-z0-9+.-]*:/i.test(href) && !/^(https?|file|mailto):/i.test(href)) a.removeAttribute('href');
        }
      } else {
        doc.className = 'plain';
        const pre = document.createElement('pre');
        pre.textContent = text;
        doc.replaceChildren(pre);
      }
      window.scrollTo(0, y);
    };
    \(renderCall(document))
    </script></body></html>
    """
  }

  static func renderCall(_ document: Document) -> String {
    let data = (try? JSONEncoder().encode([document.text])) ?? Data("[\"\"]".utf8)
    let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
    return "ttRender(\(json)[0], \(document.kind == .markdown));"
  }

  private static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  private static let markedSource: String = {
    guard
      let url = Bundle.module.url(
        forResource: "marked.min", withExtension: "js", subdirectory: "Viewer"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return "" }
    return text
  }()

  private static var style: String {
    let accent = NSColor(Palette.accent).usingColorSpace(.sRGB) ?? .systemBlue
    let hex = String(
      format: "#%02X%02X%02X", Int(accent.redComponent * 255), Int(accent.greenComponent * 255),
      Int(accent.blueComponent * 255))
    return """
      :root { color-scheme: light dark; --accent: \(hex); --muted: #6e6e73; --line: rgba(127,127,127,.28);
        --code: rgba(127,127,127,.13); }
      html { background: Canvas; }
      body { margin: 0; font: 14px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; color: CanvasText; }
      main { max-width: 860px; margin: 0 auto; padding: 28px 36px 60px; }
      .markdown h1, .markdown h2 { border-bottom: 1px solid var(--line); padding-bottom: .3em; }
      .markdown h1 { font-size: 1.9em; margin-top: .2em; } .markdown h2 { font-size: 1.45em; margin-top: 1.6em; }
      .markdown h3 { font-size: 1.2em; margin-top: 1.4em; }
      a { color: var(--accent); text-decoration: none; } a:hover { text-decoration: underline; }
      code, pre { font: 12.5px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; }
      .markdown code { background: var(--code); padding: .15em .35em; border-radius: 5px; }
      .markdown pre { background: var(--code); padding: 12px 14px; border-radius: 8px; overflow: auto; }
      .markdown pre code { background: none; padding: 0; }
      .plain pre { white-space: pre-wrap; word-wrap: break-word; margin: 0; }
      blockquote { margin: 0; padding: 0 1em; color: var(--muted); border-left: 3px solid var(--accent); }
      table { border-collapse: collapse; display: block; overflow: auto; }
      th, td { border: 1px solid var(--line); padding: 6px 12px; } th { background: var(--code); }
      hr { border: 0; border-top: 1px solid var(--line); margin: 1.6em 0; }
      img { max-width: 100%; }
      li:has(> input[type=checkbox]) { list-style: none; margin-left: -1.3em; }
      input[type=checkbox] { accent-color: var(--accent); margin-right: .45em; }
      @media (prefers-color-scheme: dark) { :root { --muted: #a1a1a6; } }
      """
  }
}

/// Serves local files to the viewer as `ttdoc://local/<path>` pages, so documents get real
/// history, reload, relative links and images. Web pages can't navigate to or embed them.
final class DocumentScheme: NSObject, WKURLSchemeHandler {
  static let scheme = "ttdoc"

  static func url(for file: URL) -> URL {
    var components = URLComponents()
    components.scheme = scheme
    components.host = "local"
    components.path = file.path
    return components.url ?? file
  }

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let url = task.request.url,
      task.request.mainDocumentURL.map({ $0.scheme == Self.scheme }) ?? true
    else {
      task.didFailWithError(URLError(.noPermissionsToReadFile))
      return
    }
    let file = URL(fileURLWithPath: url.path)
    do {
      let document = try DocumentViewer.load(file)
      let data: Data
      let mimeType: String
      if document.kind == .native {
        data = try Data(contentsOf: file)
        mimeType =
          (try? file.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.preferredMIMEType
          ?? "application/octet-stream"
      } else {
        data = Data(DocumentViewer.page(document).utf8)
        mimeType = "text/html"
      }
      task.didReceive(
        URLResponse(
          url: url, mimeType: mimeType, expectedContentLength: data.count,
          textEncodingName: "utf-8"))
      task.didReceive(data)
      task.didFinish()
    } catch {
      task.didFailWithError(error)
    }
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
