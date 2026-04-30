//
//  LumaStrings.swift
//  leanring-buddy
//
//  All user-facing strings for Luma, centralised in one place so they are easy
//  to audit, update, and eventually localise.
//

import SwiftUI

enum LumaStrings {

    // MARK: App-level

    enum App {
        static let name            = "Luma"
        static let tagline         = "Light by Darkness"
        static let quit            = "Quit Luma"
        static let menuBarTooltip  = "Luma"
    }

    // MARK: Onboarding

    enum Onboarding {
        static let welcomeTitle    = "Welcome to Luma"
        static let welcomeSubtitle = "Light by Darkness"
        static let getStarted      = "Get Started"
        static let accountTitle    = "Create Your Account"
        static let pinTitle        = "Set a PIN (Optional)"
        static let pinSubtitle     = "Protect your settings with a 6-digit PIN"
        static let pinSkip         = "Skip for now"
        static let apiTitle        = "Connect Your AI"
        static let apiSubtitle     = "Add your API credentials to get started"
        static let doneTitle       = "You're all set!"
        static let startLearning   = "Start Learning →"
    }

    // MARK: Settings

    enum Settings {
        static let title                = "Settings"
        static let accountTab           = "Account"
        static let apiProfilesTab       = "API Profiles"
        static let modelTab             = "Model"
        static let generalTab           = "General"
        static let resetLuma            = "Reset Luma"
        static let resetConfirmTitle    = "Reset Luma?"
        static let resetConfirmMessage  = "This will clear all settings, API keys, and your account. This cannot be undone."
        static let about                = "About Luma v1.0 · © 2026 Omoju Oluwamayowa (Nox)"
    }

    // MARK: PIN

    enum PIN {
        static let enterPIN    = "Enter PIN"
        static let setPIN      = "Set PIN"
        static let confirmPIN  = "Confirm PIN"
        static let incorrectPIN = "Incorrect PIN"
        static let pinMismatch  = "PINs don't match"
    }

    // MARK: Walkthrough

    enum Walkthrough {
        static let whatDoYouWantToLearn = "What do you want to learn?"
        static let cancel               = "Cancel walkthrough"
        static let skipStep             = "Skip this step"
        /// Format with String(format:) — arguments are current step and total steps.
        static let stepOf               = "Step %d of %d"
        static let complete             = "You did it! 🎉"
    }

    // MARK: Companion

    enum Companion {
        static let pushToTalkHint = "Hold Ctrl+Option to speak"
        static let listening      = "Listening..."
        static let processing     = "Thinking..."
        static let responding     = "Responding..."
    }
}
