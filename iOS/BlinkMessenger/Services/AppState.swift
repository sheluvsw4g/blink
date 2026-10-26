// AppState - Global app state management
import Foundation
import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    
    // Authentication
    @Published var currentUser: User?
    @Published var accessToken: String?
    @Published var refreshToken: String?
    @Published var isAuthenticated: Bool = false
    @Published var authState: AuthState = .unknown
    
    // Data
    @Published var conversations: [Conversation] = []
    @Published var contacts: [Contact] = []
    @Published var blockedUsers: [BlockedUser] = []
    
    // UI State
    @Published var selectedTab: Tab = .chats
    @Published var navigationPath = NavigationPath()
    @Published var activeCall: ActiveCallInfo?
    @Published var showingCallScreen = false
    
    // Connection
    @Published var connectionState: ConnectionState = .disconnected
    @Published var unreadCount: Int = 0
    
    // Pending operations
    @Published var pendingVerificationCode: String?
    @Published var verificationPhoneNumber: String?
    
    enum AuthState {
        case unknown
        case unauthenticated
        case authenticating
        case authenticated
        case needsVerification
    }
    
    enum Tab: Int, CaseIterable {
        case chats = 0
        case calls = 1
        case contacts = 2
        case settings = 3
        
        var title: String {
            switch self {
            case .chats: return "Chats"
            case .calls: return "Calls"
            case .contacts: return "Contacts"
            case .settings: return "Settings"
            }
        }
        
        var icon: String {
            switch self {
            case .chats: return "message.fill"
            case .calls: return "phone.fill"
            case .contacts: return "person.2.fill"
            case .settings: return "gear"
            }
        }
    }
    
    enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case failed(Error)
    }
    
    struct ActiveCallInfo {
        let callId: String
        let conversationId: String
        let otherUser: User
        let type: CallType
        let isOutgoing: Bool
    }
    
    private var cancellables = Set<AnyCancellable>()
    private let apiService = APIService.shared
    private let socketService = SocketService.shared
    private let keychain = KeychainService.shared
    
    private init() {
        loadPersistedState()
        setupBindings()
    }
    
    func initialize() {
        Task {
            await restoreSession()
        }
    }
    
    private func loadPersistedState() {
        if let token = keychain.getString(forKey: "accessToken"),
           let refresh = keychain.getString(forKey: "refreshToken"),
           let userData = keychain.getData(forKey: "currentUser"),
           let user = try? JSONDecoder().decode(User.self, from: userData) {
            self.accessToken = token
            self.refreshToken = refresh
            self.currentUser = user
            self.isAuthenticated = true
            self.authState = .authenticated
        }
    }
    
    private func setupBindings() {
        // Update unread count when conversations change
        $conversations
            .map { $0.reduce(0) { $0 + $1.unreadCount } }
            .assign(to: &$unreadCount)
        
        // Sync socket connection state
        socketService.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
            }
            .store(in: &cancellables)
    }
    
    func restoreSession() async {
        guard let _ = accessToken, let refresh = refreshToken else {
            authState = .unauthenticated
            return
        }
        
        authState = .authenticating
        
        do {
            let response = try await apiService.refreshToken(refreshToken: refresh)
            await updateAuth(tokens: response, user: currentUser)
            
            // Fetch initial data
            await fetchInitialData()
            
            // Connect socket
            await socketService.connect(token: response.accessToken)
            
        } catch {
            await logout()
        }
    }
    
    func updateAuth(tokens: AuthResponse, user: User? = nil) async {
        self.accessToken = tokens.accessToken
        self.refreshToken = tokens.refreshToken
        self.currentUser = tokens.user
        self.isAuthenticated = true
        self.authState = .authenticated
        
        // Persist
        keychain.setString(tokens.accessToken, forKey: "accessToken")
        keychain.setString(tokens.refreshToken, forKey: "refreshToken")
        if let userData = try? JSONEncoder().encode(tokens.user) {
            keychain.setData(userData, forKey: "currentUser")
        }
    }
    
    func logout() async {
        // Disconnect socket
        await socketService.disconnect()
        
        // Clear state
        currentUser = nil
        accessToken = nil
        refreshToken = nil
        isAuthenticated = false
        authState = .unauthenticated
        conversations = []
        contacts = []
        blockedUsers = []
        unreadCount = 0
        activeCall = nil
        
        // Clear keychain
        keychain.delete(forKey: "accessToken")
        keychain.delete(forKey: "refreshToken")
        keychain.delete(forKey: "currentUser")
    }
    
    func fetchInitialData() async {
        async let conversationsTask: () = fetchConversations()
        async let contactsTask: () = fetchContacts()
        async let blockedTask: () = fetchBlockedUsers()
        
        await conversationsTask
        await contactsTask
        await blockedTask
    }
    
    func fetchConversations() async {
        do {
            let response = try await apiService.getConversations()
            self.conversations = response
        } catch {
            print("Failed to fetch conversations: \(error)")
        }
    }
    
    func fetchContacts() async {
        do {
            let response = try await apiService.getContacts()
            self.contacts = response
        } catch {
            print("Failed to fetch contacts: \(error)")
        }
    }
    
    func fetchBlockedUsers() async {
        do {
            let response = try await apiService.getBlockedUsers()
            self.blockedUsers = response
        } catch {
            print("Failed to fetch blocked users: \(error)")
        }
    }
    
    // Navigation helpers
    func navigateToChat(userId: String) {
        selectedTab = .chats
        // Find or create conversation
        if let conversation = conversations.first(where: { 
            $0.type == .PRIVATE && $0.participants.contains(where: { $0.userId == userId })
        }) {
            navigationPath.append(conversation)
        } else {
            Task {
                do {
                    let conversation = try await apiService.createPrivateConversation(userId: userId)
                    await MainActor.run {
                        self.conversations.insert(conversation, at: 0)
                        self.navigationPath.append(conversation)
                    }
                } catch {
                    print("Failed to create conversation: \(error)")
                }
            }
        }
    }
    
    func navigateToCall(callId: String) {
        // Handle incoming call navigation
        showingCallScreen = true
    }
    
    func startCall(with user: User, type: CallType) {
        // Find or create conversation first
        if let conversation = conversations.first(where: { 
            $0.type == .PRIVATE && $0.participants.contains(where: { $0.userId == user.id })
        }) {
            initiateCall(conversationId: conversation.id, receiverId: user.id, type: type)
        } else {
            Task {
                do {
                    let conversation = try await apiService.createPrivateConversation(userId: user.id)
                    await MainActor.run {
                        self.conversations.insert(conversation, at: 0)
                        self.initiateCall(conversationId: conversation.id, receiverId: user.id, type: type)
                    }
                } catch {
                    print("Failed to create conversation for call: \(error)")
                }
            }
        }
    }
    
    private func initiateCall(conversationId: String, receiverId: String, type: CallType) {
        Task {
            do {
                let call = try await apiService.initiateCall(conversationId: conversationId, receiverId: receiverId, type: type)
                await MainActor.run {
                    if let otherUser = call.receiver ?? call.initiator {
                        self.activeCall = ActiveCallInfo(
                            callId: call.id,
                            conversationId: conversationId,
                            otherUser: otherUser,
                            type: type,
                            isOutgoing: call.initiatorId == self.currentUser?.id
                        )
                        self.showingCallScreen = true
                    }
                }
            } catch {
                print("Failed to initiate call: \(error)")
            }
        }
    }
    
    func handleIncomingCall(_ call: Call, from user: User) {
        activeCall = ActiveCallInfo(
            callId: call.id,
            conversationId: call.conversationId,
            otherUser: user,
            type: call.type,
            isOutgoing: false
        )
        showingCallScreen = true
    }
    
    func endActiveCall() {
        activeCall = nil
        showingCallScreen = false
        // TODO: Leave call room via socket
    }
    
    func updateConversation(_ conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
        // Re-sort by updatedAt
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }
    
    func addMessage(_ message: Message, to conversationId: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        var conversation = conversations[index]
        // Update last message preview
        let preview = MessagePreview(
            id: message.id,
            type: message.type,
            content: message.content,
            mediaUrl: message.mediaUrl,
            senderId: message.senderId,
            createdAt: message.createdAt,
            status: message.status
        )
        conversation.lastMessage = preview
        conversation.updatedAt = message.createdAt
        conversation.unreadCount += (message.senderId == currentUser?.id ? 0 : 1)
        conversations[index] = conversation
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }
    
    func markConversationAsRead(_ conversationId: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        conversations[index].unreadCount = 0
    }
}