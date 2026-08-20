# Luma Visual Automation Kernel — PRD

**Owner:** Nox (Omoju Mayowa)
**Source:** Synthesized from Fable 5 rivalry audit + fix plan, 2026-07-11
**Status:** Draft — ready to hand to a contributor or an agent (DeepSeek/GLM via OpenCode)

---

## 1. Problem Statement

Luma's visual automation is powerful but fragmented across five systems (`LumaImageProcessingEngine`, `CursorGuide`, `LumaFlowActions`, `LumaFlowEngine`, `WalkthroughEngine`), each with its own idea of coordinates, target resolution, and success verification. This makes automation feel unreliable and nearly impossible to debug — a failure could be a coordinate bug, a stale AX element, a wrong-window bug, or a model hallucination, and today there's no way to tell which.

**The fix is not a smarter model. It's operational discipline: one kernel, typed data, verified actions.**

## 2. Goal

Ship a `VisualAutomationKernel` that every visual action (point, click, type, scroll, launch, verify) passes through — with typed coordinates, snapshot-before-action, risk-tiered execution, and structured verification. This becomes the trust layer that lets Luma compete on reliability, not just feature parity with HeyClicky.

**Non-goal:** beating HeyClicky everywhere. The bet is: win decisively on *screen-aware teaching + safe automation*, not generic computer-use breadth.

## 3. Success Criteria

- 40/50 tasks passing reliably on the benchmark suite (see §8), tracked over time, not vibes.
- Zero silent failures — every action either succeeds with evidence or reports a specific blocker.
- No raw `CGPoint` crossing subsystem boundaries — compiler-enforced coordinate safety.
- Every action has a replayable transaction log: what was seen, what was targeted, what happened, why it was judged successful.

---

## 4. Architecture

### 4.1 Core Types

```swift
struct UISnapshot: Identifiable {
    let id: UUID
    let createdAt: Date
    let bundleID: String
    let pid: pid_t
    let windowTitle: String?
    let displayID: CGDirectDisplayID
    let screenshot: ScreenCaptureMetadata?
    let axElements: [AXElementSnapshot]
    let focusedElement: AXElementSnapshot?
}

struct AutomationTransaction: Identifiable {
    let id: UUID
    let userGoal: String
    let snapshotID: UUID
    let resolvedTarget: ResolvedTarget?
    let action: AutomationAction
    let result: ActionResult?
}

enum AutomationActionRisk: String, Codable {
    case readOnly
    case safeUI
    case mediumUI
    case riskyUI
    case destructive
}

struct ActionResult: Codable {
    let actionID: UUID
    let succeeded: Bool
    let risk: AutomationActionRisk
    let evidenceSummary: String
    let verification: VerificationResult?
    let retryRecommendation: RetryRecommendation?
    let userVisibleMessage: String
}
```

### 4.2 Typed Coordinates

Create `CoordinateSpace.swift` with explicit, non-interchangeable types:

- `ScreenshotPixelPoint`
- `DisplayPoint`
- `QuartzClickPoint`
- `AppKitOverlayPoint`

Rule: the compiler must reject using an overlay point where a real click coordinate is required. Migrate all conversions currently scattered across `CursorGuide`, `LumaImageProcessingEngine`, `CompanionScreenCaptureUtility`, and `LumaFlowActions` into this one module.

### 4.3 The Kernel's Command Set

`inspect → resolveTarget → previewAction → performAction → verifyAction → recover`

Each command carries: target app, target window, display metadata, element identity, action type, confidence score, source evidence, safety level.

### 4.4 Risk Tiers

| Tier | Examples | Execution |
|---|---|---|
| `readOnly` | read UI, inspect state | automatic |
| `safeUI` | point overlay, AXPress verified element | automatic |
| `mediumUI` | focus + type, app-scoped shortcut, scroll verified region | automatic if snapshot-bound |
| `riskyUI` | global CGEvent click, shell command, send message | requires user confirmation |
| `destructive` | file delete, account change | requires explicit confirmation, no default-yes |

### 4.5 Verification Types

Replace string results ("Clicked button") with structured verifiers: `elementExists`, `valueEquals`, `windowTitleContains`, `fileExists`, `messageBubbleExists`, `screenRegionChanged`, `appActivated`. A screenshot hash is a hint, never proof — proof ties back to the user's actual goal.

