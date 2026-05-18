//
//  InkDropBubbleView.swift
//  Luma
//
//  All 6 agent bubble orb styles + the settings picker and sliders.
//  Styles: Aurora · Crystal · Ink Drop · Spectrum · Orbital · Prism Card
//
//  Key public types:
//    AgentOrbView              — dispatcher: shows the correct style orb for the session
//    BubbleStylePickerView     — 3×2 grid style selector (used in settings)
//    BubbleAppearanceSectionView — full settings section (picker + sliders)
//    HaltedAgentPillView       — done / failed / cancelled pill with auto-dismiss
//

import SwiftUI

// MARK: - BlobShape (Ink Drop morphing shape)
//
// Translates CSS `border-radius: tlh% trh% brh% blh% / tlv% trv% brv% blv%` into
// a SwiftUI Shape. Each of the 4 corners is an independent elliptical arc drawn
// with a cubic bezier approximation (magic constant k = 0.5523).
// The 8 radius fractions are VectorArithmetic so SwiftUI can tween them smoothly.

struct BlobRadii: VectorArithmetic {
    var tlh, tlv: Double   // top-left horizontal, vertical
    var trh, trv: Double   // top-right
    var brh, brv: Double   // bottom-right
    var blh, blv: Double   // bottom-left

    static let zero = BlobRadii(tlh: 0, tlv: 0, trh: 0, trv: 0, brh: 0, brv: 0, blh: 0, blv: 0)

    static func + (a: BlobRadii, b: BlobRadii) -> BlobRadii {
        BlobRadii(tlh: a.tlh+b.tlh, tlv: a.tlv+b.tlv, trh: a.trh+b.trh, trv: a.trv+b.trv,
                  brh: a.brh+b.brh, brv: a.brv+b.brv, blh: a.blh+b.blh, blv: a.blv+b.blv)
    }
    static func - (a: BlobRadii, b: BlobRadii) -> BlobRadii {
        BlobRadii(tlh: a.tlh-b.tlh, tlv: a.tlv-b.tlv, trh: a.trh-b.trh, trv: a.trv-b.trv,
                  brh: a.brh-b.brh, brv: a.brv-b.brv, blh: a.blh-b.blh, blv: a.blv-b.blv)
    }
    mutating func scale(by rhs: Double) {
        tlh *= rhs; tlv *= rhs; trh *= rhs; trv *= rhs
        brh *= rhs; brv *= rhs; blh *= rhs; blv *= rhs
    }
    var magnitudeSquared: Double {
        tlh*tlh + tlv*tlv + trh*trh + trv*trv + brh*brh + brv*brv + blh*blh + blv*blv
    }
}

/// A rounded rect whose 4 corners each have independent horizontal + vertical radii.
/// Used by InkDropOrbView to produce organic blob morphing (CSS border-radius equivalent).
struct BlobShape: Shape {
    var radii: BlobRadii
    var animatableData: BlobRadii {
        get { radii }
        set { radii = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let k: CGFloat = 0.5523
        let w = rect.width, h = rect.height
        let TLx = CGFloat(radii.tlh) * w, TLy = CGFloat(radii.tlv) * h
        let TRx = CGFloat(radii.trh) * w, TRy = CGFloat(radii.trv) * h
        let BRx = CGFloat(radii.brh) * w, BRy = CGFloat(radii.brv) * h
        let BLx = CGFloat(radii.blh) * w, BLy = CGFloat(radii.blv) * h

        var p = Path()
        // Start after top-left corner, top edge
        p.move(to: CGPoint(x: rect.minX + TLx, y: rect.minY))
        // Top edge → top-right corner start
        p.addLine(to: CGPoint(x: rect.maxX - TRx, y: rect.minY))
        // Top-right arc
        p.addCurve(to:     CGPoint(x: rect.maxX,       y: rect.minY + TRy),
                   control1: CGPoint(x: rect.maxX - TRx*(1-k), y: rect.minY),
                   control2: CGPoint(x: rect.maxX,       y: rect.minY + TRy*(1-k)))
        // Right edge → bottom-right corner start
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - BRy))
        // Bottom-right arc
        p.addCurve(to:     CGPoint(x: rect.maxX - BRx, y: rect.maxY),
                   control1: CGPoint(x: rect.maxX,       y: rect.maxY - BRy*(1-k)),
                   control2: CGPoint(x: rect.maxX - BRx*(1-k), y: rect.maxY))
        // Bottom edge → bottom-left corner start
        p.addLine(to: CGPoint(x: rect.minX + BLx, y: rect.maxY))
        // Bottom-left arc
        p.addCurve(to:     CGPoint(x: rect.minX,       y: rect.maxY - BLy),
                   control1: CGPoint(x: rect.minX + BLx*(1-k), y: rect.maxY),
                   control2: CGPoint(x: rect.minX,       y: rect.maxY - BLy*(1-k)))
        // Left edge → top-left corner start
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + TLy))
        // Top-left arc
        p.addCurve(to:     CGPoint(x: rect.minX + TLx, y: rect.minY),
                   control1: CGPoint(x: rect.minX,       y: rect.minY + TLy*(1-k)),
                   control2: CGPoint(x: rect.minX + TLx*(1-k), y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// Blob keyframes matching the CSS blobMorph / blobMorphFast animation:
// @keyframes blobMorph {
//   0%,100% { border-radius: 62% 38% 51% 49% / 50% 56% 44% 50% }
//   33%     { border-radius: 38% 62% 39% 61% / 45% 39% 61% 55% }
//   66%     { border-radius: 55% 45% 60% 40% / 38% 55% 45% 62% }
// }
private let blobKeyframes: [BlobRadii] = [
    BlobRadii(tlh: 0.62, tlv: 0.50, trh: 0.38, trv: 0.56, brh: 0.51, brv: 0.44, blh: 0.49, blv: 0.50),
    BlobRadii(tlh: 0.38, tlv: 0.45, trh: 0.62, trv: 0.39, brh: 0.39, brv: 0.61, blh: 0.61, blv: 0.55),
    BlobRadii(tlh: 0.55, tlv: 0.38, trh: 0.45, trv: 0.55, brh: 0.60, brv: 0.45, blh: 0.40, blv: 0.62),
]

/// Returns the interpolated BlobRadii for a 0-3 morph phase (wraps from keyframe 2 back to 0).
private func blobRadii(for phase: Double) -> BlobRadii {
    let count = Double(blobKeyframes.count)
    let wrapped = phase.truncatingRemainder(dividingBy: count)
    let fromIdx = Int(wrapped) % blobKeyframes.count
    let toIdx   = (fromIdx + 1) % blobKeyframes.count
    let t = wrapped - Double(fromIdx)
    let a = blobKeyframes[fromIdx]
    let b = blobKeyframes[toIdx]
    func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
    return BlobRadii(
        tlh: lerp(a.tlh, b.tlh), tlv: lerp(a.tlv, b.tlv),
        trh: lerp(a.trh, b.trh), trv: lerp(a.trv, b.trv),
        brh: lerp(a.brh, b.brh), brv: lerp(a.brv, b.brv),
        blh: lerp(a.blh, b.blh), blv: lerp(a.blv, b.blv)
    )
}

// AgentGlyphView removed — orb styles are purely visual/gradient-based with no icon overlay.

// MARK: - OrbStatusDot

/// 10pt status dot (outside the orb, top-right corner). Pulses when working.
private struct OrbStatusDot: View {
    let sessionStatus: AgentSessionStatus
    @State private var isPulsing = false

    private var dotColor: Color {
        switch sessionStatus {
        case .stopped:  return Color(red: 0.42, green: 0.45, blue: 0.50)
        case .starting: return Color(red: 0.98, green: 0.70, blue: 0.14)
        case .ready:    return Color(red: 0.20, green: 0.83, blue: 0.60)
        case .running:  return Color(red: 0.23, green: 0.51, blue: 0.98)
        case .failed:   return Color(red: 0.93, green: 0.28, blue: 0.30)
        }
    }

    var body: some View {
        let isActive = sessionStatus == .running || sessionStatus == .starting
        ZStack {
            Circle()
                .fill(dotColor.opacity(0.40))
                .frame(width: 16, height: 16)
                .scaleEffect(isPulsing ? 1.6 : 1.0)
                .opacity(isPulsing ? 0.0 : 1.0)
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color(red: 0.04, green: 0.04, blue: 0.06), lineWidth: 1.5))
                .shadow(color: dotColor.opacity(0.70), radius: 4)
        }
        .onAppear { startPulsing(active: isActive) }
        .onChange(of: sessionStatus) { _ in startPulsing(active: isActive) }
    }

    private func startPulsing(active: Bool) {
        withAnimation(
            active
                ? .easeInOut(duration: 1.2).repeatForever(autoreverses: false)
                : .easeOut(duration: 0.3)
        ) { isPulsing = active }
    }
}

