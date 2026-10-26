// API Service - Network layer for REST API
import Foundation
import Combine

enum APIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case serverError(String)
    case decodingError(Error)
    case networkError(Error)
    case unknown
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response from server"
        case .unauthorized: return "Session expired. Please log in again."
        case .serverError(let msg): return msg
        case .decodingError(let err): return "Data parsing error: \(err.localizedDescription)"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .unknown: return "An unknown error occurred"
        }
    }
}

final class APIService {
    static let shared = APIService()
    
    private let baseURL: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    
    private init() {
        // TODO: Change to your backend URL
        // For local development with iOS simulator: http://localhost:3000
        // For device testing: http://YOUR_LOCAL_IP:3000
        // For production: https://your-domain.com
        #if DEBUG
        self.baseURL = "http://192.168.0.76:3000/api"
        #else
        self.baseURL = "http://192.168.0.76:3000/api"
        #endif
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
        
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.keyEncodingStrategy = .convertToSnakeCase
    }
    
    // MARK: - Request Helper
    
    private func request<T: Codable>(
        _ endpoint: String,
        method: String = "GET",
        body: (any Codable)? = nil,
        requiresAuth: Bool = true,
        responseType: T.Type
    ) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if requiresAuth, let token = await AppState.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        if let body = body {
            request.httpBody = try encoder.encode(AnyEncodable(body))
        }
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            switch httpResponse.statusCode {
            case 200..<300:
                if T.self == EmptyResponse.self {
                    return EmptyResponse() as! T
                }
                return try decoder.decode(T.self, from: data)
            case 401:
                // Token expired, try to refresh
                if requiresAuth {
                    try await refreshTokenIfNeeded()
                    // Retry once
                    return try await self.request(endpoint, method: method, body: body, requiresAuth: requiresAuth, responseType: responseType)
                }
                throw APIError.unauthorized
            case 400..<500:
                let errorData = try? decoder.decode(ErrorResponse.self, from: data)
                throw APIError.serverError(errorData?.error ?? "Request failed")
            default:
                throw APIError.serverError("Server error: \(httpResponse.statusCode)")
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error)
        }
    }
    
    private func refreshTokenIfNeeded() async throws {
        guard let refreshToken = await AppState.shared.refreshToken else {
            throw APIError.unauthorized
        }
        
        let response: AuthResponse = try await request(
            "/auth/refresh",
            method: "POST",
            body: RefreshTokenRequest(refreshToken: refreshToken),
            requiresAuth: false,
            responseType: AuthResponse.self
        )
        
        await AppState.shared.updateAuth(tokens: response)
    }
    
    // MARK: - Auth Endpoints
    
    func sendVerificationCode(phoneNumber: String) async throws -> EmptyResponse {
        return try await request(
            "/auth/send-code",
            method: "POST",
            body: SendCodeRequest(phoneNumber: phoneNumber),
            requiresAuth: false,
            responseType: EmptyResponse.self
        )
    }
    
    func verifyCode(phoneNumber: String, code: String, name: String?) async throws -> AuthResponse {
        return try await request(
            "/auth/verify-code",
            method: "POST",
            body: VerifyCodeRequest(phoneNumber: phoneNumber, code: code, name: name),
            requiresAuth: false,
            responseType: AuthResponse.self
        )
    }
    
    func refreshToken(refreshToken: String) async throws -> AuthResponse {
        return try await request(
            "/auth/refresh",
            method: "POST",
            body: RefreshTokenRequest(refreshToken: refreshToken),
            requiresAuth: false,
            responseType: AuthResponse.self
        )
    }
    
    func registerDevice(token: String, platform: String) async throws -> EmptyResponse {
        return try await request(
            "/auth/device",
            method: "POST",
            body: DeviceRegistrationRequest(token: token, platform: platform),
            requiresAuth: true,
            responseType: EmptyResponse.self
        )
    }
    
    func logout() async throws -> EmptyResponse {
        return try await request(
            "/auth/logout",
            method: "POST",
            requiresAuth: true,
            responseType: EmptyResponse.self
        )
    }
    
    // MARK: - User Endpoints
    
    func searchUsers(query: String, limit: Int = 20) async throws -> [User] {
        let response: UsersSearchResponse = try await request(
            "/users/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&limit=\(limit)",
            responseType: UsersSearchResponse.self
        )
        return response.users
    }
    
    func getUser(userId: String) async throws -> User {
        let response: SingleUserResponse = try await request(
            "/users/\(userId)",
            responseType: SingleUserResponse.self
        )
        return response.user
    }
    
    func getContacts() async throws -> [Contact] {
        let response: ContactsResponse = try await request(
            "/users/contacts/list",
            responseType: ContactsResponse.self
        )
        return response.contacts
    }
    
    func addContact(contactId: String, name: String?) async throws -> Contact {
        let response: SingleContactResponse = try await request(
            "/users/contacts",
            method: "POST",
            body: AddContactRequest(contactId: contactId, name: name),
            responseType: SingleContactResponse.self
        )
        return response.contact
    }
    
    func updateContact(contactId: String, name: String) async throws -> Contact {
        let response: SingleContactResponse = try await request(
            "/users/contacts/\(contactId)",
            method: "PATCH",
            body: UpdateContactRequest(name: name),
            responseType: SingleContactResponse.self
        )
        return response.contact
    }
    
    func deleteContact(contactId: String) async throws -> EmptyResponse {
        return try await request(
            "/users/contacts/\(contactId)",
            method: "DELETE",
            responseType: EmptyResponse.self
        )
    }
    
    func blockUser(userId: String) async throws -> EmptyResponse {
        return try await request(
            "/users/block/\(userId)",
            method: "POST",
            responseType: EmptyResponse.self
        )
    }
    
    func unblockUser(userId: String) async throws -> EmptyResponse {
        return try await request(
            "/users/block/\(userId)",
            method: "DELETE",
            responseType: EmptyResponse.self
        )
    }
    
    func getBlockedUsers() async throws -> [BlockedUser] {
        let response: BlockedUsersResponse = try await request(
            "/users/blocked/list",
            responseType: BlockedUsersResponse.self
        )
        return response.blocked
    }
    
    func updateProfile(name: String?, bio: String?, avatarUrl: String?) async throws -> User {
        let response: SingleUserResponse = try await request(
            "/auth/me",
            method: "PATCH",
            body: UpdateProfileRequest(name: name, bio: bio, avatarUrl: avatarUrl),
            responseType: SingleUserResponse.self
        )
        return response.user
    }
    
    // MARK: - Conversation Endpoints
    
    func getConversations(limit: Int = 50, offset: Int = 0) async throws -> [Conversation] {
        let response: ConversationsResponse = try await request(
            "/conversations?limit=\(limit)&offset=\(offset)",
            responseType: ConversationsResponse.self
        )
        return response.conversations
    }
    
    func createPrivateConversation(userId: String) async throws -> Conversation {
        let response: SingleConversationResponse = try await request(
            "/conversations/private",
            method: "POST",
            body: CreatePrivateConversationRequest(userId: userId),
            responseType: SingleConversationResponse.self
        )
        return response.conversation
    }
    
    func createGroupConversation(name: String, participantIds: [String], avatarUrl: String?) async throws -> Conversation {
        let response: SingleConversationResponse = try await request(
            "/conversations/group",
            method: "POST",
            body: CreateGroupConversationRequest(name: name, participantIds: participantIds, avatarUrl: avatarUrl),
            responseType: SingleConversationResponse.self
        )
        return response.conversation
    }
    
    func getConversation(conversationId: String) async throws -> Conversation {
        let response: SingleConversationResponse = try await request(
            "/conversations/\(conversationId)",
            responseType: SingleConversationResponse.self
        )
        return response.conversation
    }
    
    func updateConversation(conversationId: String, name: String?, avatarUrl: String?) async throws -> Conversation {
        let response: SingleConversationResponse = try await request(
            "/conversations/\(conversationId)",
            method: "PATCH",
            body: UpdateConversationRequest(name: name, avatarUrl: avatarUrl),
            responseType: SingleConversationResponse.self
        )
        return response.conversation
    }
    
    func addParticipants(conversationId: String, userIds: [String]) async throws -> [ConversationParticipant] {
        let response: ParticipantsResponse = try await request(
            "/conversations/\(conversationId)/participants",
            method: "POST",
            body: AddParticipantsRequest(userIds: userIds),
            responseType: ParticipantsResponse.self
        )
        return response.participants
    }
    
    func removeParticipant(conversationId: String, userId: String) async throws -> EmptyResponse {
        return try await request(
            "/conversations/\(conversationId)/participants/\(userId)",
            method: "DELETE",
            responseType: EmptyResponse.self
        )
    }
    
    func leaveConversation(conversationId: String) async throws -> EmptyResponse {
        return try await request(
            "/conversations/\(conversationId)/leave",
            method: "POST",
            responseType: EmptyResponse.self
        )
    }
    
    func deleteConversation(conversationId: String) async throws -> EmptyResponse {
        return try await request(
            "/conversations/\(conversationId)",
            method: "DELETE",
            responseType: EmptyResponse.self
        )
    }
    
    // MARK: - Message Endpoints
    
    func getMessages(conversationId: String, limit: Int = 50, before: Date? = nil) async throws -> MessagesResponse {
        var endpoint = "/messages/\(conversationId)?limit=\(limit)"
        if let before = before {
            endpoint += "&before=\(ISO8601DateFormatter().string(from: before))"
        }
        
        return try await request(endpoint, responseType: MessagesResponse.self)
    }
    
    func sendMessage(_ sendMessageRequest: SendMessageRequest) async throws -> Message {
        let response: SingleMessageResponse = try await request(
            "/messages",
            method: "POST",
            body: sendMessageRequest,
            responseType: SingleMessageResponse.self
        )
        return response.message
    }
    
    func editMessage(messageId: String, content: String) async throws -> Message {
        let response: SingleMessageResponse = try await request(
            "/messages/\(messageId)",
            method: "PATCH",
            body: EditMessageRequest(content: content),
            responseType: SingleMessageResponse.self
        )
        return response.message
    }
    
    func deleteMessage(messageId: String, forEveryone: Bool = false) async throws -> EmptyResponse {
        let endpoint = "/messages/\(messageId)" + (forEveryone ? "?forEveryone=true" : "")
        return try await request(endpoint, method: "DELETE", responseType: EmptyResponse.self)
    }
    
    func markMessagesAsRead(conversationId: String, messageIds: [String]) async throws -> EmptyResponse {
        return try await request(
            "/messages/\(conversationId)/read",
            method: "POST",
            body: MarkReadRequest(messageIds: messageIds),
            responseType: EmptyResponse.self
        )
    }
    
    func forwardMessage(messageId: String, conversationIds: [String]) async throws -> [Message] {
        let response: MessagesResponse = try await request(
            "/messages/\(messageId)/forward",
            method: "POST",
            body: ForwardMessageRequest(conversationIds: conversationIds),
            responseType: MessagesResponse.self
        )
        return response.messages ?? []
    }
    
    // MARK: - Call Endpoints
    
    func getCallHistory(limit: Int = 50, offset: Int = 0) async throws -> [Call] {
        let response: CallsResponse = try await request(
            "/calls/history?limit=\(limit)&offset=\(offset)",
            responseType: CallsResponse.self
        )
        return response.calls
    }
    
    func getCall(callId: String) async throws -> Call {
        let response: SingleCallResponse = try await request(
            "/calls/\(callId)",
            responseType: SingleCallResponse.self
        )
        return response.call
    }
    
    func initiateCall(conversationId: String, receiverId: String, type: CallType) async throws -> Call {
        let response: SingleCallResponse = try await request(
            "/calls/initiate",
            method: "POST",
            body: InitiateCallRequest(conversationId: conversationId, receiverId: receiverId, type: type),
            responseType: SingleCallResponse.self
        )
        return response.call
    }
    
    func updateCallStatus(callId: String, status: CallStatus) async throws -> Call {
        let response: SingleCallResponse = try await request(
            "/calls/\(callId)/status",
            method: "PATCH",
            body: UpdateCallStatusRequest(status: status),
            responseType: SingleCallResponse.self
        )
        return response.call
    }
    
    func getIceServers() async throws -> [IceServer] {
        let response: IceServersResponse = try await request(
            "/calls/ice-servers",
            responseType: IceServersResponse.self
        )
        return response.iceServers
    }
    
    // MARK: - Upload Endpoints
    
    func uploadFile(data: Data, filename: String, mimeType: String) async throws -> UploadResponse {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "\(baseURL)/upload/file")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        if let token = await AppState.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.serverError("Upload failed")
        }
        
        return try decoder.decode(UploadResponse.self, from: data)
    }
}

