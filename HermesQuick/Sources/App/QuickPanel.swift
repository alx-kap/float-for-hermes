import AppKit
import SwiftUI

/// Observable bit the SwiftUI tree uses to run its own entrance/exit animation.
@Observable
final class PanelPresentation {
    var isPresented = false
    var focusToken = 0
    /// Set by the controller: refit the window to the card's saved size.
    @ObservationIgnored var refit: () -> Void = {}
}

/// A borderless, transparent floating panel (Spotlight-style). The window is fixed-size and
/// fully transparent; SwiftUI draws and animates the glass card inside it, and clicks on the
/// transparent margin fall through to whatever is underneath.
final class QuickPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(content: some View) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.fittingSize()),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false

        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        contentView = host
    }

    /// The transparent window is the card plus room for its shadow, the error pill and cards that grow
    /// the content; the message list shrinks to fit before anything can overflow (see QuickChatView).
    static func fittingSize() -> NSSize {
        let prefs = Preferences.shared
        return NSSize(width: prefs.panelWidth + 80, height: prefs.listHeight + 280)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class PanelController {
    let presentation = PanelPresentation()
    private var panel: QuickPanel!
    private var hideWork: DispatchWorkItem?
    var onShow: (() -> Void)?

    private var pasteMonitor: Any?

    #if DEBUG
    var window: NSWindow { panel }
    #endif

    init(store: ChatStore) {
        let root = QuickChatView()
            .environment(store)
            .environment(presentation)
        panel = QuickPanel(content: root)
        panel.onCancel = { [weak self] in self?.hide() }
        presentation.refit = { [weak self] in self?.refit() }
        // ⌘V with a copied file or image attaches it instead of pasting text.
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak store] event in
            guard let self, let store, event.window === self.panel else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods == .command, event.charactersIgnoringModifiers == "k" {
                store.toggleHistory()
                return nil
            }
            // Past-chats list: arrows and return drive the list while the search field keeps typing.
            if store.showingHistory {
                if mods == .command, event.charactersIgnoringModifiers == "n" { store.newChat(); return nil }
                if mods.isEmpty {
                    switch event.keyCode {
                    case 125: store.moveHistory(1); return nil      // ↓
                    case 126: store.moveHistory(-1); return nil     // ↑
                    case 36, 76: store.openSelectedHistory(); return nil
                    case 53: store.closeHistory(); return nil       // esc goes back to the chat
                    default: break
                    }
                }
            }
            // Slash menu keys win over the text field.
            if store.showSlash, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                switch event.keyCode {
                case 125: store.moveSlash(1); return nil          // ↓
                case 126: store.moveSlash(-1); return nil         // ↑
                case 48: store.insertSlash(); return nil          // ⇥
                case 36, 76: store.runSelectedSlash(); return nil // ↩
                case 53: store.dismissSlash(); return nil         // esc
                default: break
                }
            }
            if mods.isEmpty, !store.showSlash, !store.showingHistory {
                // esc leaves edit mode instead of hiding the panel.
                if event.keyCode == 53, store.editingMessageId != nil { store.cancelEdit(); return nil }
                // ↑ in an empty composer brings back the last message (not while a card's own field has focus).
                if event.keyCode == 126, !(self.panel.firstResponder is NSSecureTextField),
                   store.activePrompt == nil, store.recallLastPrompt() { return nil }
            }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v" else { return event }
            let pb = NSPasteboard.general
            let hasFiles = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasImage = pb.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]) != nil
            guard hasFiles || (hasImage && (text.isEmpty || text.hasPrefix("http"))) else { return event }
            let items = Attachment.fromPasteboard(pb)
            guard !items.isEmpty else { return event }
            store.addAttachments(items)
            return nil
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                UserDefaults.standard.set(NSStringFromPoint(self.panel.frame.origin), forKey: "panelOrigin")
            }
        }
    }

    var isVisible: Bool { panel.isVisible && presentation.isPresented }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        hideWork?.cancel()
        if !panel.isVisible { position() }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            presentation.isPresented = true
        }
        presentation.focusToken += 1
        onShow?()
    }

    func hide() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.95)) {
            presentation.isPresented = false
        }
        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
            NSApp.hide(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    /// Resize the window to the card's saved size, keeping its top edge and horizontal centre in place,
    /// so dragging either side grows the card evenly like Spotlight.
    private func refit() {
        let size = QuickPanel.fittingSize()
        let old = panel.frame
        guard old.size != size else { return }
        panel.setFrame(NSRect(x: (old.midX - size.width / 2).rounded(), y: old.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    /// Reuse the spot the panel was last dragged to; otherwise centre it on the screen with the mouse.
    private func position() {
        if let saved = UserDefaults.standard.string(forKey: "panelOrigin") {
            let origin = NSPointFromString(saved)
            let frame = NSRect(origin: origin, size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame.insetBy(dx: 200, dy: 200)) }) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = vf.midX - size.width / 2
        let y = vf.maxY - size.height - vf.height * 0.08
        panel.setFrameOrigin(NSPoint(x: x, y: max(vf.minY, y)))
    }
}
