//
//  DesignSystem.swift
//  leanring-buddy
//
//  Centralized design system using a blue accent palette on dark surfaces,
//  with a unified button style system. All colors, button styles, and
//  interaction states are defined here as the single source of truth.
//

import SwiftUI
import AppKit

enum LumaAccentTheme: String, CaseIterable, Identifiable {
    case blue
    case mint
    case amber
    case rose

    static let userDefaultsKey = "lumaAccentTheme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue:
            return "Blue"
        case .mint:
            return "Mint"
        case .amber:
            return "Amber"
        case .rose:
            return "Rose"
        }
    }

    var accent: Color {
        switch self {
        case .blue:
            return Color(hex: "#2563EB")
        case .mint:
            return Color(hex: "#059669")
        case .amber:
            return Color(hex: "#D97706")
        case .rose:
            return Color(hex: "#E11D48")
        }
    }

    var accentHover: Color {
        switch self {
        case .blue:
            return Color(hex: "#1D4ED8")
        case .mint:
            return Color(hex: "#047857")
        case .amber:
            return Color(hex: "#B45309")
        case .rose:
            return Color(hex: "#BE123C")
        }
    }

    var accentText: Color {
        switch self {
        case .blue:
            return Color(hex: "#60A5FA")
        case .mint:
            return Color(hex: "#34D399")
        case .amber:
            return Color(hex: "#FBBF24")
        case .rose:
            return Color(hex: "#FB7185")
        }
    }

    var cursorColor: Color {
        switch self {
        case .blue:
            return Color(hex: "#3380FF")
        case .mint:
            return Color(hex: "#35D39A")
        case .amber:
            return Color(hex: "#FACC15")
        case .rose:
            return Color(hex: "#FF4F5E")
        }
    }

    var accentSubtle: Color {
        accent.opacity(0.12)
    }

    static var current: LumaAccentTheme {
        let rawValue = UserDefaults.standard.string(forKey: userDefaultsKey) ?? LumaAccentTheme.blue.rawValue
        return LumaAccentTheme(rawValue: rawValue) ?? .blue
    }
}

// MARK: - Design System Namespace

/// The top-level namespace for all design system tokens.
/// Usage: `DS.Colors.background`, `DS.Colors.accent`, etc.
enum DS {

    // MARK: - Color Tokens

    enum Colors {

        // ── Backgrounds ──────────────────────────────────────────────
        // Layered surfaces from deepest to most elevated.
        // Higher surfaces are lighter, creating a sense of depth.

        /// The deepest background — used for the main app window fill.
        static let background = Color(hex: "#101211")

        /// First elevation layer — used for cards, sidebar, top bar backgrounds.
        static let surface1 = Color(hex: "#171918")

        /// Second elevation layer — used for input fields, elevated cards, chat bubbles.
        static let surface2 = Color(hex: "#202221")

        /// Third elevation layer — used for hover backgrounds on interactive elements.
        static let surface3 = Color(hex: "#272A29")

        /// Fourth elevation layer — used for active/pressed states on interactive elements.
        static let surface4 = Color(hex: "#2E3130")

        // ── Borders ──────────────────────────────────────────────────

        /// Subtle border — used for card outlines, dividers, input field borders.
        static let borderSubtle = Color(hex: "#373B39")

        /// Strong border — used for focused inputs, hovered card outlines.
        static let borderStrong = Color(hex: "#444947")

        // ── Text ─────────────────────────────────────────────────────

        /// Primary text — main body text, titles, headings.
        static let textPrimary = Color(hex: "#ECEEED")

        /// Secondary text — descriptions, hints, muted labels.
        static let textSecondary = Color(hex: "#ADB5B2")

        /// Tertiary text — very muted, used for section labels, timestamps, disabled text.
        static let textTertiary = Color(hex: "#6B736F")

        /// Text used on top of the accent fill (#2563eb blue), like the primary button label.
        /// White on #2563eb achieves ~5.1:1 contrast — WCAG AA compliant.
        /// White on #1d4ed8 hover achieves ~6.5:1 — also WCAG AA compliant.
        static let textOnAccent: Color = .white

        // ── Tailwind Blue Scale ─────────────────────────────────────
        // Full Tailwind CSS v4 blue palette for consistent blue usage.
        //
        // Usage guide:
        //   50–100  → Very subtle tinted backgrounds (selected rows, hover fills on dark surfaces)
        //   200–300 → Light text/icons on dark backgrounds, disabled states
        //   400     → Bright accent text, links, icons, chat user bubbles
        //   500     → Mid-tone fills, badges, secondary buttons
        //   600     → Primary action fills (buttons, toggles) — main accent
        //   700     → Hover/pressed state for primary actions
        //   800–900 → Deep backgrounds, dark overlays, header bars
        //   950     → Deepest blue — near-black tinted backgrounds

        static let blue50  = Color(hex: "#eff6ff")
        static let blue100 = Color(hex: "#dbeafe")
        static let blue200 = Color(hex: "#bfdbfe")
        static let blue300 = Color(hex: "#93c5fd")
        static let blue400 = Color(hex: "#60a5fa")
        static let blue500 = Color(hex: "#3b82f6")
        static let blue600 = Color(hex: "#2563eb")
        static let blue700 = Color(hex: "#1d4ed8")
        static let blue800 = Color(hex: "#1e40af")
        static let blue900 = Color(hex: "#1e3a8a")
        static let blue950 = Color(hex: "#172554")

