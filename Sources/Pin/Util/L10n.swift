// Localization.
//
// Usage: `L("overlay.copy", "Copy")` — the first argument is the key, the second is the English
// text, which doubles as the fallback. Writing the English at the call site rather than the key
// alone means reading the code tells you what appears on screen; and if a key is missing a
// translation, what comes back is a readable sentence instead of "overlay.copy".
//
// Adding a string:
//   1. Write L("new.key", "English text") in the code
//   2. Run scripts/i18n-scan.sh — it collects every L(...), rewrites en.lproj from the source and
//      marks the key MISSING in every translation, leaving existing translations alone
//   3. Translate it

import Foundation

func L(_ key: String, _ zh: String) -> String {
    Bundle.main.localizedString(forKey: key, value: zh, table: nil)
}

/// With arguments: `Lf("record.saved", "Saved %@", name)`
func Lf(_ key: String, _ zh: String, _ args: CVarArg...) -> String {
    String(format: Bundle.main.localizedString(forKey: key, value: zh, table: nil), arguments: args)
}
