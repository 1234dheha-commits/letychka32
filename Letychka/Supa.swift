import Foundation
import Supabase

/// Thin singleton wrapping the Supabase client for the (planned) Global
/// mode. Today (Phase B): on launch we restore or create an anonymous
/// session and upsert a row into `profiles` so the user has an identity
/// on the server. No UI is wired to this yet, and Bluetooth keeps
/// working exactly as before. If anything here fails (no internet, the
/// server is down, anonymous sign-ins are disabled), the app just keeps
/// running in BLE mode and we log the error.
final class Supa {
    static let shared = Supa()

    private static let url = URL(string:
        "https://qeomwrbigwilidbkgzav.supabase.co")!
    private static let publishableKey =
        "sb_publishable_bPSBNGuwNpQbTNUw2_hacg_1B19CNra"

    let client: SupabaseClient

    private init() {
        client = SupabaseClient(supabaseURL: Self.url,
                                supabaseKey: Self.publishableKey)
    }

    /// Restore or create an anonymous session, then ensure the matching
    /// `profiles` row exists. Fire-and-forget from the app delegate.
    func start() {
        Task { @MainActor in
            do {
                _ = try await client.auth.session
            } catch {
                do {
                    _ = try await client.auth.signInAnonymously()
                } catch {
                    print("Supa: anonymous sign-in failed: \(error)")
                    return
                }
            }
            await ensureProfile()
        }
    }

    @MainActor
    private func ensureProfile() async {
        guard let uid = client.auth.currentUser?.id else { return }
        let username = BLEMessenger.shared.nick
        struct Row: Encodable {
            let id: UUID
            let username: String
        }
        do {
            try await client
                .from("profiles")
                .upsert(Row(id: uid, username: username),
                        onConflict: "id")
                .execute()
        } catch {
            // Likely a username uniqueness conflict on first run. Retry
            // once with a short random suffix so we still land a row.
            let suffix = String(UInt32.random(in: 1...0xFFFF), radix: 16)
            let row = Row(id: uid, username: username + "-" + suffix)
            do {
                try await client
                    .from("profiles")
                    .upsert(row, onConflict: "id")
                    .execute()
            } catch {
                print("Supa: profile upsert failed twice: \(error)")
            }
        }
    }
}
