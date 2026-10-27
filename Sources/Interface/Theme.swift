import AppKit
import SwiftUI

/// Whatever is selected takes the strongest contrast the window allows: white with black text
/// on dark windows, black with white text on light ones. The wheel, the editors and the other
/// windows share one colour, black or white, so the selection is the same everywhere it appears.
/// The wheel's highlighted slice is the one gentler exception: it covers a large part of the wheel.
enum Palette {
    /// The selection: primary buttons and chosen tools.
    static let selection = adaptive(dark: .white, light: NSColor(white: 0.08, alpha: 1))
    static let onSelection = adaptive(dark: NSColor(white: 0.04, alpha: 1), light: .white)
    /// Strokes, rings and selected outlines.
    static let accent = adaptive(dark: NSColor(white: 0.96, alpha: 1), light: NSColor(white: 0.1, alpha: 1))
    /// Tint for switches and sliders: graphite, so the knob stays visible on the track.
    static let controlTint = adaptive(dark: NSColor(white: 0.62, alpha: 1), light: NSColor(white: 0.42, alpha: 1))
    /// The wheel's backdrop when glass is off: a soft black, or white.
    static var wheelSurface: NSColor {
        Settings.lookColor == .white ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.165, alpha: 1)
    }
    /// The wheel's lines, names and icons.
    static var wheelInk: NSColor {
        Settings.lookColor == .white ? NSColor(white: 0.1, alpha: 1) : .white
    }
    /// The highlighted slice: a light veil of the ink, so it is seen on solid grey and on glass alike
    /// without covering them, and the names and icons on it keep the ink. At 0.18 the ink holds
    /// 4.5:1 on it and the veil shows against the surface, even on the thinnest glass over a window of the opposite colour.
    static var wheelSelection: NSColor { wheelInk.withAlphaComponent(0.18) }
    /// The glass, tinted with the chosen colour. The tint never drops below 0.75, enough to keep the ink
    /// at 4.5:1 or better, and the selected slice and the hub readable, even over a window of the opposite
    /// colour; the intensity only raises it to 0.9, short of a solid disc.
    static func glassTint(_ intensity: Double = Settings.glassIntensity) -> NSColor {
        NSColor(white: Settings.lookColor == .white ? 1 : 0, alpha: 0.75 + 0.15 * min(1, max(0, intensity)))
    }
    static var wheelAppearance: NSAppearance? {
        NSAppearance(named: Settings.lookColor == .white ? .aqua : .darkAqua)
    }

    private static func adaptive(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.isDark ? dark : light }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSColor {
    /// Resolves a dynamic colour for a given appearance (CALayer colours are static).
    func cgColor(for appearance: NSAppearance) -> CGColor {
        var result = cgColor
        appearance.performAsCurrentDrawingAppearance { result = self.cgColor }
        return result
    }
}

/// Observable copy of the look settings so open windows update live.
final class LookStore: ObservableObject {
    static let shared = LookStore()

    /// Liquid Glass behind the wheel instead of the solid dark grey.
    @Published var glassWheel: Bool = Settings.glassWheel {
        didSet {
            Settings.glassWheel = glassWheel
            NotificationCenter.default.post(name: LookStore.didChange, object: nil)
        }
    }

    /// How strongly the glass takes on the colour.
    @Published var glassIntensity: Double = Settings.glassIntensity {
        didSet {
            Settings.glassIntensity = glassIntensity
            NotificationCenter.default.post(name: LookStore.didChange, object: nil)
        }
    }

    /// Black or white, for the wheel, the editors and every other window.
    @Published var color: LookColor = Settings.lookColor {
        didSet {
            Settings.lookColor = color
            LookStore.applyColor()
            NotificationCenter.default.post(name: LookStore.didChange, object: nil)
        }
    }

    static let didChange = Notification.Name("SplitLookDidChange")

    static func applyColor() {
        NSApp.appearance = Palette.wheelAppearance
    }

    var accent: Color { Color(nsColor: Palette.accent) }
    var selection: Color { Color(nsColor: Palette.selection) }
    var onSelection: Color { Color(nsColor: Palette.onSelection) }
}

