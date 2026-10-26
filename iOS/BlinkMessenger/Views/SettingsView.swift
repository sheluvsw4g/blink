// SettingsView - App settings and account management
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingLogoutAlert = false
    @State private var showingPrivacyPolicy = false
    @State private var showingAbout = false
    @State private var notificationSettings = NotificationSettings()
    
    var body: some View {
        NavigationStack {
            List {
                // Account Section
                Section(header: Text("Account")) {
                    SettingRow(icon: "person.fill", title: "Profile") {
                        // Navigate to profile
                    }
                    SettingRow(icon: "lock.fill", title: "Privacy") {
                        showingPrivacyPolicy = true
                    }
                    SettingRow(icon: "backspace.arrow.fill", title: "Blocked Users") {
                        // Navigate to blocked users
                    }
                }
                
                // Notifications Section
                Section(header: Text("Notifications")) {
                    NotificationToggleRow(
                        title: "Message notifications",
                        subtitle: "New message alerts",
                        isOn: $notificationSettings.messageNotifications
                    )
                    NotificationToggleRow(
                        title: "Call notifications",
                        subtitle: "Incoming call alerts",
                        isOn: $notificationSettings.callNotifications
                    )
                    NotificationToggleRow(
                        title: "Group notifications",
                        subtitle: "Group message alerts",
                        isOn: $notificationSettings.groupNotifications
                    )
                }
                
                // Data & Storage Section
                Section(header: Text("Data & Storage")) {
                    SettingRow(icon: "archivebox.fill", title: "Storage Usage") {
                        // Show storage usage
                    }
                    SettingRow(icon: "goforward.10", title: "Clear Cache") {
                        // Clear cache action
                    }
                }
                
                // About Section
                Section {
                    SettingRow(icon: "questionmark.circle.fill", title: "About Blink") {
                        showingAbout = true
                    }
                    SettingRow(icon: "shareplay.fill", title: "Share Blink") {
                        // Share app
                    }
                }
                
                // Logout Section (always at bottom)
                Section {
                    Button(role: .destructive) {
                        showingLogoutAlert = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Log Out")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Log Out", isPresented: $showingLogoutAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Log Out", role: .destructive) {
                    Task { await appState.logout() }
                }
            } message: {
                Text("Are you sure you want to log out?")
            }
            .sheet(isPresented: $showingPrivacyPolicy) {
                PrivacyPolicyView()
            }
            .sheet(isPresented: $showingAbout) {
                AboutView()
            }
        }
    }
}

// MARK: - Supporting Types

struct NotificationSettings {
    var messageNotifications = true
    var callNotifications = true
    var groupNotifications = true
    var vibrateOnMessages = true
    var popupPreviews = true
}

// MARK: - Supporting Views

struct SettingRow: View {
    let icon: String
    let title: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(.blue)
                    .frame(width: 30)
                
                Text(title)
                    .font(.system(size: 17))
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

struct NotificationToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                    .font(.system(size: 17))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: .blue))
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(AppState.shared)
}