---

## 5. Per-App Adapters

Generic AX scanning isn't enough for reliability. Add adapter contracts per app:

- **FinderAdapter** — open folder, list files, reveal file, create folder, move/copy/trash (confirm on trash)
- **BrowserAdapter** — open URL, read active page, avoid address-bar typing when a direct API exists
- **XcodeAdapter** — build status, active scheme, error list via AX
- **TerminalAdapter** — run command only in a managed session, capture output
- **ChatAdapter** (Beeper/WhatsApp) — search contact, verify service, type message, confirm before send, verify sent bubble
- **SettingsAdapter** — direct deep links to permission panes, visible guidance

Each adapter must define: supported actions, forbidden actions, verifier, failure modes, and the user-facing blocked-state sentence — written *before* the code path.

---

## 6. Language & UX Contract

- **User-facing copy:** warm, specific, confident. *"I found the Send button in Enoch Computer Science on WhatsApp. Ready to send?"*
- **Internal logging:** ruthless and exact — bundle ID, window, AX role/title, snapshot ID, confidence, risk tier, verifier used.
- **Confidence surfacing:**
  - High → cursor points directly.
  - Medium → highlight region, "I think this is it."
  - Low → ask.
  - Blocked → state exactly what's missing.
  - Done → state what proof was found.

The model proposes one action as JSON only, with an expected observation. **The kernel — not the model — decides whether the action is allowed.**

---

## 7. Shipping Plan (4 Weeks)

**Week 0 (2–3 days, before any code): Failure taxonomy research.**
Run 20 real tasks manually with logging on (Finder, Xcode build, Beeper search, System Settings pane, browser form). Label every failure: coordinate conversion? stale AX element? wrong frontmost app? missing AX label? model hallucination? screenshot downscaling? weak verification? This taxonomy drives every fix that follows — don't skip it.

**Week 1 — Coordinate truth.**
Ship `CoordinateSpace.swift`. Migrate all conversions into it. Tests: single display, Retina, secondary display in all four positions, screenshot downscaling, AX frame conversion. Migrate overlay-pointing and real-clicking as separate paths.

**Week 2 — Snapshot + resolver.**
Ship `UISnapshotBuilder`. `LumaFlowActions` stops searching the world directly — it requests a snapshot, resolves a target from it, acts on that resolved target. Snapshots expire fast; any UI change forces a new one. Merge duplicate AX search logic currently split between `CursorGuide` and `LumaImageProcessingEngine`.

**Week 3 — Action policy + verification.**
`LumaFlowActionExecutor` returns structured `ActionResult`. Add risk gates and confirmation flow for risky/destructive tiers. Add the verifier types from §4.5.

**Week 4 — Eval harness + scorecard.**
Build a local JSON-fixture harness (no big lab needed). Each task: starting app, goal, allowed/forbidden actions, success verifier, timeout. Run the 25–50 task set (§8) after every automation change. Track: pass rate, wrong-target rate, retries, latency. Break it, fix the top failure class, run again.

**Rule throughout:** classify every failure to its layer before patching. Coordinate bug → fix `CoordinateSpace`. AX label bug → fix resolver scoring. Policy bug → fix risk gate. Verification bug → fix verifier. Only touch the model prompt/schema after the system layers are proven solid.

---

## 8. Benchmark Starter Set (~25–50 tasks)

- **Finder:** open Downloads, create folder, rename folder, reveal file, move file, trash file (with confirmation)
- **Browser:** open URL, search, copy page title, fill simple form, switch tab, read selected text
- **Xcode:** open project, locate build button, run build, read first error, open file from navigator
- **System Settings:** open Accessibility pane, open Screen Recording pane, verify Luma's permission state
- **Notes:** create note, append text, search note, read title
- **Beeper/WhatsApp:** search contact, verify service, type message (no send), send after explicit request, verify sent bubble
- **Terminal:** run `pwd`/`ls` in a managed session, capture output, explain error
- **Teaching:** guide through changing wallpaper, checking storage, creating a Swift file, resolving a fake build error (no clicking — walkthrough only)

Log before/after screenshots + AX trees for every run. Track success rate, median latency, wrong-click count, retries, model calls, cost.

