import AppKit
import CryptoKit
import Security
import Darwin

struct OAuthConfiguration: Codable {
    let clientID: String
    let clientSecret: String?

    static func loadJSON(_ data: Data) throws -> OAuthConfiguration {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installed = json["installed"] as? [String: Any],
              let id = installed["client_id"] as? String,
              id.hasSuffix(".apps.googleusercontent.com") else {
            throw AppError("Google Cloudで作成した「デスクトップアプリ」のOAuth JSONを選んでください。Web用のJSONは使用できません。")
        }
        return OAuthConfiguration(clientID: id, clientSecret: installed["client_secret"] as? String)
    }
}

enum CredentialStore {
    static let service = "local.GrowthFilm.GoogleOAuth"
    static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "desktop-client"]
    }
    static func read() -> OAuthConfiguration? {
        var q = query(); q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthConfiguration.self, from: data)
    }
    static func save(_ config: OAuthConfiguration) throws {
        let data = try JSONEncoder().encode(config)
        let status = SecItemUpdate(query() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(); q[kSecValueData as String] = data
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw AppError("認証設定をキーチェーンに保存できません。") }
        } else if status != errSecSuccess { throw AppError("キーチェーンの認証設定を更新できません。") }
    }
    static func delete() { SecItemDelete(query() as CFDictionary) }
}

// IPv4 loopback only, ephemeral port. No listener on LAN interfaces.
// The state is verified before any code is accepted. Socket input is bounded.
final class LoopbackReceiver {
    private let fd: Int32
    let redirect: String
    init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw AppError("ログイン受付を開始できません。") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(socketFD, 4) == 0 else {
            close(socketFD); throw AppError("ローカル認証ポートを開けません。")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        guard result == 0 else { close(socketFD); throw AppError("認証ポートを取得できません。") }
        fd = socketFD
        redirect = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/oauth/callback"
    }
    deinit { close(fd) }

    func waitForCode(state: String) throws -> String {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try Task.checkCancellation()
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 200) > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            defer { close(client) }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 2048)
            while request.count < 8192 {
                let count = recv(client, &buffer, buffer.count, 0)
                if count <= 0 { break }
                request.append(contentsOf: buffer.prefix(count))
                if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            }
            let line = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET",
                  let url = URLComponents(string: "http://127.0.0.1" + String(parts[1])),
                  url.path == "/oauth/callback" else { respond(client, success: false); continue }
            func value(_ key: String) -> String? { url.queryItems?.first(where: { $0.name == key })?.value }
            guard value("state") == state else { respond(client, success: false); continue }
            if value("error") != nil {
                respond(client, success: false)
                throw AppError("Googleログインがキャンセル、または許可されませんでした。")
            }
            guard let code = value("code"), !code.isEmpty else { respond(client, success: false); continue }
            respond(client, success: true)
            return code
        }
        throw AppError("ログインが時間切れになりました。もう一度お試しください。")
    }

    private func respond(_ client: Int32, success: Bool) {
        let body = success ? "<meta charset='utf-8'><h2>Googleの許可を受け取りました</h2><p>GrowthFilmに戻ってください。このタブは閉じられます。</p>" : "<meta charset='utf-8'><h2>認証を完了できませんでした</h2><p>GrowthFilmに戻ってやり直してください。</p>"
        let data = Data("HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        _ = data.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
    }
}

private struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Double
    let refresh_token: String?
}
private struct PickingSession: Decodable {
    let id: String
    let pickerUri: String?
    let mediaItemsSet: Bool?
    let pollingConfig: PollingConfig?
    struct PollingConfig: Decodable { let pollInterval: String?; let timeoutIn: String? }
}
private struct MediaPage: Decodable {
    let mediaItems: [PickedItem]?
    let nextPageToken: String?
}
private struct PickedItem: Decodable {
    let id: String
    let createTime: String?
    let type: String
    let mediaFile: MediaFile
    struct MediaFile: Decodable { let baseUrl: String; let mimeType: String?; let filename: String? }
}

@MainActor
final class GooglePhotos {
    private var token: String?
    private var refreshToken: String?
    private var expires = Date.distantPast
    private var client: OAuthConfiguration?
    private let api = "https://photospicker.googleapis.com/v1"
    private let network: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()
    func disconnect() { token = nil; refreshToken = nil; client = nil; expires = .distantPast }