        // ── Accent (derived from blue scale) ───────────────────────
        // The primary fill is Blue 600; hover darkens to Blue 700.

        /// Accent fill — used for solid button backgrounds.
        /// #2563eb → ~5.1:1 contrast with white text (WCAG AA).
        static var accent: Color { LumaAccentTheme.current.accent }

        /// Accent hover — slightly darker blue for hover state.
        /// #1d4ed8 → ~6.5:1 contrast with white text (WCAG AA+).
        static var accentHover: Color { LumaAccentTheme.current.accentHover }

        /// Accent text — bright blue used for accent-colored text and icons
        /// on dark backgrounds (links, active nav items, highlighted labels).
        static var accentText: Color { LumaAccentTheme.current.accentText }

        /// Very subtle accent tint — used for selected item backgrounds (e.g. current step
        /// in the sidebar). Low opacity so it doesn't overpower.
        static var accentSubtle: Color { LumaAccentTheme.current.accentSubtle }

        // ── Semantic Colors ──────────────────────────────────────────

        /// Destructive/error actions — delete buttons, error messages, close button hover.
        static let destructive = Color(hex: "#E5484D")        // Radix Red 9

        /// Destructive hover state.
        static let destructiveHover = Color(hex: "#F2555A")   // Radix Red 10

        /// Destructive used for text on dark backgrounds (brighter for readability).
        static let destructiveText = Color(hex: "#FF6369")    // Radix Red 11

        /// Success — checkmarks, granted status, completion indicators.
        /// Independent green so success states are visually distinct from the blue accent.
        static let success = Color(hex: "#34D399")      // Tailwind Emerald 400

        /// Warning — caution messages, manual verification failure explanations.
        static let warning = Color(hex: "#FFB224")            // Radix Amber 9

        /// Warning text — brighter variant for text on dark backgrounds.
        static let warningText = Color(hex: "#F1A10D")        // Radix Amber 11

        /// Info/feature highlight — used for prompt card headers, code highlights.
        /// Lighter than accentText so informational elements are visually distinct
        /// from interactive accent-colored elements.
        static let info = Color(hex: "#70B8FF")               // Radix Blue 9

        /// Inline code text color — slightly brighter blue for monospace code snippets.
        static let codeText = Color(hex: "#9DC2FF")           // Radix Blue 11 variant

        // ── Overlay Cursor ───────────────────────────────────────────

        /// The cursor/bubble color used in OverlayWindow.
        /// Kept distinct from the accent since it serves a different purpose
        /// (screen overlay vs in-app UI).
        static var overlayCursorBlue: Color { LumaAccentTheme.current.cursorColor }

        // ── Floating Button Gradient ─────────────────────────────────

        /// The floating session button gradient colors (unchanged from original —
        /// this gradient is intentionally distinct from the rest of the palette
        /// to make the floating button stand out as a "jewel" on the desktop).
        static let floatingGradientPurple = Color(hex: "#8F46EB")
        static let floatingGradientPink = Color(hex: "#E84D9E")
        static let floatingGradientOrange = Color(hex: "#FF8C33")

        // ── Help Chat ──────────────────────────────────────────────

        /// User message bubble background in the help chat.
        /// Blue 800 — deep blue that's clearly distinct from the dark surface
        /// while keeping white text highly readable (~9:1 contrast).
        static let helpChatUserBubble = blue800

        /// Slightly lighter variant for hover/pressed states on user bubbles.
        static let helpChatUserBubbleHover = blue700

        /// Footer/backdrop behind the floating help chat.
        /// Slightly lighter than the main window background so the chat zone reads
        /// as a distinct docked surface even before the pill input is visible.
        static let helpChatBackdrop = Color(hex: "#212121")

        // ── Disabled State ───────────────────────────────────────────
        // Following Material Design 3's disabled pattern:
        // Container: onSurface at 12% opacity
        // Content: onSurface at 38% opacity

        /// Disabled button/container background.
        static var disabledBackground: Color {
            textPrimary.opacity(0.12)
        }

        /// Disabled text/icon color.
        static var disabledText: Color {
            textPrimary.opacity(0.38)
        }
    }

    // MARK: - Spacing (for reference, not enforced)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Corner Radii

    enum CornerRadius {
        /// Small elements like tags, badges.
        static let small: CGFloat = 6
        /// Buttons, input fields, small cards.
        static let medium: CGFloat = 8
        /// Cards, dialogs, chat bubbles.
        static let large: CGFloat = 10
        /// Large panels, permission cards.
        static let extraLarge: CGFloat = 12
        /// Pill-shaped buttons (the continue button).
        static let pill: CGFloat = .infinity
    }

    // MARK: - Animation Durations

    enum Animation {
        /// Quick state changes — hover in/out, press feedback.
        static let fast: Double = 0.15
        /// Standard transitions — content reveal, button state changes.
        static let normal: Double = 0.25
        /// Slower, more dramatic — fade-ins, celebration screen elements.
        static let slow: Double = 0.4
    }

    // MARK: - State Layer Opacities
    // Based on Material Design 3's state layer system.
    // A "state layer" overlays the button's content color at these opacities.

