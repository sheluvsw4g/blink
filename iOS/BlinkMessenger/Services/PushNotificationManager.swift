// Push Notification Manager - APNs handling
import Foundation
import UserNotifications
import UIKit

final class PushNotificationManager: NSObject, ObservableObject {
    static let shared = PushNotificationManager()
    
    @Published var isAuthorized = false
    @Published var deviceToken: String?
    
    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
    
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
                if granted {
                    self?.registerForRemoteNotifications()
                }
            }
            
            if let error = error {
                print("Push notification authorization error: \(error)")
            }
        }
    }
    
    private func registerForRemoteNotifications() {
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
    
    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        self.deviceToken = tokenString
        
        // Send to backend
        Task {
            try? await APIService.shared.registerDevice(token: tokenString, platform: "ios")
        }
        
        print("APNs Device Token: \(tokenString)")
    }
    
    func didFailToRegisterForRemoteNotifications(withError error: Error) {
        print("Failed to register for remote notifications: \(error)")
    }
    
    func handleNotification(_ userInfo: [AnyHashable: Any]) {
        // Handle notification when app is in foreground or tapped from background
        print("Received push notification: \(userInfo)")
        
        // Navigate based on notification type
        if let type = userInfo["type"] as? String {
            switch type {
            case "message":
                if let conversationId = userInfo["conversationId"] as? String {
                    AppState.shared.navigateToChat(userId: conversationId)
                }
            case "call":
                if let callId = userInfo["callId"] as? String {
                    AppState.shared.navigateToCall(callId: callId)
                }
            default:
                break
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushNotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound, .badge])
    }
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        handleNotification(userInfo)
        completionHandler()
    }
}

// MARK: - AppDelegate Integration

// Add this to your AppDelegate or use UIApplicationDelegateAdaptor in SwiftUI
/*
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PushNotificationManager.shared.requestAuthorization()
        return true
    }
    
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushNotificationManager.shared.didRegisterForRemoteNotifications(withDeviceToken: deviceToken)
    }
    
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushNotificationManager.shared.didFailToRegisterForRemoteNotifications(withError: error)
    }
}
*/