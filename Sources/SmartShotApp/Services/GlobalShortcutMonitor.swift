import SmartShotCore
import Carbon
import Foundation

@MainActor
final class GlobalShortcutMonitor {
    enum Registration: Equatable {
        case inactive
        case registered(KeyboardShortcutValue)
        case conflict(KeyboardShortcutValue)
        case failed(KeyboardShortcutValue?, OSStatus)
    }

    enum UpdateResult: Equatable {
        case updated(KeyboardShortcutValue)
        case unchanged(KeyboardShortcutValue)
        case conflict(KeyboardShortcutValue)
        case invalid(KeyboardShortcutValidationError)
        case failed(KeyboardShortcutValue, OSStatus)
        case persistenceFailed(KeyboardShortcutValue)
    }

    private enum StoredShortcut {
        case missing
        case valid(KeyboardShortcutValue)
        case invalid
    }

    private static let preferenceKey = "captureShortcut.v1"

    private var hotKey: EventHotKeyRef?
    private(set) var activeID: UInt32?
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private var isRecording = false
    private var recordedActiveShortcutAction: ((KeyboardShortcutValue) -> Void)?
    private let action: () -> Void
    private let defaults: UserDefaults
    private(set) var registration: Registration = .inactive

    init(defaults: UserDefaults = .standard, action: @escaping () -> Void) {
        self.defaults = defaults
        self.action = action
    }

    var configuredShortcut: KeyboardShortcutValue {
        switch registration {
        case let .registered(shortcut), let .conflict(shortcut):
            shortcut
        case let .failed(shortcut?, _):
            shortcut
        case .inactive, .failed(nil, _):
            if case let .valid(shortcut) = loadStoredShortcut() { shortcut } else { .defaultCapture }
        }
    }

    @discardableResult
    func start() -> Registration {
        if hotKey != nil { return registration }
        guard installEventHandlerIfNeeded() == noErr else { return registration }

        switch loadStoredShortcut() {
        case let .valid(shortcut):
            if shortcut == .defaultCapture || shortcut == .fallbackCapture {
                registration = registerBuiltInShortcut(startingWith: shortcut)
            } else {
                registration = registerInitial(shortcut, persist: false)
            }
        case .missing, .invalid:
            registration = registerBuiltInShortcut(startingWith: .defaultCapture)
        }
        return registration
    }

    func update(to shortcut: KeyboardShortcutValue) -> UpdateResult {
        do {
            try shortcut.validate()
        } catch let error as KeyboardShortcutValidationError {
            return .invalid(error)
        } catch {
            return .failed(shortcut, OSStatus(paramErr))
        }

        if case let .registered(current) = registration, current == shortcut {
            return .unchanged(current)
        }

        let handlerStatus = installEventHandlerIfNeeded()
        guard handlerStatus == noErr else { return .failed(shortcut, handlerStatus) }

        let identifier = makeIdentifier()
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &candidate
        )
        guard status == noErr, let candidate else {
            if let candidate { UnregisterEventHotKey(candidate) }
            return status == OSStatus(eventHotKeyExistsErr)
                ? .conflict(shortcut)
                : .failed(shortcut, status)
        }

        guard save(shortcut) else {
            UnregisterEventHotKey(candidate)
            return .persistenceFailed(shortcut)
        }