// MARK: - 1. Aurora Orb

private struct AuroraOrb: View {
    let session: AgentSession
    let diameter: CGFloat
    let currentTime: TimeInterval
    let isWorking: Bool
    let rotationSpeed: Double   // auroraRotationSpeed setting
    let glowIntensity: Double   // auroraGlowIntensity setting

    var body: some View {
        // Working state always uses the fast 3.5s sweep; idle uses the user-configured speed.
        let rotationDuration: Double = isWorking ? 3.5 : rotationSpeed
        let angle = Angle.degrees(currentTime / rotationDuration * 360)
        // Glow opacity intensifies when working regardless of the idle setting.
        let activeGlow: Double = isWorking ? 0.65 : glowIntensity

        ZStack {
            // Deep background
            Circle()
                .fill(Color(red: 0.04, green: 0.03, blue: 0.09))

            // Primary rotating aurora sweep
            AngularGradient(
                gradient: Gradient(stops: [
                    .init(color: session.glowColor.opacity(activeGlow),         location: 0.00),
                    .init(color: session.glowColor.opacity(0.0),                location: 0.30),
                    .init(color: session.glowColor.opacity(activeGlow * 0.7),   location: 0.55),
                    .init(color: session.glowColor.opacity(0.0),                location: 0.80),
                    .init(color: session.glowColor.opacity(activeGlow),         location: 1.00),
                ]),
                center: .center,
                startAngle: angle,
                endAngle: angle + .degrees(360)
            )
            .blur(radius: diameter * 0.10)

            // Counter-rotating shimmer layer
            AngularGradient(
                gradient: Gradient(stops: [
                    .init(color: Color.white.opacity(0.10), location: 0.00),
                    .init(color: Color.white.opacity(0.0),  location: 0.45),
                    .init(color: Color.white.opacity(0.14), location: 0.70),
                    .init(color: Color.white.opacity(0.0),  location: 1.00),
                ]),
                center: .center,
                startAngle: -angle * 1.3,
                endAngle: -angle * 1.3 + .degrees(360)
            )
            .blur(radius: diameter * 0.12)
            .blendMode(.screen)

            // Thin accent border
            Circle()
                .stroke(session.glowColor.opacity(isWorking ? 0.55 : 0.28), lineWidth: 1)

            // Top-left specular highlight
            Ellipse()
                .fill(Color.white.opacity(0.22))
                .frame(width: diameter * 0.28, height: diameter * 0.16)
                .blur(radius: 3)
                .offset(x: -diameter * 0.12, y: -diameter * 0.18)
                .allowsHitTesting(false)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .shadow(color: Color.black.opacity(0.50), radius: 8, y: 5)
    }
}

// MARK: - 2. Crystal Orb

private struct CrystalOrb: View {
    let session: AgentSession
    let diameter: CGFloat
    let currentTime: TimeInterval
    let isWorking: Bool
    let innerGlow: Double   // crystalInnerGlow setting
    let shimmer: Double     // crystalShimmer setting

    // Flat-top hexagon clip shape
    private struct HexPath: Shape {
        func path(in rect: CGRect) -> Path {
            let cx = rect.midX, cy = rect.midY, r = min(rect.width, rect.height) / 2
            var p = Path()
            for i in 0..<6 {
                let angle = Double(i) * .pi / 3 - .pi / 2
                let pt = CGPoint(x: cx + r * CGFloat(cos(angle)), y: cy + r * CGFloat(sin(angle)))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
            return p
        }
    }

    var body: some View {
        // Working state boosts the inner glow; idle uses the user-configured value.
        let activeInnerGlow: Double = isWorking ? 0.80 : innerGlow

        ZStack {
            // Dark base
            HexPath()
                .fill(Color(red: 0.04, green: 0.04, blue: 0.10))

            // Single clean gradient: top-bright accent fading to deep base
            HexPath()
                .fill(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: session.glowColor.opacity(activeInnerGlow),         location: 0.00),
                            .init(color: session.glowColor.opacity(activeInnerGlow * 0.55),  location: 0.45),
                            .init(color: Color(red: 0.05, green: 0.05, blue: 0.12),          location: 1.00),
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Thin inner border for crystal edge definition
            HexPath()
                .stroke(Color.white.opacity(0.18), lineWidth: 1)

            // Top-left specular glint — intensity driven by crystalShimmer setting
            Ellipse()
                .fill(Color.white.opacity(shimmer))
                .frame(width: diameter * 0.25, height: diameter * 0.14)
                .blur(radius: 2.5)
                .offset(x: -diameter * 0.14, y: -diameter * 0.18)
                .allowsHitTesting(false)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(HexPath())
        .shadow(color: Color.black.opacity(0.55), radius: 6, y: 4)
    }
}

// MARK: - 3. Ink Drop Orb

private struct InkDropOrb: View {
    let session: AgentSession
    let diameter: CGFloat
    let currentTime: TimeInterval
    let isWorking: Bool
    let morphSpeed: Double          // inkDropMorphSpeed setting
    let aggressionAtRest: Double    // inkDropAggressionAtRest setting
    let glowIntensity: Double       // inkDropGlowIntensity setting (0.0 = dim, 1.0 = vivid)

