// ChatView - Individual conversation screen
import SwiftUI
import PhotosUI

struct ChatView: View {
    let conversation: Conversation
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showingMediaPicker = false
    @State private var showingActionSheet = false
    @State private var replyingToMessage: Message?
    @State private var showingUserProfile = false
    
    init(conversation: Conversation) {
        self.conversation = conversation
        self._viewModel = StateObject(wrappedValue: ChatViewModel(conversation: conversation))
    }
    
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Messages list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.messages) { message in
                                MessageBubbleView(
                                    message: message,
                                    isFromCurrentUser: message.senderId == appState.currentUser?.id,
                                    replyingToMessage: $replyingToMessage
                                )
                                .id(message.id)
                                .onAppear {
                                    // Load more when reaching top
                                    if message.id == viewModel.messages.first?.id {
                                        Task {
                                            await viewModel.loadMoreMessages()
                                        }
                                    }
                                }
                            }
                            
                            if viewModel.isLoadingMore {
                                ProgressView()
                                    .padding()
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 12)
                    }
                    .onAppear { scrollProxy = proxy }
                    .onChange(of: viewModel.messages.count) { _, _ in
                        scrollToBottom()
                    }
                    .onChange(of: isInputFocused) { _, focused in
                        if focused {
                            scrollToBottom()
                        }
                    }
                }
                
                // Typing indicator
                if viewModel.typingUsers.contains(where: { $0 != appState.currentUser?.id }) {
                    TypingIndicatorView(users: viewModel.typingUsers.filter { $0 != appState.currentUser?.id })
                }
                
                // Reply preview
                if let reply = replyingToMessage {
                    ReplyPreviewView(message: reply) {
                        replyingToMessage = nil
                    }
                }
                
                // Input bar
                ChatInputBarView(
                    text: $viewModel.draftMessage,
                    isFocused: $isInputFocused,
                    replyingTo: replyingToMessage,
                    onSend: { await viewModel.sendMessage() },
                    onAttach: { showingActionSheet = true },
                    onVoiceMessage: { await viewModel.startVoiceRecording() },
                    onCall: { startCall(type: .VOICE) },
                    onVideoCall: { startCall(type: .VIDEO) }
                )
            }
        }
        .navigationTitle(conversation.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingUserProfile = true
                } label: {
                    AvatarView(
                        url: conversation.displayAvatar,
                        name: conversation.displayName,
                        size: 32,
                        isGroup: conversation.isGroup,
                        isOnline: conversation.otherParticipants.first?.user.isOnline ?? false
                    )
                }
            }
        }
        .sheet(isPresented: $showingUserProfile) {
            if let otherUser = conversation.otherParticipants.first?.user {
                UserProfileView(user: otherUser)
            }
        }
        .actionSheet(isPresented: $showingActionSheet) {
            ActionSheet(
                title: Text("Attach"),
                buttons: [
                    .default(Text("Photo & Video")) { showingMediaPicker = true; viewModel.mediaPickerType = .photos },
                    .default(Text("Document")) { showingMediaPicker = true; viewModel.mediaPickerType = .document },
                    .default(Text("Location")) { viewModel.sendLocation() },
                    .default(Text("Contact")) { /* TODO */ },
                    .cancel()
                ]
            )
        }
        .photosPicker(
            isPresented: $showingMediaPicker,
            selection: $viewModel.selectedMediaItems,
            maxSelectionCount: 10,
            matching: viewModel.mediaPickerType == .photos ? .images : .any(of: [.images, .videos])
        )
        .onChange(of: viewModel.selectedMediaItems) { _, items in
            Task { await viewModel.handleMediaSelection(items) }
        }
        .onDisappear {
            viewModel.cleanup()
        }
        .task {
            await viewModel.loadInitialMessages()
            await viewModel.markAsRead()
        }
    }
    
    private func scrollToBottom() {
        withAnimation(.easeOut(duration: 0.3)) {
            if let lastMessage = viewModel.messages.last {
                scrollProxy?.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }
    
    private func startCall(type: CallType) {
        if let otherUser = conversation.otherParticipants.first?.user {
            appState.startCall(with: otherUser, type: type)
        }
    }
}

// MARK: - Chat ViewModel

@MainActor
final class ChatViewModel: ObservableObject {
    let conversation: Conversation
    
    @Published var messages: [Message] = []
    @Published var draftMessage = ""
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var typingUsers: Set<String> = []
    @Published var selectedMediaItems: [PhotosPickerItem] = []
    @Published var mediaPickerType: MediaPickerType = .photos
    
    private var hasLoadedInitial = false
    private var loadMoreTask: Task<Void, Never>?
    private var typingTimer: Timer?
    private let socketService = SocketService.shared
    private var cancellables = Set<AnyCancellable>()
    
    enum MediaPickerType {
        case photos, document
    }
    
    init(conversation: Conversation) {
        self.conversation = conversation
        setupSocketListeners()
    }
    
    private func setupSocketListeners() {
        socketService.on("message:new") { [weak self] data in
            Task { @MainActor in
                await self?.handleNewMessage(data)
            }
        }
        
        socketService.on("message:updated") { [weak self] data in
            Task { @MainActor in
                await self?.handleMessageUpdate(data)
            }
        }
        
        socketService.on("message:deleted") { [weak self] data in
            Task { @MainActor in
                await self?.handleMessageDelete(data)
            }
        }
        
        socketService.on("user:typing") { [weak self] data in
            Task { @MainActor in
                await self?.handleTypingStart(data)
            }
        }
        
        socketService.on("user:stopped_typing") { [weak self] data in
            Task { @MainActor in
                await self?.handleTypingStop(data)
            }
        }
        
        socketService.on("messages:read") { [weak self] data in
            Task { @MainActor in
                await self?.handleMessagesRead(data)
            }
        }
    }
    
    func loadInitialMessages() async {
        guard !hasLoadedInitial else { return }
        hasLoadedInitial = true
        isLoading = true
        defer { isLoading = false }
        
        do {
            let response = try await APIService.shared.getMessages(conversationId: conversation.id)
            messages = response.messages ?? []
            // Reverse to show oldest first
            messages.reverse()
        } catch {
            print("Failed to load messages: \(error)")
        }
    }
    
    func loadMoreMessages() async {
        guard !isLoadingMore, let firstMessage = messages.first else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        
        do {
            let response = try await APIService.shared.getMessages(
                conversationId: conversation.id,
                before: firstMessage.createdAt
            )
            let newMessages = response.messages ?? []
            newMessages.reverse()
            messages = newMessages + messages
        } catch {
            print("Failed to load more messages: \(error)")
        }
    }
    
    func sendMessage() async {
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || replyingToMessage != nil else { return }
        
        draftMessage = ""
        stopTyping()
        
        do {
            let request = SendMessageRequest(
                conversationId: conversation.id,
                type: .TEXT,
                content: text.isEmpty ? nil : text,
                replyToId: replyingToMessage?.id
            )
            
            let message = try await APIService.shared.sendMessage(request)
            replyingToMessage = nil
            
            // Optimistic update
            messages.append(message)
        } catch {
            print("Failed to send message: \(error)")
        }
    }
    
    func handleMediaSelection(_ items: [PhotosPickerItem]) async {
        for item in items {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let mimeType = item.supportedContentTypes.first?.preferredMIMEType ?? "application/octet-stream"
                    let filename = "\(UUID().uuidString).\(mimeType.split(separator: "/").last ?? "bin")"
                    
                    let upload = try await APIService.shared.uploadFile(
                        data: data,
                        filename: filename,
                        mimeType: mimeType
                    )
                    
                    let type: MessageType = mimeType.hasPrefix("image/") ? .IMAGE :
                                         mimeType.hasPrefix("video/") ? .VIDEO :
                                         mimeType.hasPrefix("audio/") ? .AUDIO : .DOCUMENT
                    
                    let request = SendMessageRequest(
                        conversationId: conversation.id,
                        type: type,
                        content: nil,
                        mediaUrl: upload.file.url,
                        mediaType: mimeType,
                        mediaSize: data.count
                    )
                    
                    let message = try await APIService.shared.sendMessage(request)
                    messages.append(message)
                }
            } catch {
                print("Media upload failed: \(error)")
            }
        }
        selectedMediaItems = []
    }
    
    func startVoiceRecording() async {
        // TODO: Implement voice message recording
        print("Start voice recording")
    }
    
    func sendLocation() {
        // TODO: Implement location sharing
        print("Send location")
    }
    
    func markAsRead() async {
        let unreadIds = messages
            .filter { $0.senderId != AppState.shared.currentUser?.id && $0.status != .READ }
            .map { $0.id }
        
        guard !unreadIds.isEmpty else { return }
        
        do {
            try await APIService.shared.markMessagesAsRead(
                conversationId: conversation.id,
                messageIds: unreadIds
            )
            
            // Update local status
            for i in messages.indices {
                if unreadIds.contains(messages[i].id) {
                    // Would need to update status in message model
                }
            }
            
            // Update conversation unread count
            AppState.shared.markConversationAsRead(conversation.id)
        } catch {
            print("Failed to mark as read: \(error)")
        }
    }
    
    func handleNewMessage(_ data: Data) async {
        do {
            let message = try JSONDecoder().decode(Message.self, from: data)
            guard message.conversationId == conversation.id else { return }
            
            if !messages.contains(where: { $0.id == message.id }) {
                messages.append(message)
            }
        } catch {
            print("Failed to decode new message: \(error)")
        }
    }
    
    func handleMessageUpdate(_ data: Data) async {
        do {
            let message = try JSONDecoder().decode(Message.self, from: data)
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            }
        } catch {
            print("Failed to decode updated message: \(error)")
        }
    }
    
    func handleMessageDelete(_ data: Data) async {
        do {
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let messageId = payload?["messageId"] as? String {
                messages.removeAll { $0.id == messageId }
            }
        } catch {
            print("Failed to handle message delete: \(error)")
        }
    }
    
    func handleTypingStart(_ data: Data) async {
        do {
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let userId = payload?["userId"] as? String,
               userId != AppState.shared.currentUser?.id {
                typingUsers.insert(userId)
            }
        } catch {
            print("Failed to handle typing start: \(error)")
        }
    }
    
    func handleTypingStop(_ data: Data) async {
        do {
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let userId = payload?["userId"] as? String {
                typingUsers.remove(userId)
            }
        } catch {
            print("Failed to handle typing stop: \(error)")
        }
    }
    
    func handleMessagesRead(_ data: Data) async {
        do {
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let userId = payload?["userId"] as? String,
               let messageIds = payload?["messageIds"] as? [String] {
                for i in messages.indices {
                    if messageIds.contains(messages[i].id) && messages[i].senderId == userId {
                        // Update status to READ
                    }
                }
            }
        } catch {
            print("Failed to handle read receipt: \(error)")
        }
    }
    
    func sendTypingStart() {
        typingTimer?.invalidate()
        typingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
            self.stopTyping()
        }
        Task {
            await socketService.sendTypingStart(conversation.id)
        }
    }
    
    func stopTyping() {
        typingTimer?.invalidate()
        Task {
            await socketService.sendTypingStop(conversation.id)
        }
    }
    
    func cleanup() {
        typingTimer?.invalidate()
        socketService.off("message:new")
        socketService.off("message:updated")
        socketService.off("message:deleted")
        socketService.off("user:typing")
        socketService.off("user:stopped_typing")
        socketService.off("messages:read")
        
        Task {
            await socketService.leaveConversation(conversation.id)
        }
    }
}