        let previous = hotKey
        hotKey = candidate
        activeID = identifier.id
        registration = .registered(shortcut)
        if let previous { UnregisterEventHotKey(previous) }
        return .updated(shortcut)
    }

    func beginRecording(onActiveShortcut: @escaping (KeyboardShortcutValue) -> Void) {
        isRecording = true
        recordedActiveShortcutAction = onActiveShortcut
    }

    func endRecording() {
        isRecording = false
        recordedActiveShortcutAction = nil
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        activeID = nil
        removeEventHandler()
        registration = .inactive
    }

    private func registerBuiltInShortcut(
        startingWith preferred: KeyboardShortcutValue
    ) -> Registration {
        let alternate: KeyboardShortcutValue = preferred == .defaultCapture
            ? .fallbackCapture
            : .defaultCapture
        for shortcut in [preferred, alternate] {
            let result = registerInitial(shortcut, persist: true)
            switch result {
            case .registered, .failed:
                return result
            case .conflict:
                continue
            case .inactive:
                break
            }
        }
        return .conflict(preferred)
    }

    private func registerInitial(_ shortcut: KeyboardShortcutValue, persist: Bool) -> Registration {
        do {
            try shortcut.validate()
        } catch {
            return .failed(shortcut, OSStatus(paramErr))
        }

        let identifier = makeIdentifier()
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &candidate
        )
        guard status == noErr, let candidate else {
            if let candidate { UnregisterEventHotKey(candidate) }
            return status == OSStatus(eventHotKeyExistsErr)
                ? .conflict(shortcut)
                : .failed(shortcut, status)
        }

        if persist && !save(shortcut) {
            UnregisterEventHotKey(candidate)
            return .failed(shortcut, OSStatus(paramErr))
        }

        hotKey = candidate
        activeID = identifier.id
        return .registered(shortcut)
    }

    private func installEventHandlerIfNeeded() -> OSStatus {
        guard eventHandler == nil else { return noErr }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var receivedID = EventHotKeyID()
                let readStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )
                guard readStatus == noErr, receivedID.signature == blockShotHotKeySignature else {
                    return readStatus == noErr ? OSStatus(eventNotHandledErr) : readStatus
                }
                let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in monitor.receiveHotKey(withID: receivedID.id) }
                return noErr
            },
            1,
            &eventType,
            pointer,
            &eventHandler
        )
        if status != noErr {
            eventHandler = nil
            registration = .failed(nil, status)
        }
        return status
    }

    func receiveHotKey(withID identifier: UInt32) {
        guard identifier == activeID else { return }
        if isRecording, case let .registered(shortcut) = registration {
            recordedActiveShortcutAction?(shortcut)
            return
        }
        action()
    }

    private func makeIdentifier() -> EventHotKeyID {
        defer {
            nextID = nextID == UInt32.max ? 1 : nextID + 1
        }
        return EventHotKeyID(signature: blockShotHotKeySignature, id: nextID)
    }

    private func loadStoredShortcut() -> StoredShortcut {
        guard let data = defaults.data(forKey: Self.preferenceKey) else { return .missing }
        guard let shortcut = try? JSONDecoder().decode(KeyboardShortcutValue.self, from: data) else {
            return .invalid
        }
        do {
            try shortcut.validate()
            return .valid(shortcut)
        } catch {
            return .invalid
        }
    }

    private func save(_ shortcut: KeyboardShortcutValue) -> Bool {
        guard let data = try? JSONEncoder().encode(shortcut) else { return false }
        defaults.set(data, forKey: Self.preferenceKey)
        return defaults.data(forKey: Self.preferenceKey) == data
    }

    private func removeEventHandler() {
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }
}

enum TransientEscapeHotKeyRegistration: Equatable {
    case registered
    case unavailable(OSStatus)

    var fallbackInstruction: String? {
        switch self {
        case .registered:
            nil
        case .unavailable:
            L10n.text("Esc unavailable - click Cancel")
        }
    }

    func detailText(_ detail: String) -> String {
        guard let fallbackInstruction else { return detail }
        return "\(fallbackInstruction). \(detail)"
    }
}

@MainActor
final class TransientEscapeHotKeyMonitor {
    typealias RegistrationHandler = (EventHotKeyID, inout EventHotKeyRef?) -> OSStatus

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let registrationHandler: RegistrationHandler
    private let action: () -> Void
    private(set) var activeID: UInt32?
    private static var nextID: UInt32 = 1

    init(
        registrationHandler: RegistrationHandler? = nil,
        action: @escaping () -> Void
    ) {
        self.registrationHandler = registrationHandler ?? { identifier, candidate in
            RegisterEventHotKey(
                UInt32(kVK_Escape),
                0,
                identifier,
                GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive),
                &candidate
            )
        }
        self.action = action
    }

    @discardableResult
    func start() -> TransientEscapeHotKeyRegistration {
        guard hotKey == nil else { return .registered }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var receivedID = EventHotKeyID()
                let readStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )
                guard readStatus == noErr,
                      receivedID.signature == smartShotEscapeHotKeySignature else {
                    return readStatus == noErr ? OSStatus(eventNotHandledErr) : readStatus
                }
                let monitor = Unmanaged<TransientEscapeHotKeyMonitor>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor in
                    monitor.receiveHotKey(withID: receivedID.id)
                }
                return noErr
            },
            1,
            &eventType,
            pointer,
            &eventHandler
        )
        guard handlerStatus == noErr else {
            eventHandler = nil
            return .unavailable(handlerStatus)
        }

        let identifier = Self.makeIdentifier()
        var candidate: EventHotKeyRef?
        let registrationStatus = registrationHandler(identifier, &candidate)
        guard registrationStatus == noErr else {
            if let candidate { UnregisterEventHotKey(candidate) }
            removeEventHandler()
            return .unavailable(registrationStatus)
        }
        guard let candidate else {
            removeEventHandler()
            return .unavailable(OSStatus(paramErr))
        }

        hotKey = candidate
        activeID = identifier.id
        return .registered
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        activeID = nil
        removeEventHandler()
    }

    func receiveHotKey(withID identifier: UInt32) {
        guard identifier == activeID else { return }
        action()
    }

    private func removeEventHandler() {
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    private static func makeIdentifier() -> EventHotKeyID {
        defer { nextID = nextID == UInt32.max ? 1 : nextID + 1 }
        return EventHotKeyID(signature: smartShotEscapeHotKeySignature, id: nextID)
    }
}

private let blockShotHotKeySignature: FourCharCode = 0x424C5348
private let smartShotEscapeHotKeySignature: FourCharCode = 0x53534553
