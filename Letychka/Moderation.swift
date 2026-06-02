import Foundation

/// On-device content moderation for the shared Room (user-generated content),
/// added to comply with App Store Review Guideline 1.2. There is no server, so
/// filtering and report-driven removal all happen on the device: reporting a
/// post hides it locally and blocks (ejects) its author, so nothing else from
/// that person reaches this user's feed.
enum Moderation {

    /// Compact, multilingual list of strongly objectionable stems. Matched at
    /// a word start, case-insensitive, with any trailing letters (so inflected
    /// forms are caught too). Not a substitute for human review, but a real
    /// automatic filter that masks slurs and profanity in the shared Room.
    private static let banned: [String] = [
        "fuck", "shit", "bitch", "cunt", "asshole", "faggot", "nigger",
        "nigga", "whore", "slut", "rape", "retard", "motherfuck", "dickhead",
        "хуй", "хуя", "хує", "хуе", "пизд", "пізд", "бляд", "блят", "сука",
        "єбать", "ебать", "ебал", "їбав", "підор", "пидор", "гандон", "гондон",
        "мудак", "залуп", "манда", "шлюх", "довбойоб", "підар"
    ]

    private static let regex: NSRegularExpression? = {
        let alts = banned
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // Word start (no preceding letter) + stem + any trailing letters.
        return try? NSRegularExpression(
            pattern: "(?<![\\p{L}])(?:\(alts))[\\p{L}]*",
            options: [.caseInsensitive])
    }()

    /// Replace objectionable words with a mask for display. The stored text is
    /// untouched; only what the user sees is filtered.
    static func clean(_ text: String) -> String {
        guard let re = regex, !text.isEmpty else { return text }
        let m = NSMutableString(string: text)
        let matches = re.matches(
            in: text, range: NSRange(location: 0, length: m.length))
        for r in matches.reversed() {
            m.replaceCharacters(in: r.range, with: "•••")
        }
        return m as String
    }
}
