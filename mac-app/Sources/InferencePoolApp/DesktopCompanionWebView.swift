import SwiftUI
import WebKit
import AppKit
import AppCore
import AuthKit
import LocalAPI

private enum DesktopCompanionConfig {
    // Remote desktop UI is a dev-only override. The bundled assets under
    // Resources/DesktopCompanionWeb/ are the source of truth for shipped
    // builds - an unset env var means "use the bundled page only". Only an
    // https override is honored (LocalOriginPolicy), and that page gets the
    // config/IPC bridge but never the local API key.
    static let remoteDesktopURL: URL? = LocalOriginPolicy.desktopWebOverrideURL()

    static let bundledURL = URL(string: "teale://localhost/")!

    static let routes: [String: String] = [
        "snapshot": "/v1/desktop/app",
        "privacyFilterMode": "/v1/desktop/app/privacy-filter/mode",
        "supplySet": "/v1/desktop/app/supply",
        "chatCompletions": "/v1/chat/completions",
        "networkModels": "/v1/desktop/app/network/models",
        "networkStats": "/v1/desktop/app/network/stats",
        "accountSummary": "/v1/desktop/app/account",
        "accountApiKeys": "/v1/desktop/app/account/api-keys",
        "accountApiKeysRevoke": "/v1/desktop/app/account/api-keys/revoke",
        "accountLink": "/v1/desktop/app/account/link",
        "accountSweep": "/v1/desktop/app/account/sweep",
        "accountSend": "/v1/desktop/app/account/send",
        "accountDevicesRemove": "/v1/desktop/app/account/devices/remove",
        "accountWithdraw": "/v1/desktop/app/account/withdraw",
        "accountWithdrawals": "/v1/desktop/app/account/withdrawals",
        "depositInfo": "/v1/desktop/app/account/deposit-info",
        "walletRefresh": "/v1/desktop/app/wallet/refresh",
        "walletSend": "/v1/desktop/app/wallet/send",
        "bundledApp": "teale://localhost/",
        "localApiKey": "teale://localhost/auth/local-api-key",
    ]

    /// The bundled companion page (`teale://localhost/...`).
    static func isBundled(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "teale" && url.host?.lowercased() == "localhost"
    }

    /// The bundled page or the https dev override (same origin).
    static func isTrustedPage(_ url: URL?) -> Bool {
        guard let url else { return false }
        if isBundled(url) { return true }
        guard let remoteDesktopURL,
              let remoteOrigin = LocalOriginPolicy.origin(of: remoteDesktopURL) else { return false }
        return LocalOriginPolicy.origin(of: url) == remoteOrigin
    }

    /// Same check for a WKSecurityOrigin's parts (port 0 = scheme default).
    static func isTrustedOrigin(scheme: String, host: String, port: Int) -> Bool {
        let scheme = scheme.lowercased()
        let host = host.lowercased()
        if scheme == "teale" && host == "localhost" { return true }
        guard let remoteDesktopURL,
              remoteDesktopURL.scheme?.lowercased() == scheme,
              remoteDesktopURL.host?.lowercased() == host else { return false }
        let expectedPort = remoteDesktopURL.port ?? 443
        let actualPort = port == 0 ? 443 : port
        return expectedPort == actualPort
    }
}

@MainActor
final class DesktopCompanionBridge {
    static let shared = DesktopCompanionBridge()

    private weak var webView: WKWebView?
    private weak var authManager: AuthManager?
    private var localAPIKey: String?
    private var localAPIKeyTask: Task<Void, Never>?

    func attach(webView: WKWebView, authManager: AuthManager?, appState: AppState) {
        self.webView = webView
        self.authManager = authManager
        prewarmLocalAPIKey(using: appState)
        syncNativeStateIntoPage()
    }

    /// The local API key, only ever handed to the bundled page.
    func localAPIKey(for pageURL: URL?) -> String? {
        DesktopCompanionConfig.isBundled(pageURL) ? localAPIKey : nil
    }

    func pageDidFinishLoading() {
        syncNativeStateIntoPage()
    }

    /// Ask the page to re-poll the local snapshot now - used after the
    /// native shell adopts a session out of band (magic-link deep link) so
    /// the web UI flips to signed-in without waiting for the next poll.
    func refreshSnapshotInPage() {
        guard let webView, DesktopCompanionConfig.isTrustedPage(webView.url) else { return }
        webView.evaluateJavaScript(
            "if (typeof window.__tealeRefreshSnapshot === \"function\") { window.__tealeRefreshSnapshot(); }",
            completionHandler: nil
        )
    }