    enum StateLayer {
        /// Hover: subtle highlight to indicate interactivity.
        static let hover: Double = 0.08
        /// Focus: keyboard navigation indicator (slightly stronger than hover).
        static let focus: Double = 0.12
        /// Pressed: active press feedback (same strength as focus).
        static let pressed: Double = 0.12
        /// Dragged: strongest overlay (rarely used).
        static let dragged: Double = 0.16
    }
}

// MARK: - Button Styles

/// Primary button — the main call-to-action per screen.
/// Accent-colored background with white text. One per view maximum.
/// Used for: "start"/"resume", "let's go", "continue", "verify completion".
struct DSPrimaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    // Separate state for the scale expansion so it animates on a slower,
    // more gradual timeline (0.6s) than the background color snap (0.15s).
    @State private var isHoverScaleExpanded = false

    // Whether the hover glow shadow is active. Builds up gradually (0.6s)
    // on hover entry, fades out faster (0.3s) on exit.
    @State private var isHoverGlowActive = false

    // Continuously toggles while hovered to drive a gentle breathing pulse
    // in the glow shadow. Creates a living, organic feel — like the button
    // is softly glowing, not just statically lit.
    @State private var isGlowBreathingIn = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textOnAccent)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 14)
            .padding(.horizontal, isFullWidth ? 0 : 20)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            // Hover glow — builds up gradually, then gently breathes while hovered.
            // The breathing oscillates opacity and radius on a slow 2.5s loop,
            // creating a candle-flame-like "alive" quality rather than a static highlight.
            .shadow(
                color: DS.Colors.accent.opacity(
                    isHoverGlowActive ? (isGlowBreathingIn ? 0.32 : 0.18) : 0
                ),
                radius: isHoverGlowActive ? (isGlowBreathingIn ? 16 : 10) : 0
            )
            // Hover: gradually expand to 1.03. Press: snap down to 0.97.
            .scaleEffect(configuration.isPressed ? 0.97 : (isHoverScaleExpanded ? 1.03 : 1.0))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering in
                // Background color — fast snap so the button feels responsive
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = hovering
                }

                // Scale — slow, gradual expansion (like the button is swelling)
                withAnimation(.easeInOut(duration: hovering ? 0.6 : 0.3)) {
                    isHoverScaleExpanded = hovering
                }

                // Glow — builds up gradually on entry, fades faster on exit
                withAnimation(.easeInOut(duration: hovering ? 0.6 : 0.3)) {
                    isHoverGlowActive = hovering
                }

                // Breathing glow loop — gentle pulse while hovered.
                // The 2.5s cycle keeps it feeling organic, not mechanical.
                if hovering {
                    withAnimation(
                        .easeInOut(duration: 2.5)
                        .repeatForever(autoreverses: true)
                    ) {
                        isGlowBreathingIn = true
                    }
                } else {
                    // Override the repeating animation with a finite one to stop cleanly
                    withAnimation(.easeOut(duration: 0.3)) {
                        isGlowBreathingIn = false
                    }
                }

                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            // Pressed: brighten slightly beyond hover
            return DS.Colors.accentHover.blendedWithWhite(fraction: DS.StateLayer.pressed)
        } else if isHovered {
            return DS.Colors.accentHover
        } else {
            return DS.Colors.accent
        }
    }
}

/// Secondary button — supporting actions, less visual weight than primary.
/// Surface-colored background with primary text. Used for: action buttons
/// (download, open link), embedded element buttons.
struct DSSecondaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }
}

/// Tertiary/ghost button — low-emphasis actions with subtle hover background.
/// Transparent at rest, shows surface fill on hover. Used for: navigation
/// links, sidebar items, medium-low emphasis actions.
struct DSTertiaryButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.accentHover
                    : isHovered
                        ? DS.Colors.accentText
                        : DS.Colors.textSecondary
            )
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return Color.clear
        }
    }
}

/// Text button — the lowest-emphasis button style. No background on any
/// state, not even hover. Only the text color changes. Used for: "restart",
/// "skip", "cancel", and other truly minimal inline actions where a
/// background would add too much visual weight.
struct DSTextButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 14

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.textPrimary
                    : isHovered
                        ? DS.Colors.textPrimary
                        : DS.Colors.textTertiary
            )
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

/// Outlined button — medium emphasis, used where a border helps define
/// the button's bounds. Used for: display selector, copy prompt.
struct DSOutlinedButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return DS.Colors.surface1
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.borderStrong
        } else {
            return DS.Colors.borderSubtle
        }
    }
}

/// Destructive button — for dangerous/irreversible actions (close session, delete).
/// Red-tinted background that intensifies on hover and press.
struct DSDestructiveButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(
                isHovered || configuration.isPressed
                    ? .white
                    : DS.Colors.destructiveText
            )
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.destructive.opacity(0.40)
        } else if isHovered {
            return DS.Colors.destructive.opacity(0.30)
        } else {
            return DS.Colors.destructive.opacity(0.10)
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.destructive.opacity(0.40)
        } else {
            return DS.Colors.destructive.opacity(0.15)
        }
    }
}

