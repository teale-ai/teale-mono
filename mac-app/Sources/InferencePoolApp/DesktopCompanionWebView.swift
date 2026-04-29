import SwiftUI
import WebKit
import AppKit
import AppCore
import AuthKit

private enum DesktopCompanionConfig {
    static let remoteDesktopURL = URL(
        string: ProcessInfo.processInfo.environment["TEALE_DESKTOP_WEB_URL"]
            ?? "https://teale.com/docs/desktop-companion/index.html"
    )

    static let routes: [String: String] = [
        "snapshot": "/v1/desktop/app",
        "privacyFilterMode": "/v1/desktop/app/privacy-filter/mode",
        "chatCompletions": "/v1/chat/completions",
        "authSession": "/v1/desktop/app/auth/session",
        "networkModels": "/v1/desktop/app/network/models",
        "networkStats": "/v1/desktop/app/network/stats",
        "accountSummary": "/v1/desktop/app/account",
        "accountApiKeys": "/v1/desktop/app/account/api-keys",
        "accountApiKeysRevoke": "/v1/desktop/app/account/api-keys/revoke",
        "accountLink": "/v1/desktop/app/account/link",
        "accountSweep": "/v1/desktop/app/account/sweep",
        "accountSend": "/v1/desktop/app/account/send",
        "accountDevicesRemove": "/v1/desktop/app/account/devices/remove",
        "walletRefresh": "/v1/desktop/app/wallet/refresh",
        "walletSend": "/v1/desktop/app/wallet/send",
        "authPending": "teale://localhost/auth/pending",
        "bundledApp": "teale://localhost/",
        "localApiKey": "teale://localhost/auth/local-api-key",
    ]
}

@MainActor
final class DesktopCompanionBridge {
    static let shared = DesktopCompanionBridge()

    private weak var webView: WKWebView?
    private weak var authManager: AuthManager?
    private var pendingOAuthCallbackURL: String?
    private var localAPIKey: String?
    private var localAPIKeyTask: Task<Void, Never>?

    func attach(webView: WKWebView, authManager: AuthManager?, appState: AppState) {
        self.webView = webView
        self.authManager = authManager
        prewarmLocalAPIKey(using: appState)
        dispatchPendingOAuthCallbackIfPossible()
        syncNativeStateIntoPage()
    }

    func handleIncomingURL(_ url: URL) {
        pendingOAuthCallbackURL = url.absoluteString
        dispatchPendingOAuthCallbackIfPossible()
    }

    func takePendingOAuthCallbackURL() -> String? {
        defer { pendingOAuthCallbackURL = nil }
        return pendingOAuthCallbackURL
    }

    func currentLocalAPIKey() -> String? {
        localAPIKey
    }

    func pageDidFinishLoading() {
        dispatchPendingOAuthCallbackIfPossible()
        syncNativeStateIntoPage()
    }

