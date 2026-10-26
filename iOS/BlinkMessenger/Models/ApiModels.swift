// API Models - Data structures matching backend
import Foundation

// MARK: - Auth Models
struct AuthResponse: Codable {
    let user: User
    let accessToken: String
    let refreshToken: String
}

struct SendCodeRequest: Codable {
    let phoneNumber: String
}

struct VerifyCodeRequest: Codable {
    let phoneNumber: String
    let code: String
    let name: String?
}

struct RefreshTokenRequest: Codable {
    let refreshToken: String
}

struct DeviceRegistrationRequest: Codable {
    let token: String
    let platform: String
}

// MARK: - User Models
struct User: Codable, Identifiable, Hashable {
    let id: String
    let phoneNumber: String
    let name: String?
    let avatarUrl: String?
    let bio: String?
    let isOnline: Bool
    let lastSeen: Date?
    let createdAt: Date?
    
    var displayName: String {
        name ?? "User \(phoneNumber.suffix(4))"
    }
    
    var initials: String {
        let components = displayName.components(separatedBy: " ")
        if components.count >= 2 {
            return "\(components[0].first!)\(components[1].first!)".uppercased()
        }
        return String(displayName.prefix(2)).uppercased()
    }
}

struct Contact: Codable, Identifiable {
    let id: String
    let ownerId: String
    let contactId: String
    let name: String?
    let createdAt: Date
    let contact: User
    
    var displayName: String {
        name ?? contact.displayName
    }
}

struct BlockedUser: Codable, Identifiable {
    let id: String
    let blockerId: String
    let blockedId: String
    let createdAt: Date
    let blocked: User
}

// MARK: - Conversation Models
enum ConversationType: String, Codable {
    case PRIVATE = "PRIVATE"
    case GROUP = "GROUP"
}

enum ParticipantRole: String, Codable {
    case ADMIN = "ADMIN"
    case MEMBER = "MEMBER"
}

struct ConversationParticipant: Codable, Identifiable {
    let id: String
    let userId: String
    let conversationId: String
    let role: ParticipantRole
    let joinedAt: Date
    let leftAt: Date?
    let lastReadAt: Date?
    let user: User
}

struct Conversation: Codable, Identifiable {
    let id: String
    let type: ConversationType
    let name: String?
    let avatarUrl: String?
    let createdAt: Date
    let updatedAt: Date
    let participants: [ConversationParticipant]
    let lastMessage: MessagePreview?
    let unreadCount: Int
    
    var displayName: String {
        if type == .GROUP {
            return name ?? "Group Chat"
        }
        return otherParticipants.first?.user.displayName ?? "Unknown"
    }
    
    var displayAvatar: String? {
        if type == .GROUP {
            return avatarUrl
        }
        return otherParticipants.first?.user.avatarUrl
    }
    
    var otherParticipants: [ConversationParticipant] {
        // Current user ID would be injected from AppState
        participants // Filter in ViewModel
    }
    
    var isGroup: Bool { type == .GROUP }
}

struct MessagePreview: Codable {
    let id: String
    let type: MessageType
    let content: String?
    let mediaUrl: String?
    let senderId: String
    let createdAt: Date
    let status: MessageStatusType
}

// MARK: - Message Models
enum MessageType: String, Codable {
    case TEXT = "TEXT"
    case IMAGE = "IMAGE"
    case VIDEO = "VIDEO"
    case AUDIO = "AUDIO"
    case DOCUMENT = "DOCUMENT"
    case VOICE_MESSAGE = "VOICE_MESSAGE"
    case VIDEO_MESSAGE = "VIDEO_MESSAGE"
    case LOCATION = "LOCATION"
    case CONTACT = "CONTACT"
    case CALL_LOG = "CALL_LOG"
    case SYSTEM = "SYSTEM"
}

enum MessageStatusType: String, Codable {
    case SENT = "SENT"
    case DELIVERED = "DELIVERED"
    case READ = "READ"
    case FAILED = "FAILED"
}

struct Message: Codable, Identifiable {
    let id: String
    let conversationId: String
    let senderId: String
    let type: MessageType
    let content: String?
    let mediaUrl: String?
    let mediaType: String?
    let mediaSize: Int?
    let duration: Int?
    let replyToId: String?
    let isEdited: Bool
    let isDeleted: Bool
    let createdAt: Date
    let updatedAt: Date
    let sender: User?
    let replyTo: MessageReply?
    let statuses: [MessageStatus]
    