/// Icon-only button — compact circular button for utility actions.
/// Used for: close button (x), send message, small toolbar actions.
struct DSIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var isDestructiveOnHover: Bool = false
    var tooltipText: String? = nil

    /// Controls horizontal alignment of the tooltip relative to the button.
    /// Use `.leading` for buttons near the left edge of the window (tooltip extends right),
    /// `.trailing` for buttons near the right edge (tooltip extends left),
    /// and `.center` for buttons in the middle.
    var tooltipAlignment: Alignment = .center

    @State private var isHovered = false
    @State private var isTooltipVisible = false
    @State private var tooltipShowWorkItem: DispatchWorkItem? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundColor(iconColor(isPressed: configuration.isPressed))
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(circleBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Circle()
                    .stroke(circleBorderColor(isPressed: configuration.isPressed), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .contentShape(Circle())
            // Cursor change via AppKit cursor rects — more reliable than NSCursor.push/pop
            // because cursor rects are managed at the window level and don't conflict
            // with SwiftUI's internal cursor handling.
            .overlay(PointerCursorView())
            .onHover { hovering in
                isHovered = hovering
                // Show the tooltip after a delay (like native tooltips), hide immediately
                tooltipShowWorkItem?.cancel()
                if hovering {
                    let workItem = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isTooltipVisible = true
                        }
                    }
                    tooltipShowWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
                } else {
                    withAnimation(.easeOut(duration: 0.1)) {
                        isTooltipVisible = false
                    }
                }
            }
            // Custom styled tooltip — positioned above the button with enough gap
            // to not overlap the button. Horizontally aligned based on tooltipAlignment
            // so tooltips near window edges don't clip outside the visible area.
            // Uses .allowsHitTesting(false) so the tooltip doesn't interfere
            // with the button's hover state.
            .overlay(
                Group {
                    if isTooltipVisible, let text = tooltipText, !text.isEmpty {
                        Text(text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(DS.Colors.surface3.opacity(0.85))
                            )
                            .overlay(
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.white.opacity(0.20), lineWidth: 0.8)

                                    RoundedRectangle(cornerRadius: 6)
                                        .trim(from: 0, to: 0.5)
                                        .stroke(
                                            LinearGradient(
                                                colors: [
                                                    Color.white.opacity(0.10),
                                                    Color.white.opacity(0.02)
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                            lineWidth: 0.8
                                        )
                                }
                            )
                            .shadow(color: Color.black.opacity(0.42), radius: 14, x: 0, y: 8)
                            .shadow(color: Color.black.opacity(0.26), radius: 4, x: 0, y: 2)
                            .fixedSize()
                            .offset(y: -(size / 2 + 20))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                },
                alignment: tooltipAlignment
            )
    }

    private func iconColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return .white
        }
        if isPressed {
            return DS.Colors.textPrimary
        } else if isHovered {
            return DS.Colors.textPrimary
        } else {
            return DS.Colors.textSecondary
        }
    }

    private func circleBackgroundColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover {
            if isPressed {
                return DS.Colors.destructive.opacity(0.40)
            } else if isHovered {
                return DS.Colors.destructive.opacity(0.30)
            } else {
                return DS.Colors.surface2
            }
        }
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }

    private func circleBorderColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return DS.Colors.destructive.opacity(0.30)
        }
        if isPressed || isHovered {
            return DS.Colors.borderStrong
        } else {
            return DS.Colors.borderSubtle.opacity(0.5)
        }
    }
}

// MARK: - Convenience View Extensions

extension View {
    /// Applies the primary button style (accent-colored CTA).
    func dsPrimaryButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSPrimaryButtonStyle(isFullWidth: isFullWidth))
    }

    /// Applies the secondary button style (surface-colored supporting action).
    func dsSecondaryButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSSecondaryButtonStyle(isFullWidth: isFullWidth))
    }

    /// Applies the tertiary/ghost button style (subtle hover background).
    func dsTertiaryButtonStyle() -> some View {
        self.buttonStyle(DSTertiaryButtonStyle())
    }

    /// Applies the text-only button style (no background ever, just color change).
    func dsTextButtonStyle(fontSize: CGFloat = 14) -> some View {
        self.buttonStyle(DSTextButtonStyle(fontSize: fontSize))
    }

    /// Applies the outlined button style (bordered, medium emphasis).
    func dsOutlinedButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSOutlinedButtonStyle(isFullWidth: isFullWidth))
    }

    /// Applies the destructive button style (red-tinted danger action).
    func dsDestructiveButtonStyle() -> some View {
        self.buttonStyle(DSDestructiveButtonStyle())
    }

    /// Applies the icon-only button style (compact circle).
    /// `tooltipAlignment` controls where the tooltip sits horizontally relative to the button:
    /// `.leading` for left-edge buttons, `.trailing` for right-edge buttons, `.center` for middle.
    func dsIconButtonStyle(size: CGFloat = 28, isDestructiveOnHover: Bool = false, tooltip: String? = nil, tooltipAlignment: Alignment = .center) -> some View {
        self.buttonStyle(DSIconButtonStyle(size: size, isDestructiveOnHover: isDestructiveOnHover, tooltipText: tooltip, tooltipAlignment: tooltipAlignment))
    }

    /// Attaches the shared pointing-hand cursor treatment used across interactive controls.
    /// Disabled controls can opt out so they keep the default arrow cursor.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        self.overlay {
            if isEnabled {
                PointerCursorView()
            }
        }
    }
}

