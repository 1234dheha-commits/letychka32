import Foundation

/// In-app language override. "system" follows the phone language; "en" /
/// "uk" / "ru" force that language regardless of the phone. Everything in
/// the UI goes through L(), so switching here updates the whole app live
/// (no restart) once the views re-render.
enum Lang {
    static let key = "appLang"
    private(set) static var code =
        UserDefaults.standard.string(forKey: key) ?? "system"
    private static var cached: Bundle = .main

    static func set(_ c: String) {
        code = c
        UserDefaults.standard.set(c, forKey: key)
        cached = resolve()
        // Every view observes BLEMessenger.shared, so bump it to redraw
        // the whole app immediately in the new language.
        DispatchQueue.main.async { BLEMessenger.shared.langTick &+= 1 }
    }

    private static func resolve() -> Bundle {
        guard code != "system",
              let p = Bundle.main.path(forResource: code, ofType: "lproj"),
              let b = Bundle(path: p)
        else { return .main }
        return b
    }

    static func bundle() -> Bundle {
        // Resolve lazily the first time (after launch the stored code is set).
        if cached === Bundle.main && code != "system" { cached = resolve() }
        return cached
    }
}

/// Tiny localization helper. The English string IS the key, looked up in
/// Localizable.strings (en / uk / ru) of the selected-language bundle.
///
/// Usage:
///   Text(L("Settings"))
///   Text(L("Receiving media %d%%", pct))
func L(_ key: String, _ args: CVarArg...) -> String {
    let fmt = Lang.bundle().localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? fmt : String(format: fmt, arguments: args)
}