    fileprivate func handleNativeMessage(_ message: DesktopNativeMessage) {
        switch message.kind {
        case "openExternal":
            guard let rawURL = message.url, let url = URL(string: rawURL) else { return }
            NSWorkspace.shared.open(url)
        case "authLog":
            if let text = message.message {
                print("[DesktopCompanion] \(text)")
            }
        case "authSession":
            guard
                let accessToken = message.accessToken,
                let refreshToken = message.refreshToken,
                let authManager
            else { return }
            Task {
                try? await authManager.adoptSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
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
        return """
        window.__TEALE_DESKTOP_CONFIG__ = \(json);
        window.ipc = {
          postMessage: function(message) {
            window.webkit.messageHandlers.ipc.postMessage(message);
          }
        };
        """
    }

    private func dispatchPendingOAuthCallbackIfPossible() {
        guard let callbackURL = pendingOAuthCallbackURL, let webView else { return }
        let payloadData = try? JSONEncoder().encode(callbackURL)
        guard let payloadData, let payload = String(data: payloadData, encoding: .utf8) else {
            return
        }
        let script = """
        window.__tealePendingOAuthCallbackUrl = \(payload);
        try {
          window.localStorage.setItem("__teale_pending_oauth_callback", \(payload));
        } catch (_error) {}
        if (typeof window.__tealeHandleOAuthCallback === "function") {
          window.__tealeHandleOAuthCallback(\(payload));
        }
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
        pendingOAuthCallbackURL = nil
    }

    private func syncNativeStateIntoPage() {
        if let key = localAPIKey {
            let payloadData = try? JSONEncoder().encode(key)
            if let payloadData, let payload = String(data: payloadData, encoding: .utf8) {
                let script = """
                window.__TEALE_DESKTOP_CONFIG__ = window.__TEALE_DESKTOP_CONFIG__ || {};
                window.__TEALE_DESKTOP_CONFIG__.localApiKey = \(payload);
                if (typeof window.__tealeSetLocalApiKey === "function") {
                  window.__tealeSetLocalApiKey(\(payload));
                }
                """
                webView?.evaluateJavaScript(script, completionHandler: nil)
            }
        }

        guard let authManager else { return }
        Task {
            guard let session = await authManager.currentSessionTokens() else { return }
            let payload: [String: String] = [
                "accessToken": session.accessToken,
                "refreshToken": session.refreshToken,
            ]
            guard
                let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                let json = String(data: data, encoding: .utf8)
            else {
                return
            }
            await MainActor.run {
                let script = """
                if (typeof window.__tealeHydrateNativeSession === "function") {
                  window.__tealeHydrateNativeSession(\(json));
                } else {
                  window.__TEALE_DESKTOP_CONFIG__ = window.__TEALE_DESKTOP_CONFIG__ || {};
                  window.__TEALE_DESKTOP_CONFIG__.nativeSession = \(json);
                }
                """
                self.webView?.evaluateJavaScript(script, completionHandler: nil)
            }
        }
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
    let accessToken: String?
    let refreshToken: String?

    private enum CodingKeys: String, CodingKey {
        case kind = "type"
        case url
        case message
        case accessToken
        case refreshToken
    }
}

private final class DesktopCompanionIPCHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
            message.name == "ipc",
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

        let host = url.host ?? ""
        let rawPath = url.path.isEmpty ? "/" : url.path
        let path: String
        if rawPath == "/" || (host == "auth" && rawPath == "/callback") || rawPath == "/auth/callback" {
            path = "index.html"
        } else {
            path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        let responseData: (Data, String, Int)?
        switch path {
        case "index.html":
            responseData = resource(named: "index.html", mimeType: "text/html")
        case "app.css":
            responseData = resource(named: "app.css", mimeType: "text/css")
        case "app.js":
            responseData = resource(named: "app.js", mimeType: "text/javascript")
        case "auth/pending":
            let payload = ["url": DesktopCompanionBridge.shared.takePendingOAuthCallbackURL()]
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data("{\"url\":null}".utf8)
            responseData = (data, "application/json", 200)
        case "auth/local-api-key":
            let payload = ["key": DesktopCompanionBridge.shared.currentLocalAPIKey()]
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data("{\"key\":null}".utf8)
            responseData = (data, "application/json", 200)
        default:
            responseData = (Data("Not Found".utf8), "text/plain", 404)
        }

        guard let (data, mimeType, statusCode) = responseData,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": mimeType,
                    "Cache-Control": "no-store",
                    "Access-Control-Allow-Origin": "*",
                    "Access-Control-Allow-Headers": "Content-Type, Accept, Authorization",
                    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                    "Access-Control-Allow-Private-Network": "true",
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
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "DesktopCompanionWeb"
        ), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return (data, mimeType, 200)
    }
}

private final class DesktopCompanionNavigationDelegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DesktopCompanionBridge.shared.pageDidFinishLoading()
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
        webView.setValue(false, forKey: "drawsBackground")
        DesktopCompanionBridge.shared.attach(webView: webView, authManager: appState.authManager, appState: appState)
        webView.load(URLRequest(url: URL(string: "teale://localhost/")!))
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
