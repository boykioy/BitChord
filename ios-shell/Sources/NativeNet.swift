import Foundation

enum NativeError: LocalizedError {
    case badURL, forbidden(String), badResponse

    var errorDescription: String? {
        switch self {
        case .badURL: return "Bad URL"
        case .forbidden(let host): return "Host not allowed: \(host)"
        case .badResponse: return "Bad response"
        }
    }
}

/// Native HTTP with the request headers the browser extension used to inject
/// (see web/extension/lib/rules.ts): YouTube's Origin/Referer, no cookies, no CORS.
enum NativeNet {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 60
        return URLSession(configuration: cfg)
    }()

    private static let lyricHosts: Set<String> = [
        "lrc.red", "lyrics-api.binimum.org", "lyrics-api.boidu.dev", "unison.boidu.dev",
        "lyrics.paxsenix.org", "api.paxsenix.org", "lyricsplus.prjktla.my.id",
        "lyricsplus.atomix.one", "lyricsplus.binimum.org", "lyricsplus.prjktla.workers.dev",
        "lyricsplus-seven.vercel.app", "lyrics-plus-backend.vercel.app", "lrclib.net",
        "mobileservice.kugou.com", "lyrics.kugou.com", "apic.musixmatch.com",
        "www.musixmatch.com", "genius.com", "music.apple.com", "amp-api.music.apple.com",
    ]

    private static func isYouTubeHost(_ host: String) -> Bool {
        host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "googlevideo.com" || host.hasSuffix(".googlevideo.com")
    }

    static func perform(
        mode: String, urlString: String, method: String,
        headers: [String: String], body: Data?,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else {
            completion(.failure(NativeError.badURL))
            return
        }
        switch mode {
        case "lyrics":
            guard lyricHosts.contains(host) else { completion(.failure(NativeError.forbidden(host))); return }
        default:
            guard isYouTubeHost(host) else { completion(.failure(NativeError.forbidden(host))); return }
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpShouldHandleCookies = false
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        if let body = body, !body.isEmpty, method != "GET", method != "HEAD" { req.httpBody = body }
        if mode == "lyrics" { req.timeoutInterval = 15 }
        applyRules(&req, url: url, host: host, mode: mode)

        let task = session.dataTask(with: req) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(NativeError.badResponse))
                return
            }
            var out: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, let v = value as? String { out[k.lowercased()] = v }
            }
            let bytes = data ?? Data()
            // URLSession already decoded the body; don't let the page decode it twice.
            out.removeValue(forKey: "content-encoding")
            if method != "HEAD" { out["content-length"] = String(bytes.count) }

            var encoding = "base64"
            var text = ""
            if mode != "page" {
                let type = out["content-type"] ?? ""
                let pattern = mode == "lyrics" ? "json|text|javascript|xml|html" : "json|text|javascript|xml"
                let textual = type.range(of: pattern, options: .regularExpression) != nil
                    || (mode == "lyrics" && type.isEmpty)
                if textual, let s = String(data: bytes, encoding: .utf8) {
                    encoding = "text"
                    text = s
                } else {
                    text = bytes.base64EncodedString()
                }
            } else {
                text = bytes.base64EncodedString()
            }
            completion(.success([
                "status": http.statusCode,
                "headers": out,
                "url": http.url?.absoluteString ?? urlString,
                "bodyEncoding": encoding,
                "body": text,
            ]))
        }
        task.resume()
    }

    // MARK: header rules (ported from extension/lib/rules.ts and lyricsFetch.ts)

    private static func applyRules(_ req: inout URLRequest, url: URL, host: String, mode: String) {
        func impersonate(_ origin: String, xOrigin: Bool) {
            req.setValue(origin, forHTTPHeaderField: "Origin")
            req.setValue(origin + "/", forHTTPHeaderField: "Referer")
            if xOrigin { req.setValue(origin, forHTTPHeaderField: "X-Origin") }
        }
        let music = "https://music.youtube.com"
        let www = "https://www.youtube.com"

        switch mode {
        case "page":
            // Requests the page makes itself (InnerTube, player scripts, SABR/direct media).
            if host == "music.youtube.com", url.path.hasPrefix("/youtubei/") {
                impersonate(music, xOrigin: true)
            } else if host == "www.youtube.com", url.path.hasPrefix("/youtubei/") {
                impersonate(www, xOrigin: true)
            } else if host.hasSuffix("googlevideo.com") {
                if url.absoluteString.contains("c=VISIONOS") {
                    req.setValue(nil, forHTTPHeaderField: "Origin")
                    req.setValue(nil, forHTTPHeaderField: "Referer")
                } else {
                    impersonate(www, xOrigin: false)
                }
            }
        case "yt":
            // yt.fetch: BotGuard's GenerateIT etc. must carry YouTube's own Origin.
            if host == "music.youtube.com" || host == "s.youtube.com" {
                impersonate(music, xOrigin: false)
            } else if host.hasSuffix("youtube.com") {
                impersonate(www, xOrigin: false)
            }
        case "lyrics":
            if host == "amp-api.music.apple.com" {
                impersonate("https://music.apple.com", xOrigin: false)
            }
            if host.hasSuffix("musixmatch.com") {
                req.setValue("mxm_bab=AB", forHTTPHeaderField: "Cookie")
            }
        default:
            break
        }
    }
}