    private func randomURLSafe() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AppError("認証用乱数を生成できません。")
        }
        return base64url(Data(bytes))
    }
    private func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(values.sorted(by: { $0.key < $1.key }).map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" +
            ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
    }
    private func exchange(_ values: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(values)
        let data = try await checked(request)
        let result = try JSONDecoder().decode(TokenResponse.self, from: data)
        token = result.access_token
        expires = Date().addingTimeInterval(result.expires_in - 60)
        refreshToken = result.refresh_token ?? refreshToken
    }
    private func authorize() async throws {
        if token != nil, Date() < expires { return }
        guard let config = CredentialStore.read() else { throw AppError("先に「Google設定」からOAuth JSONを読み込んでください。") }
        client = config
        if let refreshToken {
            var params = ["client_id": config.clientID, "grant_type": "refresh_token", "refresh_token": refreshToken]
            if let secret = config.clientSecret { params["client_secret"] = secret }
            do { try await exchange(params); return }
            catch is CancellationError { throw CancellationError() }
            catch { self.refreshToken = nil; token = nil }
        }
        let verifier = try randomURLSafe(), state = try randomURLSafe()
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let receiver = try LoopbackReceiver()
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: receiver.redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/photospicker.mediaitems.readonly"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let browserURL = url.url, NSWorkspace.shared.open(browserURL) else { throw AppError("ブラウザを開けません。") }
        let waiter = Task.detached { try receiver.waitForCode(state: state) }
        let code = try await withTaskCancellationHandler(operation: { try await waiter.value }, onCancel: { waiter.cancel() })
        try Task.checkCancellation()
        var params = ["client_id": config.clientID, "code": code, "code_verifier": verifier,
                      "grant_type": "authorization_code", "redirect_uri": receiver.redirect]
        if let secret = config.clientSecret { params["client_secret"] = secret }
        try await exchange(params)
    }

    private func checked(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await network.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AppError("Googleからの応答を確認できません。") }
        guard (200..<300).contains(response.statusCode) else {
            // Do not expose raw response bodies, tokens, or signed content URLs.
            switch response.statusCode {
            case 401: token = nil; expires = .distantPast; throw AppError("Googleの認証が切れました。もう一度取り込んでください。")
            case 403: throw AppError("Googleがアクセスを許可しませんでした。Picker APIの有効化・テストユーザー・写真への許可を確認してください。")
            case 429: throw AppError("Googleの利用回数制限です。しばらく待ってからお試しください。")
            default: throw AppError("Googleとの通信に失敗しました（HTTP \(response.statusCode)）。OAuth設定やネット接続を確認してください。")
            }
        }
        return data
    }
    private func call(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        try await authorize()
        guard let url = URL(string: api + path), let token else { throw AppError("Google認証がありません。") }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return try await checked(request)
    }
    private func cleanup(_ id: String) async {
        guard let token, let url = URL(string: api + "/sessions/" + id) else { return }
        var request = URLRequest(url: url); request.httpMethod = "DELETE"
        request.timeoutInterval = 10
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let session = network
        // Cleanup is independent of cancellation of the importing task.
        _ = await Task.detached { try? await session.data(for: request) }.value
    }
    private func seconds(_ duration: String?, fallback: Double) -> Double {
        guard let duration, let value = Double(duration.hasSuffix("s") ? String(duration.dropLast()) : duration),
              value.isFinite, value > 0 else { return fallback }
        return value
    }

    func pick(to directory: URL, status: @escaping (String) -> Void) async throws -> [ImportSource] {
        status("Googleへのログインをブラウザで完了してください…")
        let data = try await call("/sessions", method: "POST", body: Data("{}".utf8))
        var session = try JSONDecoder().decode(PickingSession.self, from: data)
        let id = session.id
        do {
            guard let uri = session.pickerUri, let url = URL(string: uri), url.scheme == "https",
                  NSWorkspace.shared.open(url) else { throw AppError("写真の選択画面を開けません。") }
            status("Googleフォトで写真を選び、「完了」を押してください…")
            let deadline = Date().addingTimeInterval(seconds(session.pollingConfig?.timeoutIn, fallback: 600))
            while session.mediaItemsSet != true {
                try Task.checkCancellation()
                let interval = max(1, seconds(session.pollingConfig?.pollInterval, fallback: 5))
                guard Date().addingTimeInterval(interval) < deadline else { throw AppError("写真選択が時間切れです。もう一度取り込んでください。") }
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                let state = try await call("/sessions/" + id)
                session = try JSONDecoder().decode(PickingSession.self, from: state)
            }
            var items: [PickedItem] = []
            var next: String?
            repeat {
                try Task.checkCancellation()
                var query = URLComponents()
                query.queryItems = [URLQueryItem(name: "sessionId", value: id), URLQueryItem(name: "pageSize", value: "100")]
                if let next { query.queryItems?.append(URLQueryItem(name: "pageToken", value: next)) }
                let pageData = try await call("/mediaItems?" + (query.percentEncodedQuery ?? ""))
                let page = try JSONDecoder().decode(MediaPage.self, from: pageData)
                items += page.mediaItems ?? []; next = page.nextPageToken
            } while next != nil && next != ""
            let photos = items.filter { $0.type == "PHOTO" }
            guard !photos.isEmpty else { throw AppError("静止画が選ばれていません。動画ではなく写真を選んでください。") }
            var sources: [ImportSource] = []
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            for (index, item) in photos.enumerated() {
                try Task.checkCancellation()
                status("写真をダウンロード中 \(index + 1) / \(photos.count)")
                try await authorize()
                guard let url = URL(string: item.mediaFile.baseUrl + "=d"), url.scheme == "https", let token else {
                    throw AppError("写真の取得先が無効です。")
                }
                var request = URLRequest(url: url)
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                let bytes = try await checked(request)
                let path = directory.appendingPathComponent(UUID().uuidString + ".photo")
                try bytes.write(to: path, options: .atomic)
                let date = item.createTime.flatMap { fractional.date(from: $0) ?? standard.date(from: $0) }
                sources.append(ImportSource(url: path, title: item.mediaFile.filename ?? "Googleフォト", date: date))
            }
            await cleanup(id)
            return sources
        } catch {
            await cleanup(id)
            throw error
        }
    }
}
