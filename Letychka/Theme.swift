import SwiftUI

/// Visual language shared with Reboard: near-black dark theme, violet accent,
/// rounded controls, system font, minimalist. Adapts to light mode too.
enum Theme {
    static let accent = Color(red: 0.545, green: 0.361, blue: 1.0)   // #8B5CFF

    static func bg(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black
                        : Color(red: 0.96, green: 0.96, blue: 0.97)
    }
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.06)
                        : Color.black.opacity(0.04)
    }
    static func line(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10)
                        : Color.black.opacity(0.10)
    }
    static func text(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white : Color(red: 0.07, green: 0.07, blue: 0.08)
    }
    static func muted(_ scheme: ColorScheme) -> Color {
        (scheme == .dark ? Color.white : Color.black).opacity(0.55)
    }
}

/// Reboard-style primary button: solid violet, rounded, bold.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Reboard-style key/secondary button: translucent surface, rounded.
struct KeyButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.text(scheme))
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(Theme.surface(scheme))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.line(scheme), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// "light" | "dark" theme choice, persisted. No System: only Dark and Light.
/// Default is Dark, so any unknown/legacy value resolves to the dark theme.
enum AppTheme {
    static let key = "themeMode"
    static func scheme(for mode: String) -> ColorScheme {
        mode == "light" ? .light : .dark
    }
}
