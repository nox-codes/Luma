//
//  LumaTheme.swift
//  leanring-buddy
//
//  Luma dark design system. All UI tokens live here — colors, spacing,
//  corner radii, typography, and animation timing — so every view
//  references a single source of truth.
//

import SwiftUI

// MARK: - LumaTheme

struct LumaTheme {

    // MARK: Backgrounds

    static let background      = Color(hex: "#0E0F0E")   // bg
    static let surface         = Color(hex: "#141614")   // surface1 — cards
    static let surfaceElevated = Color(hex: "#1A1C1A")   // surface2 — sidebar, titlebar

    // MARK: Borders

    static let border      = Color(hex: "#2E322E")   // dividers, card borders
    static let borderFocus = Color(hex: "#3A3F3A")   // focused / hover borders

    // MARK: Text

    static let textPrimary     = Color(hex: "#ECEEED")   // text1
    static let textSecondary   = Color(hex: "#9BA39D")   // text2 — labels
    static let textPlaceholder = Color(hex: "#555D58")   // text3 — placeholder

    // MARK: Accent

    /// Primary accent — white, matching the retro monochrome aesthetic.
    static let accent           = Color(hex: "#FFFFFF")
    /// Foreground drawn on top of accent-colored buttons (near-black text on white).
    static let accentForeground = Color(hex: "#111111")

    // MARK: Semantic

    static let destructive = Color(hex: "#E5484D")   // error
    static let success     = Color(hex: "#34D399")
    static let warning     = Color(hex: "#FFB224")

    // MARK: Input

    static let inputBackground = Color(hex: "#212421")   // surface3 — input fields
    static let inputBorder     = Color(hex: "#2E322E")
    static let inputText       = Color(hex: "#ECEEED")

    // MARK: - Companion Appearance
    //
    // ┌─────────────────────────────────────────────────────────────────────┐
    // │  Change these two values to restyle the floating companion.         │
    // │  Everything — dot, waveform, glow, spinner — updates automatically. │
    // └─────────────────────────────────────────────────────────────────────┘

    /// Color of the floating companion, waveform bars, and glow.
    /// Change the hex value to any colour you like.
    static let companionColor = Color(hex: "#0A84FF") // #0A84FF — Old blue color

    // Shape options — set companionShape and companionMorphTargetShape to any of these:
    //
    //   .circle   — a perfect round dot. Clean, minimal.
    //               Good idle shape when you want something subtle and non-directional.
    //
    //   .capsule  — a pill / stadium shape. Taller than it is wide when the companion
    //               is small (16×16 frame), so it looks like a vertical oval/pill.
    //               Because the frame is square, width == height, making it identical
    //               to a circle at that size. To get a visible pill you must increase
    //               the companion frame size in OverlayWindow.swift (the .frame(width:16,
    //               height:16) line) — e.g. width:24, height:14 for a wide pill, or
    //               width:10, height:20 for a tall pill. The capsule fills whatever
    //               frame it is given and rounds the two shorter ends automatically.
    //
    //   .triangle — equilateral arrow that rotates to face its direction of travel.
    //               Classic cursor look. Best as the morph target so it snaps into
    //               a pointer when the companion flies to a UI element.

    /// Width of the companion shape in points.
    /// For a capsule pill, make width and height different (e.g. width:24, height:14).
    /// For circle/triangle, width and height should be equal.
    static let companionWidth:  CGFloat = 14
    static let companionHeight: CGFloat = 14

    /// Shape of the companion while idle / following the cursor.
    static let companionShape: CompanionShape = .capsule

    // MARK: Companion Morph
    //
    // When the companion navigates to a UI element it morphs into companionMorphTargetShape
    // then morphs back when it returns. Tune the spring feel here.
    //
    // ┌────────────────────────────────────────────────────────────────────────┐
    // │ Change these values to tune how the morph feels.                       │
    // └────────────────────────────────────────────────────────────────────────┘

    /// Shape the companion morphs INTO when navigating to or pointing at a UI element.
    /// .triangle gives the classic pointer look. Can be any CompanionShape.
    static let companionMorphTargetShape: CompanionShape = .triangle

    /// Size of the companion in its morph target (pointing) state.
    /// Interpolated from companionWidth/Height as the morph progresses.
    /// Set equal to companionWidth/Height to keep the size constant during morph.
    static let companionMorphTargetWidth:  CGFloat = 32
    static let companionMorphTargetHeight: CGFloat = 32

