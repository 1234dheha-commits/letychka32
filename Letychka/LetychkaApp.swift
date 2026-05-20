import SwiftUI
import UIKit
import UserNotifications

/// Lets Letychka show a message notification even while the app is open
/// (BLE only delivers while the app is running, so foreground banners are
/// the useful case here).
final class AppDelegate: NSObject, UIApplicationDelegate,
                         UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                     [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Start Bluetooth at launch (incl. background relaunch by iOS for
        // state restoration) so messages can arrive and notify off-screen.
        BLEMessenger.shared.start()
        // Phase B: also try to bring up an anonymous Supabase session so
        // the user has a server identity. No UI is wired to this yet; on
        // failure (offline, server down, anon disabled) BLE keeps working.
        Supa.shared.start()
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    /// Tapped a notification (foreground or from a cold/background launch):
    /// jump straight into that chat / the Room.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler:
                                @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let room = (info["room"] as? Bool) ?? false
        let peer = info["peer"] as? String
        BLEMessenger.shared.openFromNotification(peer: peer, room: room)
        completionHandler()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        BLEMessenger.shared.appBecameActive()
    }
}

@main
struct LetychkaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Theme is applied here at the root so EVERY view (and its
    // @Environment(\.colorScheme)) sees the same, correct value.
    @AppStorage(AppTheme.key) private var themeMode = "dark"

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(AppTheme.scheme(for: themeMode))
        }
    }
}

/// Avatar image stored in the app's Documents (Letychka is a normal app,
/// not an extension, so images are fine here). Local only - BLE payloads
/// are tiny so the photo is not sent to peers, it personalises your side.
enum AvatarStore {
    private static var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("avatar.jpg")
    }
    static func save(_ image: UIImage) {
        guard let url = url else { return }
        let maxDim: CGFloat = 256
        let s = min(1, maxDim / max(image.size.width, image.size.height))
        let sz = CGSize(width: image.size.width * s, height: image.size.height * s)
        let r = UIGraphicsImageRenderer(size: sz)
        let img = r.image { _ in image.draw(in: CGRect(origin: .zero, size: sz)) }
        if let data = img.jpegData(compressionQuality: 0.8) {
            // Encrypted at rest while device locked.
            try? data.write(to: url,
                            options: [.atomic, .completeFileProtection])
        }
    }
    static func load() -> UIImage? {
        guard let url = url, let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
    static func clear() {
        guard let url = url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