    var body: some View {
        let cycleDuration = isWorking ? morphSpeed : (8.0 - (8.0 - morphSpeed) * aggressionAtRest)
        let phase = (currentTime / cycleDuration).truncatingRemainder(dividingBy: 1.0) * 3.0
        let currentRadii = blobRadii(for: phase)
        // Working state always boosts glow above the user's idle setting for clear activity feedback.
        let glowStrength: Double = isWorking ? max(glowIntensity, 0.55) : glowIntensity

        ZStack {
            // Solid dark backing — prevents the radial gradient's semi-transparent center
            // from showing the desktop through the orb. The gradient blends over this.
            BlobShape(radii: currentRadii)
                .fill(Color(red: 0.08, green: 0.03, blue: 0.14))
                .frame(width: diameter, height: diameter)

            // Blob body — clean radial gradient, no rings.
            // glowStrength drives both inner gradient brightness and outer shadow intensity
            // so the slider visibly affects how vivid the blob's core appears.
            BlobShape(radii: currentRadii)
                .fill(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: session.glowColor.opacity(0.30 + glowStrength * 0.70), location: 0.00),
                            .init(color: session.glowColor.opacity(0.20 + glowStrength * 0.55), location: 0.45),
                            .init(color: Color(red: 0.08, green: 0.03, blue: 0.14),             location: 1.00),
                        ]),
                        center: UnitPoint(x: 0.35, y: 0.28),
                        startRadius: 0,
                        endRadius: diameter * 0.65
                    )
                )
                .overlay(
                    BlobShape(radii: currentRadii)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .frame(width: diameter, height: diameter)

            // Subtle wet-surface highlight
            Ellipse()
                .fill(Color.white.opacity(0.22))
                .frame(width: diameter * 0.30, height: diameter * 0.18)
                .blur(radius: 3)
                .offset(x: -diameter * 0.08, y: -diameter * 0.14)
                .allowsHitTesting(false)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: Color.black.opacity(0.50), radius: 6, y: 4)
    }
}

// MARK: - 4. Spectrum Orb

/// Single waveform bar for SpectrumOrb. Extracted to keep the ForEach closure free of `let` bindings.
private struct SpectrumBar: View {
    let glowColor: Color
    let barIndex: Int
    let barCount: Int
    let currentTime: TimeInterval
    let isWorking: Bool
    let idleAnimationSpeed: Double  // spectrumAnimationSpeed setting

    var body: some View {
        let angle = Double(barIndex) / Double(barCount) * 360.0
        let baseHeight: CGFloat = 3 + CGFloat(barIndex % 4) * 1.5
        // Working uses fixed fast speed (4.0); idle uses the user-configured multiplier.
        let barPhase = currentTime * (isWorking ? 4.0 : idleAnimationSpeed) + Double(barIndex) * 0.45
        let dynamicScale = CGFloat(isWorking
            ? 0.5 + abs(sin(barPhase)) * 1.0
            : 0.3 + abs(sin(barPhase)) * 0.25)
        let barOpacity: Double = isWorking ? 0.90 : 0.35

        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(glowColor)
            .frame(width: 2, height: baseHeight)
            .scaleEffect(x: 1, y: dynamicScale, anchor: .bottom)
            .opacity(barOpacity)
            .rotationEffect(.degrees(angle))
    }
}

private struct SpectrumOrb: View {
    let session: AgentSession
    let diameter: CGFloat
    let currentTime: TimeInterval
    let isWorking: Bool
    let barCount: Int           // spectrumBarCount setting (converted from Double)
    let animationSpeed: Double  // spectrumAnimationSpeed setting
    let glowIntensity: Double   // spectrumGlowIntensity setting (0.0 = dim, 1.0 = vivid)

    var body: some View {
        // Disc shrinks slightly when working so bars have more visual room
        let discDiameter: CGFloat = isWorking ? diameter * 0.72 : diameter * 0.85
        // glowIntensity controls both the inner disc gradient brightness and the outer shadow.
        // Working state always boosts to at least 0.50 so the disc reads clearly while active.
        let activeDiscGlow: Double = isWorking ? max(glowIntensity, 0.50) : glowIntensity
        let outerShadowOpacity: Double = isWorking ? activeDiscGlow * 0.85 : activeDiscGlow * 0.55

        ZStack {
            // Waveform bars — always visible (idle: subtle; working: active)
            ForEach(0..<barCount, id: \.self) { barIndex in
                SpectrumBar(
                    glowColor: session.glowColor,
                    barIndex: barIndex,
                    barCount: barCount,
                    currentTime: currentTime,
                    isWorking: isWorking,
                    idleAnimationSpeed: animationSpeed
                )
                .offset(y: -(discDiameter / 2 + 4))
            }

            // Inner glassy disc — activeDiscGlow drives both gradient brightness and shadow halo.
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: session.glowColor.opacity(0.30 + activeDiscGlow * 0.70), location: 0.00),
                            .init(color: session.glowColor.opacity(0.20 + activeDiscGlow * 0.40), location: 0.50),
                            .init(color: Color(red: 0.04, green: 0.04, blue: 0.10),               location: 1.00),
                        ]),
                        center: UnitPoint(x: 0.30, y: 0.28),
                        startRadius: 0,
                        endRadius: discDiameter * 0.65
                    )
                )
                .frame(width: discDiameter, height: discDiameter)
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: session.glowColor.opacity(activeDiscGlow * 0.7), radius: 8)
                .animation(.easeInOut(duration: 0.35), value: isWorking)

            // Specular highlight
            Ellipse()
                .fill(Color.white.opacity(0.20))
                .frame(width: discDiameter * 0.28, height: discDiameter * 0.16)
                .blur(radius: 2.5)
                .offset(x: -discDiameter * 0.12, y: -discDiameter * 0.16)
                .allowsHitTesting(false)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: Color.black.opacity(0.55), radius: 6, y: 4)
    }
}

// MARK: - 5. Orbital Orb

/// Single orbiting dot for OrbitalOrb. Extracted to avoid `let` bindings inside
/// ViewBuilder closures that cause Swift type-checker timeouts.
private struct OrbitalDot: View {
    let glowColor: Color
    let orbitRadius: CGFloat
    let currentTime: TimeInterval
    let duration: Double
    let phaseOffset: Double
    let dotSize: CGFloat
    let dotOpacity: Double