    // MARK: Companion Corner Radius
    //
    // Controls how rounded the corners of the companion shape are.
    // Only applies to shapes with corners (.triangle, polygon).
    // .circle and .capsule are already smooth and ignore this value.
    //
    // Good starting values:
    //   .triangle idle,  14pt frame  →  0 (sharp) or 2–4 (soft)
    //   .triangle morph, 32pt frame  →  4–6 (nicely rounded corners)
    //   0 = perfectly sharp corners (fastest, no extra computation)

    /// Corner radius in points for the companion in its idle state.
    /// Only affects .triangle and polygon shapes; .circle/.capsule are already smooth.
    static let companionCornerRadius: CGFloat = 0

    /// Corner radius in points for the companion when it morphs to its target shape.
    /// For the default .triangle morph target at 32pt, 4–6 gives visibly rounded corners.
    static let companionMorphTargetCornerRadius: CGFloat = 6

    // MARK: Companion Morph Target Color

    /// Fill color of the companion after it has fully morphed into its target shape.
    /// Cross-fades with companionColor as the morph progresses.
    /// Set to companionColor to keep a constant fill throughout the morph.
    static let companionMorphTargetColor: Color = Color(hex: "#0A84FF") // changes to blue color on morph

    // MARK: Companion Border (idle state)

    /// Stroke color drawn around the companion in its idle / cursor-following state.
    /// Set width to 0 to disable the border entirely.
    static let companionBorderColor: Color  = .black.opacity(0.5)
    static let companionBorderWidth: CGFloat = 1.0

    // MARK: Companion Border (morph target / pointing state)

    /// Stroke color drawn around the companion after morphing into the target shape.
    /// Cross-fades with the idle border as the morph progresses.
    static let companionMorphTargetBorderColor: Color  = .black.opacity(0.75)
    static let companionMorphTargetBorderWidth: CGFloat = 1.5

    /// Spring response for the morph animation. Lower = faster / snappier.
    static let companionMorphSpringResponse: Double = 0.72
    /// Spring damping for the morph animation. Lower = more bounce. 1.0 = no bounce.
    static let companionMorphSpringDamping: Double = 0.36
    /// Number of outline sample points used to interpolate between shapes.
    /// Higher = smoother morph edge. 24–48 is a good range; rarely needs changing.
    static let companionMorphPointCount: Int = 36

    // Internal alias — existing code uses cursorBlue; this keeps it working
    // without needing to update every call site. Change companionColor above.
    static let cursorBlue = companionColor

    // MARK: Spacing

    static let spacingXS:  CGFloat = 4
    static let spacingSM:  CGFloat = 8
    static let spacingMD:  CGFloat = 16
    static let spacingLG:  CGFloat = 24
    static let spacingXL:  CGFloat = 32
    static let spacingXXL: CGFloat = 40

    // MARK: Padding
    // Use these for view padding (insets), not for spacing between elements.
    // paddingMD (12) ≠ spacingMD (16) — intentional: inputs use tighter insets.

    static let paddingXS:      CGFloat = 4
    static let paddingSM:      CGFloat = 8
    static let paddingMD:      CGFloat = 12
    static let paddingLG:      CGFloat = 16
    static let paddingXL:      CGFloat = 20
    static let paddingXXL:     CGFloat = 24
    static let sectionSpacing: CGFloat = 32

    // MARK: Corner Radius

    static let radiusSM:   CGFloat = 0
    static let radiusMD:   CGFloat = 0
    static let radiusLG:   CGFloat = 0
    static let radiusXL:   CGFloat = 0
    static let radiusFull: CGFloat = 0

    // MARK: Animation Durations (seconds)

    static let animationFast:   Double = 0.15
    static let animationNormal: Double = 0.25
    static let animationSlow:   Double = 0.4

    // MARK: Menu Bar
    //
    // ┌──────────────────────────────────────────────────────────────────────┐
    // │  Change menuBarIconName to any SF Symbol to update the menu bar icon.│
    // │  Browse symbols at: https://developer.apple.com/sf-symbols/          │
    // └──────────────────────────────────────────────────────────────────────┘

    /// SF Symbol name for the Luma menu bar icon. e.g. "sparkles", "brain", "eye.fill"
    static let menuBarIconName = "lightbulb.fill"

