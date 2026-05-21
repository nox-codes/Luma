# Luma - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via AssemblyAI streaming, and sends the transcript + a screenshot of the user's screen to Claude. Claude responds with text (streamed via SSE) and voice (macOS native AVSpeechSynthesizer). A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

API keys are stored directly in the macOS Keychain — nothing sensitive ships in the app binary.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Any OpenRouter model (default: google/gemini-2.5-flash:free) with SSE streaming. Full model picker with search, free/paid sections, and recommended badges.
- **Speech-to-Text**: AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: macOS native `AVSpeechSynthesizer` (fully local, no API calls)
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `LumaAnalytics.swift`
- **Key Storage**: API keys stored in macOS Keychain via `KeychainManager.swift`. No Cloudflare Worker proxy.

### API Key Management (Keychain)

The app calls external APIs directly using keys stored in the macOS Keychain. Keys are written once during onboarding and read on demand.

| Key | Upstream | Purpose |
|-----|----------|---------|
| `openrouter_api_key` | `openrouter.ai/api/v1/chat/completions` | Vision + streaming chat (via OpenRouter) |
| `assemblyai_api_key` | `streaming.assemblyai.com/v3/token` | AssemblyAI websocket token |

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Luma" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

**Intent Classifier**: Every user voice input passes through `LumaIntentClassifier` before any action is taken. It calls Claude (cheap model, max_tokens:300) with the user's input plus AX screen context (active app, window title, top-20 interactive elements) and receives a JSON routing decision. Paths: `cli` (shell command via `LumaCLIExecutor`), `visual_agent` (spawns agent session), `guide` (walkthrough pipeline), `response` (standard Claude call). Confidence levels drive confirmation/clarification loops — low confidence asks a follow-up question, required confirmation waits for a spoken yes/no. AX context is cached for 500ms to avoid redundant traversal on rapid inputs. No hardcoded prefixes or mode names required.

**Agent System (v3.0)**: Session-based multi-agent mode with dual-runtime architecture. Each `AgentSession` has its own transcript, accent theme, status, and response cards. Managed by `CompanionManager` (agentSessions array). Dual runtime: `ClaudeCodeAgentRuntime` (default, spawns `claude` CLI subprocess with `--output-format stream-json`) and `ClaudeAPIAgentRuntime` (fallback, tool-use loop via OpenRouter). Auto-detection via `AgentRuntimeManager`. UI: inline `AgentModePanelSection` in companion panel, floating `LumaAgentHUDWindowManager` dashboard with team strip/transcript/composer, floating `LumaAgentDockWindowManager` bottom dock. Voice commands ("spawn agent and research X") detected via regex in `AgentVoiceIntegration`. Hotkeys: Ctrl+Cmd+N spawn, Ctrl+Option+Tab cycle, Ctrl+Option+1-9 switch. Memory persisted via `LumaMemoryManager` to ~/Library/Application Support/Luma/.

