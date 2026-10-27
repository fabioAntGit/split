import AppKit

// MARK: - Settings

enum Quality: String, CaseIterable {
    case compact, balanced, high

    var label: String {
        switch self {
        case .compact: return L("Compact")
        case .balanced: return L("Balanced")
        case .high: return L("High")
        }
    }

    var lossy: Double {
        switch self {
        case .compact: return 0.6
        case .balanced: return 0.8
        case .high: return 0.92
        }
    }

    var webp: Int { Int(lossy * 100) }

    var audioKbps: String {
        switch self {
        case .compact: return "128k"
        case .balanced: return "192k"
        case .high: return "256k"
        }
    }

    var x264CRF: String {
        switch self {
        case .compact: return "28"
        case .balanced: return "23"
        case .high: return "19"
        }
    }

    var vp9CRF: String {
        switch self {
        case .compact: return "38"
        case .balanced: return "33"
        case .high: return "28"
        }
    }
}

/// How big the wheels are drawn (Settings › Wheels).
enum WheelSize: Int, CaseIterable {
    case extraSmall, small, medium, large, extraLarge

    var label: String {
        switch self {
        case .extraSmall: return L("Extra Small")
        case .small: return L("Small")
        case .medium: return L("Medium")
        case .large: return L("Large")
        case .extraLarge: return L("Extra Large")
        }
    }
}

/// The colour of the wheel, the editors and every other window: a soft black, or white. Glass,
/// when it is on, takes on this colour.
enum LookColor: String, CaseIterable {
    case black, white

    var label: String {
        switch self {
        case .black: return L("Black")
        case .white: return L("White")
        }
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    static var quality: Quality {
        get { Quality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .balanced }
        set { defaults.set(newValue.rawValue, forKey: "quality") }
    }

    static var keepsMetadata: Bool {
        get { defaults.object(forKey: "keepsMetadata") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepsMetadata") }
    }

    static var language: Language {
        get { Language(rawValue: defaults.string(forKey: "language") ?? "") ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: "language")
            // Panels drawn by macOS itself (Open, Save, standard alert buttons) follow from the next launch.
            if newValue == .system {
                defaults.removeObject(forKey: "AppleLanguages")
            } else {
                defaults.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    /// Black until the user picks white, as Split has always looked.
    static var lookColor: LookColor {
        get { LookColor(rawValue: defaults.string(forKey: "lookColor") ?? "") ?? .black }
        set { defaults.set(newValue.rawValue, forKey: "lookColor") }
    }

    /// Liquid Glass behind the wheel (macOS 26), or the closest material before that.
    static var glassWheel: Bool {
        get { defaults.bool(forKey: "glassWheel") }
        set { defaults.set(newValue, forKey: "glassWheel") }
    }

    /// How strongly the glass takes on the colour, from 0 (clear) to 1 (nearly solid).
    static var glassIntensity: Double {
        get { min(1, max(0, defaults.object(forKey: "glassIntensity") as? Double ?? 0.25)) }
        set { defaults.set(min(1, max(0, newValue)), forKey: "glassIntensity") }
    }

    static var wheelSize: WheelSize {
        get { WheelSize(rawValue: defaults.object(forKey: "wheelSize") as? Int ?? -1) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "wheelSize") }
    }

    /// Names under the icons of the slices; without them the wheel shows icons only.
    static var wheelNames: Bool {
        get { defaults.object(forKey: "wheelNames") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "wheelNames") }
    }

    /// What was typed last time in "Compress To…".
    static var lastTargetSize: String {
        get { defaults.string(forKey: "lastTargetSize") ?? "2 MB" }
        set { defaults.set(newValue, forKey: "lastTargetSize") }
    }

    static var playSounds: Bool {
        get { defaults.object(forKey: "playSounds") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "playSounds") }
    }

    /// Word, Excel and PowerPoint keep Office layouts intact when exporting to PDF.
    static var useOfficeApps: Bool {
        get { defaults.object(forKey: "useOfficeApps") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "useOfficeApps") }
    }

    /// The order, hidden slices and groups of one wheel; `key` names the wheel (see WheelScope).
    static func wheelArrangement(_ key: String) -> WheelArrangement {
        WheelArrangement(order: defaults.stringArray(forKey: "wheel.\(key).order") ?? [],
                         hidden: Set(defaults.stringArray(forKey: "wheel.\(key).hidden") ?? []),
                         groups: defaults.data(forKey: "wheel.\(key).groups").flatMap { try? JSONDecoder().decode([WheelGroup].self, from: $0) })
    }

    static func setWheelArrangement(_ arrangement: WheelArrangement, for key: String) {
        store(arrangement.order.isEmpty ? nil : arrangement.order, "wheel.\(key).order")
        store(arrangement.hidden.isEmpty ? nil : arrangement.hidden.sorted(), "wheel.\(key).hidden")
        store(arrangement.groups.flatMap { try? JSONEncoder().encode($0) }, "wheel.\(key).groups")
    }

    private static func store(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    static func modifier(for wheel: WheelKind) -> NSEvent.ModifierFlags {
        if let raw = defaults.object(forKey: "modifier.\(wheel.rawValue)") as? UInt {
            return NSEvent.ModifierFlags(rawValue: raw)
        }
        return wheel.defaultModifier
    }

    static func setModifier(_ flags: NSEvent.ModifierFlags, for wheel: WheelKind) {
        defaults.set(flags.rawValue, forKey: "modifier.\(wheel.rawValue)")
    }
}
