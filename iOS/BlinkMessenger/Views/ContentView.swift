// ContentView - Main app container with tab navigation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var pushManager: PushNotificationManager
    
    var body: some View {
        Group {
            if appState.isAuthenticated {
                mainTabView
            } else {
                AuthView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.isAuthenticated)
        .sheet(isPresented: $appState.showingCallScreen) {
            if let callInfo = appState.activeCall {
                CallScreenView(callInfo: callInfo)
                    .environmentObject(appState)
            }
        }
    }
    
    private var mainTabView: some View {
        TabView(selection: $appState.selectedTab) {
            NavigationStack(path: $appState.navigationPath) {
                ChatsListView()
                    .navigationDestination(for: Conversation.self) { conversation in
                        ChatView(conversation: conversation)
                    }
            }
            .tabItem {
                Label(AppState.Tab.chats.title, systemImage: AppState.Tab.chats.icon)
            }
            .tag(AppState.Tab.chats)
            .badge(appState.unreadCount > 0 ? "\(appState.unreadCount)" : nil)
            
            NavigationStack {
                Text("Calls History")
                    .navigationTitle("Calls")
            }
            .tabItem {
                Label(AppState.Tab.calls.title, systemImage: AppState.Tab.calls.icon)
            }
            .tag(AppState.Tab.calls)
            
            NavigationStack {
                Text("Contacts")
                    .navigationTitle("Contacts")
            }
            .tabItem {
                Label(AppState.Tab.contacts.title, systemImage: AppState.Tab.contacts.icon)
            }
            .tag(AppState.Tab.contacts)
            
            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label(AppState.Tab.settings.title, systemImage: AppState.Tab.settings.icon)
            }
            .tag(AppState.Tab.settings)
        }
        .onAppear {
            // Configure tab bar appearance
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

// MARK: - Preview
#Preview {
    ContentView()
        .environmentObject(AppState.shared)
        .environmentObject(PushNotificationManager.shared)
}