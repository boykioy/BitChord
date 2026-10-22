import SwiftUI
import WebKit
import AVFoundation

/// Hosts the BitChord web app (bundled in `www/`) in a WKWebView, served from
/// app://localhost/ so the page has a stable origin and a secure-context host name.
struct WebHost: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        // Audio keeps playing with the screen locked (UIBackgroundModes = audio).
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.applicationNameForUserAgent = "Version/17.0 Mobile/15E148 Safari/604.1"
        config.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: "app")

        let controller = config.userContentController
        controller.addScriptMessageHandler(NativeBridge.shared, contentWorld: .page, name: "bc")
        if let url = Bundle.main.url(forResource: "bridge", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            controller.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.bounces = false
        if #available(iOS 16.4, *) { web.isInspectable = true }
        web.load(URLRequest(url: URL(string: "app://localhost/")!))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Serves the bundled `www/` folder, with a single-page-app fallback to index.html.
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL = Bundle.main.resourceURL!.appendingPathComponent("www").standardizedFileURL

    private static let mime: [String: String] = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
        "json": "application/json", "map": "application/json", "svg": "image/svg+xml",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "ico": "image/x-icon", "woff": "font/woff", "woff2": "font/woff2",
        "ttf": "font/ttf", "wasm": "application/wasm", "txt": "text/plain; charset=utf-8",
        "webmanifest": "application/manifest+json",
    ]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        var relative = url.path
        if relative.isEmpty || relative == "/" { relative = "/index.html" }

        var file = root.appendingPathComponent(String(relative.dropFirst())).standardizedFileURL
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir)
        if !exists || isDir.boolValue || !file.path.hasPrefix(root.path) {
            if (relative as NSString).pathExtension.isEmpty {
                file = root.appendingPathComponent("index.html")  // client-side route
            } else {
                respond(urlSchemeTask, url: url, status: 404, type: "text/plain", data: Data("Not found".utf8))
                return
            }
        }

        guard let data = try? Data(contentsOf: file) else {
            respond(urlSchemeTask, url: url, status: 404, type: "text/plain", data: Data("Not found".utf8))
            return
        }
        let ext = file.pathExtension.lowercased()
        respond(urlSchemeTask, url: url, status: 200, type: Self.mime[ext] ?? "application/octet-stream", data: data)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, type: String, data: Data) {
        let headers = [
            "Content-Type": type,
            "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        ]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