    var body: some View {
        let angle = Angle.degrees(currentTime / duration * 360 + phaseOffset)
        let x = orbitRadius * CGFloat(cos(angle.radians - .pi / 2))
        let y = orbitRadius * CGFloat(sin(angle.radians - .pi / 2))
        Circle()
            .fill(glowColor.opacity(dotOpacity))
            .frame(width: dotSize, height: dotSize)
            .shadow(color: glowColor.opacity(dotOpacity * 0.9), radius: 4)
            .offset(x: x, y: y)
    }
}

private struct OrbitalOrb: View {
    let session: AgentSession
    let diameter: CGFloat
    let currentTime: TimeInterval
    let isWorking: Bool
    let coreSizeRatio: Double           // orbitalCoreSizeRatio: core diameter fraction (e.g. 0.72)
    let orbitRadiusMultiple: Double     // orbitalOrbitRadiusMultiple: orbit radius as multiple of core radius
    let orbitSpeedSeconds: Double       // orbitalOrbitSpeedSeconds: seconds per revolution at rest
    let glowIntensity: Double           // orbitalGlowIntensity setting (0.0 = dim, 1.0 = vivid)

    var body: some View {
        // Core fills coreSizeRatio of the bubble diameter.
        let coreDiameter: CGFloat = diameter * CGFloat(coreSizeRatio)
        let coreRadius: CGFloat = coreDiameter / 2

        // Orbit radius = core radius × multiple, so orbit visually sits well outside the core.
        // With default multiple=2.0, orbit radius = 2× the core's own radius → clear separation.
        let orbitRadius: CGFloat = coreRadius * CGFloat(orbitRadiusMultiple)

        // glowStrength scales inner gradient brightness and outer shadow together so the
        // Glow Intensity slider visibly affects the core's inner radiance, not just the halo.
        let glowStrength: Double = isWorking ? max(glowIntensity, 0.55) : glowIntensity

        ZStack {
            // Solid white guide ring at the exact orbit radius.
            // All orbiting dots travel on this ring — their centers sit at exactly
            // orbitRadius from the ZStack center, matching the ring's diameter.
            // Increasing orbitRadiusMultiple in settings expands this ring (and moves the dots).
            Circle()
                .stroke(Color.white.opacity(0.20), lineWidth: 0.7)
                .frame(width: orbitRadius * 2, height: orbitRadius * 2)

            // Inner core — large, centered. glowStrength drives gradient brightness
            // so the Glow Intensity slider visibly dims or brightens the core, not just the halo.
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: session.glowColor.opacity(0.30 + glowStrength * 0.70), location: 0.00),
                            .init(color: session.glowColor.opacity(0.15 + glowStrength * 0.25), location: 0.55),
                            .init(color: Color(red: 0.04, green: 0.04, blue: 0.10),             location: 1.00),
                        ]),
                        center: UnitPoint(x: 0.30, y: 0.28),
                        startRadius: 0,
                        endRadius: coreDiameter * 0.60
                    )
                )
                .frame(width: coreDiameter, height: coreDiameter)
                .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
                .shadow(color: session.glowColor.opacity(isWorking ? max(glowIntensity, 0.55) : glowIntensity), radius: 10)

            // Primary orbiting dot — always visible, speeds up when working.
            OrbitalDot(
                glowColor: session.glowColor,
                orbitRadius: orbitRadius,
                currentTime: currentTime,
                duration: isWorking ? 2.0 : orbitSpeedSeconds,
                phaseOffset: 0,
                dotSize: 8,
                dotOpacity: 1.0
            )

            // Second dot appears when working, offset 180° so they appear opposite each other.
            if isWorking {
                OrbitalDot(
                    glowColor: session.glowColor,
                    orbitRadius: orbitRadius,
                    currentTime: currentTime,
                    duration: orbitSpeedSeconds * 0.55,
                    phaseOffset: 180,
                    dotSize: 6,
                    dotOpacity: 0.65
                )
            }
        }
        // Frame matches the bubble diameter — the ring/dots extend visually beyond but
        // SwiftUI doesn't clip them (no clipShape). Keeping the frame at diameter ensures
        // the status dot in AgentOrbView positions at the orb's top-right, not the ring's.
        .frame(width: diameter, height: diameter)
        .shadow(color: Color.black.opacity(0.50), radius: 6, y: 4)
    }
}

// MARK: - 6. Prism Card Orb

private struct PrismCardOrb: View {
    let session: AgentSession
    let diameter: CGFloat
    let currentTime: TimeInterval
    let isWorking: Bool
    let borderPulseRate: Double  // prismBorderPulseRate setting
    let accentGlow: Double       // prismAccentGlow setting

    var body: some View {
        // Border pulses at the user-configured rate when working; static when idle.
        let borderOpacity: Double = isWorking
            ? 0.50 + abs(sin(currentTime * borderPulseRate)) * 0.30
            : 0.25

        ZStack {
            // Solid base prevents the frosted glass gradient's near-transparent top region
            // from letting the desktop show through when the orb is fully opaque.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.05, green: 0.05, blue: 0.10))

            // Frosted glass card background
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: session.glowColor.opacity(0.10),         location: 0.00),
                            .init(color: Color(red: 0.06, green: 0.06, blue: 0.12), location: 0.50),
                            .init(color: Color(red: 0.04, green: 0.04, blue: 0.08), location: 1.00),
                        ]),
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )

            // Accent border — breathes when working
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(session.glowColor.opacity(borderOpacity), lineWidth: 1.5)

            // Inner top highlight line
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                .offset(y: -0.5)

            // Left accent strip — glow intensity driven by prismAccentGlow setting
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [session.glowColor, session.glowColor.opacity(0.40)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 4)
                .shadow(color: session.glowColor.opacity(accentGlow), radius: 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: Color.black.opacity(0.55), radius: 6, y: 4)
    }
}

// MARK: - AgentOrbView (dispatcher)
//
// Renders the correct style orb for a session based on AgentBubbleSettingsManager.
// Each orb receives its own style-specific settings so all parameters are live-configurable.
// Visibility (show/hide) is controlled entirely by the parent (AgentBubbleRootView) using
// SwiftUI transitions — this view does not hold an isExpanded flag.

