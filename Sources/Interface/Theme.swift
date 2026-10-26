import AppKit
import SwiftUI

/// The app has one look: black surfaces, and whatever is selected turns white with black text.
/// Windows always use the dark appearance, so system controls and materials match.
enum Palette {
    /// The selection: highlighted wheel segment, primary buttons, chosen tools (21:1 with `onSelection`).
    static let selection = NSColor.white
    static let onSelection = NSColor(white: 0.04, alpha: 1)
    /// Strokes, rings and selected outlines on dark surfaces.
    static let accent = NSColor(white: 0.96, alpha: 1)
    /// Tint for switches and sliders: graphite, so the white knob stays visible on the track.
    static let controlTint = NSColor(white: 0.62, alpha: 1)
    /// The wheel's solid backdrop when glass is off.
    static let wheelSurface = NSColor(white: 0.06, alpha: 0.97)

    static let appearance = NSAppearance(named: .darkAqua)
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

    /// Liquid Glass behind the wheel instead of solid black.
    @Published var glassWheel: Bool = Settings.glassWheel {
        didSet {
            Settings.glassWheel = glassWheel
            NotificationCenter.default.post(name: LookStore.didChange, object: nil)
        }
    }

    static let didChange = Notification.Name("SplitLookDidChange")

    static func applyAppearance() {
        NSApp.appearance = Palette.appearance
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

/// Primary action button: white with black text, like the selection; pressing scales it down instantly.
struct PrimaryButtonStyle: ButtonStyle {
    @ObservedObject var look = LookStore.shared
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(look.onSelection)
            .padding(.horizontal, 14)
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(look.selection))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Secondary button: quiet fill, same press feedback.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
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
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension View {
    /// Tooltip and VoiceOver name for a button that only shows a symbol.
    func iconLabel(_ text: String) -> some View {
        help(text).accessibilityLabel(text)
    }

    /// Graphite tint for standard controls (sliders, toggles, pickers) and the dark appearance.
    func themed() -> some View {
        modifier(ThemedModifier())
    }
}

private struct ThemedModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(Color(nsColor: Palette.controlTint))
            .accentColor(Color(nsColor: Palette.controlTint))
            .preferredColorScheme(.dark)
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
