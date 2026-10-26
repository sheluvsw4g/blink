// ChatsListView - Main chats list screen
import SwiftUI

struct ChatsListView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingNewChat = false
    @State private var searchText = ""
    
    var filteredConversations: [Conversation] {
        if searchText.isEmpty {
            return appState.conversations
        }
        return appState.conversations.filter { conversation in
            conversation.displayName.localizedCaseInsensitiveContains(searchText) ||
            conversation.lastMessage?.content?.localizedCaseInsensitiveContains(searchText) == true
        }
    }
    
    var body: some View {
        ZStack {
            if appState.conversations.isEmpty && !appState.isLoading {
                emptyStateView
            } else {
                listView
            }
        }
        .navigationTitle("Chats")
        .searchable(text: $searchText, prompt: "Search conversations")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    // Edit mode
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingNewChat = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $showingNewChat) {
            NewChatView()
                .environmentObject(appState)
        }
        .refreshable {
            await appState.fetchConversations()
        }
        .task {
            if appState.conversations.isEmpty {
                await appState.fetchConversations()
            }
        }
    }
    
    private var listView: some View {
        List {
            ForEach(filteredConversations) { conversation in
                NavigationLink(value: conversation) {
                    ConversationRowView(conversation: conversation)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteConversation(conversation)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    
                    Button {
                        muteConversation(conversation)
                    } label: {
                        Label("Mute", systemImage: "bell.slash")
                    }
                    .tint(.orange)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        markAsUnread(conversation)
                    } label: {
                        Label("Unread", systemImage: "envelope.badge")
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(.plain)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 80))
                .foregroundColor(.secondary.opacity(0.5))
            
            VStack(spacing: 8) {
                Text("No Conversations Yet")
                    .font(.title2.bold())
                Text("Start a new chat with your contacts")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Button {
                showingNewChat = true
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .font(.headline)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
        .padding()
    }
    
    private func deleteConversation(_ conversation: Conversation) {
        Task {
            do {
                try await APIService.shared.deleteConversation(conversationId: conversation.id)
                await MainActor.run {
                    appState.conversations.removeAll { $0.id == conversation.id }
                }
            } catch {
                print("Failed to delete conversation: \(error)")
            }
        }
    }
    
    private func muteConversation(_ conversation: Conversation) {
        // TODO: Implement mute
    }
    
    private func markAsUnread(_ conversation: Conversation) {
        // TODO: Implement mark as unread
    }
}

// MARK: - Conversation Row

struct ConversationRowView: View {
    let conversation: Conversation
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            AvatarView(
                url: conversation.displayAvatar,
                name: conversation.displayName,
                size: 56,
                isGroup: conversation.isGroup,
                isOnline: conversation.otherParticipants.first?.user.isOnline ?? false
            )
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text(conversation.lastMessage?.formattedTime ?? "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 4) {
                    // Status indicator
                    if let lastMessage = conversation.lastMessage {
                        MessageStatusIcon(status: lastMessage.status, isFromCurrentUser: lastMessage.senderId == appState.currentUser?.id)
                    }
                    
                    // Message preview
                    Text(messagePreviewText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    Spacer()
                }
            }
            
            // Unread badge
            if conversation.unreadCount > 0 {
                Text("\(conversation.unreadCount)")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.blue)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
    
    private var messagePreviewText: String {
        guard let lastMessage = conversation.lastMessage else { return "No messages yet" }
        
        let senderName = lastMessage.senderId == appState.currentUser?.id ? "You" : 
            conversation.otherParticipants.first(where: { $0.userId == lastMessage.senderId })?.user.displayName ?? "Unknown"
        
        let prefix = conversation.isGroup ? "\(senderName): " : ""
        
        switch lastMessage.type {
        case .TEXT:
            return "\(prefix)\(lastMessage.content ?? "")"
        case .IMAGE:
            return "\(prefix)📷 Photo"
        case .VIDEO:
            return "\(prefix)🎥 Video"
        case .VOICE_MESSAGE, .AUDIO:
            return "🎵 Voice message"
        case .VIDEO_MESSAGE:
            return "\(prefix)📹 Video message"
        case .DOCUMENT:
            return "\(prefix)📄 Document"
        case .LOCATION:
            return "\(prefix)📍 Location"
        case .CONTACT:
            return "\(prefix)👤 Contact"
        case .CALL_LOG:
            return "\(prefix)📞 Call"
        case .SYSTEM:
            return lastMessage.content ?? "System message"
        }
    }
}

// MARK: - Message Status Icon

struct MessageStatusIcon: View {
    let status: MessageStatusType
    let isFromCurrentUser: Bool
    
    var body: some View {
        if isFromCurrentUser {
            Image(systemName: statusIcon)
                .font(.caption)
                .foregroundColor(statusColor)
        }
    }
    
    private var statusIcon: String {
        switch status {
        case .SENT: return "checkmark"
        case .DELIVERED: return "checkmark.circle.fill"
        case .READ: return "checkmark.circle.fill"
        case .FAILED: return "exclamationmark.circle.fill"
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .SENT: return .secondary
        case .DELIVERED: return .blue
        case .READ: return .blue
        case .FAILED: return .red
        }
    }
}

// MARK: - Avatar View

struct AvatarView: View {
    let url: String?
    let name: String
    let size: CGFloat
    let isGroup: Bool
    let isOnline: Bool
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let url = url, let imageUrl = URL(string: url) {
                AsyncImage(url: imageUrl) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholderView
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
            } else {
                placeholderView
            }
            
            if !isGroup && isOnline && size > 40 {
                Circle()
                    .fill(Color.green)
                    .frame(width: size * 0.25, height: size * 0.25)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
        }
    }
    
    private var placeholderView: some View {
        Circle()
            .fill(avatarColor)
            .frame(width: size, height: size)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundColor(.white)
            )
    }
    
    private var initials: String {
        let components = name.components(separatedBy: " ")
        if components.count >= 2 {
            return "\(components[0].first!)\(components[1].first!)".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
    
    private var avatarColor: Color {
        let hash = name.hashValue
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .red, .teal, .indigo]
        return colors[abs(hash) % colors.count]
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ChatsListView()
    }
    .environmentObject(AppState.shared)
}