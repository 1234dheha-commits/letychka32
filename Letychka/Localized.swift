import Foundation

/// Tiny localization helper. The English string IS the key, looked up in
/// Localizable.strings (en / uk / ru). Classic NSLocalizedString is used
/// on purpose: it is the most predictable mechanism (no String Catalog
/// auto-key guesswork), so translations resolve reliably.
///
/// Usage:
///   Text(L("Settings"))
///   Text(L("Receiving media %d%%", pct))
func L(_ key: String, _ args: CVarArg...) -> String {
    let fmt = NSLocalizedString(key, comment: "")
    return args.isEmpty ? fmt : String(format: fmt, arguments: args)
}