// MARK: - Message Bubble View

struct MessageBubbleView: View {
    let message: Message
    let isFromCurrentUser: Bool
    @Binding var replyingToMessage: Message?
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !isFromCurrentUser {
                AvatarView(
                    url: message.sender?.avatarUrl,
                    name: message.sender?.displayName ?? "Unknown",
                    size: 32,
                    isGroup: false,
                    isOnline: message.sender?.isOnline ?? false
                )
            }
            
            VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: 4) {
                if !isFromCurrentUser && message.type != .SYSTEM {
                    Text(message.sender?.displayName ?? "Unknown")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }
                
                // Reply preview
                if let replyTo = message.replyTo {
                    ReplyPreviewInline(message: replyTo) {
                        // Navigate to replied message
                    }
                }
                
                // Message content
                messageContentView
                
                // Time and status
                HStack(spacing: 4) {
                    Text(message.formattedTime)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    if isFromCurrentUser {
                        MessageStatusIcon(status: message.status, isFromCurrentUser: true)
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(bubbleBackground)
            .cornerRadius(18)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color(.separator).opacity(0.2), lineWidth: 0.5)
            )
            
            if isFromCurrentUser {
                Spacer(minLength: 40)
            }
        }
        .padding(.horizontal, 4)
        .contextMenu {
            messageContextMenu
        }
    }
    
    @ViewBuilder
    private var messageContentView: some View {
        switch message.type {
        case .TEXT:
            Text(message.content ?? "")
                .font(.body)
                .textSelection(.enabled)
            
        case .IMAGE:
            if let url = message.mediaUrl, let imageUrl = URL(string: url) {
                AsyncImage(url: imageUrl) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView().frame(height: 200)
                }
                .frame(maxWidth: 250, maxHeight: 250)
                .cornerRadius(12)
            }
            
        case .VIDEO:
            if let url = message.mediaUrl {
                VideoThumbnailView(url: url)
            }
            
        case .VOICE_MESSAGE, .AUDIO:
            AudioMessageView(message: message)
            
        case .VIDEO_MESSAGE:
            if let url = message.mediaUrl {
                VideoThumbnailView(url: url, isVideoMessage: true)
            }
            
        case .DOCUMENT:
            DocumentMessageView(message: message)
            
        case .LOCATION:
            LocationMessageView(message: message)
            
        case .CONTACT:
            ContactMessageView(message: message)
            
        case .CALL_LOG:
            CallLogMessageView(message: message)
            
        case .SYSTEM:
            Text(message.content ?? "")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
    
    private var bubbleBackground: Color {
        if isFromCurrentUser {
            return Color.blue
        } else {
            return Color(.systemBackground)
        }
    }
    
    @ViewBuilder
    private var messageContextMenu: some View {
        Button {
            // Copy
            UIPasteboard.general.string = message.content
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        
        if message.type == .TEXT || message.type == .IMAGE || message.type == .VIDEO {
            Button {
                replyingToMessage = message
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
        }
        
        Button {
            // Forward
        } label: {
            Label("Forward", systemImage: "arrowshape.turn.up.right")
        }
        
        if isFromCurrentUser {
            Button(role: .destructive) {
                // Delete
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Supporting Views

struct TypingIndicatorView: View {
    let users: Set<String>
    @State private var animationPhase = 0
    
    var body: some View {
        HStack(spacing: 8) {
            AvatarView(url: nil, name: " ", size: 24, isGroup: false, isOnline: false)
            
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 8, height: 8)
                        .scaleEffect(animationPhase == index ? 1.2 : 0.8)
                        .animation(
                            .easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(index) * 0.2),
                            value: animationPhase
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray5))
            .cornerRadius(18)
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .onAppear {
            withAnimation { animationPhase = 2 }
        }
    }
}

struct ReplyPreviewView: View {
    let message: Message
    let onDismiss: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.caption)
                    Text("Replying to")
                        .font(.caption.weight(.medium))
                }
                .foregroundColor(.blue)
                
                Text(messagePreview)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray5))
            .cornerRadius(12)
            
            Spacer()
            
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
    
    private var messagePreview: String {
        switch message.type {
        case .TEXT: return message.content ?? ""
        case .IMAGE: return "📷 Photo"
        case .VIDEO: return "🎥 Video"
        case .VOICE_MESSAGE: return "🎵 Voice message"
        case .DOCUMENT: return "📄 Document"
        default: return "Message"
        }
    }
}