struct AgentOrbView: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var settingsManager: AgentBubbleSettingsManager = .shared

    var body: some View {
        let settings = settingsManager.settings
        let diameter = CGFloat(settings.bubbleSize)
        let isWorking = session.status == .running || session.status == .starting

        // Rate-limited at idle: orb ambient animations (slow rotation, morph, orbit) are
        // visually smooth at 10fps — saves ~83% render cost vs 60fps when not working.
        let orbFrameInterval: TimeInterval = isWorking ? 1.0/60.0 : 1.0/10.0
        TimelineView(.animation(minimumInterval: orbFrameInterval)) { timeline in
            let currentTime = timeline.date.timeIntervalSinceReferenceDate

            ZStack(alignment: .topTrailing) {
                switch settings.style {
                case .aurora:
                    AuroraOrb(

                        session: session, diameter: diameter, currentTime: currentTime, isWorking: isWorking,
                        rotationSpeed: settings.auroraRotationSpeed,
                        glowIntensity: settings.auroraGlowIntensity
                    )
                case .crystal:
                    CrystalOrb(
                        session: session, diameter: diameter, currentTime: currentTime, isWorking: isWorking,
                        innerGlow: settings.crystalInnerGlow,
                        shimmer: settings.crystalShimmer
                    )
                case .inkDrop:
                    InkDropOrb(
                        session: session, diameter: diameter, currentTime: currentTime, isWorking: isWorking,
                        morphSpeed: settings.inkDropMorphSpeed,
                        aggressionAtRest: settings.inkDropAggressionAtRest,
                        glowIntensity: settings.inkDropGlowIntensity
                    )
                case .spectrum:
                    SpectrumOrb(
                        session: session, diameter: diameter, currentTime: currentTime, isWorking: isWorking,
                        barCount: Int(settings.spectrumBarCount.rounded()),
                        animationSpeed: settings.spectrumAnimationSpeed,
                        glowIntensity: settings.spectrumGlowIntensity
                    )
                case .orbital:
                    OrbitalOrb(
                        session: session, diameter: diameter, currentTime: currentTime, isWorking: isWorking,
                        coreSizeRatio: settings.orbitalCoreSizeRatio,
                        orbitRadiusMultiple: settings.orbitalOrbitRadiusMultiple,
                        orbitSpeedSeconds: settings.orbitalOrbitSpeedSeconds,
                        glowIntensity: settings.orbitalGlowIntensity
                    )
                case .prismCard:
                    PrismCardOrb(
                        session: session, diameter: diameter, currentTime: currentTime, isWorking: isWorking,
                        borderPulseRate: settings.prismBorderPulseRate,
                        accentGlow: settings.prismAccentGlow
                    )
                }

                // Status dot — top-right corner of the orb.
                // OrbitalOrb's frame is `diameter × diameter` (ring/dots render outside without clipping),
                // so this dot correctly aligns with the core's top-right for all styles.
                OrbStatusDot(sessionStatus: session.status)
                    .offset(x: 3, y: -3)
            }
        }
        // bubbleOpacity lets the user dial in transparency from fully solid (1.0) to invisible (0.0).
        // Applied here so the entire orb — including glow and status dot — fades uniformly.
        .opacity(Double(settings.bubbleOpacity))
        // Ensure the whole orb frame responds to gestures (not just non-transparent pixels)
        .contentShape(Rectangle())
    }
}

// MARK: - HaltedAgentPillView

/// Pill shown when a session enters a terminal state (done / failed / cancelled).
/// Auto-dismisses after `dismissDelay` seconds and calls `onDismissed`.
struct HaltedAgentPillView: View {

    enum HaltedReason { case done, failed, cancelled }

    let reason: HaltedReason
    let dismissDelay: Double
    let onDismissed: () -> Void

    @State private var isVisible = true

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(pillColor)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.90))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color(red: 0.08, green: 0.07, blue: 0.12).opacity(0.96))
                .overlay(Capsule().stroke(pillColor.opacity(0.30), lineWidth: 1.0))
        )
        .shadow(color: pillColor.opacity(0.28), radius: 8)
        .opacity(isVisible ? 1.0 : 0.0)
        .scaleEffect(isVisible ? 1.0 : 0.85)
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: isVisible)
        .contentShape(Rectangle())
        .onAppear {
            Task {
                try? await Task.sleep(for: .seconds(dismissDelay))
                withAnimation(.easeOut(duration: 0.4)) { isVisible = false }
                try? await Task.sleep(for: .seconds(0.45))
                onDismissed()
            }
        }
    }

    private var label: String {
        switch reason { case .done: "Done"; case .failed: "Failed"; case .cancelled: "Cancelled" }
    }
    private var iconName: String {
        switch reason { case .done: "checkmark.circle.fill"; case .failed: "xmark.circle.fill"; case .cancelled: "minus.circle.fill" }
    }
    private var pillColor: Color {
        switch reason {
        case .done:      return Color(red: 0.20, green: 0.83, blue: 0.60)
        case .failed:    return Color(red: 0.93, green: 0.28, blue: 0.30)
        case .cancelled: return Color(red: 0.61, green: 0.64, blue: 0.63)
        }
    }
}

// MARK: - StyleAwareMiniIconView
//
// 28pt header avatar for the expanded card. Each bubble style has a distinct
// mini representation that matches the collapsed orb — providing visual continuity
// between the orb (collapsed) and the card header (expanded).

private struct AuroraMiniIconImpl: View {
    let accentColor: Color
    let isWorking: Bool
    let size: CGFloat

    var body: some View {
        // Aurora rotates every 14s at idle — 8fps is visually identical to 60fps for this speed.
        TimelineView(.animation(minimumInterval: isWorking ? 1.0/60.0 : 1.0/8.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let duration: Double = isWorking ? 4.0 : 14.0
            let angle = Angle.degrees(t / duration * 360)
            ZStack {
                Color.black
                // Rotating conic aurora sweep
                AngularGradient(
                    gradient: Gradient(stops: [
                        .init(color: accentColor.opacity(0.90), location: 0.00),
                        .init(color: accentColor.opacity(0.00), location: 0.30),
                        .init(color: accentColor.opacity(0.60), location: 0.55),
                        .init(color: accentColor.opacity(0.00), location: 0.80),
                        .init(color: accentColor.opacity(0.90), location: 1.00),
                    ]),
                    center: .center,
                    startAngle: angle,
                    endAngle: angle + .degrees(360)
                )
                .blur(radius: size * 0.12)
                // Thin accent ring
                Circle().stroke(accentColor.opacity(isWorking ? 0.35 : 0.20), lineWidth: 0.8)
                // Top-left specular highlight
                Ellipse()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: size * 0.30, height: size * 0.18)
                    .blur(radius: 2)
                    .offset(x: -size * 0.12, y: -size * 0.18)
                    .allowsHitTesting(false)
            }
            .clipShape(Circle())
            .frame(width: size, height: size)
        }
    }
}

private struct CrystalMiniIconImpl: View {
    let accentColor: Color
    let size: CGFloat

    private struct HexClipPath: Shape {
        func path(in rect: CGRect) -> Path {
            let cx = rect.midX, cy = rect.midY, r = min(rect.width, rect.height) / 2
            var p = Path()
            for i in 0..<6 {
                let a = Double(i) * .pi / 3 - .pi / 2
                let pt = CGPoint(x: cx + r * CGFloat(cos(a)), y: cy + r * CGFloat(sin(a)))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
            return p
        }
    }

