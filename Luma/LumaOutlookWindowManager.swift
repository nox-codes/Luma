//
//  LumaOutlookWindowManager.swift
//  Luma
//
//  Manages the read-only window that shows the user's AI-generated behavioral profile
//  (the "Outlook"). Renders full markdown — including tables, code blocks, and all inline
//  formatting — via WKWebView with a custom dark-theme CSS layer.
//
//  The window polls the profile file every 2 seconds for real-time updates so changes
//  made by the background observation engine appear without a manual refresh.
//  A "Reset" button clears the profile file after confirmation.
//

import AppKit
import Combine
import SwiftUI
import WebKit

// MARK: - LumaOutlookWindowManager

@MainActor
final class LumaOutlookWindowManager {

    static let shared = LumaOutlookWindowManager()

    private var outlookWindow: NSWindow?

    private init() {}

    /// Shows the outlook profile window. Brings it to front if already open.
    func showOutlookWindow() {
        if let existingWindow = outlookWindow, existingWindow.isVisible {
            existingWindow.orderFrontRegardless()
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = makeOutlookWindow()
        outlookWindow = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                NSApp.setActivationPolicy(.accessory)
                self.outlookWindow = nil
            }
        }
    }

    // MARK: - Window Construction

    private func makeOutlookWindow() -> NSWindow {
        let windowSize = NSSize(width: 700, height: 580)

        let hostingView = NSHostingView(
            rootView: OutlookProfileWindow()
                .preferredColorScheme(.dark)
        )
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]

        let window = KeyAcceptingOutlookWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Luma — User Profile"
        window.minSize = NSSize(width: 540, height: 420)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.isOpaque = true
        window.backgroundColor = NSColor(red: 0.055, green: 0.059, blue: 0.055, alpha: 1)
        window.hasShadow = true
        window.contentView = hostingView
        return window
    }
}

// MARK: - KeyAcceptingOutlookWindow

private final class KeyAcceptingOutlookWindow: NSWindow {
    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - OutlookProfileWindow (Root SwiftUI View)

private struct OutlookProfileWindow: View {

    @State private var profileMarkdownContent: String = ""
    @State private var lastUpdatedDate: Date? = nil
    @State private var showingResetConfirmation: Bool = false

    /// Polls the profile file every 2 seconds for real-time updates.
    /// More reliable than DispatchSourceFileSystemObject for atomic writes,
    /// which swap inodes rather than modifying the original file in place.
    private let pollingTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            outlookWindowHeader
            Divider()
                .background(Color(red: 0.18, green: 0.20, blue: 0.18))

            if profileMarkdownContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyOutlookPlaceholder
            } else {
                OutlookMarkdownWebView(markdownContent: profileMarkdownContent)
            }
        }
        .background(Color(red: 0.055, green: 0.059, blue: 0.055))
        .onAppear { reloadProfileFromDisk() }
        .onReceive(pollingTimer) { _ in
            let latestContent = LumaUserOutlookManager.shared.loadOutlook()
            guard latestContent != profileMarkdownContent else { return }
            profileMarkdownContent = latestContent
            if !latestContent.isEmpty {
                lastUpdatedDate = Date()
            }
        }
        .alert("Reset User Profile", isPresented: $showingResetConfirmation) {
            Button("Reset", role: .destructive) { performProfileReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete Luma's behavioral profile for you. It cannot be undone.")
        }
    }

    // MARK: - Header

    private var outlookWindowHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(Color(red: 0.40, green: 0.80, blue: 0.60))

            VStack(alignment: .leading, spacing: 2) {
                Text("User Profile")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(red: 0.93, green: 0.93, blue: 0.93))
                Text("Luma's behavioral observations — read only")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.50, green: 0.54, blue: 0.50))
            }

            Spacer()

            if let updatedDate = lastUpdatedDate {
                Text("Updated \(updatedDate.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.40, green: 0.44, blue: 0.40))
            }

            // Reset button — only visible when a profile exists
            if !profileMarkdownContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: { showingResetConfirmation = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                        Text("Reset")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(Color(red: 0.80, green: 0.38, blue: 0.38))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.18, green: 0.10, blue: 0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }

            Button(action: reloadProfileFromDisk) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                    Text("Refresh")
                        .font(.system(size: 12))
                }
                .foregroundColor(Color(red: 0.60, green: 0.64, blue: 0.60))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(red: 0.12, green: 0.14, blue: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(red: 0.07, green: 0.08, blue: 0.07))
    }

    // MARK: - Empty State

    private var emptyOutlookPlaceholder: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.crop.circle.dashed")
                .font(.system(size: 44))
                .foregroundColor(Color(red: 0.25, green: 0.28, blue: 0.25))
            VStack(spacing: 6) {
                Text("No profile yet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(red: 0.55, green: 0.58, blue: 0.55))
                Text("Luma will build your profile as you interact with it.\nCheck back after a few conversations.")
                    .font(.system(size: 13))
                    .foregroundColor(Color(red: 0.38, green: 0.41, blue: 0.38))
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func reloadProfileFromDisk() {
        let currentContent = LumaUserOutlookManager.shared.loadOutlook()
        profileMarkdownContent = currentContent
        if !currentContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastUpdatedDate = Date()
        }
    }

    private func performProfileReset() {
        LumaUserOutlookManager.shared.resetOutlook()
        profileMarkdownContent = ""
        lastUpdatedDate = nil
    }
}

