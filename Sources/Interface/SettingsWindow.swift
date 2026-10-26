import AppKit
import ServiceManagement
import SwiftUI

enum ModifierChoice {
    static var all: [(String, NSEvent.ModifierFlags)] { [
        ("⇧ Shift", .shift), ("⌘ Command", .command), ("⌥ Option", .option), ("⌃ Control", .control),
        ("⌃⌥ Control + Option", [.control, .option]), (L("Off"), []),
    ] }

    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        if flags.isEmpty { return "—" }
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text
    }

    /// Each modifier opens one wheel: choosing a taken one swaps the two.
    static func set(_ flags: NSEvent.ModifierFlags, for wheel: WheelKind) {
        if !flags.isEmpty {
            for other in WheelKind.allCases where other != wheel && Settings.modifier(for: other) == flags {
                Settings.setModifier(Settings.modifier(for: wheel), for: other)
            }
        }
        Settings.setModifier(flags, for: wheel)
    }
}

enum SettingsTab: String {
    case general, activity, shortcuts, wheels, engines
}

/// Which tab is showing, so the menu and the HUD can open Settings straight on Activity.
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject var look = LookStore.shared
    @ObservedObject var localizer = Localizer.shared
    @ObservedObject var navigation = SettingsNavigation.shared
    @ObservedObject var log = ActivityLog.shared

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralSettings().tabItem { Label(L("General"), systemImage: "gearshape") }.tag(SettingsTab.general)
            ActivityView().tabItem { Label(activityTitle, systemImage: "list.bullet.rectangle") }.tag(SettingsTab.activity)
            ShortcutSettings().tabItem { Label(L("Shortcuts"), systemImage: "keyboard") }.tag(SettingsTab.shortcuts)
            WheelSettings().tabItem { Label(L("Wheels"), systemImage: "chart.pie") }.tag(SettingsTab.wheels)
            EngineSettings().tabItem { Label(L("Engines"), systemImage: "cpu") }.tag(SettingsTab.engines)
        }
        .padding(.top, 8)
        .frame(width: 600, height: 600)
        // A new language rebuilds every view, so no text is left in the old one.
        .id(localizer.language)
    }

    private var activityTitle: String {
        log.active.isEmpty ? L("Activity") : L("Activity (%@)", String(log.active.count))
    }
}

struct GeneralSettings: View {
    @ObservedObject var look = LookStore.shared
    @ObservedObject var localizer = Localizer.shared
    @State private var quality = Settings.quality
    @State private var metadata = Settings.keepsMetadata
    @State private var office = Settings.useOfficeApps
    @State private var sounds = Settings.playSounds
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Picker(L("Language"), selection: $localizer.language) {
                    ForEach(Language.allCases) { language in
                        Text(language == .system ? "\(language.nativeName) (\(language.resolved.nativeName))" : language.nativeName).tag(language)
                    }
                }
            } header: {
                Text(L("Language"))
            } footer: {
                Text(L("Panels drawn by macOS, such as Open and Save, change the next time Split opens.")).footnote()
            }
            Section {
                HStack(spacing: 18) {
                    BackdropCard(title: L("Black"), glass: false, selected: !look.glassWheel) {
                        withAnimation(Motion.standard) { look.glassWheel = false }
                    }
                    BackdropCard(title: L("Glass"), glass: true, selected: look.glassWheel) {
                        withAnimation(Motion.standard) { look.glassWheel = true }
                    }
                }
                .frame(maxWidth: .infinity)
            } header: {
                Text(L("Wheel Background"))
            } footer: {
                Text(L("Glass lets what is behind show through, like macOS menus. With “Reduce transparency” on in the Accessibility settings, the wheel stays black.")).footnote()
            }
            Section {
                Picker(L("Quality"), selection: $quality) {
                    ForEach(Quality.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: quality) { Settings.quality = $0 }
                Toggle(L("Keep metadata (date, location, camera)"), isOn: $metadata)
                    .onChange(of: metadata) { Settings.keepsMetadata = $0 }
                Toggle(L("Use Word, Excel and PowerPoint when installed"), isOn: $office)
                    .onChange(of: office) { Settings.useOfficeApps = $0 }
            } header: {
                Text(L("Conversion"))
            } footer: {
                Text(L("Office exports PDFs with the exact layout and the file never leaves the Mac, but Word and PowerPoint follow their own rules: they may load pictures or templates the document fetches from the Internet. When off, only the macOS converters are used, and Split removes anything remote first.")).footnote()
            }
            Section {
                Toggle(L("Sounds when done and on errors"), isOn: $sounds)
                    .onChange(of: sounds) { Settings.playSounds = $0 }
                Toggle(L("Open at login"), isOn: $login)
                    .onChange(of: login) { setLogin($0) }
                if let loginError { Text(loginError).font(.system(size: 11)).foregroundColor(.secondary) }
            } header: {
                Text(L("General"))
            }
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Everything happens on this Mac")).font(.system(size: 13, weight: .semibold))
                        Text(L("Split doesn’t use the Internet: it sends no files, has no accounts and collects no usage statistics."))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "lock.shield").foregroundStyle(look.accent).font(.system(size: 18))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = L("macOS refused: %@. The app has to be in Applications (or ~/Applications) to open at login.", error.localizedDescription)
            login = SMAppService.mainApp.status == .enabled
        }
    }
}