    var body: some View {
        ZStack {
            HexClipPath()
                .fill(LinearGradient(
                    colors: [accentColor, accentColor.opacity(0.20), Color(red: 0.04, green: 0.04, blue: 0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            HexClipPath().stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        }
        .frame(width: size, height: size)
    }
}

private struct InkDropMiniIconImpl: View {
    let accentColor: Color
    let isWorking: Bool
    let size: CGFloat

    var body: some View {
        // Blob morphs over a 9s cycle at idle — 8fps is imperceptible vs 60fps at this speed.
        TimelineView(.animation(minimumInterval: isWorking ? 1.0/60.0 : 1.0/8.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let cycleDuration: Double = isWorking ? 3.0 : 9.0
            let phase = t.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration * 3.0
            let radii = blobRadii(for: phase)
            BlobShape(radii: radii)
                .fill(RadialGradient(
                    colors: [accentColor.opacity(0.90), accentColor.opacity(0.50), accentColor.opacity(0.10)],
                    center: UnitPoint(x: 0.30, y: 0.30),
                    startRadius: 0,
                    endRadius: size * 0.55
                ))
                .overlay(BlobShape(radii: radii).stroke(Color.white.opacity(0.20), lineWidth: 0.8))
                .frame(width: size, height: size)
        }
    }
}

private struct SpectrumMiniIconImpl: View {
    let accentColor: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [accentColor, accentColor.opacity(0.40), Color.black],
                    center: UnitPoint(x: 0.30, y: 0.30),
                    startRadius: 0,
                    endRadius: size * 0.55
                ))
            Circle().stroke(accentColor.opacity(0.30), lineWidth: 0.8)
        }
        .frame(width: size, height: size)
    }
}

private struct OrbitalMiniIconImpl: View {
    let accentColor: Color
    let isWorking: Bool
    let size: CGFloat

    var body: some View {
        // Orbit period is 7s at idle — 10fps gives smooth enough arc interpolation at that speed.
        TimelineView(.animation(minimumInterval: isWorking ? 1.0/60.0 : 1.0/10.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let duration: Double = isWorking ? 2.0 : 7.0
            let angle = Angle.degrees(t / duration * 360)
            let orbitRadius: CGFloat = size * 0.44
            ZStack {
                // Dashed orbit ring
                Circle()
                    .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 0.8, dash: [2, 2.5]))
                    .frame(width: size, height: size)
                // Inner core
                Circle()
                    .fill(RadialGradient(
                        colors: [accentColor.opacity(0.30), Color.black],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.26
                    ))
                    .overlay(Circle().stroke(accentColor.opacity(0.30), lineWidth: 0.8))
                    .frame(width: size * 0.52, height: size * 0.52)
                // Orbiting dot
                Circle()
                    .fill(accentColor)
                    .frame(width: 3.5, height: 3.5)
                    .shadow(color: accentColor, radius: 3)
                    .offset(
                        x: orbitRadius * CGFloat(cos(angle.radians - .pi / 2)),
                        y: orbitRadius * CGFloat(sin(angle.radians - .pi / 2))
                    )
            }
            .frame(width: size, height: size)
        }
    }
}

private struct PrismMiniIconImpl: View {
    let accentColor: Color
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(
                    colors: [accentColor.opacity(0.22), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .stroke(accentColor.opacity(0.35), lineWidth: 0.8)
                )
            // Left accent strip
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(LinearGradient(
                    colors: [accentColor.opacity(0.90), accentColor.opacity(0.60)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: 2.5)
                .shadow(color: accentColor.opacity(0.70), radius: 2)
        }
        .frame(width: size, height: size)
    }
}

/// 28pt header avatar for the expanded agent card. Renders a style-specific mini
/// representation of the collapsed orb — providing visual continuity between the
/// orb (collapsed) and the card header (expanded).
struct StyleAwareMiniIconView: View {
    let style: BubbleStyle
    let accentColor: Color
    let isWorking: Bool
    var size: CGFloat = 28

    var body: some View {
        switch style {
        case .aurora:
            AuroraMiniIconImpl(accentColor: accentColor, isWorking: isWorking, size: size)
        case .crystal:
            CrystalMiniIconImpl(accentColor: accentColor, size: size)
        case .inkDrop:
            InkDropMiniIconImpl(accentColor: accentColor, isWorking: isWorking, size: size)
        case .spectrum:
            SpectrumMiniIconImpl(accentColor: accentColor, size: size)
        case .orbital:
            OrbitalMiniIconImpl(accentColor: accentColor, isWorking: isWorking, size: size)
        case .prismCard:
            PrismMiniIconImpl(accentColor: accentColor, size: size)
        }
    }
}

// MARK: - Style Mini-Preview Tiles

private struct AuroraMiniPreview: View {
    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.03, blue: 0.10)
            AngularGradient(
                colors: [Color(hex: "#A78BFA"), Color(hex: "#A78BFA").opacity(0), Color(hex: "#5EEAD4"), Color(hex: "#A78BFA")],
                center: .center
            )
            .blur(radius: 8)
            .opacity(0.80)
            Circle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 10, height: 6)
                .blur(radius: 3)
                .offset(x: -5, y: -8)
        }
        .clipShape(Circle())
        .frame(width: 40, height: 40)
    }
}

private struct CrystalMiniPreview: View {
    private struct Hex: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            let cx = r.midX, cy = r.midY, rad = min(r.width, r.height) / 2
            for i in 0..<6 {
                let a = Double(i) * .pi / 3 - .pi / 2
                let pt = CGPoint(x: cx + rad * CGFloat(cos(a)), y: cy + rad * CGFloat(sin(a)))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
            return p
        }
    }
    var body: some View {
        ZStack {
            Hex().fill(LinearGradient(colors: [Color(hex: "#60A5FA"), Color(hex: "#60A5FA").opacity(0.25), Color(red:0.04,green:0.04,blue:0.10)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Hex().stroke(Color.white.opacity(0.20), lineWidth: 0.8)
        }
        .frame(width: 40, height: 40)
    }
}

private struct InkDropMiniPreview: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/10.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: 8.0) / 8.0 * 3.0
            let r = blobRadii(for: phase)
            ZStack {
                BlobShape(radii: r)
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: "#3B82F6"), Color(hex: "#1E3A8A").opacity(0.60)],
                            center: UnitPoint(x: 0.35, y: 0.30),
                            startRadius: 0, endRadius: 20
                        )
                    )
                    .overlay(BlobShape(radii: r).stroke(Color.white.opacity(0.15), lineWidth: 0.8))
            }
        }
        .frame(width: 40, height: 40)
    }
}

/// Single mini bar for SpectrumMiniPreview — extracted to avoid ForEach
/// type-check timeouts caused by `let` bindings inside @ViewBuilder closures.
private struct SpectrumMiniBar: View {
    let barIndex: Int
    let currentTime: TimeInterval