struct ReplyPreviewInline: View {
    let message: MessageReply
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                Rectangle()
                    .fill(Color.blue)
                    .frame(width: 3)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.senderId == AppState.shared.currentUser?.id ? "You" : "User")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.blue)
                    
                    Text(messagePreview)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
            }
            .padding(8)
            .background(Color(.systemGray6))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
    
    private var messagePreview: String {
        switch message.type {
        case .TEXT: return message.content ?? ""
        case .IMAGE: return "📷 Photo"
        case .VIDEO: return "🎥 Video"
        default: return "Message"
        }
    }
}

struct ChatInputBarView: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    let replyingTo: Message?
    let onSend: () async -> Void
    let onAttach: () -> Void
    let onVoiceMessage: () async -> Void
    let onCall: () -> Void
    let onVideoCall: () -> Void
    
    @State private var showVoiceButton = true
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack(spacing: 8) {
                // Attach button
                Button(action: onAttach) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.blue)
                }
                
                // Text field
                HStack(spacing: 8) {
                    TextField("Message", text: $text, axis: .vertical)
                        .font(.body)
                        .focused($isFocused)
                        .lineLimit(1...5)
                        .onChange(of: text) { _, _ in
                            showVoiceButton = text.trimmingCharacters(in: .whitespaces).isEmpty
                        }
                        .onSubmit {
                            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                                Task { await onSend() }
                            }
                        }
                    
                    if !text.isEmpty {
                        Button {
                            text = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .cornerRadius(20)
                
                // Voice/Video call buttons
                if showVoiceButton {
                    Button(action: onVoiceMessage) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.blue)
                            .frame(width: 40, height: 40)
                    }
                } else {
                    Button(action: { Task { await onSend() } }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.blue)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Media Message Views

struct VideoThumbnailView: View {
    let url: String
    var isVideoMessage = false
    
    var body: some View {
        ZStack {
            AsyncImage(url: URL(string: url)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color(.systemGray5)
            }
            .frame(maxWidth: 250, maxHeight: 250)
            .cornerRadius(12)
            
            Image(systemName: "play.circle.fill")
                .font(.system(size: 50))
                .foregroundColor(.white)
                .shadow(radius: 4)
        }
    }
}

struct AudioMessageView: View {
    let message: Message
    @State private var isPlaying = false
    @State private var progress: Double = 0
    
    var body: some View {
        HStack(spacing: 12) {
            Button {
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.blue)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                    .tint(.blue)
                
                Text(formatDuration(message.duration ?? 0))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 200)
        .padding(.vertical, 4)
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

struct DocumentMessageView: View {
    let message: Message
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: documentIcon)
                .font(.system(size: 40))
                .foregroundColor(documentColor)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(message.content ?? "Document")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                
                if let size = message.mediaSize {
                    Text(formatFileSize(size))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(width: 250)
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    private var documentIcon: String {
        guard let mimeType = message.mediaType else { return "doc.fill" }
        if mimeType.hasPrefix("application/pdf") { return "doc.fill" }
        if mimeType.hasPrefix("application/msword") { return "doc.fill" }
        if mimeType.hasPrefix("application/vnd.openxmlformats") { return "doc.fill" }
        if mimeType.hasPrefix("text/") { return "doc.text.fill" }
        return "doc.fill"
    }
    
    private var documentColor: Color {
        guard let mimeType = message.mediaType else { return .blue }
        if mimeType.hasPrefix("application/pdf") { return .red }
        if mimeType.hasPrefix("text/") { return .green }
        return .blue
    }
    
    private func formatFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

struct LocationMessageView: View {
    let message: Message
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "location.fill")
                .font(.title)
                .foregroundColor(.red)
            
            Text(message.content ?? "Location")
                .font(.subheadline)
            
            // Map preview would go here
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray5))
                .frame(height: 150)
                .overlay(
                    Image(systemName: "map")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                )
        }
        .frame(width: 250)
        .padding(12)
        .background(Color(.systemBackground))
        .cornerRadius(12)
    }
}

struct ContactMessageView: View {
    let message: Message
    
    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: nil, name: message.content ?? "Contact", size: 50, isGroup: false, isOnline: false)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(message.content ?? "Contact")
                    .font(.headline)
                
                Text("Tap to view contact")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct CallLogMessageView: View {
    let message: Message
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: callIcon)
                .font(.title2)
                .foregroundColor(callColor)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(callTitle)
                    .font(.subheadline.weight(.medium))
                
                if let duration = message.duration {
                    Text(formatDuration(duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Image(systemName: "phone.fill")
                .font(.caption)
                .foregroundColor(.blue)
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    private var callIcon: String {
        guard let content = message.content,
              let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return "phone.fill"
        }
        return type == "VIDEO" ? "video.fill" : "phone.fill"
    }
    
    private var callColor: Color {
        guard let content = message.content,
              let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String else {
            return .blue
        }
        
        switch status {
        case "MISSED": return .red
        case "REJECTED": return .orange
        default: return .green
        }
    }
    
    private var callTitle: String {
        guard let content = message.content,
              let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String else {
            return "Call"
        }
        
        switch status {
        case "MISSED": return "Missed call"
        case "REJECTED": return "Declined call"
        case "ENDED": return "Call ended"
        default: return "Call"
        }
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}