    fileprivate func handleNativeMessage(_ message: DesktopNativeMessage) {
        switch message.kind {
        case "openExternal":
            guard let rawURL = message.url,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  ["https", "http", "mailto"].contains(scheme) else { return }
            NSWorkspace.shared.open(url)
        case "authLog":
            if let text = message.message {
                print("[DesktopCompanion] \(text)")
            }
        case "authSignOut":
            guard let authManager else { return }
            Task { await authManager.signOut() }
        default:
            break
        }
    }

    func initializationScript(appState: AppState) -> String {
        let payload: [String: Any] = [
            "apiBase": "http://127.0.0.1:\(appState.serverPort)",
            "platform": "macos",
            "shellMode": true,
            "deviceLabel": "Mac device",
            "chatTransport": "openai",
            "routes": DesktopCompanionConfig.routes,
        ]
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var trustedOrigins = ["teale://localhost"]
        if let remote = DesktopCompanionConfig.remoteDesktopURL,
           let origin = LocalOriginPolicy.origin(of: remote) {
            trustedOrigins.append(origin)
        }
        let originsJSON = (try? JSONSerialization.data(withJSONObject: trustedOrigins, options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        // Defense in depth: the navigation delegate already keeps the web
        // view on trusted pages, but never define the bridge for anything
        // else.
        return """
        (function () {
          var trusted = \(originsJSON);
          var origin = window.location.protocol === "teale:"
            ? "teale://" + window.location.host
            : window.location.origin;
          if (trusted.indexOf(origin) === -1) { return; }
          window.__TEALE_DESKTOP_CONFIG__ = \(json);
          window.ipc = {
            postMessage: function(message) {
              window.webkit.messageHandlers.ipc.postMessage(message);
            }
          };
        })();
        """
    }

    private func syncNativeStateIntoPage() {
        guard let webView, let key = localAPIKey(for: webView.url) else { return }
        let payloadData = try? JSONEncoder().encode(key)
        guard let payloadData, let payload = String(data: payloadData, encoding: .utf8) else { return }
        let script = """
        if (window.location.protocol === "teale:") {
          window.__TEALE_DESKTOP_CONFIG__ = window.__TEALE_DESKTOP_CONFIG__ || {};
          window.__TEALE_DESKTOP_CONFIG__.localApiKey = \(payload);
          if (typeof window.__tealeSetLocalApiKey === "function") {
            window.__tealeSetLocalApiKey(\(payload));
          }
        }
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func prewarmLocalAPIKey(using appState: AppState) {
        guard localAPIKey == nil, localAPIKeyTask == nil else { return }
        localAPIKeyTask = Task { @MainActor in
            let existing = await appState.apiKeyStore.allKeys().first {
                $0.isActive && $0.name == "Desktop Companion Web UI"
            }
            if let existing {
                localAPIKey = existing.key
            } else {
                localAPIKey = await appState.apiKeyStore.generateKey(name: "Desktop Companion Web UI").key
            }
            localAPIKeyTask = nil
            syncNativeStateIntoPage()
        }
    }
}

private struct DesktopNativeMessage: Decodable {
    let kind: String
    let url: String?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case kind = "type"
        case url
        case message
    }
}

private final class DesktopCompanionIPCHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let frame = message.frameInfo
        guard
            message.name == "ipc",
            frame.isMainFrame,
            DesktopCompanionConfig.isTrustedOrigin(
                scheme: frame.securityOrigin.protocol,
                host: frame.securityOrigin.host,
                port: frame.securityOrigin.port
            ),
            let body = message.body as? String,
            let data = body.data(using: .utf8),
            let payload = try? JSONDecoder().decode(DesktopNativeMessage.self, from: data)
        else {
            return
        }
        DesktopCompanionBridge.shared.handleNativeMessage(payload)
    }
}

private final class DesktopCompanionSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
            return
        }

        let rawPath = url.path.isEmpty ? "/" : url.path
        let path = rawPath == "/" ? "index.html" : rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let responseData: (Data, String, Int)?
        if !DesktopCompanionConfig.isBundled(url) {
            responseData = (Data("Not Found".utf8), "text/plain", 404)
        } else {
            switch path {
            case "index.html":
                responseData = resource(named: "index.html", mimeType: "text/html")
            case "app.css":
                responseData = resource(named: "app.css", mimeType: "text/css")
            case "app.js":
                responseData = resource(named: "app.js", mimeType: "text/javascript")
            case "auth/local-api-key":
                // Only the bundled page itself may read the key.
                let key = DesktopCompanionBridge.shared.localAPIKey(for: webView.url)
                let payload: [String: Any] = ["key": key ?? NSNull()]
                let data = (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data("{\"key\":null}".utf8)
                responseData = (data, "application/json", key == nil ? 403 : 200)
            default:
                responseData = (Data("Not Found".utf8), "text/plain", 404)
            }
        }

        // Same-origin only: no Access-Control-* headers, so no other origin
        // can read these responses.
        guard let (data, mimeType, statusCode) = responseData,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": mimeType,
                    "Cache-Control": "no-store",
                ]
              ) else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeContentData))
            return
        }

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func resource(named name: String, mimeType: String) -> (Data, String, Int)? {
        // Package.swift uses .process("Resources"), which flattens
        // DesktopCompanionWeb/* into the bundle root - so look up by
        // bare filename, not by subdirectory.
        guard let url = Bundle.module.url(forResource: name, withExtension: nil),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return (data, mimeType, 200)
    }
}

private final class DesktopCompanionNavigationDelegate: NSObject, WKNavigationDelegate {
    /// Keep the web view on the bundled page (or the https dev override).
    /// Any other http(s) navigation - a link in chat output, a docs link -
    /// opens in the default browser instead of inheriting the bridge.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if DesktopCompanionConfig.isTrustedPage(url) {
            return .allow
        }
        if url.scheme?.lowercased() == "about", navigationAction.targetFrame?.isMainFrame == false {
            return .allow
        }
        if let scheme = url.scheme?.lowercased(),
           ["https", "http", "mailto"].contains(scheme),
           navigationAction.navigationType == .linkActivated || navigationAction.targetFrame?.isMainFrame != false {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DesktopCompanionBridge.shared.pageDidFinishLoading()
    }
}

/// WKWebView drops window.alert()/confirm() calls unless a UIDelegate
/// presents them. The companion UI surfaces every error through alert()
/// (22 call sites in app.js), which meant failures - including a failed
/// sign-in code verify - were completely invisible ("nothing happened").
/// Present them as real sheets instead.
private final class DesktopCompanionUIDelegate: NSObject, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Teale"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = webView.window {
            alert.beginSheetModal(for: window) { _ in completionHandler() }
        } else {
            alert.runModal()
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Teale"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let respond = { (button: NSApplication.ModalResponse) in
            completionHandler(button == .alertFirstButtonReturn)
        }
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }
}

private struct DesktopCompanionWebContainer: NSViewRepresentable {
    let appState: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController = WKUserContentController()
        configuration.userContentController.add(context.coordinator.ipcHandler, name: "ipc")
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: DesktopCompanionBridge.shared.initializationScript(appState: appState),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: "teale")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator.navigationDelegate
        webView.uiDelegate = context.coordinator.uiDelegate
        webView.setValue(false, forKey: "drawsBackground")
        // Allow Safari → Develop → <hostname> → Teale to attach a Web
        // Inspector to the bundled UI. Required for diagnosing rendering
        // and JS-state issues against shipped builds.
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        DesktopCompanionBridge.shared.attach(webView: webView, authManager: appState.authManager, appState: appState)
        webView.load(URLRequest(url: DesktopCompanionConfig.bundledURL))
        context.coordinator.maybeLoadRemoteDesktop(into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        DesktopCompanionBridge.shared.attach(webView: webView, authManager: appState.authManager, appState: appState)
    }

    final class Coordinator {
        let ipcHandler = DesktopCompanionIPCHandler()
        let schemeHandler = DesktopCompanionSchemeHandler()
        let navigationDelegate = DesktopCompanionNavigationDelegate()
        let uiDelegate = DesktopCompanionUIDelegate()
        private var attemptedRemoteDesktopLoad = false

        init(appState: AppState) {
            _ = appState
        }

        func maybeLoadRemoteDesktop(into webView: WKWebView) {
            guard !attemptedRemoteDesktopLoad, let remoteURL = DesktopCompanionConfig.remoteDesktopURL else { return }
            attemptedRemoteDesktopLoad = true
            Task {
                guard await remoteDesktopIsAvailable(remoteURL) else { return }
                await MainActor.run {
                    let request = URLRequest(
                        url: remoteURL,
                        cachePolicy: .reloadIgnoringLocalCacheData,
                        timeoutInterval: 5
                    )
                    webView.load(request)
                }
            }
        }

        private func remoteDesktopIsAvailable(_ url: URL) async -> Bool {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = 2.5
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse else { return false }
                return (200..<300).contains(response.statusCode)
            } catch {
                return false
            }
        }
    }
}

struct DesktopCompanionRootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        DesktopCompanionWebContainer(appState: appState)
            .task {
                await appState.startServer()
                await appState.initializeAsync()
            }
            .preferredColorScheme(.dark)
    }
}
