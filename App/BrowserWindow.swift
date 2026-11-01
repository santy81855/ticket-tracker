import CryptoKit
import SwiftUI
import WebKit

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate,
  WKHTTPCookieStoreObserver
{
  static let shared = BrowserModel()
  static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
  @Published private(set) var tabs: [BrowserTab] = []
  @Published var selectedID: UUID?
  @Published var address = ""
  @Published var canGoBack = false
  @Published var canGoForward = false
  @Published var isLoading = false
  @Published var isVisible = false
  @Published var failure: String?
  @Published var untrusted: (host: String, fingerprint: String, issuer: String)?
  var homeURL = ""
  private static let trustKey = "browser.trustedCertificates"
  private var restore: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?

  var selected: BrowserTab { tabs.first { $0.id == selectedID } ?? tabs[0] }
  var webView: WKWebView { selected.webView }

  override private init() {
    super.init()
    let tab = makeTab()
    tabs = [tab]
    selectedID = tab.id
    let store = tab.webView.configuration.websiteDataStore.httpCookieStore
    restore = Task { @MainActor in
      for cookie in Self.savedSessionCookies() { await store.setCookie(cookie) }
      store.add(self)
    }
  }

  private func makeTab(configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
    let configuration = configuration ?? WKWebViewConfiguration()
    if configuration.websiteDataStore !== WKWebsiteDataStore.default() {
      configuration.websiteDataStore = .default()
    }
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.allowsBackForwardNavigationGestures = true
    view.customUserAgent = Self.userAgent
    view.navigationDelegate = self
    view.uiDelegate = self
    let tab = BrowserTab(webView: view)
    tab.observations = [
      view.observe(\.url) { _, _ in MainActor.assumeIsolated { BrowserModel.shared.sync() } },
      view.observe(\.title) { _, _ in MainActor.assumeIsolated { BrowserModel.shared.sync() } },
      view.observe(\.isLoading) { _, _ in
        MainActor.assumeIsolated { BrowserModel.shared.sync() }
      },
    ]
    return tab
  }

  private func sync() {
    address = webView.url?.absoluteString ?? ""
    isLoading = webView.isLoading
    canGoBack = webView.canGoBack
    canGoForward = webView.canGoForward
    objectWillChange.send()
  }

  @discardableResult
  func newTab(url: String? = nil) -> BrowserTab {
    let tab = makeTab()
    tabs.append(tab)
    select(tab)
    isVisible = true
    open(url ?? homeURL)
    return tab
  }

  func select(_ tab: BrowserTab) {
    selectedID = tab.id
    failure = nil
    untrusted = nil
    sync()
  }

  func selectAdjacent(_ offset: Int) {
    guard let index = tabs.firstIndex(where: { $0.id == selected.id }) else { return }
    select(tabs[(index + offset + tabs.count) % tabs.count])
  }

  func close(_ tab: BrowserTab) {
    guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
    tab.webView.stopLoading()
    tab.webView.removeFromSuperview()
    if tabs.count == 1 {
      tabs = [makeTab()]
      select(tabs[0])
      isVisible = false
      open(homeURL)
      return
    }
    tabs.remove(at: index)
    if selectedID == tab.id { select(tabs[max(0, index - 1)]) }
  }

  func open(_ text: String) {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    if !value.contains("://") { value = "https://" + value }
    guard let url = URL(string: value) else { return }
    Task { @MainActor in
      await restore?.value
      self.webView.load(URLRequest(url: url))
    }
  }

  func clearSiteData() {
    try? FileManager.default.removeItem(at: Self.cookieFile)
    WKWebsiteDataStore.default().removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
    ) { [weak self] in
      MainActor.assumeIsolated {
        try? FileManager.default.removeItem(at: Self.cookieFile)
        self?.webView.reload()
      }
    }
  }

  func forgetTrustedCertificates() {
    UserDefaults.standard.removeObject(forKey: Self.trustKey)
  }

  // MARK: Session cookie persistence
  // WebKit drops cookies without an expiry date on quit, which signs Jira out. Keep a private
  // copy so the next launch restores the login, the same way Safari restores its session.

  private static var cookieFile: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("TicketTracker/browser-session-cookies.plist")
  }

  nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
    Task { @MainActor in BrowserModel.shared.scheduleSave() }
  }

  private func scheduleSave() {
    saveTask?.cancel()
    saveTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
      Self.save(cookies.filter { $0.expiresDate == nil })
    }
  }

  private static func save(_ cookies: [HTTPCookie]) {
    let list: [[String: Any]] = cookies.compactMap { cookie in
      guard let properties = cookie.properties else { return nil }
      return Dictionary(uniqueKeysWithValues: properties.map { ($0.key.rawValue, $0.value) })
    }
    guard
      let data = try? PropertyListSerialization.data(
        fromPropertyList: list, format: .binary, options: 0)
    else { return }
    let file = cookieFile
    try? FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: file, options: [.atomic, .completeFileProtection])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  private static func savedSessionCookies() -> [HTTPCookie] {
    guard let data = try? Data(contentsOf: cookieFile),
      let list = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [[String: Any]]
    else { return [] }
    return list.compactMap { values in
      HTTPCookie(
        properties: Dictionary(
          uniqueKeysWithValues: values.map { (HTTPCookiePropertyKey($0.key), $0.value) }))
    }
  }

  func webView(
    _ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge
  ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    let space = challenge.protectionSpace
    guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = space.serverTrust
    else { return (.performDefaultHandling, nil) }
    if SecTrustEvaluateWithError(trust, nil) { return (.performDefaultHandling, nil) }
    guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      let root = chain.last
    else { return (.performDefaultHandling, nil) }
    let data = SecCertificateCopyData(root) as Data
    let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let trusted = UserDefaults.standard.dictionary(forKey: Self.trustKey) as? [String: String]
    if trusted?.values.contains(fingerprint) == true {
      return (.useCredential, URLCredential(trust: trust))
    }
    let issuer = SecCertificateCopySubjectSummary(root) as String?
    untrusted = (space.host, fingerprint, issuer ?? "an unknown issuer")
    return (.performDefaultHandling, nil)
  }

  func trustPendingCertificate() {
    guard let untrusted else { return }
    var trusted =
      UserDefaults.standard.dictionary(forKey: Self.trustKey) as? [String: String] ?? [:]
    trusted[untrusted.issuer] = untrusted.fingerprint
    UserDefaults.standard.set(trusted, forKey: Self.trustKey)
    self.untrusted = nil
    failure = nil
    webView.reload()
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) { report(error) }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    report(error)
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    failure = nil
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    failure = "The page stopped unexpectedly. Press reload."
  }

  private func report(_ error: Error) {
    let code = (error as NSError).code
    guard code != NSURLErrorCancelled, code != 102 else { return }
    failure = "\(error.localizedDescription) Check that you're on VPN, then reload."
  }

  func openIfEmpty(_ text: String) {
    if webView.url == nil { open(text) }
  }

  // Links that ask for a new window open in a new tab.
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    let tab = makeTab(configuration: configuration)
    tabs.append(tab)
    select(tab)
    return tab.webView
  }

  func webViewDidClose(_ webView: WKWebView) {
    if let tab = tabs.first(where: { $0.webView === webView }) { close(tab) }
  }
}