    var body: some View {
        let angle = Double(barIndex) / 12.0 * 360.0
        let barHeight: CGFloat = 3 + CGFloat(barIndex % 3) * 2
        let scaleY = CGFloat(0.4 + abs(sin(currentTime * 3 + Double(barIndex) * 0.5)) * 0.7)
        Rectangle()
            .fill(Color(red: 0.51, green: 0.55, blue: 0.97))  // #818CF8 approx
            .frame(width: 1.5, height: barHeight)
            .scaleEffect(x: 1, y: scaleY, anchor: .bottom)
            .rotationEffect(.degrees(angle))
            .offset(y: -16)
    }
}

private struct SpectrumMiniPreview: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/10.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<12, id: \.self) { i in
                    SpectrumMiniBar(barIndex: i, currentTime: t)
                }
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 0.51, green: 0.55, blue: 0.97), Color(red:0.04,green:0.04,blue:0.10)], center: UnitPoint(x:0.3,y:0.3), startRadius: 0, endRadius: 12))
                    .frame(width: 24, height: 24)
            }
        }
        .frame(width: 40, height: 40)
    }
}

private struct OrbitalMiniPreview: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/10.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees(t / 8.0 * 360)
            let r: CGFloat = 17
            ZStack {
                Circle().stroke(Color(hex: "#6366F1").opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [2,3]))
                    .frame(width: 38, height: 38)
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: "#818CF8"), Color(red:0.04,green:0.04,blue:0.10)], center: UnitPoint(x:0.3,y:0.3), startRadius: 0, endRadius: 12))
                    .frame(width: 22, height: 22)
                Circle()
                    .fill(Color(hex: "#818CF8"))
                    .frame(width: 5, height: 5)
                    .shadow(color: Color(hex: "#818CF8"), radius: 3)
                    .offset(x: r * CGFloat(cos(angle.radians - .pi/2)), y: r * CGFloat(sin(angle.radians - .pi/2)))
            }
        }
        .frame(width: 40, height: 40)
    }
}

private struct PrismCardMiniPreview: View {
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "#312E81").opacity(0.60), Color(red:0.05,green:0.05,blue:0.10)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(hex: "#6366F1").opacity(0.35), lineWidth: 0.8))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "#818CF8"), Color(hex: "#4338CA")], startPoint: .top, endPoint: .bottom))
                .frame(width: 4)
                .shadow(color: Color(hex: "#818CF8"), radius: 4)
        }
        .frame(width: 40, height: 40)
    }
}

// MARK: - BubbleStylePickerView

struct BubbleStylePickerView: View {
    @ObservedObject var settingsManager: AgentBubbleSettingsManager = .shared
    // Re-renders the picker when accent theme changes so selected-tile highlights
    // immediately update to the new accent color.
    @AppStorage(LumaAccentTheme.userDefaultsKey) private var accentThemeID: String = LumaAccentTheme.blue.rawValue
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(BubbleStyle.allCases, id: \.self) { style in
                // Button fires on the first click even in non-key windows.
                // onTapGesture requires the window to be key first (double-click behaviour).
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        settingsManager.settings.style = style
                    }
                } label: {
                    StyleTileView(style: style, isSelected: settingsManager.settings.style == style)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct StyleTileView: View {
    let style: BubbleStyle
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.14))
                previewContent
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? DS.Colors.accent : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
            }
            .frame(height: 68)

            VStack(spacing: 2) {
                Text(style.ordinalLabel)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(isSelected ? DS.Colors.accent : Color.white.opacity(0.30))
                Text(style.displayName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : Color.white.opacity(0.55))
            }
        }
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.80), value: isSelected)
        .pointerCursor()
    }

    @ViewBuilder
    private var previewContent: some View {
        switch style {
        case .aurora:    AuroraMiniPreview()
        case .crystal:   CrystalMiniPreview()
        case .inkDrop:   InkDropMiniPreview()
        case .spectrum:  SpectrumMiniPreview()
        case .orbital:   OrbitalMiniPreview()
        case .prismCard: PrismCardMiniPreview()
        }
    }
}

// MARK: - BubbleAppearanceSectionView

/// Settings section embedded in Settings → Agents tab.
/// Shows the style picker and per-style sliders — only the sliders for the currently
/// selected style are shown. Detects style changes in real time via @ObservedObject.
struct BubbleAppearanceSectionView: View {
    @ObservedObject var settingsManager: AgentBubbleSettingsManager = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Bubble Appearance")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(LumaTheme.textPrimary)

            BubbleStylePickerView(settingsManager: settingsManager)

            Divider().background(LumaTheme.border)

