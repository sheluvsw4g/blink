// UserProfileView - View for viewing/editing user profile
import SwiftUI
import PhotosUI

struct UserProfileView: View {
    let user: User
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showingEditProfile = false
    @State private var selectedImage: UIImage?
    @State private var avatarItem: PhotosPickerItem?
    @State private var currentBio: String = ""
    
    init(user: User) {
        self.user = user
        _currentBio = State(initialValue: user.bio ?? "")
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Avatar and basic info
                    VStack(spacing: 16) {
                        PhotosPicker(selection: $avatarItem, matching: .images) {
                            ZStack {
                                Circle()
                                    .fill(Color(.systemGray5))
                                    .frame(width: 120, height: 120)
                                
                                if let image = selectedImage {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 120, height: 120)
                                        .clipShape(Circle())
                                } else {
                                    Circle()
                                        .fill(avatarColor)
                                        .frame(width: 120, height: 120)
                                        .overlay(
                                            Text(initials)
                                                .font(.system(size: 40, weight: .medium))
                                                .foregroundColor(.white)
                                        )
                                }
                            }
                        }
                        
                        Text(user.displayName)
                            .font(.title.bold())
                        
                        HStack {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                            Text(user.phoneNumber)
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        
                        if let bio = user.bio, !bio.isEmpty {
                            Text("Bio: \(bio)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Edit button (for own profile)
                    if user.id == appState.currentUser?.id {
                        Button {
                            showingEditProfile = true
                        } label: {
                            HStack {
                                Image(systemName: "pencil")
                                Text("Edit Profile")
                                    .font(.system(size: 16, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                    }
                    
                    // Device sessions
                    DeviceSessionsRow()
                }
                .padding(.horizontal)
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: avatarItem) { _, newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        selectedImage = image
                    }
                }
            }
            .sheet(isPresented: $showingEditProfile) {
                EditProfileView(onSave: { name, bio in
                    Task {
                        do {
                            _ = try await APIService.shared.updateProfile(
                                name: name,
                                bio: bio,
                                avatarUrl: selectedImage.map { _ in "uploaded" }
                            )
                            // Refresh user data
                            await MainActor.run {
                                appState.currentUser = appState.currentUser
                            }
                        } catch {
                            print("Failed to update profile: \(error)")
                        }
                    }
                    dismiss()
                })
            }
        }
    }
    
    private var avatarColor: Color {
        let hash = user.name.hashValue
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .red, .teal, .indigo]
        return colors[abs(hash) % colors.count]
    }
    
    private var initials: String {
        let components = user.name.components(separatedBy: " ")
        if components.count >= 2 {
            return "\(components[0].first!)\(components[1].first!)".uppercased()
        }
        return String(user.name.prefix(2)).uppercased()
    }
}

// MARK: - Edit Profile View

struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @State private var name: String
    @State private var bio: String
    @State private var isSaving = false
    
    init(onSave: @escaping (String, String) -> Void) {
        self.onSave = onSave
        _name = State(initialValue: appState.currentUser?.name ?? "")
        _bio = State(initialValue: appState.currentUser?.bio ?? "")
    }
    
    let onSave: (String, String) -> Void
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Name")) {
                    TextField("Your Name", text: $name)
                        .textContentType(.name)
                }
                
                Section(header: Text("About")) {
                    TextField("About you (optional)", text: $bio)
                        .textContentType(.bio)
                        .lineLimit(3)
                }
                
                Section {
                    Button {
                        Task {
                            isSaving = true
                            defer { isSaving = false }
                            await onSave(name, bio)
                        }
                    } label: {
                        HStack {
                            if isSaving {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            }
                            Text("Save")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Device Sessions Row

struct DeviceSessionsRow: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "phone.gen.gen")
                    .foregroundColor(.blue)
                Text("Active Sessions")
                    .font(.headline)
                Spacer()
                Text("2 devices")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // List of active sessions
            ForEach(0..<2, id: \.self) { _ in
                HStack {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("iPhone 15")
                        .font(.subheadline)
                    Spacer()
                    Button("Sign Out") {
                        // Sign out from this device
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                }
            }
        }
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Preview

#Preview {
    UserProfileView(user: User(
        id: "1",
        phoneNumber: "+1 (555) 123-4567",
        name: "John Doe",
        avatarUrl: nil,
        bio: "iOS developer and open source enthusiast",
        isOnline: false,
        lastSeen: nil,
        createdAt: nil
    ))
    .environmentObject(AppState.shared)
}