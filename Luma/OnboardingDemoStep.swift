//
//  OnboardingDemoStep.swift
//  Luma
//
//  Wizard step 5: plays a local demo video from the app bundle.
//
//  To add the video:
//  1. Drag your video file into the Xcode project (any target membership).
//  2. Name the resource "LumaDemo" with extension "mp4" (or adjust the
//     resource name/extension constants below if you use a different name).
//
//  The user can skip the video at any time or wait for it to finish —
//  both paths call onSkipOrContinue() to advance to the Done step.
//

import AVKit
import SwiftUI

@MainActor
struct OnboardingDemoStep: View {

    /// Called when the user taps "Continue" or "Skip" — advances to Done step.
    var onSkipOrContinue: () -> Void

    // MARK: - State

    /// The AVPlayer driving the demo video. Nil when the video file is not found in the bundle.
    @State private var videoPlayer: AVPlayer? = nil

    // MARK: - Constants

    /// Bundle resource name (without extension) for the demo video.
    private let videoBundleResourceName = "LumaDemo"
    /// File extension of the demo video in the bundle.
    private let videoBundleResourceExtension = "mp4"

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            VStack(alignment: .leading, spacing: 6) {
                Text("See Luma in action")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Color(hex: "#ECEEED"))
                Text("Watch the demo, then click Continue when you're ready.")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#9BA39D"))
            }
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 20)

            // Video player area
            Group {
                if let player = videoPlayer {
                    VideoPlayer(player: player)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color(hex: "#2E322E"), lineWidth: 1)
                        )
                } else {
                    // Video file not yet added to the bundle — show a placeholder
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(hex: "#1A1C1A"))
                        .frame(height: 260)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "play.circle")
                                    .font(.system(size: 36))
                                    .foregroundColor(Color(hex: "#555D58"))
                                Text("Add LumaDemo.mp4 to the Xcode project")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(hex: "#555D58"))
                                    .multilineTextAlignment(.center)
                            }
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color(hex: "#2E322E"), lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal, 40)

            Spacer()

            // Bottom actions
            VStack(spacing: 8) {
                Button(action: onSkipOrContinue) {
                    Text("Continue →")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(hex: "#ECEEED"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(hex: "#2563EB"))
                        )
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                Button(action: onSkipOrContinue) {
                    Text("Skip")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#555D58"))
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 28)
        }
        .onAppear {
            setupVideoPlayer()
        }
        .onDisappear {
            tearDownVideoPlayer()
        }
    }

    // MARK: - Video Lifecycle

    private func setupVideoPlayer() {
        guard let videoURL = Bundle.main.url(
            forResource: videoBundleResourceName,
            withExtension: videoBundleResourceExtension
        ) else {
            // Video file not in bundle yet — leave videoPlayer nil so the placeholder shows
            return
        }

        let player = AVPlayer(url: videoURL)
        player.play()
        videoPlayer = player
    }

    private func tearDownVideoPlayer() {
        videoPlayer?.pause()
        videoPlayer = nil
    }
}
