import Foundation

/// Languages the interface is written in. English is the source language: every text in the
/// code is English and is looked up, as written, in the other languages' tables
/// (`Resources/Localization/<code>.lproj/Localizable.strings`).
enum Language: String, CaseIterable, Identifiable {
    case system, en, pt, fr, es

    var id: String { rawValue }

    /// Each language is named in itself, so it can be found by someone who can't read the current one.
    var nativeName: String {
        switch self {
        case .system: return L("Mac language")
        case .pt: return "Português"
        case .en: return "English"
        case .fr: return "Français"
        case .es: return "Español"
        }
    }

    /// The language actually shown: the chosen one, or the Mac's first supported language
    /// (English when the Mac uses none of them).
    var resolved: Language {
        guard self == .system else { return self }
        for identifier in Locale.preferredLanguages {
            let code = String(identifier.prefix(2))
            if let language = Language(rawValue: code), language != .system { return language }
        }
        return .en
    }

    var locale: Locale {
        switch resolved {
        case .pt: return Locale(identifier: "pt_PT")
        case .fr: return Locale(identifier: "fr_FR")
        case .es: return Locale(identifier: "es_ES")
        default: return Locale(identifier: "en_US")
        }
    }
}

/// Holds the strings of the current language. Thread-safe: jobs build their messages off
/// the main thread. Windows observe it and rebuild when the language changes.
final class Localizer: ObservableObject {
    static let shared = Localizer()
    static let didChange = Notification.Name("SplitLanguageDidChange")

    /// Where the `.lproj` folders are: inside the app bundle, or set by the test runner.
    static var tablesDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Localization")

    @Published var language: Language {
        didSet {
            if persists { Settings.language = language }
            reload()
            NotificationCenter.default.post(name: Localizer.didChange, object: nil)
        }
    }

    /// False when SPLIT_LANGUAGE chose the language for this run only (tests, scripts):
    /// then changing it is never saved.
    private let persists: Bool
    private let lock = NSLock()
    private var table: [String: String] = [:]
    private var currentLocale = Locale(identifier: "en_US")

    init() {
        if let forced = ProcessInfo.processInfo.environment["SPLIT_LANGUAGE"].flatMap(Language.init(rawValue:)) {
            language = forced
            persists = false
        } else {
            language = Settings.language
            persists = true
        }
        reload()
    }

    func reload() {
        let resolved = language.resolved
        let loaded = resolved == .en ? [:] : Localizer.loadTable(resolved)
        lock.lock()
        table = loaded
        currentLocale = language.locale
        lock.unlock()
    }

    static func loadTable(_ language: Language) -> [String: String] {
        guard let url = tablesDirectory?.appendingPathComponent("\(language.rawValue).lproj/Localizable.strings"),
              let data = try? Data(contentsOf: url),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return [:] }
        return table
    }

    func string(_ key: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return table[key] ?? key
    }

    var locale: Locale {
        lock.lock()
        defer { lock.unlock() }
        return currentLocale
    }
}

/// The text for `key` (written in English) in the current language, with each `%@` replaced by
/// the next argument. A translation that needs another order uses `%1$@`, `%2$@`.
func L(_ key: String, _ arguments: Any...) -> String {
    fill(Localizer.shared.string(key), arguments)
}

/// Fills in a format that is already translated, such as one of the pair passed to
/// `JobRunner.phrase` (`L("%@ files converted")` without arguments returns the format).
func fill(_ format: String, _ arguments: [Any]) -> String {
    guard !arguments.isEmpty else { return format }
    let values: [CVarArg] = arguments.map { "\($0)" as NSString }
    return String(format: format, locale: Localizer.shared.locale, arguments: values)
}

/// "A, B and C" in the current language.
func listed(_ items: [String]) -> String {
    let formatter = ListFormatter()
    formatter.locale = Localizer.shared.locale
    return formatter.string(from: items) ?? items.joined(separator: ", ")
}
