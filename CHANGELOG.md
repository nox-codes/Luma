# Luma — Changelog

---

## Origins: Clicky by Farza

Luma began as **Clicky**, an open-source macOS menu bar companion app built by Farza. Clicky established the core idea: a status bar icon that opens a floating panel, push-to-talk voice input, a Cloudflare Worker proxy routing requests to Claude, and a blue cursor overlay that could point at UI elements on screen. API keys were routed through the proxy rather than stored locally, and the app shipped with a basic onboarding flow and accessibility-based element detection.

---

## Luma v1 — The Rebrand and Rebuild

**Nox forked Clicky and bootstrapped Luma**, rewriting the app from the ground up under a new identity while preserving the core premise.

Key changes from Clicky:

- Full rebrand across all Swift source files, assets, and config — Clicky became Luma
- Removed the Cloudflare Worker proxy entirely; API keys now live in the macOS Keychain via a new `KeychainManager`
- Replaced the design system with `LumaTheme` — a unified token system for colors, spacing, corner radii, and typography
- Added a 5-step onboarding wizard to guide new users through permissions and key setup
- Added a multi-profile system (`ProfileManager`) supporting different API providers per profile
- Added `AccountManager` with local user accounts, display names, and avatar initials
- Added PIN protection (`PINManager`) with a custom numeric keypad view
- Rebuilt the settings panel with four tabs covering account, provider, voice, and permissions
- Replaced ElevenLabs TTS with macOS-native `AVSpeechSynthesizer` — fully local, no API calls
- Ported AssemblyAI token fetching directly to the Keychain key, removing the proxy dependency
- Added a `WalkthroughEngine` with step-by-step guided task execution using AX + cursor pointing
- Added `PostOnboardingTutorialManager` — a 5-step first-run walkthrough that highlights panel UI elements with a pulse ring

---

## Luma v2 — Smarter Vision, On-Device ML, and Intent Routing

With the foundation solid, the focus shifted to making Luma genuinely useful as a screen-aware assistant.

- Introduced a **3-layer visual detection pipeline**: Layer 1 uses `VNRecognizeTextRequest` + `VNDetectRectanglesRequest` for real bounding boxes; Layer 2 validates coordinates via MobileNetV2 crop confidence; Layer 3 falls back to Claude Vision API for elements that on-device inference misses
- Added `LumaImageProcessingEngine` as the central element-finding authority, running AX and visual scans in parallel and cross-validating results
- Added `LumaMobileNetDetector` and `LumaOnDeviceAI` — on-device ML inference (MobileNetV2) fully integrated into the element detection flow
- Added `LumaIntentClassifier` — every voice input now routes through a lightweight Claude call with AX screen context before any action is taken; paths: `cli` (shell command), `visual_agent`, `guide`, `response`
- Added `LumaCLIExecutor` for running shell commands from voice input
- Switched to **OpenRouter** as the model layer, enabling any compatible model with a searchable model picker (free/paid sections, recommended badges)
- AssemblyAI streaming (`u3-rt-pro`) added as the primary STT provider with a pluggable `BuddyTranscriptionProvider` layer; Apple Speech remains the local fallback
- Added file-based logging via `LumaLogger` with auto-rotation at 2 MB and a live log viewer window (`LumaLogWindowManager`)
- Added `PostHog` analytics via `LumaAnalytics`
- Improved multi-monitor coordinate mapping and bezier arc cursor animations
- Improved push-to-talk reliability with a listen-only `CGEvent` tap for system-wide modifier shortcuts

---

## Luma v3 — Agent System and Floating Bubble UI

The largest update to date, v3 introduced a full multi-agent architecture and a completely new floating UI layer.

**Agent System**

- Dual-runtime architecture: `ClaudeCodeAgentRuntime` (default) spawns the `claude` CLI subprocess with `--output-format stream-json`; `ClaudeAPIAgentRuntime` (fallback) runs a tool-use loop via OpenRouter with 7 built-in tools
- `AgentRuntimeManager` auto-detects Claude Code CLI and selects the appropriate runtime
- Each `AgentSession` owns its own transcript, accent theme, status, and response card; managed by `CompanionManager`
- Sessions auto-generate titles via a lightweight API call and summarize themselves on completion for cost-efficient follow-up prompts
- `LumaMemoryManager` persists memory and per-agent history to `~/Library/Application Support/Luma/`
- Voice command detection for agent spawning via regex in `AgentVoiceIntegration`
- Hotkeys: Ctrl+Cmd+N to spawn, Ctrl+Option+Tab to cycle, Ctrl+Option+1-9 to switch

**Floating Bubble Dock**

- One `NSPanel` per active agent session, driven by a 25 Hz physics timer with idle drift (Lissajous path), working pulse, and proximity offsets
- Orbs morph in-place into expanded cards on hover — no position drift, anchored to tracked corner
- Expanded cards show a short headline summary and full `RichMarkdownView` (tables, code blocks, Mermaid diagrams, bullet lists, blockquotes)
- Adaptive card height measured via a hidden sizer, springs from 155pt to 520pt max
- Glassy orb visuals with radial gradient, specular highlight, and pulsing status dot

**UI and Design**

- Redesigned companion bubble: backdrop blur, angular gradient animated border (8s hue cycle), `AttributedString` markdown rendering, smooth spring resize, scroll for overflow, and walkthrough step indicators
- Rebuilt settings with `DS` design tokens and agent runtime controls
- Inline `AgentModePanelSection` in the companion panel for quick agent access
- Transient cursor mode: when the cursor overlay is hidden, it fades in for the duration of each interaction and fades out automatically

---

*Built by Nox. Originally forked from Clicky by Farza.*
