import CryptoKit
import Foundation
import Security

enum BridgeScheme: String, CaseIterable, Identifiable {
    case https
    case http

    var id: String { rawValue }
}

enum BridgeEndpoint {
    static func canonicalURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        return components.url?.absoluteString
    }

    /// Removes a pasted `http://` or `https://` prefix from the host field and
    /// reports which scheme it was, so the picker can follow it.
    static func strippingScheme(_ value: String) -> (host: String, scheme: BridgeScheme?) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in BridgeScheme.allCases {
            let prefix = "\(scheme.rawValue)://"
            if trimmed.lowercased().hasPrefix(prefix) {
                return (String(trimmed.dropFirst(prefix.count)), scheme)
            }
        }
        return (value, nil)
    }

    /// Builds the canonical bridge URL from the scheme picker and a
    /// `host[:port]` field. Paths, queries and pasted schemes are ignored.
    static func make(scheme: BridgeScheme, host: String) -> String? {
        var value = strippingScheme(host).host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = value.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            value = String(value[..<end])
        }
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return nil }
        return canonicalURL("\(scheme.rawValue)://\(value)")
    }

    /// Splits a canonical URL back into the picker and host field values.
    static func fields(from url: String) -> (scheme: BridgeScheme, host: String) {
        let stripped = strippingScheme(url)
        return (stripped.scheme ?? .https, stripped.host.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    static func tokenAccount(for bridgeBaseURL: String) -> String? {
        guard let endpoint = canonicalURL(bridgeBaseURL) else { return nil }
        let digest = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
        return "bridge-token.\(digest)"
    }
}

struct BridgeRequestError: LocalizedError {
    let message: String
    var statusCode: Int? = nil
    var errorDescription: String? { message }
    var isExpiredSession: Bool { statusCode == 410 }
    var isUnauthorized: Bool { statusCode == 401 }
}

enum BridgeClient {
    static func get<T: Decodable>(base: String, path: String, query: [URLQueryItem] = [], timeoutInterval: TimeInterval = 30) async throws -> T {
        var components = try components(base: base, path: path)
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw BridgeRequestError(message: "La dirección del bridge no es válida.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutInterval
        authorize(&request, bridgeBaseURL: base)
        return try await send(request)
    }

    static func post<T: Decodable, Body: Encodable>(base: String, path: String, body: Body) async throws -> T {
        try await sendJSON(method: "POST", base: base, path: path, body: body, timeoutInterval: path == "/api/play" ? 90 : 30)
    }

    static func put<T: Decodable, Body: Encodable>(base: String, path: String, body: Body) async throws -> T {
        try await sendJSON(method: "PUT", base: base, path: path, body: body, timeoutInterval: 30)
    }

    static func provisionUser<T: Decodable, Body: Encodable>(base: String, administratorToken: String, body: Body) async throws -> T {
        let components = try components(base: base, path: "/api/admin/users")
        guard let url = components.url else { throw BridgeRequestError(message: "La dirección del bridge no es válida.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(administratorToken.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-Bridge-Admin-Token")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request, unauthorizedMessage: "El token administrador no es válido para este bridge.")
    }

    /// `true` when the bridge rejects requests without a user token.
    static func requiresIdentity(base: String) async -> Bool {
        do {
            let _: HistoryResponse = try await get(base: base, path: "/api/history", timeoutInterval: 10)
            return false
        } catch let error as BridgeRequestError {
            return error.isUnauthorized
        } catch {
            return false
        }
    }

    private static func sendJSON<T: Decodable, Body: Encodable>(method: String, base: String, path: String, body: Body, timeoutInterval: TimeInterval) async throws -> T {
        let components = try components(base: base, path: path)
        guard let url = components.url else { throw BridgeRequestError(message: "La dirección del bridge no es válida.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        authorize(&request, bridgeBaseURL: base)
        return try await send(request)
    }

    private static func components(base: String, path: String) throws -> URLComponents {
        guard let canonical = BridgeEndpoint.canonicalURL(base), var components = URLComponents(string: canonical) else {
            throw BridgeRequestError(message: "Configura primero la dirección del bridge.")
        }
        components.path = path
        return components
    }

    private static func authorize(_ request: inout URLRequest, bridgeBaseURL: String) {
        let token = SecureTokenStore.currentToken(for: bridgeBaseURL)
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Bridge-Token")
        }
    }

    private static func send<T: Decodable>(_ request: URLRequest, unauthorizedMessage: String = "El bridge requiere una identidad privada válida. Configúrala en Configuración.") async throws -> T {
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw BridgeRequestError(message: message(for: error))
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw BridgeRequestError(message: "El bridge no respondió correctamente.")
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw BridgeRequestError(message: unauthorizedMessage, statusCode: 401)
            }
            let bridgeMessage = try? JSONDecoder().decode(BridgeErrorResponse.self, from: data).error
            throw BridgeRequestError(message: bridgeMessage ?? "El bridge respondió HTTP \(http.statusCode).", statusCode: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BridgeRequestError(message: "El bridge devolvió una respuesta que la app no pudo leer. ¿Está actualizado?")
        }
    }

    private static func message(for error: URLError) -> String {
        switch error.code {
        case .appTransportSecurityRequiresSecureConnection:
            return "iOS sólo permite HTTP dentro de tu red local. Usa HTTPS para un dominio público."
        case .timedOut:
            return "El bridge no respondió a tiempo."
        case .cannotFindHost, .dnsLookupFailed:
            return "No se encontró el host del bridge. Revisa el dominio o la IP."
        case .cannotConnectToHost, .networkConnectionLost:
            return "No se pudo conectar con el bridge. Comprueba que esté encendido y accesible."
        case .notConnectedToInternet:
            return "Sin conexión. Si iOS pidió acceso a la red local, permítelo y vuelve a intentarlo."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "Falló la conexión HTTPS. Revisa el certificado del dominio o usa HTTP si es una IP local."
        default:
            return error.localizedDescription
        }
    }
}

enum HistoryIdentity {
    static func storageID(for token: String, bridgeBaseURL: String) -> String {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = BridgeEndpoint.canonicalURL(bridgeBaseURL) ?? "unconfigured"
        let material = "\(endpoint)\u{0}\(value.isEmpty ? "local" : value)"
        return SHA256.hash(data: Data(material.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

enum SecureTokenStore {
    private static let service = "com.personal.airplaysubtitleplayer"
    private static let legacyAccount = "bridge-access-token"
    private static let legacyDefaultsKey = "anksubbrd.bridge-access-token"

    static func currentToken(for bridgeBaseURL: String) -> String {
        guard let account = BridgeEndpoint.tokenAccount(for: bridgeBaseURL) else { return "" }
        return token(forAccount: account, synchronizable: kSecAttrSynchronizableAny) ?? ""
    }

    static func restoreFromICloud(for bridgeBaseURL: String) throws -> String {
        guard let account = BridgeEndpoint.tokenAccount(for: bridgeBaseURL) else {
            throw BridgeRequestError(message: "Primero configura una URL válida del bridge.")
        }
        guard let token = token(forAccount: account, synchronizable: true) else {
            throw BridgeRequestError(message: "No hay una identidad para esta URL en el Llavero de iCloud todavía.")
        }
        return token
    }

    static func migrateLegacyToken(to bridgeBaseURL: String) throws -> Bool {
        guard currentToken(for: bridgeBaseURL).isEmpty else { return false }
        let legacyToken = token(forAccount: legacyAccount, synchronizable: kSecAttrSynchronizableAny)
            ?? UserDefaults.standard.string(forKey: legacyDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let legacyToken, !legacyToken.isEmpty else { return false }
        try save(legacyToken, for: bridgeBaseURL)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        deleteLegacyToken()
        return true
    }

    static func makeCurrentTokenSynchronizable(for bridgeBaseURL: String) throws -> Bool {
        let account = try account(for: bridgeBaseURL)
        if token(forAccount: account, synchronizable: true) != nil { return false }
        guard let existing = token(forAccount: account, synchronizable: false) else { return false }
        try save(existing, for: bridgeBaseURL)
        guard token(forAccount: account, synchronizable: true) == existing else {
            throw BridgeRequestError(message: "No se pudo verificar la copia sincronizable del token. La copia anterior sigue intacta.")
        }
        return true
    }

    static func save(_ token: String, for bridgeBaseURL: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: try account(for: bridgeBaseURL),
            kSecAttrSynchronizable as String: true,
        ]
        let data = Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard !data.isEmpty else { throw BridgeRequestError(message: "El token no puede estar vacío.") }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw BridgeRequestError(message: "No se pudo guardar el token en el Llavero.") }
        var add = query
        attributes.forEach { add[$0.key] = $0.value }
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw BridgeRequestError(message: "No se pudo guardar el token en el Llavero.")
        }
    }

    private static func account(for bridgeBaseURL: String) throws -> String {
        guard let account = BridgeEndpoint.tokenAccount(for: bridgeBaseURL) else {
            throw BridgeRequestError(message: "Primero configura una URL válida del bridge.")
        }
        return account
    }

    private static func token(forAccount account: String, synchronizable: Any) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            return nil
        }
        return token
    }

    private static func deleteLegacyToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyAccount,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum TokenGenerator {
    static func make() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BridgeRequestError(message: "No se pudo generar un token seguro.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
