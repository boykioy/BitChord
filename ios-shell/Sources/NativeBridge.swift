import Foundation
import WebKit

/// Receives `window.webkit.messageHandlers.bc.postMessage({...})` from bridge.js
/// and answers with the HTTP result. Replaces the browser extension's network layer.
final class NativeBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = NativeBridge()

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let url = body["url"] as? String else {
            replyHandler(nil, "Malformed request")
            return
        }
        let mode = (body["mode"] as? String) ?? "page"
        let method = ((body["method"] as? String) ?? "GET").uppercased()
        let headers = (body["headers"] as? [String: String]) ?? [:]
        var data: Data? = nil
        if let b64 = body["body"] as? String, !b64.isEmpty {
            data = Data(base64Encoded: b64)
        }

        NativeNet.perform(mode: mode, urlString: url, method: method, headers: headers, body: data) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let dict): replyHandler(dict, nil)
                case .failure(let error): replyHandler(nil, error.localizedDescription)
                }
            }
        }
    }
}