    // MARK: Typography

    enum Typography {
        // Body text: SF Pro Text (system default design)
        static let caption    = Font.system(size: 11, weight: .regular, design: .default)
        static let body       = Font.system(size: 13, weight: .regular, design: .default)
        static let bodyMedium = Font.system(size: 13, weight: .medium, design: .default)
        // Headers: SF Pro Display (rounded design for distinction at larger sizes)
        static let headline   = Font.system(size: 15, weight: .semibold, design: .default)
        static let title      = Font.system(size: 20, weight: .bold, design: .default)
        static let largeTitle = Font.system(size: 28, weight: .bold, design: .default)
    }

    // MARK: - Backward Compatibility Shims
    //
    // Views that still use the old nested-enum token paths (LumaTheme.Colors.*,
    // LumaTheme.Spacing.*, etc.) continue to compile via these computed-property
    // aliases. Migrate call-sites to the flat names above over time, then delete
    // these shims.

    enum Colors {
        static var background:       Color { LumaTheme.background }
        static var surface:          Color { LumaTheme.surface }
        static var surfaceElevated:  Color { LumaTheme.surfaceElevated }
        static var primaryText:      Color { LumaTheme.textPrimary }
        static var secondaryText:    Color { LumaTheme.textSecondary }
        static var tertiaryText:     Color { LumaTheme.textPlaceholder }
        static var accent:           Color { LumaTheme.accent }
        static var accentForeground: Color { LumaTheme.accentForeground }
        static var error:            Color { LumaTheme.destructive }
        static var success:          Color { LumaTheme.success }
        static var warning:          Color { LumaTheme.warning }
        static var overlayCursorBlue: Color { LumaTheme.cursorBlue }
        static var panelBackground:  Color { LumaTheme.surface }
        static var borderSubtle:     Color { LumaTheme.border }
        static var textPrimary:      Color { LumaTheme.textPrimary }
        static var textSecondary:    Color { LumaTheme.textSecondary }
        static var textTertiary:     Color { LumaTheme.textPlaceholder }
        static var textOnAccent:     Color { LumaTheme.accentForeground }
        static var inputBackground:  Color { LumaTheme.inputBackground }
        static var blue400:          Color { LumaTheme.cursorBlue }
        static var buttonHover:      Color { LumaTheme.surfaceElevated }
        static var iconTint:         Color { LumaTheme.textSecondary }
        static var panelBorder:      Color { LumaTheme.border }
    }

    enum CornerRadius {
        static var small:      CGFloat { LumaTheme.radiusSM }
        static var medium:     CGFloat { LumaTheme.radiusMD }
        static var large:      CGFloat { LumaTheme.radiusLG }
        static var extraLarge: CGFloat { LumaTheme.radiusXL }
        static var panel:      CGFloat { LumaTheme.radiusLG }
        static var bubble:     CGFloat { LumaTheme.radiusLG }
    }

    enum Spacing {
        static var xs:  CGFloat { LumaTheme.spacingXS }
        static var sm:  CGFloat { LumaTheme.spacingSM }
        static var md:  CGFloat { LumaTheme.spacingMD }
        static var lg:  CGFloat { LumaTheme.spacingLG }
        static var xl:  CGFloat { LumaTheme.spacingXL }
        static var xxl: CGFloat { LumaTheme.spacingXXL }
    }

    enum Animation {
        static var fast:     Double { LumaTheme.animationFast }
        static var standard: Double { LumaTheme.animationNormal }
        static var slow:     Double { LumaTheme.animationSlow }
    }

    enum MenuBar {
        static var iconName: String { LumaTheme.menuBarIconName }
    }
}

// CompanionShape, CompanionTriangle, MorphingCompanionShape, NoiseTextureView,
// ButtonGlowHoverModifier, and glowOnHover are now defined in DesignSystem.swift.

// MARK: - Markdown helper

/// Parses `string` as inline Markdown and returns an `AttributedString` for use in
/// SwiftUI `Text` views. Handles **bold**, *italic*, `code`, and ~~strikethrough~~.
/// Falls back to plain `AttributedString` if parsing fails so callers never crash.
func lumaMarkdown(_ string: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    return (try? AttributedString(markdown: string, options: options)) ?? AttributedString(string)
}