// MARK: - Luma Composer Visual Style

enum LumaComposerVisualStyle {
    static let waveformLeadingColor = Color(hex: "#F3FBFF")
    static let waveformTrailingColor = Color(hex: "#8FD2FF")
    static let waveformGlowColor = Color(hex: "#AEE3FF")
}

// MARK: - Pointer Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show a pointing hand cursor.
/// More reliable than NSCursor.push()/pop() inside SwiftUI's .onHover because
/// cursor rects are managed at the window level and don't conflict with
/// SwiftUI's internal cursor handling.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - I-Beam Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show an I-beam (text selection) cursor.
/// Same approach as PointerCursorView — cursor rects are managed at the window level
/// and don't conflict with SwiftUI's internal cursor handling.
/// Unlike NSCursor.push()/pop() in .onHover, this avoids cursor stack imbalance
/// when the mouse moves quickly between views.
private class IBeamCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    /// Pass through all mouse events so the TextField underneath still receives
    /// focus, clicks, and text selection. Cursor rects are registered with the
    /// window (via resetCursorRects) and work independently of hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

struct IBeamCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return IBeamCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Native Tooltip

/// Uses AppKit's `NSView.toolTip` to show a tooltip on hover.
/// SwiftUI's `.help()` conflicts with `.onHover` tracking areas, so
/// this bridges directly to AppKit's tooltip system which works independently.
private struct NativeTooltipView: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

extension View {
    /// Attaches a native macOS tooltip that works even alongside `.onHover`.
    func nativeTooltip(_ text: String?) -> some View {
        if let text = text, !text.isEmpty {
            return AnyView(self.overlay(NativeTooltipView(tooltip: text)))
        } else {
            return AnyView(self)
        }
    }
}

// MARK: - Noise Texture View

/// A subtle procedural grain texture overlay generated via Core Image.
/// Renders at low opacity to add visual depth to dark surfaces.
struct NoiseTextureView: View {
    var opacity: Double = 0.03

    var body: some View {
        GeometryReader { geometry in
            if let noiseImage = Self.generateNoiseImage(
                width: Int(geometry.size.width),
                height: Int(geometry.size.height)
            ) {
                Image(nsImage: noiseImage)
                    .resizable()
                    .opacity(opacity)
                    .blendMode(.screen)
            }
        }
        .allowsHitTesting(false)
    }

    /// Generates a grain noise pattern using CIRandomGenerator + CIColorMatrix.
    private static func generateNoiseImage(width: Int, height: Int) -> NSImage? {
        guard width > 0, height > 0 else { return nil }

        let context = CIContext()
        guard let noiseFilter = CIFilter(name: "CIRandomGenerator") else { return nil }
        guard let noiseOutput = noiseFilter.outputImage else { return nil }

        // Reduce the noise to a subtle monochrome grain
        guard let monoFilter = CIFilter(name: "CIColorMatrix") else { return nil }
        monoFilter.setValue(noiseOutput, forKey: kCIInputImageKey)
        monoFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
        monoFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
        monoFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
        monoFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0.1), forKey: "inputAVector")
        monoFilter.setValue(CIVector(x: 0.5, y: 0.5, z: 0.5, w: 0), forKey: "inputBiasVector")

        guard let monoOutput = monoFilter.outputImage else { return nil }

        let croppedOutput = monoOutput.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.createCGImage(croppedOutput, from: croppedOutput.extent) else { return nil }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        return nsImage
    }
}

// MARK: - Button Glow Hover Modifier

/// Adds a subtle accent-colored glow behind a button when hovered.
struct ButtonGlowHoverModifier: ViewModifier {
    var glowColor: Color = LumaAccentTheme.current.accent
    var glowRadius: CGFloat = 8
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small)
                    .fill(glowColor.opacity(isHovering ? 0.12 : 0))
                    .blur(radius: glowRadius)
                    .animation(.easeInOut(duration: 0.2), value: isHovering)
            )
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

extension View {
    /// Applies a subtle glow on hover with a pointing hand cursor.
    func glowOnHover(color: Color = LumaAccentTheme.current.accent, radius: CGFloat = 8) -> some View {
        modifier(ButtonGlowHoverModifier(glowColor: color, glowRadius: radius))
    }
}

// MARK: - Companion Triangle Shape

