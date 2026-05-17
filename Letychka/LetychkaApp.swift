import SwiftUI
import UIKit

@main
struct LetychkaApp: App {
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
            try? data.write(to: url)
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