@MainActor
final class BrowserTab: Identifiable {
  let id = UUID()
  let webView: WKWebView
  var observations: [NSKeyValueObservation] = []
  init(webView: WKWebView) { self.webView = webView }

  var title: String {
    if let title = webView.title, !title.isEmpty { return title }
    return webView.url?.host ?? "New tab"
  }
}

struct BrowserWebView: NSViewRepresentable {
  let webView: WKWebView

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ container: NSView, context: Context) {
    guard container.subviews.first !== webView else { return }
    for subview in container.subviews { subview.removeFromSuperview() }
    webView.frame = container.bounds
    webView.autoresizingMask = [.width, .height]
    container.addSubview(webView)
  }
}

struct BrowserPanel: View {
  @ObservedObject var model: WorkspaceModel
  @ObservedObject private var browser = BrowserModel.shared
  @State private var typed = ""

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        button("chevron.left", "Back") { browser.webView.goBack() }.disabled(!browser.canGoBack)
        button("chevron.right", "Forward") { browser.webView.goForward() }
          .disabled(!browser.canGoForward)
        button(browser.isLoading ? "xmark" : "arrow.clockwise", "Reload") {
          if browser.isLoading { browser.webView.stopLoading() } else { browser.webView.reload() }
        }
        TextField("Address", text: $typed).textFieldStyle(.roundedBorder)
          .onSubmit { browser.open(typed) }
        Button("Board") { browser.open(model.settings.jiraBoardURL) }
          .help("Open the Jira board from Settings")
        button("xmark.circle.fill", "Close browser (⇧⌘B)") { browser.isVisible = false }
      }.padding(10).background(.bar)
      tabBar
      Divider()
      BrowserWebView(webView: browser.webView)
        .overlay {
          if let failure = browser.failure {
            ContentUnavailableView {
              Label("Couldn't load the page", systemImage: "wifi.exclamationmark")
            } description: {
              if let untrusted = browser.untrusted {
                Text(
                  "\(untrusted.host) presented a certificate issued by “\(untrusted.issuer)”, which this Mac doesn't trust. This is common on company networks that inspect traffic. Only continue if you recognize the issuer."
                )
              } else {
                Text(failure)
              }
            } actions: {
              if let untrusted = browser.untrusted {
                Button("Trust “\(untrusted.issuer)”") {
                  browser.trustPendingCertificate()
                }
              }
            }.background(.background)
          }
        }
    }
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.15)))
    .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
    .padding(24)
    .background(Color.black.opacity(0.25).onTapGesture { browser.isVisible = false })
    .onChange(of: browser.address) { _, value in typed = value }
    .onAppear {
      browser.homeURL = model.settings.jiraBoardURL
      browser.openIfEmpty(model.settings.jiraBoardURL)
      typed = browser.address
    }
  }

  private var tabBar: some View {
    HStack(spacing: 4) {
      ForEach(browser.tabs) { tab in
        let isSelected = tab.id == browser.selected.id
        HStack(spacing: 6) {
          Text(tab.title).font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
            .lineLimit(1).truncationMode(.tail).frame(
              minWidth: 20, maxWidth: 200, alignment: .leading)
          Button {
            browser.close(tab)
          } label: {
            Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
              .frame(width: 15, height: 15).contentShape(Rectangle())
          }.buttonStyle(.plain).foregroundStyle(.secondary).help("Close tab")
        }
        .padding(.leading, 10).padding(.trailing, 5).frame(height: 25)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background(
          RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(isSelected ? 0.10 : 0.03))
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture { browser.select(tab) }
        .help(tab.title)
      }
      button("plus", "New tab (⌘T)") { browser.newTab() }
      Spacer(minLength: 0)
    }.padding(.horizontal, 10).padding(.bottom, 6).background(.bar)
  }

  private func button(_ symbol: String, _ help: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol).frame(width: 22, height: 22).contentShape(Rectangle())
    }.buttonStyle(.plain).help(help).accessibilityLabel(help)
  }
}