// MARK: - Motion (Apple's fluid-interface defaults)

enum Motion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    /// A spring described like UIKit/SwiftUI (response in seconds, damping ratio), as Core Animation physics.
    static func spring(_ keyPath: String, from: Any?, to: Any?, response: Double = 0.32, damping: Double = 1) -> CAAnimation {
        guard !reduceMotion else {
            let fade = CABasicAnimation(keyPath: keyPath)
            fade.fromValue = to
            fade.toValue = to
            fade.duration = 0.01
            return fade
        }
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / response, 2)
        spring.damping = 4 * .pi * damping / response
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        return spring
    }

    /// Default SwiftUI motion: critically damped spring, or a short cross-fade with Reduce Motion.
    static var standard: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 1)
    }

    /// For moves that follow a flick or a drop: a touch of bounce.
    static var momentum: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.82)
    }
}

/// Haptics only on the trackpad, only for meaningful moments (snapping to a target, committing).
enum Haptics {
    static func snap() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    static func commit() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
}

enum Sounds {
    static func success() { if Settings.playSounds { NSSound(named: "Glass")?.play() } }
    static func failure() { if Settings.playSounds { NSSound(named: "Basso")?.play() } }
}

// MARK: - SwiftUI building blocks

/// Primary action button: the selection's colours, semibold. Like every button here it answers
/// the press at once, shrinking a little in a tenth of a second, and lets go the same way.
struct PrimaryButtonStyle: ButtonStyle {
    @ObservedObject var look = LookStore.shared
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(look.onSelection)
            .padding(.horizontal, 14)
            .frame(minHeight: 28)
            .background(shape.fill(look.selection))
            .overlay(shape.strokeBorder(Color.primary.opacity(Motion.increaseContrast ? 0.6 : 0), lineWidth: 1))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
            .pressable(configuration.isPressed)
    }
}

/// Secondary button: a light fill with a hairline edge, so it reads on dark grey, on glass and
/// in light windows alike; the text a little heavier than body text, as on materials. Compact
/// ones sit in rows of choices.
struct SecondaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .padding(.horizontal, compact ? 10 : 12)
            .frame(minHeight: compact ? 24 : 28)
            .background(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.18 : 0.1)))
            .overlay(shape.strokeBorder(Color.primary.opacity(Motion.increaseContrast ? 0.5 : 0.12), lineWidth: Motion.increaseContrast ? 1 : 0.5))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
            .pressable(configuration.isPressed)
    }
}

/// Square icon button for tool palettes; the selected tool turns white.
struct ToolButtonStyle: ButtonStyle {
    var selected: Bool
    @ObservedObject var look = LookStore.shared

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(selected ? look.onSelection : .primary)
            .frame(width: 30, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? look.selection : Color.primary.opacity(configuration.isPressed ? 0.14 : 0)))
            .contentShape(Rectangle())
            .pressable(configuration.isPressed, scale: 0.94)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension View {
    /// Tooltip and VoiceOver name for a button that only shows a symbol.
    func iconLabel(_ text: String) -> some View {
        help(text).accessibilityLabel(text)
    }

    /// The press answered at once: a little smaller while held, in a tenth of a second. With
    /// Reduce Motion on, it dims instead of moving.
    func pressable(_ pressed: Bool, scale: CGFloat = 0.97) -> some View {
        scaleEffect(pressed && !Motion.reduceMotion ? scale : 1)
            .brightness(pressed && Motion.reduceMotion ? -0.08 : 0)
            .animation(.easeOut(duration: 0.1), value: pressed)
    }

    /// Graphite tint for standard controls (sliders, toggles, pickers).
    func themed() -> some View {
        modifier(ThemedModifier())
    }
}

private struct ThemedModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(Color(nsColor: Palette.controlTint))
            .accentColor(Color(nsColor: Palette.controlTint))
    }
}

/// NSVisualEffectView for SwiftUI (behind-window blur that follows the system appearance).
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        if cornerRadius > 0 { view.maskImage = VisualEffect.roundedMask(cornerRadius) }
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }

    /// A stretchable rounded-rectangle mask, the supported way to round a material.
    static func roundedMask(_ radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