// MARK: - OutlookMarkdownWebView

/// Renders profile markdown via WKWebView with dark CSS.
/// Supports the full markdown feature set: tables, code blocks, blockquotes,
/// ordered/unordered lists, all heading levels, inline bold/italic/code, and HR dividers.
/// Only re-loads when the content string actually changes to avoid unnecessary flickers.
private struct OutlookMarkdownWebView: NSViewRepresentable {

    let markdownContent: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        // Transparent backing so the window background shows before the HTML loads.
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = NSColor(red: 0.055, green: 0.059, blue: 0.055, alpha: 1)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let fullHTML = buildHTMLPage(markdownContent: markdownContent)
        // Skip reload if the page content hasn't changed — prevents scroll position reset
        // during the 2-second polling cycle when nothing new has arrived.
        guard fullHTML != context.coordinator.lastLoadedHTML else { return }
        context.coordinator.lastLoadedHTML = fullHTML
        webView.loadHTMLString(fullHTML, baseURL: nil)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// Tracks the last HTML string loaded so we can skip redundant reloads.
        var lastLoadedHTML: String = ""

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Allow the initial HTML string load; cancel any link navigations.
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }

    // MARK: - HTML Page Builder

    private func buildHTMLPage(markdownContent: String) -> String {
        var converter = MarkdownToHTMLConverter()
        let bodyHTML = converter.convert(markdownContent)
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        ::-webkit-scrollbar { width: 6px; }
        ::-webkit-scrollbar-track { background: transparent; }
        ::-webkit-scrollbar-thumb { background: #2a352a; border-radius: 3px; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
            font-size: 13px;
            line-height: 1.68;
            color: #c8d0c8;
            background: #0e0f0e;
            padding: 24px 32px 48px;
            -webkit-font-smoothing: antialiased;
        }
        h1 {
            font-size: 19px; font-weight: 700;
            color: #67d49f;
            margin: 28px 0 10px;
            letter-spacing: -0.2px;
        }
        h1:first-child { margin-top: 0; }
        h2 {
            font-size: 14px; font-weight: 600;
            color: #b0c0b0;
            margin: 22px 0 7px;
        }
        h3 {
            font-size: 13px; font-weight: 500;
            color: #8a9a8a;
            margin: 16px 0 5px;
        }
        h4 {
            font-size: 12px; font-weight: 500;
            color: #768076;
            margin: 12px 0 4px;
        }
        p { margin: 4px 0 8px; }
        strong { font-weight: 600; color: #e4ece4; }
        em { font-style: italic; color: #b4c4b4; }
        ul { padding-left: 20px; margin: 5px 0 9px; list-style-type: disc; }
        ol { padding-left: 20px; margin: 5px 0 9px; }
        li { margin: 3px 0; padding-left: 3px; }
        li::marker { color: #4a6a50; }
        code {
            font-family: 'SF Mono', Menlo, Monaco, monospace;
            font-size: 11.5px;
            background: #181e18;
            color: #9fd4b8;
            padding: 1px 5px;
            border-radius: 3px;
            border: 1px solid #242c24;
        }
        pre {
            background: #131713;
            border: 1px solid #1e271e;
            border-radius: 7px;
            padding: 13px 16px;
            margin: 10px 0;
            overflow-x: auto;
        }
        pre code {
            background: none; border: none; padding: 0;
            font-size: 12px; color: #a8d0b8; line-height: 1.6;
        }
        blockquote {
            border-left: 3px solid #3a5a42;
            padding: 6px 14px;
            margin: 8px 0;
            color: #8a9a8a;
            background: #111711;
            border-radius: 0 4px 4px 0;
        }
        hr {
            border: none;
            border-top: 1px solid #1c221c;
            margin: 20px 0;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 12px 0 16px;
            font-size: 12.5px;
        }
        th {
            background: #141e14;
            color: #9ab09a;
            font-weight: 600;
            text-align: left;
            padding: 8px 12px;
            border: 1px solid #1e2a1e;
        }
        td {
            padding: 7px 12px;
            border: 1px solid #1a221a;
            color: #bccbbc;
            vertical-align: top;
        }
        tr:nth-child(even) td { background: #111511; }
        </style>
        </head>
        <body>
        \(bodyHTML)
        </body>
        </html>
        """
    }
}

// MARK: - MarkdownToHTMLConverter

/// Converts a markdown string to an HTML body fragment.
/// Handles: H1–H4, bold, italic, inline code, unordered lists, ordered lists,
/// tables (with header/separator/data rows), fenced code blocks, blockquotes, and HR.
private struct MarkdownToHTMLConverter {

    private var output: String = ""
    private var inUnorderedList: Bool = false
    private var inOrderedList: Bool = false
    private var inCodeBlock: Bool = false
    private var inTable: Bool = false

    mutating func convert(_ markdown: String) -> String {
        output = ""
        inUnorderedList = false
        inOrderedList = false
        inCodeBlock = false
        inTable = false

        let lines = markdown.components(separatedBy: "\n")
        var lineIndex = 0

        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // --- Fenced code block ---
            if trimmedLine.hasPrefix("```") {
                if inCodeBlock {
                    output += "</code></pre>"
                    inCodeBlock = false
                } else {
                    closeAllOpenBlocks()
                    let languageTag = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    let classAttr = languageTag.isEmpty ? "" : " class=\"language-\(escapeAttr(languageTag))\""
                    output += "<pre><code\(classAttr)>"
                    inCodeBlock = true
                }
                lineIndex += 1
                continue
            }

            if inCodeBlock {
                output += escapeHTML(line) + "\n"
                lineIndex += 1
                continue
            }

            // --- Table: header row followed by separator ---
            let lineHasPipe = line.contains("|")
            let nextLineIsTableSeparator = lineIndex + 1 < lines.count
                && lines[lineIndex + 1].contains("|")
                && lines[lineIndex + 1].contains("-")

            if lineHasPipe && nextLineIsTableSeparator && !inTable {
                closeAllOpenBlocks()
                let headerCells = splitTableRow(line)
                output += "<table><thead><tr>"
                for cell in headerCells {
                    output += "<th>\(renderInlineMarkdown(cell))</th>"
                }
                output += "</tr></thead><tbody>"
                inTable = true
                lineIndex += 2  // consume header row + separator row
                continue
            }

            if inTable && lineHasPipe && !trimmedLine.isEmpty {
                let dataCells = splitTableRow(line)
                output += "<tr>"
                for cell in dataCells {
                    output += "<td>\(renderInlineMarkdown(cell))</td>"
                }
                output += "</tr>"
                lineIndex += 1
                continue
            }

            if inTable {
                closeTable()
                // Fall through to process this non-table line normally.
            }

            // --- Headings (check longer prefixes first to avoid false matches) ---
            if line.hasPrefix("#### ") {
                closeAllOpenBlocks()
                output += "<h4>\(renderInlineMarkdown(String(line.dropFirst(5))))</h4>"
            } else if line.hasPrefix("### ") {
                closeAllOpenBlocks()
                output += "<h3>\(renderInlineMarkdown(String(line.dropFirst(4))))</h3>"
            } else if line.hasPrefix("## ") {
                closeAllOpenBlocks()
                output += "<h2>\(renderInlineMarkdown(String(line.dropFirst(3))))</h2>"
            } else if line.hasPrefix("# ") {
                closeAllOpenBlocks()
                output += "<h1>\(renderInlineMarkdown(String(line.dropFirst(2))))</h1>"

            // --- Horizontal rule ---
            } else if trimmedLine == "---" || trimmedLine == "***" || trimmedLine == "___" {
                closeAllOpenBlocks()
                output += "<hr>"

            // --- Blockquote ---
            } else if line.hasPrefix("> ") {
                closeAllOpenBlocks()
                output += "<blockquote>\(renderInlineMarkdown(String(line.dropFirst(2))))</blockquote>"

            // --- Unordered list item ---
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                if inOrderedList { output += "</ol>"; inOrderedList = false }
                if inTable { closeTable() }
                if !inUnorderedList { output += "<ul>"; inUnorderedList = true }
                output += "<li>\(renderInlineMarkdown(String(line.dropFirst(2))))</li>"

            // --- Ordered list item (matches "1. ", "2. ", etc.) ---
            } else if let orderedItemText = extractOrderedListItemText(from: trimmedLine) {
                if inUnorderedList { output += "</ul>"; inUnorderedList = false }
                if inTable { closeTable() }
                if !inOrderedList { output += "<ol>"; inOrderedList = true }
                output += "<li>\(renderInlineMarkdown(orderedItemText))</li>"

            // --- Empty line ---
            } else if trimmedLine.isEmpty {
                closeLists()
                closeTable()
                // Blank lines are handled by CSS margins — no explicit element needed.

            // --- Regular paragraph ---
            } else {
                closeAllOpenBlocks()
                output += "<p>\(renderInlineMarkdown(line))</p>"
            }

            lineIndex += 1
        }

        // Close any blocks still open at end of input
        if inUnorderedList { output += "</ul>" }
        if inOrderedList   { output += "</ol>" }
        if inTable         { output += "</tbody></table>" }
        if inCodeBlock     { output += "</code></pre>" }

        return output
    }

    // MARK: - Block Management

    private mutating func closeLists() {
        if inUnorderedList { output += "</ul>"; inUnorderedList = false }
        if inOrderedList   { output += "</ol>"; inOrderedList = false }
    }

    private mutating func closeTable() {
        if inTable { output += "</tbody></table>"; inTable = false }
    }

    private mutating func closeAllOpenBlocks() {
        closeLists()
        closeTable()
    }

    // MARK: - Table Helpers

    /// Splits a markdown table row string on `|`, trimming empty leading/trailing cells
    /// produced by the surrounding pipe characters.
    private func splitTableRow(_ rowLine: String) -> [String] {
        var cells = rowLine.components(separatedBy: "|")
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true  { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Ordered List Detection

    /// Returns the list item text if the line matches an ordered list pattern (e.g. "1. text").
    /// Returns nil if the line is not an ordered list item.
    private func extractOrderedListItemText(from line: String) -> String? {
        guard let firstChar = line.first, firstChar.isNumber else { return nil }
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let afterDot = line.index(after: dotIndex)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        let textStart = line.index(afterDot, offsetBy: 1)
        return String(line[textStart...])
    }

    // MARK: - Inline Markdown Rendering

    /// Renders inline markdown within a single line of text:
    /// inline code, bold (**text** / __text__), italic (*text* / _text_).
    private func renderInlineMarkdown(_ text: String) -> String {
        var result = escapeHTML(text)
        // Inline code first so ** inside backtick spans isn't processed as bold.
        result = applyRegex(result, pattern: #"`([^`]+)`"#, replacement: "<code>$1</code>")
        // Bold
        result = applyRegex(result, pattern: #"\*\*(.+?)\*\*"#, replacement: "<strong>$1</strong>")
        result = applyRegex(result, pattern: #"__(.+?)__"#, replacement: "<strong>$1</strong>")
        // Italic (single asterisk/underscore, not adjacent to another of the same character)
        result = applyRegex(result, pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, replacement: "<em>$1</em>")
        result = applyRegex(result, pattern: #"(?<!_)_(?!_)(.+?)(?<!_)_(?!_)"#, replacement: "<em>$1</em>")
        return result
    }

    // MARK: - Escaping

    private func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func escapeAttr(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func applyRegex(_ text: String, pattern: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
