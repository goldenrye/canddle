import CryptoKit
import Foundation
import Security

struct PairingTicket: Decodable, Identifiable {
    let type: String
    let v: Int
    let relay: String
    let code: String
    var id: String { code }

    static func parse(_ text: String) throws -> PairingTicket {
        guard text.utf8.count <= 1024,
              let ticket = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
              ticket.type == "vpcomm-pair", ticket.v == 1 else { throw VoiceError.packet }
        _ = try VoiceProtocol.decode(ticket.code, size: 32)
        guard ticket.relay.utf8.count <= 256,
              ticket.relay.utf8.allSatisfy({ (33...126).contains($0) }),
              !ticket.relay.contains("\\") else { throw VoiceError.endpoint }
        _ = try RelaySettings(address: ticket.relay, token: ticket.code)
        return ticket
    }
}

struct RelaySettings {
    let url: URL
    let token: String
    let root: Data?

    init(address: String, token: String, root: Data? = nil, testLoopback: Bool = false) throws {
        guard let parts = URLComponents(string: address),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil,
              parts.fragment == nil, parts.percentEncodedPath == "/relay",
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              let url = parts.url,
              parts.scheme == "wss" || (
                testLoopback && parts.scheme == "ws" && ["localhost", "127.0.0.1", "[::1]"].contains(host)
              ) else { throw VoiceError.endpoint }
        guard token.utf8.count >= 32, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw VoiceError.token
        }
        self.url = url
        self.token = token
        self.root = root
    }

    static func certificate(_ data: Data) throws -> Data {
        guard data.count <= 32768 else { throw VoiceError.certificate }
        var der = data
        if let pem = String(data: data, encoding: .utf8),
           pem.contains("-----BEGIN CERTIFICATE-----") {
            let blocks = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----")
            guard blocks.count == 2 else { throw VoiceError.certificate }
            let tail = blocks[1].components(separatedBy: "-----END CERTIFICATE-----")
            guard tail.count == 2,
                  tail[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let decoded = Data(base64Encoded: tail[0].filter { !$0.isWhitespace }) else {
                throw VoiceError.certificate
            }
            der = decoded
        }
        guard SecCertificateCreateWithData(nil, der as CFData) != nil else {
            throw VoiceError.certificate
        }
        return der
    }

    static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

private class CertificateDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate,
                                         @unchecked Sendable {
    let host: String
    let root: Data?
    init(_ settings: RelaySettings) {
        host = settings.url.host ?? ""
        root = settings.root
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.protectionSpace.host == host else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard let root else { completionHandler(.performDefaultHandling, nil); return }
        guard let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecCertificateCreateWithData(nil, root as CFData) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // Trust evaluation must not block URLSession's delegate/cancellation queue.
        DispatchQueue.global(qos: .userInitiated).async { [host] in
            guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
                  SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                  SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
                  SecTrustEvaluateWithError(trust, nil) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Don't forward the bearer token to a redirect destination.
    }
}

private final class PairingResponseDelegate: CertificateDelegate, URLSessionDataDelegate,
                                             @unchecked Sendable {
    private var bytes = Data()
    private var response: URLResponse?
    private let completion: @Sendable (Result<(Data, URLResponse), Error>) -> Void

    init(_ settings: RelaySettings,
         completion: @escaping @Sendable (Result<(Data, URLResponse), Error>) -> Void) {
        self.completion = completion
        super.init(settings)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= 8192 else {
            completionHandler(.cancel)
            return
        }
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= 8192 else { dataTask.cancel(); return }
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { completion(.failure(error)); return }
        guard let response else { completion(.failure(VoiceError.packet)); return }
        completion(.success((bytes, response)))
    }
}

@MainActor
final class Relay {
    private(set) var supportsPresence = false
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private var keys: CallKeys?
    private var ready = false
    private var ended = false
    private var pending: [UUID: (Error) -> Void] = [:]
    private let settings: RelaySettings

    init(_ settings: RelaySettings) {
        self.settings = settings
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 150
        config.timeoutIntervalForResource = 3700
        session = URLSession(configuration: config, delegate: CertificateDelegate(settings),
                             delegateQueue: nil)
        var request = URLRequest(url: settings.url)
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1024
    }

    func redeem(_ ticket: PairingTicket) async throws -> String {
        guard settings.url.absoluteString == ticket.relay else { throw VoiceError.endpoint }
        var components = URLComponents(url: settings.url, resolvingAgainstBaseURL: false)!
        components.scheme = "https"
        components.path = "/pair"
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        // The capability goes in a header, never in URLs, browser history, or query logs.
        request.setValue("Pair \(ticket.code)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        var pairingSession: URLSession?
        defer { pairingSession?.invalidateAndCancel(); stop() }
        let (data, response): (Data, URLResponse) = try await bounded(10) { complete in
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.connectionProxyDictionary = [:]
            pairingSession = URLSession(
                configuration: config,
                delegate: PairingResponseDelegate(self.settings, completion: complete),
                delegateQueue: nil
            )
            pairingSession?.dataTask(with: request).resume()
        }
        try Task.checkCancellation()
        guard !ended, let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == request.url else { throw VoiceError.ended }
        struct Reply: Decodable {
            let v: Int
            let relay: String
            let token: String
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.v == 1, reply.relay == ticket.relay, reply.token.utf8.count <= 4096 else {
            throw VoiceError.packet
        }
        _ = try RelaySettings(address: reply.relay, token: reply.token)
        return reply.token
    }

    func unregisterPush(identity: Curve25519.Signing.PrivateKey) async throws {
        defer { stop() }
        try await openLobby(identity: identity, name: "Push control", pushControl: true)
        try await lobbySend(["type": "push-unregister"])
        guard try await lobbyReceive(seconds: 10) == ["type": "push-unregistered"] else {
            throw VoiceError.packet
        }
    }

    func openLobby(identity: Curve25519.Signing.PrivateKey, name: String, group: Bool = false,
                   pushControl: Bool = false) async throws {
        guard LobbyProtocol.nameValid(name), !ended else { throw VoiceError.packet }
        if group { socket.maximumMessageSize = 8192 }
        socket.resume()
        let hello = pushControl ? "{\"v\":2,\"push\":true}"
            : (group ? "{\"v\":2,\"group\":true}" : "{\"v\":1,\"lobby\":true}")
        try await send(.string(hello), seconds: 10)
        let challenge = try await lobbyReceive(seconds: 10)
        guard challenge["type"] == "challenge", let nonce = challenge["challenge"] else {
            throw VoiceError.packet
        }
        _ = try VoiceProtocol.decode(nonce, size: 32)
        supportsPresence = group && challenge["presence"] == "1"
        let publicKey = VoiceProtocol.base64(identity.publicKey.rawRepresentation)
        try await lobbySend([
            "type": "register", "identity": publicKey, "name": name,
            "signature": VoiceProtocol.base64(try identity.signature(
                for: LobbyProtocol.transcript("register", [nonce, publicKey, name])
            ))
        ])
        guard try await lobbyReceive(seconds: 10) == ["type": "online"] else {
            throw VoiceError.packet
        }
    }

    func lobbySend(_ message: [String: String]) async throws {
        let data = try JSONEncoder().encode(message)
        guard data.count <= 1024 else { throw VoiceError.packet }
        try await send(.string(String(decoding: data, as: UTF8.self)))
    }

    func lobbyReceive(seconds: Double = 45) async throws -> [String: String] {
        guard case .string(let text) = try await receive(seconds: seconds),
              text.utf8.count <= 1024 else { throw VoiceError.packet }
        return try JSONDecoder().decode([String: String].self, from: Data(text.utf8))
    }

    func groupSend(_ message: [String: String]) async throws {
        let data = try JSONEncoder().encode(message)
        guard data.count <= 8192 else { throw VoiceError.packet }
        try await send(.string(String(decoding: data, as: UTF8.self)))
    }

    func groupMedia(_ data: Data) async throws {
        guard data.count == 705 else { throw VoiceError.packet }
        try await send(.data(data))
    }

    func groupReceive() async throws -> URLSessionWebSocketTask.Message {
        try await receive(seconds: 45)
    }

    func connect(_ invitation: CallInvitation, waiting: () -> Void) async throws -> String {
        guard !ended else { throw VoiceError.ended }
        socket.resume()
        do {
            let json = try JSONSerialization.data(withJSONObject: ["v": 1, "room": invitation.roomID])
            try await send(.string(String(decoding: json, as: UTF8.self)), seconds: 10)
            var response = try await receive(seconds: 10)
            if case .string("{\"type\":\"waiting\"}") = response {
                waiting()
                response = try await receive(seconds: 130)
            }
            guard case .string("{\"type\":\"ready\"}") = response else { throw VoiceError.peer }
            let exchange = KeyExchange(invitation)
            try await send(.data(exchange.hello()))
            guard case .data(let hello) = try await receive(seconds: 10) else { throw VoiceError.peer }
            keys = try exchange.authenticate(hello)
            try await send(.data(encrypt(VoiceProtocol.confirmation)))
            guard case .data(let packet) = try await receive(seconds: 10),
                  try decrypt(packet) == VoiceProtocol.confirmation,
                  let code = keys?.code else { throw VoiceError.peer }
            ready = true
            return code
        } catch {
            stop()
            throw error
        }
    }

    func transmit(_ frame: Data) async throws {
        guard ready, frame.count == VoiceProtocol.frameSize else { throw VoiceError.packet }
        try await send(.data(encrypt(Data([1]) + frame)))
    }

    func listen() async throws -> Data {
        guard ready, case .data(let packet) = try await receive(seconds: 10) else {
            throw VoiceError.ended
        }
        let plain = try decrypt(packet)
        guard plain.count == 641, plain.first == 1 else { throw VoiceError.packet }
        return Data(plain.dropFirst())
    }

    private func encrypt(_ data: Data) throws -> Data {
        guard !ended, var current = keys else { throw VoiceError.ended }
        let result = try current.seal(data)
        keys = current
        return result
    }

    private func decrypt(_ data: Data) throws -> Data {
        guard !ended, var current = keys else { throw VoiceError.ended }
        let result = try current.open(data)
        keys = current
        return result
    }

    private func send(_ message: URLSessionWebSocketTask.Message, seconds: Double = 3) async throws {
        try await bounded(seconds) { complete in
            self.socket.send(message) { error in
                complete(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    private func receive(seconds: Double) async throws -> URLSessionWebSocketTask.Message {
        try await bounded(seconds) { self.socket.receive(completionHandler: $0) }
    }

    private func bounded<T>(
        _ seconds: Double, start: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        guard !ended else { throw VoiceError.ended }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                // Own the continuation: cancellation during a TLS challenge doesn't
                // reliably produce an immediate URLSession completion callback.
                let timer = Task { @MainActor in
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    self.stop(VoiceError.timeout)
                }
                pending[id] = {
                    timer.cancel()
                    continuation.resume(throwing: $0)
                }
                start { result in
                    Task { @MainActor in
                        guard self.pending.removeValue(forKey: id) != nil else { return }
                        timer.cancel()
                        continuation.resume(with: result)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.stop(CancellationError()) }
        }
    }

    func stop(_ error: Error = VoiceError.ended) {
        guard !ended else { return }
        ended = true
        ready = false
        keys = nil
        let waiters = Array(pending.values)
        pending.removeAll()
        waiters.forEach { $0(error) }
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}