            VStack(spacing: 16) {
                // Style-specific controls — update immediately when the style picker changes.
                styleSpecificSliders

                // Shared controls — always visible regardless of style.
                BubbleSlider(
                    label: "Pill Dismiss Delay",
                    detail: "Seconds before done/failed/cancelled pill fades out",
                    value: Binding(get: { settingsManager.settings.pillDismissDelay },
                                   set: { settingsManager.settings.pillDismissDelay = $0 }),
                    range: 1.0...8.0, step: 0.5,
                    formatted: String(format: "%.1fs", settingsManager.settings.pillDismissDelay)
                )
                BubbleSlider(
                    label: "Bubble Size",
                    detail: "Visual diameter of the floating orb",
                    value: Binding(get: { settingsManager.settings.bubbleSize },
                                   set: { settingsManager.settings.bubbleSize = $0 }),
                    range: 48.0...88.0, step: 2.0,
                    formatted: String(format: "%.0fpt", settingsManager.settings.bubbleSize)
                )
                BubbleSlider(
                    label: "Opacity",
                    detail: "Overall orb transparency (100% = fully solid, lower = frosted glass effect)",
                    value: Binding(get: { settingsManager.settings.bubbleOpacity },
                                   set: { settingsManager.settings.bubbleOpacity = $0 }),
                    range: 0.10...1.0, step: 0.01,
                    formatted: String(format: "%.0f%%", settingsManager.settings.bubbleOpacity * 100)
                )
            }
        }
        .padding(20)
        .background(LumaTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: LumaTheme.radiusMD, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LumaTheme.radiusMD, style: .continuous)
                .stroke(LumaTheme.border, lineWidth: 1)
        )
    }

    /// Sliders that are specific to the currently selected bubble style.
    /// Re-renders automatically when `settingsManager.settings.style` changes.
    @ViewBuilder
    private var styleSpecificSliders: some View {
        switch settingsManager.settings.style {

        case .aurora:
            BubbleSlider(
                label: "Rotation Speed",
                detail: "Aurora sweep rotation period at rest (lower = faster)",
                value: Binding(get: { settingsManager.settings.auroraRotationSpeed },
                               set: { settingsManager.settings.auroraRotationSpeed = $0 }),
                range: 2.0...20.0, step: 0.5,
                formatted: String(format: "%.1fs/rev", settingsManager.settings.auroraRotationSpeed)
            )
            BubbleSlider(
                label: "Glow Intensity",
                detail: "Ambient aurora brightness at rest",
                value: Binding(get: { settingsManager.settings.auroraGlowIntensity },
                               set: { settingsManager.settings.auroraGlowIntensity = $0 }),
                range: 0.0...1.0, step: 0.01,
                formatted: String(format: "%.0f%%", settingsManager.settings.auroraGlowIntensity * 100)
            )

        case .crystal:
            BubbleSlider(
                label: "Inner Glow",
                detail: "Gradient brightness inside the hex shape",
                value: Binding(get: { settingsManager.settings.crystalInnerGlow },
                               set: { settingsManager.settings.crystalInnerGlow = $0 }),
                range: 0.1...1.0, step: 0.01,
                formatted: String(format: "%.0f%%", settingsManager.settings.crystalInnerGlow * 100)
            )
            BubbleSlider(
                label: "Shimmer",
                detail: "Top specular highlight intensity on the crystal face",
                value: Binding(get: { settingsManager.settings.crystalShimmer },
                               set: { settingsManager.settings.crystalShimmer = $0 }),
                range: 0.0...1.0, step: 0.01,
                formatted: String(format: "%.0f%%", settingsManager.settings.crystalShimmer * 100)
            )

        case .inkDrop:
            BubbleSlider(
                label: "Morph Speed",
                detail: "Blob cycle duration while working (lower = faster)",
                value: Binding(get: { settingsManager.settings.inkDropMorphSpeed },
                               set: { settingsManager.settings.inkDropMorphSpeed = $0 }),
                range: 0.5...10.0, step: 0.5,
                formatted: String(format: "%.1fs", settingsManager.settings.inkDropMorphSpeed)
            )
            BubbleSlider(
                label: "Aggression at Rest",
                detail: "Idle morph speed (0 = calm, 1 = full working speed)",
                value: Binding(get: { settingsManager.settings.inkDropAggressionAtRest },
                               set: { settingsManager.settings.inkDropAggressionAtRest = $0 }),
                range: 0.0...1.0, step: 0.01,
                formatted: String(format: "%.2f", settingsManager.settings.inkDropAggressionAtRest)
            )
            BubbleSlider(
                label: "Glow Intensity",
                detail: "Outer halo glow strength at rest (0 = dim, 1 = vivid)",
                value: Binding(get: { settingsManager.settings.inkDropGlowIntensity },
                               set: { settingsManager.settings.inkDropGlowIntensity = $0 }),
                range: 0.0...1.0, step: 0.05,
                formatted: String(format: "%.2f", settingsManager.settings.inkDropGlowIntensity)
            )

        case .spectrum:
            BubbleSlider(
                label: "Bar Count",
                detail: "Number of radial waveform bars around the disc",
                value: Binding(get: { settingsManager.settings.spectrumBarCount },
                               set: { settingsManager.settings.spectrumBarCount = $0 }),
                range: 8.0...36.0, step: 2.0,
                formatted: String(format: "%.0f bars", settingsManager.settings.spectrumBarCount)
            )
            BubbleSlider(
                label: "Animation Speed",
                detail: "Idle bar animation speed multiplier",
                value: Binding(get: { settingsManager.settings.spectrumAnimationSpeed },
                               set: { settingsManager.settings.spectrumAnimationSpeed = $0 }),
                range: 0.3...3.0, step: 0.1,
                formatted: String(format: "%.1fx", settingsManager.settings.spectrumAnimationSpeed)
            )
            BubbleSlider(
                label: "Disc Glow",
                detail: "Inner disc glow intensity (0 = dim, 1 = vivid)",
                value: Binding(get: { settingsManager.settings.spectrumGlowIntensity },
                               set: { settingsManager.settings.spectrumGlowIntensity = $0 }),
                range: 0.0...1.0, step: 0.05,
                formatted: String(format: "%.2f", settingsManager.settings.spectrumGlowIntensity)
            )

        case .orbital:
            BubbleSlider(
                label: "Core Size",
                detail: "Central orb diameter as fraction of bubble size",
                value: Binding(get: { settingsManager.settings.orbitalCoreSizeRatio },
                               set: { settingsManager.settings.orbitalCoreSizeRatio = $0 }),
                range: 0.40...0.85, step: 0.01,
                formatted: String(format: "%.0f%%", settingsManager.settings.orbitalCoreSizeRatio * 100)
            )
            BubbleSlider(
                label: "Orbit Radius",
                detail: "Orbit ring distance from core (as multiple of core radius)",
                value: Binding(get: { settingsManager.settings.orbitalOrbitRadiusMultiple },
                               set: { settingsManager.settings.orbitalOrbitRadiusMultiple = $0 }),
                range: 1.2...3.5, step: 0.1,
                formatted: String(format: "%.1fx", settingsManager.settings.orbitalOrbitRadiusMultiple)
            )
            BubbleSlider(
                label: "Orbit Speed",
                detail: "Seconds per orbit revolution at rest",
                value: Binding(get: { settingsManager.settings.orbitalOrbitSpeedSeconds },
                               set: { settingsManager.settings.orbitalOrbitSpeedSeconds = $0 }),
                range: 1.5...15.0, step: 0.5,
                formatted: String(format: "%.1fs/rev", settingsManager.settings.orbitalOrbitSpeedSeconds)
            )
            BubbleSlider(
                label: "Glow Intensity",
                detail: "Core and outer glow brightness",
                value: Binding(get: { settingsManager.settings.orbitalGlowIntensity },
                               set: { settingsManager.settings.orbitalGlowIntensity = $0 }),
                range: 0.0...1.0, step: 0.05,
                formatted: String(format: "%.0f%%", settingsManager.settings.orbitalGlowIntensity * 100)
            )

        case .prismCard:
            BubbleSlider(
                label: "Border Pulse Rate",
                detail: "Border glow pulse frequency when working",
                value: Binding(get: { settingsManager.settings.prismBorderPulseRate },
                               set: { settingsManager.settings.prismBorderPulseRate = $0 }),
                range: 0.5...4.0, step: 0.1,
                formatted: String(format: "%.1f Hz", settingsManager.settings.prismBorderPulseRate)
            )
            BubbleSlider(
                label: "Accent Glow",
                detail: "Left accent strip glow intensity",
                value: Binding(get: { settingsManager.settings.prismAccentGlow },
                               set: { settingsManager.settings.prismAccentGlow = $0 }),
                range: 0.3...1.0, step: 0.05,
                formatted: String(format: "%.0f%%", settingsManager.settings.prismAccentGlow * 100)
            )
        }
    }
}

private struct BubbleSlider: View {
    let label: String
    let detail: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let formatted: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(LumaTheme.textPrimary)
                Spacer()
                Text(formatted)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(LumaTheme.textSecondary)
            }
            Slider(value: $value, in: range, step: step).tint(DS.Colors.accent)
            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(LumaTheme.textPlaceholder)
        }
    }
}
