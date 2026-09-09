// The interface language. macOS overrides an app's language through the `AppleLanguages`
// UserDefaults key, and the change needs a restart — the system reads it once at launch and
// then holds on to it.
// and the change needs a restart — the system reads it once at launch and holds on to it.

import Foundation

enum AppLanguage: String, CaseIterable {
    case system, zhHans = "zh-Hans", en, ja, ko, de, fr, es

    var title: String {
        switch self {
        case .system: L("lang.system", "Follow system")
        case .zhHans: "简体中文"
        case .en:     "English"
        case .ja:     "日本語"
        case .ko:     "한국어"
        case .de:     "Deutsch"
        case .fr:     "Français"
        case .es:     "Español"
        }
    }

    @MainActor
    static var current: AppLanguage {
        AppLanguage(rawValue: Preferences.shared.language) ?? .system
    }

    @MainActor
    func apply() {
        Preferences.shared.language = rawValue
        let d = UserDefaults.standard
        if self == .system {
            d.removeObject(forKey: "AppleLanguages")
        } else {
            d.set([rawValue], forKey: "AppleLanguages")
        }
        d.synchronize()
    }
}
