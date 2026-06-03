import SwiftUI

/// Community rules + contact info, required by App Store Guideline 1.2 for
/// apps with user-generated content. Shown on first launch (must be accepted)
/// and any time from Settings > Terms of Use.
enum SafetyText {
    static let reportEmail = "support@anonimniyov.xyz"
    static let reportTelegram = "https://t.me/LetychkaReportbot"

    /// The agreement / community rules. Must state zero tolerance for
    /// objectionable content and abusive users.
    static var rules: [String] {
        [
            L("Zero tolerance: objectionable content and abusive users are not allowed on Letychka."),
            L("Do not post or send content that is hateful, harassing, threatening, sexual, or illegal."),
            L("Everything you write in the Room is broadcast to everyone nearby. Be respectful."),
            L("You can report any message and block any user at any time, right from the message."),
            L("Reports are reviewed and acted on within 24 hours: offending content is removed and offending users are ejected."),
            L("Offensive words are automatically hidden in the Room.")
        ]
    }
}

/// Full-screen first-launch gate. The user must agree before using the app.
struct EULAGateView: View {
    var onAgree: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Theme.bg(scheme).ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                        Text(L("Welcome to Letychka"))
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(Theme.text(scheme))
                            .frame(maxWidth: .infinity)
                        Text(L("Community rules"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.muted(scheme))
                            .frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(SafetyText.rules, id: \.self) { line in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(Theme.accent)
                                        .padding(.top, 2)
                                    Text(line)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Theme.text(scheme))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.top, 6)
                        Text(L("By tapping I Agree you accept these rules. Breaking them can get your messages removed and your device blocked from others."))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted(scheme))
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
                Button(action: onAgree) {
                    Text(L("I Agree"))
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
            }
        }
    }
}

/// Read-only rules, opened from Settings > Terms of Use.
struct TermsView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg(scheme).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(SafetyText.rules, id: \.self) { line in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.top, 2)
                                Text(line)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.text(scheme))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text(L("Report content from the message menu, or contact us:"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text(scheme))
                            .padding(.top, 10)
                        Link(SafetyText.reportEmail,
                             destination: URL(string: "mailto:\(SafetyText.reportEmail)")!)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.accent)
                        Link(L("Contact on Telegram"),
                             destination: URL(string: SafetyText.reportTelegram)!)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(20)
                }
            }
            .navigationTitle(L("Terms of Use"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
    }
}
