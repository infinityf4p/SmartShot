import AppKit
import SmartShotCore
import Carbon
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: KeyboardShortcutValue
    let onBeginRecording: (@escaping (KeyboardShortcutValue) -> Void) -> Void
    let onEndRecording: () -> Void
    let onCommit: (KeyboardShortcutValue) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.shortcut = shortcut
        button.onBeginRecording = onBeginRecording
        button.onEndRecording = onEndRecording
        button.onCommit = onCommit
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.shortcut = shortcut
        button.onBeginRecording = onBeginRecording
        button.onEndRecording = onEndRecording
        button.onCommit = onCommit
        button.refreshTitle()
    }

    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) {
        button.stopRecording()
    }
}

@MainActor
final class ShortcutRecorderButton: NSButton {
    var shortcut: KeyboardShortcutValue = .defaultCapture
    var onBeginRecording: (((@escaping (KeyboardShortcutValue) -> Void) -> Void))?
    var onEndRecording: (() -> Void)?
    var onCommit: ((KeyboardShortcutValue) -> Void)?

    private var localMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private(set) var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = shortcut.displayName
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        focusRingType = .exterior
        setAccessibilityLabel(L10n.text("Capture shortcut"))
        setAccessibilityHelp(L10n.text("Click, then press a key with at least two modifiers"))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func refreshTitle() {
        guard !isRecording else { return }
        title = shortcut.displayName
        setAccessibilityValue(shortcut.accessibilityDisplayName)
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        onEndRecording?()
        refreshTitle()
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        onBeginRecording? { [weak self] shortcut in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.stopRecording()
                self.onCommit?(shortcut)
            }
        }
        title = L10n.text("Type shortcut")
        setAccessibilityValue(L10n.text("Recording shortcut"))
        window?.makeFirstResponder(self)

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopRecording() }
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }
        switch event.type {
        case .flagsChanged:
            title = modifierDisplayName(for: event.modifierFlags).nilIfEmpty ?? L10n.text("Type shortcut")
            return nil
        case .keyDown:
            guard !event.isARepeat else { return nil }
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            let value = KeyboardShortcutValue(
                keyCode: UInt32(event.keyCode),
                modifiers: carbonModifiers(for: event.modifierFlags)
            )
            stopRecording()
            onCommit?(value)
            return nil
        case .leftMouseDown:
            if let eventWindow = event.window, eventWindow == window {
                let point = convert(event.locationInWindow, from: nil)
                if bounds.contains(point) {
                    stopRecording()
                    return nil
                }
            }
            stopRecording()
            return event
        default:
            return event
        }
    }

    private func carbonModifiers(for flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    private func modifierDisplayName(for flags: NSEvent.ModifierFlags) -> String {
        var value = ""
        if flags.contains(.control) { value += "⌃" }
        if flags.contains(.option) { value += "⌥" }
        if flags.contains(.shift) { value += "⇧" }
        if flags.contains(.command) { value += "⌘" }
        return value
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
