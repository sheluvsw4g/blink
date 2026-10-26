// BlinkMessenger iOS App - Main Entry Point
import SwiftUI
import UserNotifications

@main
struct BlinkMessengerApp: App {
    @StateObject private var appState = AppState.shared
    @StateObject private var pushManager = PushNotificationManager.shared
    
    init() {
        // Configure app appearance
        setupAppearance()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(pushManager)
                .onAppear {
                    pushManager.requestAuthorization()
                    appState.initialize()
                }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }
    
    private func setupAppearance() {
        // Navigation bar appearance
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor.systemBackground
        appearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.label]
        
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        
        // Tab bar appearance
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor.systemBackground
        
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    }
    
    private func handleDeepLink(_ url: URL) {
        // Handle deep links like blink://chat/userId or blink://call/callId
        guard url.scheme == "blink" else { return }
        
        let components = url.pathComponents.filter { $0 != "/" }
        guard let action = components.first else { return }
        
        switch action {
        case "chat":
            if let userId = components.dropFirst().first {
                appState.navigateToChat(userId: userId)
            }
        case "call":
            if let callId = components.dropFirst().first {
                appState.navigateToCall(callId: callId)
            }
        default:
            break
        }
    }
}