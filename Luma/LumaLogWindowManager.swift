//
//  LumaLogWindowManager.swift
//  leanring-buddy
//
//  Non-modal NSWindow that displays Luma's activity log in real time.
//  Opens from the General settings tab. Subscribes to LumaLogger's live
//  publisher and appends entries with timestamps in a monospaced font.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class LumaLogWindowManager {

    static let shared = LumaLogWindowManager()

    private var window: NSWindow?
    private var logSubscription: AnyCancellable?

    // MARK: - Public API

    func showLogWindow() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let newWindow = makeLogWindow()
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideLogWindow() {
        window?.orderOut(nil)
    }

    // MARK: - Window Construction

    private func makeLogWindow() -> NSWindow {
        let logWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 450),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        logWindow.title = "Luma Activity Log"
        logWindow.minSize = NSSize(width: 700, height: 400)
        logWindow.isReleasedWhenClosed = false
        logWindow.center()
        logWindow.backgroundColor = NSColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1.0) // #0A0A0F

        // Build the content view: a toolbar with Clear button + scrollable text view
        let containerView = NSView()
        containerView.wantsLayer = true

        // Clear button at top right
        let clearButton = NSButton(title: "Clear", target: nil, action: #selector(LogWindowClearAction.clearLogView(_:)))
        clearButton.bezelStyle = .recessed
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        // Scrollable text view with monospaced font
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = NSColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1.0)
        textView.textColor = NSColor.white.withAlphaComponent(0.85)
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView

        containerView.addSubview(clearButton)
        containerView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            clearButton.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            clearButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: clearButton.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        logWindow.contentView = containerView

        // Load existing log contents into the text view
        if let existingLogContents = LumaLogger.readCurrentLogFileContents() {
            textView.string = existingLogContents
        }

        // Store a reference to the text view so the clear action can find it
        let clearActionHandler = LogWindowClearAction(textView: textView)
        clearButton.target = clearActionHandler
        // Prevent deallocation by associating with the window
        objc_setAssociatedObject(logWindow, &LogWindowClearAction.associatedKey, clearActionHandler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // Subscribe to live log entries and auto-scroll to bottom
        logSubscription = LumaLogger.shared.liveLogEntryPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak textView, weak scrollView] logLine in
                guard let textView = textView, let scrollView = scrollView else { return }
                let shouldAutoScroll = scrollView.isAtBottom
                textView.textStorage?.append(NSAttributedString(
                    string: logLine + "\n",
                    attributes: [
                        .foregroundColor: NSColor.white.withAlphaComponent(0.85),
                        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                    ]
                ))
                if shouldAutoScroll {
                    textView.scrollToEndOfDocument(nil)
                }
            }

        return logWindow
    }
}

// MARK: - Clear Button Handler

/// Target-action handler for the Clear button. Clears the text view content
/// without deleting the underlying file logs.
private class LogWindowClearAction: NSObject {
    static var associatedKey: UInt8 = 0
    weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
    }

    @objc func clearLogView(_ sender: Any?) {
        textView?.string = ""
    }
}

// MARK: - NSScrollView Extension

private extension NSScrollView {
    /// Returns true when the scroll view is scrolled to the bottom (or within a small tolerance).
    var isAtBottom: Bool {
        guard let documentView = documentView else { return true }
        let visibleRect = contentView.bounds
        let documentHeight = documentView.frame.height
        // Consider "at bottom" if within 40pt of the bottom edge
        return visibleRect.maxY >= documentHeight - 40
    }
}
