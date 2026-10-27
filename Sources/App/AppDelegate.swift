import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var menuBarItem: NSStatusItem!
    private let dragMonitor = DragMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        LookStore.applyColor()
        MainMenu.install(target: self, settings: #selector(showSettingsAction), about: #selector(openAboutPanel))

        menuBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menuBarItem.button?.image = Logo.menuBarImage()
        menuBarItem.button?.toolTip = "Split"
        let menu = NSMenu()
        menu.delegate = self
        menuBarItem.menu = menu

        dragMonitor.onTrigger = { [weak self] wheel, urls in self?.showWheel(wheel, urls: urls, clickMode: false) }
        dragMonitor.onDragEnded = { WheelController.shared.dragEnded() }
        dragMonitor.start()
        // Menus built once (the app menu) are rebuilt in the new language.
        NotificationCenter.default.addObserver(forName: Localizer.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainMenu.install(target: self, settings: #selector(self.showSettingsAction), about: #selector(self.openAboutPanel))
        }

        if !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            showHelp()
        }
    }

    /// "Open With → Split" or dropping files on the app icon opens a wheel in click mode.
    func application(_ application: NSApplication, open urls: [URL]) {
        let urls = Intake.resolve(urls)
        let kind: WheelKind = WheelCatalog.items(.convert, for: urls).isEmpty ? .tools : .convert
        showWheel(kind, urls: urls, clickMode: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettings() }
        return true
    }

    // MARK: Wheels

    func showWheel(_ kind: WheelKind, urls: [URL], clickMode: Bool) {
        let urls = Intake.resolve(urls)
        let items = WheelCatalog.items(kind, for: urls)
        guard !items.isEmpty else {
            // Say why there's nothing to choose, instead of an empty wheel.
            let allHidden = !WheelCatalog.offered(kind, for: urls).isEmpty
            HUD.shared.showNotice(allHidden ? Explain.allHidden(wheel: kind.title) : Explain.noTargets(urls, tools: kind == .tools))
            return
        }
        let subtitle = urls.count == 1 ? urls[0].lastPathComponent : L("%@ files", urls.count)
        let point = clickMode ? screenCenter() : NSEvent.mouseLocation
        WheelController.shared.show(items: items, title: kind.title, subtitle: subtitle, urls: urls, at: point, clickMode: clickMode)
    }

    private func screenCenter() -> NSPoint {
        let frame = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    private func chooseFiles(for kind: WheelKind) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = kind != .convert
        panel.prompt = L("Choose")
        panel.message = kind.choosePrompt
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        showWheel(kind, urls: panel.urls, clickMode: true)
    }

    // MARK: Menu bar menu (short, like other menu bar extras; settings live in their own window)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(L("Convert Files…"), #selector(convertFiles), symbol: "arrow.triangle.2.circlepath"))
        menu.addItem(item(L("Tools…"), #selector(toolFiles), symbol: "wrench.and.screwdriver"))
        menu.addItem(item(L("Actions…"), #selector(actionFiles), symbol: "square.and.arrow.up"))
        let shelf = item(Shelf.shared.isVisible ? L("Close the Shelf") : L("Open the Shelf"), #selector(toggleShelf), symbol: "tray")
        menu.addItem(shelf)
        let running = ActivityLog.shared.active.count
        menu.addItem(item(running == 0 ? L("Activity…") : L("Activity (%@ running)…", running), #selector(showActivity), symbol: "list.bullet.rectangle"))
        menu.addItem(.separator())

        let shortcuts = WheelKind.allCases.map { "\(ModifierChoice.symbols(Settings.modifier(for: $0))) \($0.title.lowercased())" }.joined(separator: "  ·  ")
        let hint = NSMenuItem(title: L("While dragging, tap: %@", shortcuts), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        menu.addItem(item(L("Settings…"), #selector(showSettingsAction), key: ",", symbol: "gearshape"))
        menu.addItem(item(L("How to Use"), #selector(showHelpAction), symbol: "questionmark.circle"))
        menu.addItem(.separator())
        menu.addItem(item(L("Quit Split"), #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    @objc private func convertFiles() { chooseFiles(for: .convert) }
    @objc private func toolFiles() { chooseFiles(for: .tools) }
    @objc private func actionFiles() { chooseFiles(for: .actions) }
    @objc private func toggleShelf() { Shelf.shared.toggle() }
    @objc private func showHelpAction() { showHelp() }

    @objc private func showSettingsAction() { showSettings() }
    @objc private func showActivity() { showSettings(tab: .activity) }

    func showSettings(tab: SettingsTab? = nil) {
        if let tab { SettingsNavigation.shared.tab = tab }
        Windows.shared.show(title: L("Split Settings"), size: SettingsView.size, minSize: SettingsView.size,
                            id: "settings", resizable: false, content: SettingsView())
    }

    @objc func openAboutPanel() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: L("A local file converter and editor. Everything happens on this Mac, without the Internet."),
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    private func showHelp() {
        var window: NSWindow?
        window = Windows.shared.show(title: L("How to Use"), size: NSSize(width: 540, height: 470), minSize: NSSize(width: 540, height: 400),
                                     id: "help", resizable: false, content: HelpView(close: { window?.close() }))
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