---

## 9. Production Readiness Gates (before wider release)

- No silent failures — audit for swallowed empty API responses.
- Every macOS permission prompt explains *why* Luma needs it and what happens if denied.
- Crash-safe logging redacts secrets; sensitive screen text isn't retained longer than needed.
- All send/delete/pay/account-change actions require confirmation *and* post-action verification.
- Screen-capture state is visible to the user; pause capture and per-app exclusion are supported; redaction mode exists for passwords/financial apps/private chats.

---

## 10. Positioning Note

Don't chase HeyClicky feature-for-feature. Their strength is general-purpose breadth with a funded team. Luma's strength is native macOS presence, Keychain-first privacy, local TTS, and — most importantly — **screen-aware teaching**: point, explain, guide the hand, remember the learner. HeyClicky executes tasks. Luma teaches them.

Build the kernel first so the companion bubble sits on top of something that doesn't lie about what it did. Ship one narrow demo that wins every time before trying to win everywhere.

---

## 11. Missing Pieces To Add Before Implementation

This section closes the gaps that would otherwise make the kernel sound good on paper but fail in real use.

### 11.1 Migration Plan

The kernel should not land as a second automation system beside the current five. It has to become the one path gradually, with old systems either wrapped, folded in, or deprecated.

**Phase 1 — Wrap, don't replace.**
Create `VisualAutomationKernel` as the public entry point, but route its first implementation through the existing systems:

- `LumaImageProcessingEngine` remains the vision provider, but it can only return typed observations and candidate targets.
- `LumaFlowActions` remains the action performer, but it receives a `ResolvedTarget` from the kernel instead of searching or guessing on its own.
- `CursorGuide` remains the overlay renderer, but it only accepts `AppKitOverlayPoint` and cannot generate click coordinates.
- `WalkthroughEngine` remains the teaching layer, but it requests kernel previews and verified pointers instead of directly driving UI state.

**Phase 2 — Move shared logic inward.**
After the wrapper works, move duplicated coordinate conversion, AX scoring, target ranking, screenshot handling, and verification code into kernel-owned modules. Existing call sites should become thin adapters.

**Phase 3 — Deprecate direct paths.**
Mark direct action APIs in `LumaFlowActions`, direct visual targeting in `LumaImageProcessingEngine`, and direct coordinate use in `CursorGuide` as deprecated. Add warnings or debug assertions when any new code bypasses the kernel.

**Phase 4 — Remove the old authority.**
Once the benchmark suite is stable, delete or privatize the old execution paths. The old modules can still exist as providers, but none of them should independently inspect, resolve, act, and verify.

**Order of operations:**

1. Add kernel entry point and typed transaction model.
2. Route one low-risk action through it, such as pointing to a Finder item.
3. Route one medium-risk action through it, such as focusing and typing into a verified text field.
4. Route one walkthrough-only flow through it, with no real clicking.
5. Route one confirmation-gated flow through it, such as sending a message.
6. Freeze direct legacy APIs.
7. Expand coverage module by module.

To avoid breaking current users, every migrated action needs a feature flag, a fallback to the old path for one release, and side-by-side logging so the old result and kernel result can be compared before the kernel becomes the default.

### 11.2 Coordinate-Space Rules

The kernel needs one source of truth for coordinates because this is where the wrong-window and wrong-click bugs will hide.

- **No raw `CGPoint` outside `CoordinateSpace.swift`.** Every point must carry its coordinate space in the type name.
- **Screenshot pixels are not display points.** Retina screenshots may be 2x the logical display size, so every screenshot must store `pixelWidth`, `pixelHeight`, `pointWidth`, `pointHeight`, and `scaleFactor`.
- **Window-relative points are preferred for app UI.** Store element frames relative to the owning window when possible, then convert to screen-relative points only at the final action boundary.
- **Screen-relative points must include display identity.** A screen point without `displayID` is invalid on multi-display setups.
- **Global clicks use Quartz coordinates only at the final edge.** The conversion into `QuartzClickPoint` should happen in one place, after display, window, scale, and origin are validated.
- **Overlay points are never click points.** `CursorGuide` should render with `AppKitOverlayPoint`; it should not be able to produce `QuartzClickPoint`.
- **Multi-display origin rules must be tested.** Secondary displays can sit left, right, above, or below the main display, producing negative origins. Tests must cover all four positions.
- **Every conversion validates round-trip accuracy.** Convert source → target → source and fail if drift is beyond a small tolerance, especially after screenshot downscaling.