**Companion Bubble (v3.0)**: The floating response bubble uses backdrop blur with rgba(10,10,15,0.85) overlay, animated angular gradient border (8s hue cycle), AttributedString markdown rendering, smooth spring resize animations, scroll for overflow, and walkthrough step indicators.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `LumaApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1026 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, native TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot → Claude → TTS → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~244 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~900 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, searchable model picker (fetches from OpenRouter, free/paid sections, recommended badges), permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OpenRouterModelFetcher.swift` | ~150 | Fetches and parses the OpenRouter model list. Provides `OpenRouterModel` structs, recommended badge mapping, and caching. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens directly from AssemblyAI using the Keychain key, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeAPI.swift` | ~291 | Claude vision API client with streaming (SSE) and non-streaming modes. TLS warmup optimization, image MIME detection, conversation history support. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ~140 | Native macOS TTS client using `AVSpeechSynthesizer`. Fully local — no API calls. Reads voice settings (gender, pitch, rate, volume) from UserDefaults before each utterance. Exposes `isPlaying` and `waitUntilFinished()` for transient cursor scheduling. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `LumaImageProcessingEngine.swift` | ~743 | Central element-finding authority for the walkthrough system. Runs AX scan and visual scan in parallel, cross-validates results, and returns the highest-confidence candidate. Owns the Layer 3 Claude Vision fallback (`detectElementViaAPIClient`, `parsePointTagFromAPIResponse`, `adaptiveBoundingBoxSize`). |
| `LumaMobileNetDetector.swift` | ~354 | 3-layer on-device visual detection pipeline. Layer 1: `VNRecognizeTextRequest` + `VNDetectRectanglesRequest` returns real bounding boxes. Layer 2: MobileNetV2 crop-validates Layer 1 coordinates (downgrade if < 0.35 confidence). Layer 3 trigger lives in `LumaImageProcessingEngine.scanVisual`. |
| `LumaOnDeviceAI.swift` | ~82 | Unified manager for all on-device AI inference (Whisper, DistilBERT classifier, MobileNetV2 detector). All sub-engines are lazily loaded. `detectElements` threads `searchQuery` through to `LumaMobileNetDetector`. |
| `LumaTheme.swift` | ~800 | Design system tokens — colors, spacing, corner radii, typography, companion shape/morph config. All UI references `LumaTheme.Colors`, `LumaTheme.CornerRadius`, etc. Includes `NoiseTextureView` (CIRandomGenerator grain), `ButtonGlowHoverModifier`, `MorphingCompanionShape`, and the `pointerCursor()` / `glowOnHover()` view extensions. |
| `LumaAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `LumaUpdateManager.swift` | ~245 | GitHub Releases API update checker (Option C, default active). Polls `api.github.com/repos/nox-codes/Luma/releases/latest` on launch (5s delay) and every 24h. Compares semver, publishes `availableUpdate: LumaReleaseInfo?`. Beta detection via `prerelease` API field and `(Beta)` in release name. Dismissal persisted in UserDefaults per version tag. Sparkle (Options A/B) wired in `Info.plist` + `appcast.xml` but dormant — uncomment `startSparkleUpdater()` in `LumaApp.swift` when GitHub Actions is ready. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `AccountManager.swift` | ~107 | Manages local user account persistence via UserDefaults. Owns `LumaAccount` model with username, display name, and avatar initials. Provides singleton manager with create, update, and delete lifecycle methods. Includes `LumaAvatarView` for displaying user initials using LumaTheme accent colors. |
| `PostOnboardingTutorialManager.swift` | ~80 | Drives a 5-step post-onboarding walkthrough. Runs once after onboarding completes, highlights panel UI elements with a pulse ring, and auto-advances. Completion persisted in UserDefaults. |
| `LumaOnboardingWindowManager.swift` | ~128 | Dedicated NSWindow manager for the onboarding wizard. Mirrors `LumaSettingsWindowManager`: borderless `KeyAcceptingOnboardingWindow` hosting `OnboardingWizardView` via `NSHostingView`. Switches to `.regular` activation policy while open, returns to `.accessory` on close. |
| `LumaLogger.swift` | ~120 | Thread-safe file-based logger. Writes all `[Luma]`, `[LIPE]`, `[LumaMobileNet]`, and `[LumaML]` messages to `~/Library/Logs/Luma/luma.log`. Auto-rotates at 2 MB (backup: `luma.log.1`). Works in Debug and Release. Use `LumaLogger.log()` instead of `print()` for all tagged diagnostic output. Has a Combine `liveLogEntryPublisher` for real-time log streaming to the log window. |
| `LumaLogWindowManager.swift` | ~100 | Non-modal NSWindow with monospaced NSTextView for real-time log viewing. Subscribes to LumaLogger's live publisher. Clear button, auto-scroll. |
| `LumaCursorProfile.swift` | ~150 | Per-state cursor appearance configuration. CursorProfile stores per-LumaCursorState shape/color/size, persisted to Keychain. |
| `CustomCursorManager.swift` | ~200 | Reads CursorProfile from Keychain, builds NSCursor cache per state, exposes `setState(_:)` for state transitions. Renders teardrop, circle, triangle, diamond, cross, dot shapes with glow. |
| `LumaMemoryManager.swift` | ~180 | Manages memory.md and per-agent JSON history in ~/Library/Application Support/Luma/. Thread-safe via NSLock, ISO8601 date encoding, auto-rotation at 2MB. |
| `LumaUserOutlookManager.swift` | ~220 | Manages the User Profile / Outlook — an AI-generated behavioral profile stored at ~/Library/Application Support/Luma/.profile/outlook.md (hidden directory). Observes every interaction via fire-and-forget background tasks, calls a cheap AI model to update the profile, and provides `outlookSystemPromptSection()` for injection into all system prompts. `@MainActor` singleton. |
| `LumaOutlookWindowManager.swift` | ~640 | NSWindow manager for the read-only User Profile viewer. Renders full markdown (H1–H4, bold, italic, inline code, tables, fenced code blocks, blockquotes, ordered/unordered lists, HR) via `WKWebView` with custom dark-theme CSS. Polls the profile file every 2 seconds for real-time updates. Includes a Reset button (with confirmation alert) that clears the profile file. |
| `Agent/AgentSession.swift` | ~615 | Core agent session model. ObservableObject with id, title, accentTheme, status, transcript entries, response card. Binds to AgentRuntime, handles submit/stop/warmUp, auto-generates titles via lightweight API call. On task completion, auto-summarizes session via cheap model and stores result in `completedTaskSummary` for cost-efficient follow-up prompts. |
| `Agent/AgentTranscriptEntry.swift` | ~20 | Transcript entry model with TranscriptRole enum (user, assistant, system, command, plan). |
| `Agent/ResponseCard.swift` | ~50 | Response card model that parses `<NEXT_ACTIONS>` tags and provides truncated text for compact display. |
| `Agent/AgentRuntime.swift` | ~150 | AgentRuntime protocol (startSession, submitPrompt, stopSession, Combine publishers) + AgentRuntimeManager singleton that auto-detects Claude Code CLI and creates appropriate runtime. |
| `Agent/ClaudeCodeAgentRuntime.swift` | ~200 | Subprocess runtime that spawns `claude` CLI with `--output-format stream-json`. Parses streaming JSON messages (assistant, tool_use, result, error). One Process per session. |
| `Agent/ClaudeAPIAgentRuntime.swift` | ~407 | Tool-use loop fallback runtime via OpenRouter API. 7 tools (bash, screenshot, click, type, key_press, open_app, wait). Max 50 iterations safety limit. Sliding window context pruning (first + last 4 messages), 1200-char tool output cap, 2048 max_tokens. |
| `Agent/AgentBubbleSettings.swift` | ~105 | Data model and singleton manager for agent bubble visual appearance settings. `BubbleStyle` enum (6 styles), `AgentBubbleSettings` struct (Codable, persisted via JSONEncoder to UserDefaults), `AgentBubbleSettingsManager` singleton. |
| `Agent/InkDropBubbleView.swift` | ~1260 | All visual components for the Ink Drop bubble style. `InkDropMorphShape` (custom Shape, 4-keyframe cubic bezier interpolation at 60fps), `IsoGlyphView` (Canvas-based isometric glyph renderer), `InkRingsView` (radial-gradient fill pulse rings), `InkDropStatusDot`, `InkDropOrbView` (TimelineView), `HaltedAgentPillView` (done/failed/cancelled pill with auto-dismiss), `StyleAwareMiniIconView` (28pt header avatar for each of the 6 bubble styles, used in expanded card header), `BubbleStylePickerView` (3×2 grid), `BubbleAppearanceSectionView` (settings section). |
| `Agent/AgentModePanelSection.swift` | ~285 | Inline agent controls for companion panel: status header, prompt input, inline response display, response card compact view, dashboard/send buttons. |
| `Agent/LumaAgentHUDWindowManager.swift` | ~590 | Floating agent dashboard NSPanel. Agent team strip, transcript viewer with role-colored entries, response card display, composer with run button. |
| `Agent/LumaAgentDockWindowManager.swift` | ~2611 | One floating NSPanel per agent session. Coordinator manages `[UUID: AgentBubbleWindow]`, syncs on each `show(sessions:)` call, drives 25 Hz physics timer. `AgentBubblePhysicsState` owns idle/working/proximity offsets + `measuredExpandedCardHeight`. Expanded card: `#141614` background, `#2E322E` border, 14pt corner radius, 3pt left accent strip (session glowColor). `cardHeader` shows `StyleAwareMiniIconView` + agent title + status badge pill. `InputZone` has `#1A1C1A` background with mic + send/cancel in a `#212421` input row. Expanded card shows ≤20-word `shortSummary` headline + full `RichMarkdownView` (tables, code blocks, mermaid diagrams, bullet/numbered lists, blockquotes). Adaptive card height measured via `CardBodySizePreferenceKey` hidden sizer, springs to fit content (compact 155pt → max 520pt). |
| `Agent/AgentHotkeyHandler.swift` | ~115 | Global NSEvent monitors for agent hotkeys: Ctrl+Cmd+N spawn, Ctrl+Option+Tab cycle, Ctrl+Option+1-9 switch. |
| `Agent/AgentVoiceIntegration.swift` | ~110 | Voice command detection for agent spawning via regex. Heuristic title generation from task text. |
| `Agent/AgentMemoryIntegration.swift` | ~80 | Bridges agent system with LumaMemoryManager. Summarizes memory for system context, records user/agent messages. |
| `Agent/AgentProfile.swift` | ~50 | AgentModel enum (claudeSonnet, claudeOpus, gpt4o, gpt4oMini) and AgentProfile struct (Codable, UserDefaults persisted). |
| `Agent/AgentSettingsManager.swift` | ~90 | Singleton managing maxAgentCount, isAgentModeEnabled, agentProfiles. Enforces agent limit with UNNotification on removal. |
| `Agent/LumaAppIntegrations.swift` | ~370 | Built-in action modules for common macOS apps and system controls. `LumaAppActivator` (activate/launch by name, poll for frontmost), `LumaBrowserIntegration` (openURL, openURLInSafari, readPageContentViaAX), `LumaFinderIntegration` (openFolder, createFolder, moveItem, copyItem, trashItem, listDirectory via NSFileManager), `LumaNotesIntegration` (createNote, appendToNote, readNote via AppleScript/osascript), `LumaSystemControlIntegration` (setOutputVolume/getOutputVolume via CoreAudio, setDisplayBrightness/getDisplayBrightness via IOKit, setWiFiEnabled via networksetup shell). |
| `LumaIntentClassifier.swift` | ~370 | Intent classifier — reasoning layer that runs on every user input before any action. Calls Claude (max_tokens:300, cheap model) with AX screen context to return `LumaClassifierResult` with path (`cli`, `visual_agent`, `guide`, `response`), confidence, confirmation, and clarification fields. Also contains `LumaCLIExecutor` for shell command execution. 500ms AX context cache. |

## Build & Run

```bash
# Open in Xcode
open Luma.xcodeproj

# Select the "Luma by Nox" scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or main scheme
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
