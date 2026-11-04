import SwiftUI
import WebKit
import AppKit

/// Shared holder for a single recycled `WKWebView` instance across the app lifecycle.
@MainActor
final class RecycledWebViewContainer {
    static let shared = RecycledWebViewContainer()

    let webView: WKWebView

    private init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsMagnification = false
        self.webView = view
    }
}

/// A lightweight, memory-efficient AppKit WKWebView wrapper for SwiftUI that recycles
/// a single underlying `WKWebView` instance and enforces strict Content Security Policy.
public struct RecycledWKWebView: NSViewRepresentable {
    public let htmlContent: String
    public let loadRemoteImages: Bool

    public init(htmlContent: String, loadRemoteImages: Bool = false) {
        self.htmlContent = htmlContent
        self.loadRemoteImages = loadRemoteImages
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let webView = RecycledWebViewContainer.shared.webView

        // Detach from any prior superview and reparent to this container
        webView.removeFromSuperview()
        webView.navigationDelegate = context.coordinator
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        updateHTML(in: webView, coordinator: context.coordinator)
        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        let webView = RecycledWebViewContainer.shared.webView

        // Ensure webView is housed inside current container view
        if webView.superview !== nsView {
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
            nsView.addSubview(webView)

            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: nsView.topAnchor),
                webView.bottomAnchor.constraint(equalTo: nsView.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: nsView.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: nsView.trailingAnchor)
            ])
        }

        webView.navigationDelegate = context.coordinator
        updateHTML(in: webView, coordinator: context.coordinator)
    }

    private func updateHTML(in webView: WKWebView, coordinator: Coordinator) {
        let fullHTML = wrapHTML(htmlContent, loadRemoteImages: loadRemoteImages)
        guard coordinator.lastLoadedHTML != fullHTML else { return }
        coordinator.lastLoadedHTML = fullHTML
        webView.loadHTMLString(fullHTML, baseURL: nil)
    }

    private func wrapHTML(_ body: String, loadRemoteImages: Bool) -> String {
        let csp: String
        if loadRemoteImages {
            csp = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; font-src local:; img-src https: data:;">"#
        } else {
            csp = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; font-src local:;">"#
        }

        let css = """
        <style>
        :root {
            color-scheme: light dark;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
        }
        body {
            margin: 18px;
            line-height: 1.6;
            word-break: break-word;
            font-size: 14px;
            color: #1c1c1e;
            background-color: transparent;
        }
        img {
            max-width: 100%;
            height: auto;
            border-radius: 4px;
        }
        pre, code {
            font-family: ui-monospace, Menlo, Monaco, "SF Mono", monospace;
            font-size: 13px;
            background: rgba(128, 128, 128, 0.1);
            padding: 2px 4px;
            border-radius: 4px;
        }
        pre {
            padding: 10px;
            overflow-x: auto;
        }
        blockquote {
            border-left: 3px solid rgba(128, 128, 128, 0.4);
            margin-left: 0;
            padding-left: 12px;
            color: rgba(128, 128, 128, 0.9);
        }
        a {
            color: #007aff;
            text-decoration: underline;
        }
        @media (prefers-color-scheme: dark) {
            body {
                color: #e5e5ea;
                background-color: transparent;
            }
            a {
                color: #0a84ff;
            }
            blockquote {
                border-left: 3px solid rgba(255, 255, 255, 0.2);
                color: rgba(255, 255, 255, 0.6);
            }
        }
        </style>
        """

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            \(csp)
            \(css)
        </head>
        <body>
            \(body)
        </body>
        </html>
        """
    }

    public final class Coordinator: NSObject, WKNavigationDelegate {
        var lastLoadedHTML: String?

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}
