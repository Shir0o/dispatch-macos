import Foundation
import CryptoKit

// MARK: - GmailError

public enum GmailError: LocalizedError, Sendable, Equatable {
    case invalidHistoryId
    case unauthorized
    case forbidden(String)
    case notFound(String)
    case rateLimited
    case httpError(statusCode: Int, message: String)
    case decodingError(String)
    case missingToken
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case .invalidHistoryId:
            return "Gmail history ID is invalid or expired (HTTP 404). Full inbox reconciliation required."
        case .unauthorized:
            return "Gmail API authorization failed (HTTP 401). Token may be expired."
        case .forbidden(let message):
            return "Gmail API access forbidden: \(message)"
        case .notFound(let message):
            return "Gmail resource not found: \(message)"
        case .rateLimited:
            return "Gmail API rate limit exceeded."
        case .httpError(let statusCode, let message):
            return "Gmail API HTTP error \(statusCode): \(message)"
        case .decodingError(let message):
            return "Gmail response decoding failed: \(message)"
        case .missingToken:
            return "No Google access token provided in Keychain."
        case .invalidURL:
            return "Failed to construct Gmail API URL."
        }
    }
}

// MARK: - GmailService

public final class GmailService: Sendable {
    private let tokenProvider: @Sendable () async throws -> String
    private let session: URLSession
    private let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"

    public init(
        session: URLSession = .shared,
        tokenProvider: @escaping @Sendable () async throws -> String
    ) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    public convenience init(authService: AuthService, session: URLSession = .shared) {
        self.init(session: session) {
            guard let token = try await authService.readKeychainValue(key: AuthService.googleAccessTokenKey) else {
                throw GmailError.missingToken
            }
            return token
        }
    }

    // MARK: - HTTP Helpers

    private func makeRequest(
        endpoint: String,
        method: String = "GET",
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard var components = URLComponents(string: "\(baseURL)/\(endpoint)") else {
            throw GmailError.invalidURL
        }
        if let queryItems = queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw GmailError.invalidURL
        }

