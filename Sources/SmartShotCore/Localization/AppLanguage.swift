import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public static let preferenceKey = "interfaceLanguage"

    // Keep one language for the entire session, including AppKit menus and panels.
    public static let current = AppLanguage(
        rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? ""
    ) ?? .english

    public var id: String { rawValue }
    public var locale: Locale { Locale(identifier: rawValue) }

    public var title: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    public static func prepareForLaunch() {
        UserDefaults.standard.set([current.rawValue], forKey: "AppleLanguages")
    }

    public func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.preferenceKey)
        UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
    }
}

public enum L10n {
    private static let bundle: Bundle = {
        guard let path = Bundle.main.path(forResource: AppLanguage.current.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }()

    public static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: AppLanguage.current.locale, arguments: arguments)
    }
}