    var isFromCurrentUser: Bool {
        // Set by ViewModel
        false
    }
    
    var status: MessageStatusType {
        statuses.first?.status ?? .SENT
    }
    
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
    
    var formattedDate: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(createdAt) {
            return "Today"
        } else if calendar.isDateInYesterday(createdAt) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter.string(from: createdAt)
        }
    }
}

struct MessageReply: Codable {
    let id: String
    let type: MessageType
    let content: String?
    let mediaUrl: String?
    let senderId: String
}

struct MessageStatus: Codable {
    let messageId: String
    let userId: String
    let status: MessageStatusType
}

// MARK: - Call Models
enum CallType: String, Codable {
    case VOICE = "VOICE"
    case VIDEO = "VIDEO"
}

enum CallStatus: String, Codable {
    case INITIATED = "INITIATED"
    case RINGING = "RINGING"
    case ANSWERED = "ANSWERED"
    case REJECTED = "REJECTED"
    case MISSED = "MISSED"
    case ENDED = "ENDED"
    case FAILED = "FAILED"
}

struct Call: Codable, Identifiable {
    let id: String
    let conversationId: String
    let initiatorId: String
    let receiverId: String
    let type: CallType
    let status: CallStatus
    let startedAt: Date?
    let answeredAt: Date?
    let endedAt: Date?
    let duration: Int?
    let createdAt: Date
    let initiator: User?
    let receiver: User?
    let conversation: ConversationPreview?
    
    var isOutgoing: Bool {
        // Set by ViewModel based on current user ID
        false
    }
    
    var durationFormatted: String {
        guard let duration = duration else { return "0:00" }
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct ConversationPreview: Codable {
    let id: String
    let type: ConversationType
    let name: String?
}

struct IceServer: Codable {
    let urls: [String]
    let username: String?
    let credential: String?
}

// MARK: - Request/Response Models
struct CreatePrivateConversationRequest: Codable {
    let userId: String
}

struct CreateGroupConversationRequest: Codable {
    let name: String
    let participantIds: [String]
    let avatarUrl: String?
}

struct SendMessageRequest: Codable {
    let conversationId: String
    let type: MessageType
    let content: String?
    let mediaUrl: String?
    let mediaType: String?
    let mediaSize: Int?
    let duration: Int?
    let replyToId: String?
}

struct EditMessageRequest: Codable {
    let content: String
}

struct MarkReadRequest: Codable {
    let messageIds: [String]
}

struct InitiateCallRequest: Codable {
    let conversationId: String
    let receiverId: String
    let type: CallType
}

struct UpdateCallStatusRequest: Codable {
    let status: CallStatus
}

// MARK: - Pagination
struct PaginatedResponse<T: Codable>: Codable {
    let data: [T]
    let hasMore: Bool
    let nextCursor: String?
}

// MARK: - Socket Events
enum SocketEvent: String {
    case connect = "connect"
    case disconnect = "disconnect"
    case error = "error"
    
    // Messages
    case messageNew = "message:new"
    case messageSent = "message:sent"
    case messageUpdated = "message:updated"
    case messageDeleted = "message:deleted"
    case messageError = "message:error"
    case messagesRead = "messages:read"
    
    // Typing
    case userTyping = "user:typing"
    case userStoppedTyping = "user:stopped_typing"
    
    // Calls
    case callIncoming = "call:incoming"
    case callAnswered = "call:answered"
    case callRejected = "call:rejected"
    case callEnded = "call:ended"
    case callIceCandidate = "call:ice-candidate"
    case callRenegotiate = "call:renegotiate"
    case callTimeout = "call:timeout"
    case callCancelled = "call:cancelled"
    case callPeerDisconnected = "call:peer-disconnected"
    case callStatus = "call:status"
    
    // Presence
    case userStatus = "user:status"
    case conversationUpdated = "conversation:updated"
    
    // Client -> Server
    case joinConversation = "join:conversation"
    case leaveConversation = "leave:conversation"
    case typingStart = "typing:start"
    case typingStop = "typing:stop"
    case statusUpdate = "status:update"
    case callInitiate = "call:initiate"
    case callAnswer = "call:answer"
    case callReject = "call:reject"
    case callEnd = "call:end"
}