/// Equilateral triangle used for the companion cursor.
/// Tip points upward at 0° — OverlayWindow rotates it to a cursor-like -35°.
struct CompanionTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size   = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0
        path.move(to:     CGPoint(x: rect.midX,           y: rect.midY - height / 1.5))
        path.addLine(to:  CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        path.addLine(to:  CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

// MARK: - Companion Shape

/// Defines the shape of the floating companion cursor.
enum CompanionShape {
    /// Default arrow-like cursor — rotates to face its direction of travel.
    case triangle
    /// Simple round dot — ignores rotation during flight.
    case circle
    /// Horizontal pill — ignores rotation during flight.
    case capsule

    /// Returns the shape as an AnyShape so it can be used with .fill() and
    /// other Shape modifiers at the call site without knowing the concrete type.
    var asAnyShape: AnyShape {
        switch self {
        case .triangle: return AnyShape(CompanionTriangle())
        case .circle:   return AnyShape(Circle())
        case .capsule:  return AnyShape(Capsule())
        }
    }
}

// MARK: - Companion Configuration

/// All configuration values for the floating companion overlay cursor.
/// These were previously in LumaTheme and are referenced primarily from OverlayWindow.swift.
enum CompanionConfig {

    // MARK: Size

    /// Width of the companion shape in points.
    static let width:  CGFloat = 14
    static let height: CGFloat = 14

    // MARK: Shape

    /// Shape of the companion while idle / following the cursor.
    static let shape: CompanionShape = .capsule

    // MARK: Color

    /// Color of the floating companion, waveform bars, and glow.
    static let color = Color(hex: "#0A84FF")

    // MARK: Border (idle state)

    /// Stroke color drawn around the companion in its idle / cursor-following state.
    static let borderColor: Color  = .white.opacity(0.5)
    static let borderWidth: CGFloat = 1.0

    // MARK: Morph Target

    /// Shape the companion morphs INTO when navigating to or pointing at a UI element.
    static let morphTargetShape: CompanionShape = .triangle

    /// Size of the companion in its morph target (pointing) state.
    static let morphTargetWidth:  CGFloat = 32
    static let morphTargetHeight: CGFloat = 32

    /// Fill color after fully morphing into the target shape.
    static let morphTargetColor: Color = Color(hex: "#0A84FF")

    /// Border in the morph target state.
    static let morphTargetBorderColor: Color  = .white.opacity(0.25)
    static let morphTargetBorderWidth: CGFloat = 1.5

    // MARK: Corner Radius

    /// Corner radius for the companion in its idle state (only affects triangle/polygon).
    static let cornerRadius: CGFloat = 0

    /// Corner radius for the companion when morphed to its target shape.
    static let morphTargetCornerRadius: CGFloat = 6

    // MARK: Morph Animation

    /// Spring response for the morph animation. Lower = faster / snappier.
    static let morphSpringResponse: Double = 0.72
    /// Spring damping for the morph animation. Lower = more bounce. 1.0 = no bounce.
    static let morphSpringDamping: Double = 0.36
    /// Number of outline sample points used to interpolate between shapes.
    static let morphPointCount: Int = 36
}

// MARK: - Morphing Companion Shape

/// A SwiftUI Shape that smoothly morphs between CompanionConfig.shape and a
/// triangle by sampling N evenly-spaced points along each shape's perimeter and
/// linearly interpolating between corresponding points.
///
/// progress = 0  ->  CompanionConfig.shape (idle / following cursor)
/// progress = 1  ->  triangle (navigating to / pointing at a UI element)
struct MorphingCompanionShape: Shape {

    /// 0 = companion's idle shape, 1 = triangle pointer.
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let n = CompanionConfig.morphPointCount
        let fromPoints = Self.sampleShapePoints(CompanionConfig.shape,           in: rect, count: n,
                                                cornerRadius: CompanionConfig.cornerRadius)
        let toPoints   = Self.sampleShapePoints(CompanionConfig.morphTargetShape, in: rect, count: n,
                                                cornerRadius: CompanionConfig.morphTargetCornerRadius)

        let interpolated = zip(fromPoints, toPoints).map { (from, to) -> CGPoint in
            CGPoint(
                x: from.x + (to.x - from.x) * progress,
                y: from.y + (to.y - from.y) * progress
            )
        }

        var path = Path()
        guard let first = interpolated.first else { return path }
        path.move(to: first)
        interpolated.dropFirst().forEach { path.addLine(to: $0) }
        path.closeSubpath()
        return path
    }

    // MARK: Shape Sampling

    private static func sampleShapePoints(_ shape: CompanionShape, in rect: CGRect, count: Int,
                                          cornerRadius: CGFloat = 0) -> [CGPoint] {
        switch shape {
        case .triangle: return sampleTrianglePoints(in: rect, count: count, cornerRadius: cornerRadius)
        case .circle:   return sampleCirclePoints(in: rect, count: count)
        case .capsule:  return sampleCapsulePoints(in: rect, count: count)
        }
    }

    /// N points evenly distributed along the triangle perimeter, starting near the top vertex.
    static func sampleTrianglePoints(in rect: CGRect, count: Int, cornerRadius: CGFloat = 0) -> [CGPoint] {
        let size   = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0
        let top         = CGPoint(x: rect.midX,            y: rect.midY - height / 1.5)
        let bottomRight = CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3)
        let bottomLeft  = CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3)

        guard cornerRadius > 0 else {
            return samplePolygonPerimeter([top, bottomRight, bottomLeft], totalCount: count)
        }

        let vertices: [CGPoint] = [top, bottomRight, bottomLeft]
        let vertexCount = vertices.count
        let inradius = height / 3.0
        let clampedRadius = min(Double(cornerRadius), inradius * 0.85)

        let cgPath = CGMutablePath()
        for i in 0..<vertexCount {
            let prevVertex = vertices[(i + vertexCount - 1) % vertexCount]
            let currVertex = vertices[i]
            let nextVertex = vertices[(i + 1) % vertexCount]

            let dx = currVertex.x - prevVertex.x
            let dy = currVertex.y - prevVertex.y
            let edgeLength = sqrt(dx * dx + dy * dy)
            let inDirX = edgeLength > 0 ? dx / edgeLength : 0
            let inDirY = edgeLength > 0 ? dy / edgeLength : 0

            let tangentStartPoint = CGPoint(x: currVertex.x - inDirX * clampedRadius,
                                            y: currVertex.y - inDirY * clampedRadius)

            if i == 0 {
                cgPath.move(to: tangentStartPoint)
            } else {
                cgPath.addLine(to: tangentStartPoint)
            }

            cgPath.addArc(tangent1End: currVertex, tangent2End: nextVertex, radius: clampedRadius)
        }
        cgPath.closeSubpath()

        return sampleCGPathPoints(cgPath, count: count)
    }

    /// N points evenly distributed around the circle, starting at the top (12 o'clock).
    private static func sampleCirclePoints(in rect: CGRect, count: Int) -> [CGPoint] {
        let cx = rect.midX
        let cy = rect.midY
        let radius = min(rect.width, rect.height) / 2.0
        return (0..<count).map { i in
            let angle = 2.0 * .pi * Double(i) / Double(count) - .pi / 2.0
            return CGPoint(x: cx + radius * cos(angle), y: cy + radius * sin(angle))
        }
    }

    /// N points evenly distributed around the capsule perimeter, starting at the top center.
    private static func sampleCapsulePoints(in rect: CGRect, count: Int) -> [CGPoint] {
        let w = rect.width
        let h = rect.height
        let radius = min(w, h) / 2.0
        let isHorizontal = w >= h
        let straightLength = max(w, h) - 2.0 * radius
        let totalPerimeter = 2.0 * straightLength + 2.0 * .pi * radius

        return (0..<count).map { i in
            let distance = totalPerimeter * Double(i) / Double(count)
            return capsulePoint(
                atDistance: distance,
                isHorizontal: isHorizontal,
                straightLength: straightLength,
                radius: radius,
                midX: Double(rect.midX),
                midY: Double(rect.midY)
            )
        }
    }

    private static func capsulePoint(
        atDistance distance: Double,
        isHorizontal: Bool,
        straightLength: Double,
        radius: Double,
        midX: Double,
        midY: Double
    ) -> CGPoint {
        let half = straightLength / 2.0

        if isHorizontal {
            let seg1End = straightLength
            let seg2End = seg1End + .pi * radius
            let seg3End = seg2End + straightLength

            if distance < seg1End {
                return CGPoint(x: midX - half + distance, y: midY - radius)
            } else if distance < seg2End {
                let angle = (distance - seg1End) / radius - .pi / 2.0
                return CGPoint(x: midX + half + radius * cos(angle), y: midY + radius * sin(angle))
            } else if distance < seg3End {
                return CGPoint(x: midX + half - (distance - seg2End), y: midY + radius)
            } else {
                let angle = (distance - seg3End) / radius + .pi / 2.0
                return CGPoint(x: midX - half + radius * cos(angle), y: midY + radius * sin(angle))
            }
        } else {
            let seg1End = Double.pi * radius
            let seg2End = seg1End + straightLength
            let seg3End = seg2End + .pi * radius

            if distance < seg1End {
                let angle = distance / radius - .pi / 2.0
                return CGPoint(x: midX + radius * cos(angle), y: midY - half + radius * sin(angle))
            } else if distance < seg2End {
                return CGPoint(x: midX + radius, y: midY - half + (distance - seg1End))
            } else if distance < seg3End {
                let angle = (distance - seg2End) / radius + .pi / 2.0
                return CGPoint(x: midX + radius * cos(angle), y: midY + half + radius * sin(angle))
            } else {
                return CGPoint(x: midX - radius, y: midY + half - (distance - seg3End))
            }
        }
    }

    private static func sampleCGPathPoints(_ cgPath: CGPath, count: Int) -> [CGPoint] {
        var lineSegments: [(start: CGPoint, end: CGPoint)] = []
        var currentPoint = CGPoint.zero
        var pathStartPoint = CGPoint.zero

        cgPath.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {

            case .moveToPoint:
                currentPoint   = element.points[0]
                pathStartPoint = currentPoint

            case .addLineToPoint:
                let endPoint = element.points[0]
                lineSegments.append((start: currentPoint, end: endPoint))
                currentPoint = endPoint

            case .addQuadCurveToPoint:
                let controlPoint = element.points[0]
                let endPoint     = element.points[1]
                let subdivisionCount = 8
                for j in 0..<subdivisionCount {
                    let t0 = Double(j)     / Double(subdivisionCount)
                    let t1 = Double(j + 1) / Double(subdivisionCount)
                    let segStart = quadraticBezierPoint(from: currentPoint, control: controlPoint,
                                                        to: endPoint, t: t0)
                    let segEnd   = quadraticBezierPoint(from: currentPoint, control: controlPoint,
                                                        to: endPoint, t: t1)
                    lineSegments.append((start: segStart, end: segEnd))
                }
                currentPoint = endPoint

            case .addCurveToPoint:
                let cp1      = element.points[0]
                let cp2      = element.points[1]
                let endPoint = element.points[2]
                let subdivisionCount = 8
                for j in 0..<subdivisionCount {
                    let t0 = Double(j)     / Double(subdivisionCount)
                    let t1 = Double(j + 1) / Double(subdivisionCount)
                    let segStart = cubicBezierPoint(from: currentPoint, cp1: cp1, cp2: cp2,
                                                    to: endPoint, t: t0)
                    let segEnd   = cubicBezierPoint(from: currentPoint, cp1: cp1, cp2: cp2,
                                                    to: endPoint, t: t1)
                    lineSegments.append((start: segStart, end: segEnd))
                }
                currentPoint = endPoint

            case .closeSubpath:
                if currentPoint != pathStartPoint {
                    lineSegments.append((start: currentPoint, end: pathStartPoint))
                }
                currentPoint = pathStartPoint

            default:
                break
            }
        }

        let segmentLengths = lineSegments.map { hypot($0.end.x - $0.start.x, $0.end.y - $0.start.y) }
        let totalPerimeter = segmentLengths.reduce(0.0, +)
        guard totalPerimeter > 0 else { return Array(repeating: .zero, count: count) }

        return (0..<count).map { sampleIndex in
            var remainingDistance = totalPerimeter * Double(sampleIndex) / Double(count)
            for (segIndex, segment) in lineSegments.enumerated() {
                let segmentLength = segmentLengths[segIndex]
                if remainingDistance <= segmentLength || segIndex == lineSegments.count - 1 {
                    let t = segmentLength > 0 ? min(1.0, remainingDistance / segmentLength) : 0.0
                    return CGPoint(
                        x: segment.start.x + (segment.end.x - segment.start.x) * t,
                        y: segment.start.y + (segment.end.y - segment.start.y) * t
                    )
                }
                remainingDistance -= segmentLength
            }
            return lineSegments.last?.end ?? .zero
        }
    }

    private static func quadraticBezierPoint(from p0: CGPoint, control p1: CGPoint,
                                             to p2: CGPoint, t: Double) -> CGPoint {
        let u = 1.0 - t
        return CGPoint(
            x: u * u * p0.x + 2.0 * u * t * p1.x + t * t * p2.x,
            y: u * u * p0.y + 2.0 * u * t * p1.y + t * t * p2.y
        )
    }

    private static func cubicBezierPoint(from p0: CGPoint, cp1 p1: CGPoint,
                                         cp2 p2: CGPoint, to p3: CGPoint, t: Double) -> CGPoint {
        let u   = 1.0 - t
        let uu  = u * u
        let uuu = uu * u
        let tt  = t * t
        let ttt = tt * t
        return CGPoint(
            x: uuu * p0.x + 3.0 * uu * t * p1.x + 3.0 * u * tt * p2.x + ttt * p3.x,
            y: uuu * p0.y + 3.0 * uu * t * p1.y + 3.0 * u * tt * p2.y + ttt * p3.y
        )
    }

    private static func samplePolygonPerimeter(_ vertices: [CGPoint], totalCount: Int) -> [CGPoint] {
        let vertexCount = vertices.count
        var edgeLengths = [Double]()
        var totalPerimeter = 0.0
        for i in 0..<vertexCount {
            let next = (i + 1) % vertexCount
            let length = hypot(
                Double(vertices[next].x - vertices[i].x),
                Double(vertices[next].y - vertices[i].y)
            )
            edgeLengths.append(length)
            totalPerimeter += length
        }

        return (0..<totalCount).map { sampleIndex in
            var remaining = totalPerimeter * Double(sampleIndex) / Double(totalCount)
            var edgeIndex = 0
            while edgeIndex < vertexCount - 1 && remaining > edgeLengths[edgeIndex] {
                remaining -= edgeLengths[edgeIndex]
                edgeIndex += 1
            }
            let fraction = edgeLengths[edgeIndex] > 0 ? remaining / edgeLengths[edgeIndex] : 0.0
            let a = vertices[edgeIndex]
            let b = vertices[(edgeIndex + 1) % vertexCount]
            return CGPoint(
                x: a.x + (b.x - a.x) * CGFloat(fraction),
                y: a.y + (b.y - a.y) * CGFloat(fraction)
            )
        }
    }
}

