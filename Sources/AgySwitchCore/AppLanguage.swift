import Foundation

public enum AppLanguage: String, CaseIterable {
    case system, zhHans, en

    public static let preferenceKey = "appLanguage"

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> DisplayLanguage {
        switch self {
        case .system: return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? .zhHans : .en
        case .zhHans: return .zhHans
        case .en: return .en
        }
    }

    public func menuTitle(in language: DisplayLanguage) -> String {
        switch self {
        case .system: return language[.followSystem]
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }
}

public enum DisplayLanguage: String, CaseIterable {
    case en
    case zhHans = "zh-Hans"

    public subscript(_ label: AppLabel) -> String { label.text.localized(in: self) }
}
