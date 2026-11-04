import Foundation
import Security
import AuthenticationServices
import CryptoKit
import AppKit

// MARK: - AuthError

public enum AuthError: LocalizedError, Sendable, Equatable {
    case keychainError(status: OSStatus)
    case encodingFailed
    case decodingFailed
    case invalidAuthURL
    case sessionStartFailed
    case missingAuthorizationCode
    case oauthError(String)
    case missingRefreshToken
    case missingAccessToken
    case invalidGitHubToken
    case httpError(statusCode: Int, message: String)
    case networkError(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .keychainError(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error (\(status)): \(message)"
            }
            return "Keychain error with status code \(status)."
        case .encodingFailed:
            return "Failed to encode credential string to UTF-8 data."
        case .decodingFailed:
            return "Failed to decode credential data from Keychain as UTF-8 string."
        case .invalidAuthURL:
            return "Failed to construct Google OAuth authorization URL."
        case .sessionStartFailed:
            return "Failed to start ASWebAuthenticationSession."
        case .missingAuthorizationCode:
            return "OAuth callback did not contain an authorization code."
        case .oauthError(let message):
            return "OAuth error returned from provider: \(message)"
        case .missingRefreshToken:
            return "No Google refresh token found in macOS Keychain."
        case .missingAccessToken:
            return "No Google access token found in macOS Keychain."
        case .invalidGitHubToken:
            return "GitHub Personal Access Token is invalid or expired (HTTP 401)."
        case .httpError(let statusCode, let message):
            return "HTTP error \(statusCode): \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .invalidResponse:
            return "Received unexpected or invalid response from server."
        }
    }
}

// MARK: - WebAuthPresentationContextProvider

@MainActor
private final class WebAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthPresentationContextProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            return window
        }
        if let window = NSApplication.shared.windows.first {
            return window
        }
        return ASPresentationAnchor()
    }
}

// MARK: - AuthService

public actor AuthService {
    public static let googleAccessTokenKey = "google_access_token"
    public static let googleRefreshTokenKey = "google_refresh_token"
    public static let googleTokenExpiryKey = "google_token_expiry"
    public static let gitHubPATKey = "github_pat"

    public static let serviceName = "com.devtriage.macos"
    public static let callbackScheme = "com.googleusercontent.apps.devtriage"
    public static let redirectURI = "com.googleusercontent.apps.devtriage:/oauth2redirect"

    private let session: URLSession
    public private(set) var activeCodeVerifier: String?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Keychain Operations

    public func saveKeychainValue(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw AuthError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AuthError.keychainError(status: addStatus)
            }
        } else if status != errSecSuccess {
            throw AuthError.keychainError(status: status)
        }
    }

    public func readKeychainValue(key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AuthError.keychainError(status: status)
        }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            throw AuthError.decodingFailed
        }
        return string
    }

    public func deleteKeychainValue(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw AuthError.keychainError(status: status)
        }
    }

    public func clearAllCredentials() throws {
        try deleteKeychainValue(key: Self.googleAccessTokenKey)
        try deleteKeychainValue(key: Self.googleRefreshTokenKey)
        try deleteKeychainValue(key: Self.googleTokenExpiryKey)
        try deleteKeychainValue(key: Self.gitHubPATKey)
    }

    // MARK: - PKCE Generation

    public func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return base64URLEncode(Data(bytes))
    }

    public func generateCodeChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    // MARK: - Google OAuth

    @MainActor
    private func runWebAuthSession(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL = callbackURL else {
                    continuation.resume(throwing: AuthError.missingAuthorizationCode)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = WebAuthPresentationContextProvider.shared
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: AuthError.sessionStartFailed)
            }
        }
    }

    public func startGoogleOAuth(clientId: String) async throws -> String {
        let verifier = generateCodeVerifier()
        self.activeCodeVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/userinfo.email"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let authURL = components?.url else {
            throw AuthError.invalidAuthURL
        }

        let callbackURL = try await runWebAuthSession(url: authURL, callbackScheme: Self.callbackScheme)

        guard let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems else {
            throw AuthError.missingAuthorizationCode
        }

        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            throw AuthError.oauthError(error)
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw AuthError.missingAuthorizationCode
        }

        return code
    }

    public func exchangeGoogleCode(
        code: String,
        clientId: String,
        codeVerifier: String
    ) async throws -> (accessToken: String, refreshToken: String?, expiresIn: Int) {
        guard let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else {
            throw AuthError.invalidAuthURL
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let parameters: [String: String] = [
            "code": code,
            "client_id": clientId,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": Self.redirectURI
        ]
        request.httpBody = formURLEncode(parameters)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw AuthError.httpError(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Int
            let refresh_token: String?
        }

        let tokenResponse: TokenResponse
        do {
            tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw AuthError.decodingFailed
        }

        try saveKeychainValue(key: Self.googleAccessTokenKey, value: tokenResponse.access_token)
        if let refresh = tokenResponse.refresh_token {
            try saveKeychainValue(key: Self.googleRefreshTokenKey, value: refresh)
        }

        let expiryDate = Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in))
        let expiryString = ISO8601DateFormatter().string(from: expiryDate)
        try saveKeychainValue(key: Self.googleTokenExpiryKey, value: expiryString)

        return (
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token,
            expiresIn: tokenResponse.expires_in
        )
    }

    public func refreshGoogleToken(clientId: String) async throws -> String {
        guard let refreshToken = try readKeychainValue(key: Self.googleRefreshTokenKey) else {
            throw AuthError.missingRefreshToken
        }

        guard let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else {
            throw AuthError.invalidAuthURL
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let parameters: [String: String] = [
            "client_id": clientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        request.httpBody = formURLEncode(parameters)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw AuthError.httpError(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        struct RefreshResponse: Decodable {
            let access_token: String
            let expires_in: Int
            let refresh_token: String?
        }

        let refreshResponse: RefreshResponse
        do {
            refreshResponse = try JSONDecoder().decode(RefreshResponse.self, from: data)
        } catch {
            throw AuthError.decodingFailed
        }

        try saveKeychainValue(key: Self.googleAccessTokenKey, value: refreshResponse.access_token)
        if let newRefresh = refreshResponse.refresh_token {
            try saveKeychainValue(key: Self.googleRefreshTokenKey, value: newRefresh)
        }

        let expiryDate = Date().addingTimeInterval(TimeInterval(refreshResponse.expires_in))
        let expiryString = ISO8601DateFormatter().string(from: expiryDate)
        try saveKeychainValue(key: Self.googleTokenExpiryKey, value: expiryString)

        return refreshResponse.access_token
    }

    // MARK: - GitHub Authentication

    public func validateGitHubPAT(token: String) async throws -> (username: String, scopes: [String]) {
        guard let userURL = URL(string: "https://api.github.com/user") else {
            throw AuthError.invalidResponse
        }

        var request = URLRequest(url: userURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("DevTriage-macOS", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw AuthError.invalidGitHubToken
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw AuthError.httpError(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        struct GitHubUser: Decodable {
            let login: String
        }

        let user: GitHubUser
        do {
            user = try JSONDecoder().decode(GitHubUser.self, from: data)
        } catch {
            throw AuthError.decodingFailed
        }

        var scopes: [String] = []
        if let scopesHeader = httpResponse.value(forHTTPHeaderField: "X-OAuth-Scopes") {
            scopes = scopesHeader
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        try saveKeychainValue(key: Self.gitHubPATKey, value: token)
        return (username: user.login, scopes: scopes)
    }

    // MARK: - Form URL Encoding Helper

    private func formURLEncode(_ parameters: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let bodyString = parameters.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(bodyString.utf8)
    }
}