// MARK: - Menu Bar Configuration

enum LumaMenuBar {
    /// SF Symbol name for the Luma menu bar icon. e.g. "sparkles", "brain", "eye.fill"
    static let iconName = "lightbulb.fill"
}

// MARK: - Color Utilities

extension Color {
    /// Create a Color from a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    /// Returns a lighter version of this color by blending toward white.
    /// `fraction` is 0.0 (no change) to 1.0 (pure white).
    func blendedWithWhite(fraction: Double) -> Color {
        // Convert to NSColor to access RGB components for blending
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return self }

        let red = nsColor.redComponent + (1.0 - nsColor.redComponent) * fraction
        let green = nsColor.greenComponent + (1.0 - nsColor.greenComponent) * fraction
        let blue = nsColor.blueComponent + (1.0 - nsColor.blueComponent) * fraction

        return Color(red: red, green: green, blue: blue)
    }

    /// Extracts the red, green, blue components as Doubles (0.0–1.0).
    /// Falls back to zero if the color space conversion fails.
    var cgColorComponents: (red: Double, green: Double, blue: Double) {
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else {
            return (red: 0, green: 0, blue: 0)
        }
        return (red: nsColor.redComponent, green: nsColor.greenComponent, blue: nsColor.blueComponent)
    }
}