struct ShortcutSettings: View {
    @State private var shortcuts: [WheelKind: UInt] = Dictionary(uniqueKeysWithValues: WheelKind.allCases.map { ($0, Settings.modifier(for: $0).rawValue) })

    var body: some View {
        Form {
            Section {
                ForEach(WheelKind.allCases, id: \.self) { wheel in
                    Picker(wheel.title, selection: Binding(
                        get: { shortcuts[wheel] ?? 0 },
                        set: { value in
                            ModifierChoice.set(NSEvent.ModifierFlags(rawValue: value), for: wheel)
                            for kind in WheelKind.allCases { shortcuts[kind] = Settings.modifier(for: kind).rawValue }
                        })) {
                        ForEach(ModifierChoice.all, id: \.1.rawValue) { choice in
                            Text(choice.0).tag(choice.1.rawValue)
                        }
                    }
                }
            } header: {
                Text(L("While Dragging"))
            } footer: {
                Text(L("Start dragging files and, without letting go, tap the key once. The wheel appears around the pointer. Each key opens one wheel only: choosing one that is taken swaps the two.")).footnote()
            }
            Section(L("Without Dragging")) {
                Text(L("Use “Open With › Split” in Finder, or the menu bar menu (Convert, Tools, Actions)."))
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

struct EngineSettings: View {
    var body: some View {
        Form {
            if let command = Engines.missingPackagesCommand {
                Section {
                    CommandRow(title: L("Install everything that is missing"),
                               detail: Engines.path("brew") == nil ? L("Install Homebrew first (brew.sh), then paste the command in Terminal.") : L("Paste the command in Terminal."),
                               command: command)
                }
            }
            Section {
                EngineRow(name: "ffmpeg", purpose: L("Audio, video, GIF and subtitles"), ok: Engines.path("ffmpeg") != nil, install: "brew install ffmpeg")
                EngineRow(name: "cwebp / gif2webp", purpose: L("WebP images"), ok: Engines.path("cwebp") != nil, install: "brew install webp")
                EngineRow(name: "cjxl / djxl", purpose: L("JPEG XL images"), ok: Engines.path("cjxl") != nil, install: "brew install jpeg-xl")
                EngineRow(name: "exiftool", purpose: L("Removing image metadata"), ok: Engines.path("exiftool") != nil, install: "brew install exiftool")
                EngineRow(name: "LibreOffice", purpose: L("An alternative for ODS, ODP and PPT"), ok: Engines.soffice != nil, install: "brew install --cask libreoffice", optional: true)
            } header: {
                Text(L("Programs (Homebrew)"))
            } footer: {
                Text(L("Installed once from Homebrew. After that they work without the Internet.")).footnote()
            }
            Section(L("Mac Apps")) {
                EngineRow(name: "Pages", purpose: L(".pages files"), ok: Engines.pages, install: nil, optional: true)
                EngineRow(name: "Numbers", purpose: L("XLS and .numbers"), ok: Engines.numbers, install: nil, optional: true)
                EngineRow(name: "Keynote", purpose: L("Keynote and PPTX → PDF"), ok: Engines.keynote, install: nil, optional: true)
                EngineRow(name: "Word", purpose: L("DOCX → PDF with the exact layout"), ok: Engines.word, install: nil, optional: true)
                EngineRow(name: "Excel", purpose: L("XLS/XLSX → PDF and XLSX"), ok: Engines.excel, install: nil, optional: true)
                EngineRow(name: "PowerPoint", purpose: L("PPTX/PPT → PDF"), ok: Engines.powerPoint, install: nil, optional: true)
            }
            Section {
                EngineRow(name: "splitapp", purpose: L("Conversions and tools from Terminal"), ok: CommandLineTool.isInstalled,
                          install: CommandLineTool.installCommand, optional: true)
            } header: {
                Text(L("Terminal"))
            } footer: {
                Text(L("The command links to this copy of the app, so “splitapp convert pdf file.docx” works in Terminal.")).footnote()
            }
            Section {
                Label(L("ImageIO, PDFKit, Vision (OCR, QR codes, faces, subject cut-out) and the Cocoa text converter"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
            } header: {
                Text(L("Included in macOS"))
            } footer: {
                Text(L("Libraries that are part of macOS and run on this Mac, with no Internet connection.")).footnote()
            }
        }
        .formStyle(.grouped)
    }
}

struct EngineRow: View {
    let name: String
    let purpose: String
    let ok: Bool
    let install: String?
    var optional = false
    @ObservedObject var look = LookStore.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : (optional ? "minus.circle" : "xmark.circle.fill"))
                .foregroundStyle(ok ? look.accent : (optional ? Color.secondary : Color.primary))
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text(ok ? purpose : (optional ? L("Optional · %@", purpose) : L("Missing · %@", purpose)))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            if !ok, let install {
                Button(L("Copy Command")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(install, forType: .string)
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
                .help(install)
            }
        }
    }
}

/// A command to paste in Terminal, with a button that copies it.
struct CommandRow: View {
    let title: String
    let detail: String
    let command: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Text(detail).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            Button(L("Copy Command")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .buttonStyle(PrimaryButtonStyle())
            .controlSize(.small)
        }
    }
}

/// A miniature wheel on each backdrop, like the appearance previews in System Settings.
struct BackdropCard: View {
    let title: String
    let glass: Bool
    let selected: Bool
    let action: () -> Void
    @ObservedObject var look = LookStore.shared

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                WheelPreview(glass: glass)
                    .frame(width: 150, height: 96)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(
                        LinearGradient(colors: [Color(white: 0.32), Color(white: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(selected ? look.accent : .clear, lineWidth: 3))
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct WheelPreview: View {
    let glass: Bool

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2 - 6
            let inner = outer * 0.36
            let disc = Path(ellipseIn: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
            if glass {
                context.fill(disc, with: .linearGradient(Gradient(colors: [Color.white.opacity(0.34), Color.white.opacity(0.12)]),
                                                         startPoint: CGPoint(x: center.x - outer, y: center.y - outer),
                                                         endPoint: CGPoint(x: center.x + outer, y: center.y + outer)))
                context.stroke(disc, with: .color(Color.white.opacity(0.55)), lineWidth: 0.75)
            } else {
                context.fill(disc, with: .color(Color(nsColor: Palette.wheelSurface)))
                context.stroke(disc, with: .color(Color.white.opacity(0.14)), lineWidth: 0.5)
            }
            let count = 8
            for index in 0..<count {
                let start = Angle.degrees(Double(index) * 360 / Double(count) - 90)
                let end = Angle.degrees(Double(index + 1) * 360 / Double(count) - 90)
                var segment = Path()
                segment.addArc(center: center, radius: outer - 3, startAngle: start + .degrees(2), endAngle: end - .degrees(2), clockwise: false)
                segment.addArc(center: center, radius: inner + 3, startAngle: end - .degrees(4), endAngle: start + .degrees(4), clockwise: true)
                segment.closeSubpath()
                if index == 1 {
                    context.fill(segment, with: .color(Color(nsColor: Palette.selection)))
                } else {
                    context.stroke(segment, with: .color(Color.white.opacity(0.14)), lineWidth: 0.5)
                }
            }
            context.fill(Path(ellipseIn: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2)),
                         with: .color(Color.white.opacity(0.08)))
        }
    }
}

// MARK: - How to use

struct HelpView: View {
    @ObservedObject var look = LookStore.shared
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("How to Use Split")).font(.system(size: 20, weight: .bold))
                    Text(L("Convert and edit files without leaving what you are doing.")).foregroundColor(.secondary)
                }
            }
            step(1, L("Start dragging files"), L("In Finder, on the desktop or in another app. Don’t let go."))
            VStack(alignment: .leading, spacing: 10) {
                step(2, L("Tap a key once"), L("A wheel appears around the pointer:"))
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(WheelKind.allCases, id: \.self) { wheel in
                        HStack(spacing: 10) {
                            KeyCap(text: ModifierChoice.symbols(Settings.modifier(for: wheel)))
                            Text(wheel.title).font(.system(size: 13, weight: .medium))
                            Text(wheel.summary).font(.system(size: 12)).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.leading, 40)
            }
            step(3, L("Drop on the slice you want"), L("The result is saved next to the original. The original is never changed."))
            if Engines.missingPackagesCommand != nil {
                Label(L("Audio, video, WebP, JPEG XL and metadata removal need free programs from Homebrew. Settings › Engines has the command that installs them."),
                      systemImage: "shippingbox")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Label(L("Everything happens on this Mac, without the Internet."), systemImage: "lock.shield")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
                Button(L("Get Started"), action: close)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 540)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(look.onSelection)
                .frame(width: 26, height: 26)
                .background(Circle().fill(look.selection))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
    }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .frame(minWidth: 30, minHeight: 26)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 0, x: 0, y: 1)
    }
}

private extension View {
    /// Section footers wrap in full and read left-aligned, never cut with an ellipsis.
    func footnote() -> some View {
        foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