Before any real click, the kernel must validate: active display, target window bounds, point inside window, point inside screenshot region, expected element near that point, and snapshot freshness.

### 11.3 Observability Requirements

Every action needs enough evidence that future Nox can replay what happened instead of guessing.

Each `AutomationTransaction` should record:

- user goal
- app bundle ID, pid, window title, window ID, display ID
- before screenshot and AX tree
- resolved target candidates with scores
- chosen target and why it won
- coordinate conversions performed
- action requested, action allowed, and policy decision
- model/tool used, prompt/schema version, latency, and cost if applicable
- after screenshot and AX tree
- verifier used and verifier result
- recovery attempt, if any
- final user-facing sentence

The trace format should be replayable locally: load the before screenshot, overlay candidate boxes, show the chosen target, show the click/type/scroll action, then show the after state and verifier result. This is the debugging UI Luma needs before it needs more model cleverness.

Logs must be privacy-aware by default: redact passwords, tokens, financial text, private chat bodies, and API keys; keep full screenshots only in local debug mode; allow per-app capture exclusion.

### 11.4 Fallback Ladder And Latency Budgets

The resolver must use the cheapest reliable signal first and escalate only when needed.

| Step | Source | When to use | Target budget |
|---|---|---|---|
| 1 | Accessibility | Element has usable role/title/value/frame, or app adapter knows the UI | 50–150 ms |
| 2 | Local vision model | AX is missing, canvas/web content is unlabeled, or visual disambiguation is needed | 200–700 ms |
| 3 | Claude or hosted reasoning model | The task needs semantic judgment, ambiguous visual reasoning, or recovery planning | 1.5–5 s |
| 4 | Ask user | Confidence is low, action is risky, or evidence conflicts | human-gated |

Rules:

- Accessibility is always first for native controls.
- Vision can propose candidates but cannot approve risky actions.
- Claude can reason and choose between candidates, but it cannot bypass policy, confirmation, or verification.
- If the fallback ladder exceeds the latency budget, the user-facing state should change from silent waiting to a clear progress sentence.
- If two layers disagree, the kernel should prefer the safer interpretation and ask rather than click.

The expected steady-state goal: most native macOS actions resolve through AX without a model call; vision handles unlabeled visual surfaces; Claude is reserved for ambiguity and recovery.

### 11.5 Model Risk Mitigation

The PRD should assume hosted models will occasionally be slow, unavailable, expensive, or wrong.

- Define a primary reasoning model and a backup model in configuration, not scattered constants.
- Use Claude when available for AX-heavy reasoning and ambiguous recovery.
- Keep DeepSeek or GLM as the planned backup for structured Swift architecture work and JSON action proposals.
- Add a local/no-model mode where Luma can still inspect AX, point, explain, and run deterministic app adapters.
- Version every model prompt and action schema so regressions can be traced.
- Cache stable app UI fingerprints where safe, but never cache sensitive screen text.
- Treat model output as an untrusted proposal. The kernel validates schema, policy, coordinates, app/window identity, and verifier before acting.
- Add circuit breakers: if the model returns malformed JSON, mismatched coordinates, or repeated low-confidence targets, stop escalating and ask the user.

Backup model requirement: if the hosted model becomes flaky, Luma should fall back to `GLM-4.5` or `DeepSeek-V3.1` for structured action planning, while keeping risky Accessibility and coordinate decisions inside deterministic Swift code.

## 12. Model/Tooling Notes (for whoever implements this)

- Coordinate typing, snapshot structs, risk enums, and the eval harness are standard Swift architecture work — DeepSeek or GLM via OpenCode should handle these reliably.
- AX API specifics (`AXUIElement` attributes, `CGEvent` synthesis quirks, ScreenCaptureKit edge cases) are higher hallucination risk for non-Claude models — verify against Apple documentation directly rather than trusting generated code blindly.
- If Claude access returns even briefly, prioritize spending it on the Accessibility-heavy pieces (Week 1–2 resolver work), not the boilerplate.