        let token = try await tokenProvider()

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailError.httpError(statusCode: 0, message: "Invalid HTTP response")
        }

        return (data, httpResponse)
    }

    // MARK: - Profile

    public func getProfile() async throws -> (emailAddress: String, historyId: String) {
        let (data, response) = try await makeRequest(endpoint: "profile")
        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 401 { throw GmailError.unauthorized }
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(response.statusCode)"
            throw GmailError.httpError(statusCode: response.statusCode, message: msg)
        }

        struct ProfileResponse: Decodable {
            let emailAddress: String
            let historyId: String
        }

        let profile = try JSONDecoder().decode(ProfileResponse.self, from: data)
        return (emailAddress: profile.emailAddress, historyId: profile.historyId)
    }

    // MARK: - Inbox Threads

    public func fetchInboxThreads(
        pageToken: String?
    ) async throws -> (items: [TriageItem], nextPageToken: String?, historyId: String?) {
        var queryItems = [
            URLQueryItem(name: "q", value: "label:INBOX"),
            URLQueryItem(name: "maxResults", value: "50")
        ]
        if let token = pageToken, !token.isEmpty {
            queryItems.append(URLQueryItem(name: "pageToken", value: token))
        }

        let (listData, listResponse) = try await makeRequest(endpoint: "threads", queryItems: queryItems)

        guard (200...299).contains(listResponse.statusCode) else {
            if listResponse.statusCode == 401 { throw GmailError.unauthorized }
            let msg = String(data: listData, encoding: .utf8) ?? "HTTP \(listResponse.statusCode)"
            throw GmailError.httpError(statusCode: listResponse.statusCode, message: msg)
        }

        struct ThreadListItem: Decodable {
            let id: String
            let snippet: String?
            let historyId: String?
        }

        struct ThreadListResponse: Decodable {
            let threads: [ThreadListItem]?
            let nextPageToken: String?
            let resultSizeEstimate: Int?
        }

        let listResult: ThreadListResponse
        do {
            listResult = try JSONDecoder().decode(ThreadListResponse.self, from: listData)
        } catch {
            throw GmailError.decodingError(error.localizedDescription)
        }

        guard let threadStubs = listResult.threads, !threadStubs.isEmpty else {
            let profileHistoryId = try? await getProfile().historyId
            return (items: [], nextPageToken: listResult.nextPageToken, historyId: profileHistoryId)
        }

        // Fetch thread metadata concurrently while preserving index ordering
        let fetchedItems = try await withThrowingTaskGroup(
            of: (Int, TriageItem)?.self,
            returning: [TriageItem].self
        ) { group in
            for (index, stub) in threadStubs.enumerated() {
                group.addTask {
                    do {
                        let item = try await self.fetchThreadMetadata(threadId: stub.id)
                        return (index, item)
                    } catch {
                        // Skip corrupted or deleted individual threads gracefully
                        return nil
                    }
                }
            }

            var indexedItems: [(Int, TriageItem)] = []
            for try await result in group {
                if let result = result {
                    indexedItems.append(result)
                }
            }
            indexedItems.sort { $0.0 < $1.0 }
            return indexedItems.map { $0.1 }
        }

        // Resolve latest history ID
        let maxThreadHistoryId = threadStubs.compactMap { $0.historyId }.max()
        let profileHistoryId = try? await getProfile().historyId
        let resolvedHistoryId = profileHistoryId ?? maxThreadHistoryId

        return (
            items: fetchedItems,
            nextPageToken: listResult.nextPageToken,
            historyId: resolvedHistoryId
        )
    }

    private func fetchThreadMetadata(threadId: String) async throws -> TriageItem {
        let queryItems = [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "Date")
        ]

        let (data, response) = try await makeRequest(
            endpoint: "threads/\(threadId)",
            queryItems: queryItems
        )

        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 401 { throw GmailError.unauthorized }
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(response.statusCode)"
            throw GmailError.httpError(statusCode: response.statusCode, message: msg)
        }

        struct HeaderItem: Decodable {
            let name: String
            let value: String
        }

        struct MessagePayload: Decodable {
            let headers: [HeaderItem]?
        }

        struct MessageItem: Decodable {
            let id: String
            let labelIds: [String]?
            let snippet: String?
            let internalDate: String?
            let payload: MessagePayload?
        }

        struct ThreadDetailResponse: Decodable {
            let id: String
            let historyId: String?
            let messages: [MessageItem]?
        }

        let threadDetail = try JSONDecoder().decode(ThreadDetailResponse.self, from: data)
        let messages = threadDetail.messages ?? []

        var allLabels = Set<String>()
        var subject = "(No Subject)"
        var senderHeader = ""
        var timestampDate = Date()
        var snippet = ""

        if let firstMsg = messages.first {
            if let headers = firstMsg.payload?.headers {
                if let subj = headers.first(where: { $0.name.caseInsensitiveCompare("Subject") == .orderedSame })?.value, !subj.isEmpty {
                    subject = subj
                }
            }
        }

        if let lastMsg = messages.last {
            snippet = lastMsg.snippet ?? ""
            if let headers = lastMsg.payload?.headers {
                if let from = headers.first(where: { $0.name.caseInsensitiveCompare("From") == .orderedSame })?.value {
                    senderHeader = from
                }
            }
            if let dateMsStr = lastMsg.internalDate, let dateMs = Double(dateMsStr) {
                timestampDate = Date(timeIntervalSince1970: dateMs / 1000.0)
            }
        }

        for msg in messages {
            if let labels = msg.labelIds {
                allLabels.formUnion(labels)
            }
        }

        let isUnread = allLabels.contains("UNREAD")
        let isStarred = allLabels.contains("STARRED")
        let isArchived = !allLabels.contains("INBOX")

        let (authorName, authorEmail) = parseSender(senderHeader)
        let avatarURL = gravatarURL(for: authorEmail)

        let webURL = URL(string: "https://mail.google.com/mail/u/0/#inbox/\(threadId)")
            ?? URL(string: "https://mail.google.com")!

        return TriageItem(
            id: threadId,
            source: .gmail,
            title: subject,
            authorName: authorName.isEmpty ? "Unknown" : authorName,
            authorAvatarURL: avatarURL,
            timestamp: timestampDate,
            isUnread: isUnread,
            isStarred: isStarred,
            isArchived: isArchived,
            tags: Array(allLabels).sorted(),
            kind: .email(threadId: threadId, snippet: snippet, hasHtml: true),
            webURL: webURL
        )
    }

    // MARK: - History Incremental Polling

    public func fetchHistory(
        startHistoryId: String
    ) async throws -> (addedThreadIds: [String], removedThreadIds: [String], newHistoryId: String) {
        let queryItems = [
            URLQueryItem(name: "startHistoryId", value: startHistoryId),
            URLQueryItem(name: "labelId", value: "INBOX")
        ]

        let (data, response) = try await makeRequest(endpoint: "history", queryItems: queryItems)

        if response.statusCode == 404 {
            throw GmailError.invalidHistoryId
        }

        if response.statusCode == 401 {
            throw GmailError.unauthorized
        }

        guard (200...299).contains(response.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(response.statusCode)"
            if errorMsg.contains("INVALID_HISTORY_ID") || errorMsg.contains("historyId not found") {
                throw GmailError.invalidHistoryId
            }
            throw GmailError.httpError(statusCode: response.statusCode, message: errorMsg)
        }

        struct HistoryMessageContainer: Decodable {
            let message: HistoryMessage?
        }

        struct HistoryLabelContainer: Decodable {
            let message: HistoryMessage?
            let labelIds: [String]?
        }

        struct HistoryMessage: Decodable {
            let id: String?
            let threadId: String?
            let labelIds: [String]?
        }

        struct HistoryRecord: Decodable {
            let id: String?
            let messagesAdded: [HistoryMessageContainer]?
            let messagesDeleted: [HistoryMessageContainer]?
            let labelsAdded: [HistoryLabelContainer]?
            let labelsRemoved: [HistoryLabelContainer]?
        }

        struct HistoryListResponse: Decodable {
            let history: [HistoryRecord]?
            let nextPageToken: String?
            let historyId: String?
        }

        let historyResult: HistoryListResponse
        do {
            historyResult = try JSONDecoder().decode(HistoryListResponse.self, from: data)
        } catch {
            throw GmailError.decodingError(error.localizedDescription)
        }

        var addedThreadIds = Set<String>()
        var removedThreadIds = Set<String>()

        if let records = historyResult.history {
            for record in records {
                if let added = record.messagesAdded {
                    for item in added {
                        if let tid = item.message?.threadId {
                            addedThreadIds.insert(tid)
                        }
                    }
                }

                if let labelsAdded = record.labelsAdded {
                    for item in labelsAdded {
                        if item.labelIds?.contains("INBOX") == true, let tid = item.message?.threadId {
                            addedThreadIds.insert(tid)
                        }
                    }
                }

                if let deleted = record.messagesDeleted {
                    for item in deleted {
                        if let tid = item.message?.threadId {
                            removedThreadIds.insert(tid)
                        }
                    }
                }

                if let labelsRemoved = record.labelsRemoved {
                    for item in labelsRemoved {
                        if item.labelIds?.contains("INBOX") == true, let tid = item.message?.threadId {
                            removedThreadIds.insert(tid)
                        }
                    }
                }
            }
        }

        return (
            addedThreadIds: Array(addedThreadIds),
            removedThreadIds: Array(removedThreadIds),
            newHistoryId: historyResult.historyId ?? startHistoryId
        )
    }

    // MARK: - Thread Details & MIME Body

    public func fetchThreadDetails(
        threadId: String
    ) async throws -> (snippet: String, htmlBody: String?, messagesCount: Int) {
        let queryItems = [
            URLQueryItem(name: "format", value: "full")
        ]

        let (data, response) = try await makeRequest(
            endpoint: "threads/\(threadId)",
            queryItems: queryItems
        )

        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 401 { throw GmailError.unauthorized }
            if response.statusCode == 404 { throw GmailError.notFound("Thread \(threadId)") }
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(response.statusCode)"
            throw GmailError.httpError(statusCode: response.statusCode, message: msg)
        }

        struct BodyData: Decodable {
            let size: Int?
            let data: String?
        }

        final class MessagePart: Decodable, @unchecked Sendable {
            let mimeType: String?
            let body: BodyData?
            let parts: [MessagePart]?
        }

        struct MessageDetail: Decodable {
            let id: String
            let snippet: String?
            let payload: MessagePart?
        }

        struct ThreadDetail: Decodable {
            let id: String
            let messages: [MessageDetail]?
        }

        let thread = try JSONDecoder().decode(ThreadDetail.self, from: data)
        let messages = thread.messages ?? []
        let snippet = messages.last?.snippet ?? ""

        // Find the latest message payload with body content
        var htmlContent: String?
        if let lastMessage = messages.last, let payload = lastMessage.payload {
            htmlContent = extractHTML(from: payload)
            if htmlContent == nil, let plainText = extractPlainText(from: payload) {
                let escaped = escapeHTML(plainText)
                htmlContent = "<html><body style=\"font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; padding: 16px; line-height: 1.5; color: #1c1c1e; background-color: #ffffff;\"><pre style=\"white-space: pre-wrap; word-wrap: break-word; font-family: inherit;\">\(escaped)</pre></body></html>"
            }
        }

        return (
            snippet: snippet,
            htmlBody: htmlContent,
            messagesCount: messages.count
        )
    }

    private func extractHTML(from part: AnyObject) -> String? {
        guard let mirror = Mirror(reflecting: part).children.first(where: { $0.label == "mimeType" })?.value as? String? else {
            return nil
        }
        _ = mirror // Dynamic inspection fallback or typed recursion

        // We use typed recursive helper below
        return nil
    }

    private func extractHTML<T>(from payload: T) -> String? {
        let mirror = Mirror(reflecting: payload)
        var mimeType: String?
        var bodyData: String?
        var subparts: [Any] = []

        for child in mirror.children {
            if child.label == "mimeType", let value = child.value as? String? {
                mimeType = value
            } else if child.label == "body" {
                let bodyMirror = Mirror(reflecting: child.value)
                for bodyChild in bodyMirror.children {
                    if bodyChild.label == "data", let dataVal = bodyChild.value as? String? {
                        bodyData = dataVal
                    }
                }
            } else if child.label == "parts", let partsList = child.value as? [Any]? {
                subparts = partsList ?? []
            }
        }

        if mimeType == "text/html", let raw = bodyData {
            if let decoded = decodeBase64URL(raw) {
                return decoded
            }
        }

        for subpart in subparts {
            if let result = extractHTML(from: subpart) {
                return result
            }
        }

        return nil
    }

    private func extractPlainText<T>(from payload: T) -> String? {
        let mirror = Mirror(reflecting: payload)
        var mimeType: String?
        var bodyData: String?
        var subparts: [Any] = []

        for child in mirror.children {
            if child.label == "mimeType", let value = child.value as? String? {
                mimeType = value
            } else if child.label == "body" {
                let bodyMirror = Mirror(reflecting: child.value)
                for bodyChild in bodyMirror.children {
                    if bodyChild.label == "data", let dataVal = bodyChild.value as? String? {
                        bodyData = dataVal
                    }
                }
            } else if child.label == "parts", let partsList = child.value as? [Any]? {
                subparts = partsList ?? []
            }
        }

        if mimeType == "text/plain", let raw = bodyData {
            if let decoded = decodeBase64URL(raw) {
                return decoded
            }
        }

        for subpart in subparts {
            if let result = extractPlainText(from: subpart) {
                return result
            }
        }

        return nil
    }

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - Thread Mutations

    public func archiveThread(threadId: String) async throws {
        let payload: [String: [String]] = [
            "removeLabelIds": ["INBOX"]
        ]
        let bodyData = try JSONEncoder().encode(payload)

        let (data, response) = try await makeRequest(
            endpoint: "threads/\(threadId)/modify",
            method: "POST",
            body: bodyData
        )

        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 401 { throw GmailError.unauthorized }
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(response.statusCode)"
            throw GmailError.httpError(statusCode: response.statusCode, message: msg)
        }
    }

    public func trashThread(threadId: String) async throws {
        let (data, response) = try await makeRequest(
            endpoint: "threads/\(threadId)/trash",
            method: "POST"
        )

        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 401 { throw GmailError.unauthorized }
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(response.statusCode)"
            throw GmailError.httpError(statusCode: response.statusCode, message: msg)
        }
    }

    public func starThread(threadId: String, starred: Bool) async throws {
        let payload: [String: [String]] = starred
            ? ["addLabelIds": ["STARRED"]]
            : ["removeLabelIds": ["STARRED"]]
        let bodyData = try JSONEncoder().encode(payload)

        let (data, response) = try await makeRequest(
            endpoint: "threads/\(threadId)/modify",
            method: "POST",
            body: bodyData
        )

        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 401 { throw GmailError.unauthorized }
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(response.statusCode)"
            throw GmailError.httpError(statusCode: response.statusCode, message: msg)
        }
    }

    // MARK: - Utilities

    private func parseSender(_ fromHeader: String) -> (name: String, email: String) {
        let trimmed = fromHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("Unknown", "") }

        if let openBracket = trimmed.range(of: "<"),
           let closeBracket = trimmed.range(of: ">", range: openBracket.upperBound..<trimmed.endIndex) {
            let name = String(trimmed[..<openBracket.lowerBound])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
            let email = String(trimmed[openBracket.upperBound..<closeBracket.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (name.isEmpty ? email : name, email)
        }

        return (trimmed, trimmed)
    }

    private func gravatarURL(for email: String) -> URL? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let digest = Insecure.MD5.hash(data: Data(trimmed.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://www.gravatar.com/avatar/\(hash)?d=identicon")
    }

    private func decodeBase64URL(_ base64URLString: String) -> String? {
        var base64 = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