// MARK: - Response Wrappers

struct EmptyResponse: Codable {}

struct ErrorResponse: Codable {
    let error: String
}

struct UsersSearchResponse: Codable {
    let users: [User]
}

struct SingleUserResponse: Codable {
    let user: User
}

struct ContactsResponse: Codable {
    let contacts: [Contact]
}

struct SingleContactResponse: Codable {
    let contact: Contact
}

struct AddContactRequest: Codable {
    let contactId: String
    let name: String?
}

struct UpdateContactRequest: Codable {
    let name: String
}

struct BlockedUsersResponse: Codable {
    let blocked: [BlockedUser]
}

struct UpdateProfileRequest: Codable {
    let name: String?
    let bio: String?
    let avatarUrl: String?
}

struct ConversationsResponse: Codable {
    let conversations: [Conversation]
}

struct SingleConversationResponse: Codable {
    let conversation: Conversation
}

struct UpdateConversationRequest: Codable {
    let name: String?
    let avatarUrl: String?
}

struct ParticipantsResponse: Codable {
    let participants: [ConversationParticipant]
}

struct AddParticipantsRequest: Codable {
    let userIds: [String]
}

struct MessagesResponse: Codable {
    let messages: [Message]?
    let hasMore: Bool?
}

struct SingleMessageResponse: Codable {
    let message: Message
}

struct ForwardMessageRequest: Codable {
    let conversationIds: [String]
}

struct CallsResponse: Codable {
    let calls: [Call]
}

struct SingleCallResponse: Codable {
    let call: Call
}

struct IceServersResponse: Codable {
    let iceServers: [IceServer]
}

struct UploadResponse: Codable {
    let file: UploadedFile
}

struct UploadedFile: Codable {
    let url: String
    let filename: String
    let originalName: String
    let mimeType: String
    let size: Int
    let mediaType: String
}

// MARK: - Type Erasure for Encoding

struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    
    init<T: Encodable>(_ value: T) {
        self.encodeFunc = value.encode
    }
    
    func encode(to encoder: Encoder) throws {
        try encodeFunc(encoder)
    }
}