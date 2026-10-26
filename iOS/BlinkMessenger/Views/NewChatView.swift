// NewChatView - Start new conversation
import SwiftUI

struct NewChatView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedUsers: Set<String> = []
    @State private var isCreatingGroup = false
    @State private var groupName = ""
    
    var filteredContacts: [Contact] {
        if searchText.isEmpty {
            return appState.contacts
        }
        return appState.contacts.filter { contact in
            contact.displayName.localizedCaseInsensitiveContains(searchText) ||
            contact.contact.phoneNumber.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                SearchBar(text: $searchText, placeholder: "Search contacts")
                    .padding()
                
                // Contact list
                List {
                    Section {
                        ForEach(filteredContacts) { contact in
                            ContactRowView(
                                contact: contact,
                                isSelected: selectedUsers.contains(contact.contactId),
                                onTap: { toggleSelection(contact) }
                            )
                        }
                    } header: {
                        if selectedUsers.isEmpty {
                            Text("CONTACTS")
                        } else {
                            HStack {
                                Text("\(selectedUsers.count) selected")
                                Spacer()
                                Button("Create Group") {
                                    isCreatingGroup = true
                                }
                                .font(.subheadline.weight(.medium))
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if selectedUsers.count == 1 {
                        Button("Chat") {
                            createPrivateChat()
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
            .sheet(isPresented: $isCreatingGroup) {
                CreateGroupView(selectedUserIds: Array(selectedUsers)) {
                    dismiss()
                }
                .environmentObject(appState)
            }
        }
    }
    
    private func toggleSelection(_ contact: Contact) {
        if selectedUsers.contains(contact.contactId) {
            selectedUsers.remove(contact.contactId)
        } else {
            selectedUsers.insert(contact.contactId)
        }
    }
    
    private func createPrivateChat() {
        guard let userId = selectedUsers.first else { return }
        Task {
            do {
                let conversation = try await APIService.shared.createPrivateConversation(userId: userId)
                await MainActor.run {
                    appState.conversations.insert(conversation, at: 0)
                    appState.navigationPath.append(conversation)
                    dismiss()
                }
            } catch {
                print("Failed to create chat: \(error)")
            }
        }
    }
}

// MARK: - Contact Row

struct ContactRowView: View {
    let contact: Contact
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Selection indicator
                ZStack {
                    Circle()
                        .stroke(isSelected ? Color.blue : Color(.systemGray4), lineWidth: 2)
                        .frame(width: 24, height: 24)
                    
                    if isSelected {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 14, height: 14)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                
                // Avatar
                AvatarView(
                    url: contact.contact.avatarUrl,
                    name: contact.displayName,
                    size: 48,
                    isGroup: false,
                    isOnline: contact.contact.isOnline
                )
                
                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                        .font(.body)
                        .foregroundColor(.primary)
                    
                    Text(contact.contact.phoneNumber)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Create Group View

struct CreateGroupView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let selectedUserIds: [String]
    let onComplete: () -> Void
    
    @State private var groupName = ""
    @State private var groupAvatar: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var isCreating = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Group avatar
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $groupAvatar, matching: .images) {
                            ZStack {
                                Circle()
                                    .fill(Color(.systemGray5))
                                    .frame(width: 80, height: 80)
                                
                                if let image = selectedImage {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 80, height: 80)
                                        .clipShape(Circle())
                                } else {
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 30))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    
                    TextField("Group Name", text: $groupName)
                        .textContentType(.none)
                }
                
                Section("Members (\(selectedUserIds.count + 1))") {
                    // Current user
                    HStack {
                        AvatarView(
                            url: appState.currentUser?.avatarUrl,
                            name: appState.currentUser?.displayName ?? "You",
                            size: 40,
                            isGroup: false,
                            isOnline: true
                        )
                        Text("\(appState.currentUser?.displayName ?? "You") (You)")
                        Spacer()
                    }
                    
                    // Selected contacts
                    ForEach(selectedUserIds, id: \.self) { userId in
                        if let contact = appState.contacts.first(where: { $0.contactId == userId }) {
                            HStack {
                                AvatarView(
                                    url: contact.contact.avatarUrl,
                                    name: contact.displayName,
                                    size: 40,
                                    isGroup: false,
                                    isOnline: contact.contact.isOnline
                                )
                                Text(contact.displayName)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        Task { await createGroup() }
                    }
                    .fontWeight(.semibold)
                    .disabled(groupName.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                }
            }
        }
        .onChange(of: groupAvatar) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    selectedImage = image
                }
            }
        }
    }
    
    private func createGroup() async {
        isCreating = true
        defer { isCreating = false }
        
        var avatarUrl: String?
        if let image = selectedImage,
           let imageData = image.jpegData(compressionQuality: 0.8) {
            do {
                let upload = try await APIService.shared.uploadFile(
                    data: imageData,
                    filename: "group_avatar.jpg",
                    mimeType: "image/jpeg"
                )
                avatarUrl = upload.file.url
            } catch {
                print("Avatar upload failed: \(error)")
            }
        }
        
        do {
            let conversation = try await APIService.shared.createGroupConversation(
                name: groupName,
                participantIds: selectedUserIds,
                avatarUrl: avatarUrl
            )
            
            await MainActor.run {
                appState.conversations.insert(conversation, at: 0)
                appState.navigationPath.append(conversation)
                onComplete()
            }
        } catch {
            print("Failed to create group: \(error)")
        }
    }
}

// MARK: - Search Bar

struct SearchBar: View {
    @Binding var text: String
    let placeholder: String
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField(placeholder, text: $text)
                .textContentType(.none)
            
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
        .padding(.vertical, 10)
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
}

// MARK: - Preview

#Preview {
    NewChatView()
        .environmentObject(AppState.shared)
}