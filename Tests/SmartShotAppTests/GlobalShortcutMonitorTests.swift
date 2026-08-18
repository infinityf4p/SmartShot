import SmartShotCore
import Carbon
import XCTest

@MainActor
final class GlobalShortcutMonitorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "com.infinityf4p.SmartShotTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testSuccessfulUpdatePersistsAndReloadsShortcut() throws {
        let shortcut = testShortcut(keyCode: UInt32(kVK_F9))
        let first = GlobalShortcutMonitor(defaults: defaults) {}
        defer { first.stop() }

        XCTAssertEqual(first.update(to: shortcut), .updated(shortcut))
        XCTAssertEqual(first.registration, .registered(shortcut))
        first.stop()

        let second = GlobalShortcutMonitor(defaults: defaults) {}
        defer { second.stop() }
        XCTAssertEqual(second.start(), .registered(shortcut))
    }

    func testStoredBuiltInShortcutFallsBackWhenItBecomesOccupied() throws {
        let stored = KeyboardShortcutValue.defaultCapture
        let alternate = KeyboardShortcutValue.fallbackCapture
        let data = try JSONEncoder().encode(stored)
        defaults.set(data, forKey: "captureShortcut.v1")

        var alternateProbe: EventHotKeyRef?
        let alternateStatus = RegisterEventHotKey(
            alternate.keyCode,
            alternate.modifiers,
            EventHotKeyID(signature: 0x42535454, id: 92),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &alternateProbe
        )
        if let alternateProbe { UnregisterEventHotKey(alternateProbe) }
        if alternateStatus == OSStatus(eventHotKeyExistsErr) {
            throw XCTSkip("The fallback shortcut is occupied by another process")
        }
        XCTAssertEqual(alternateStatus, noErr)

        var blocker: EventHotKeyRef?
        let blockerStatus = RegisterEventHotKey(
            stored.keyCode,
            stored.modifiers,
            EventHotKeyID(signature: 0x42535454, id: 93),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &blocker
        )
        guard blockerStatus == noErr || blockerStatus == OSStatus(eventHotKeyExistsErr) else {
            XCTFail("Could not establish the occupied-shortcut precondition: \(blockerStatus)")
            return
        }
        defer {
            if let blocker { UnregisterEventHotKey(blocker) }
        }

        let monitor = GlobalShortcutMonitor(defaults: defaults) {}
        defer { monitor.stop() }
        XCTAssertEqual(monitor.start(), .registered(alternate))

        let savedData = try XCTUnwrap(defaults.data(forKey: "captureShortcut.v1"))
        XCTAssertEqual(try JSONDecoder().decode(KeyboardShortcutValue.self, from: savedData), alternate)
    }

    func testConflictKeepsPreviousRegistrationAndPreference() throws {
        let current = testShortcut(keyCode: UInt32(kVK_F9))
        let occupied = testShortcut(keyCode: UInt32(kVK_F10))
        let monitor = GlobalShortcutMonitor(defaults: defaults) {}
        defer { monitor.stop() }
        XCTAssertEqual(monitor.update(to: current), .updated(current))

        var occupiedReference: EventHotKeyRef?
        let occupiedID = EventHotKeyID(signature: 0x42535454, id: 90)
        XCTAssertEqual(
            RegisterEventHotKey(
                occupied.keyCode,
                occupied.modifiers,
                occupiedID,
                GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive),
                &occupiedReference
            ),
            noErr
        )
        defer {
            if let occupiedReference { UnregisterEventHotKey(occupiedReference) }
        }

        XCTAssertEqual(monitor.update(to: occupied), .conflict(occupied))
        XCTAssertEqual(monitor.registration, .registered(current))

        monitor.stop()
        let reloaded = GlobalShortcutMonitor(defaults: defaults) {}
        defer { reloaded.stop() }
        XCTAssertEqual(reloaded.start(), .registered(current))
    }

    func testInvalidUpdateKeepsCurrentShortcut() {
        let current = testShortcut(keyCode: UInt32(kVK_F9))
        let invalid = KeyboardShortcutValue(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(controlKey)
        )
        let monitor = GlobalShortcutMonitor(defaults: defaults) {}
        defer { monitor.stop() }
        XCTAssertEqual(monitor.update(to: current), .updated(current))

        XCTAssertEqual(monitor.update(to: invalid), .invalid(.insufficientModifiers))
        XCTAssertEqual(monitor.registration, .registered(current))
    }

    func testRecordingGateAndActiveIdentifierFilterDelivery() {
        var actionCount = 0
        let shortcut = testShortcut(keyCode: UInt32(kVK_F9))
        let monitor = GlobalShortcutMonitor(defaults: defaults) { actionCount += 1 }
        defer { monitor.stop() }
        XCTAssertEqual(monitor.update(to: shortcut), .updated(shortcut))
        let activeID = try! XCTUnwrap(monitor.activeID)

        monitor.receiveHotKey(withID: activeID &+ 1)
        XCTAssertEqual(actionCount, 0)

        var recordedShortcut: KeyboardShortcutValue?
        monitor.beginRecording { recordedShortcut = $0 }
        monitor.receiveHotKey(withID: activeID)
        XCTAssertEqual(actionCount, 0)
        XCTAssertEqual(recordedShortcut, shortcut)

        monitor.endRecording()
        monitor.receiveHotKey(withID: activeID)
        XCTAssertEqual(actionCount, 1)
    }

    func testRecordingKeepsCurrentShortcutExclusivelyRegistered() {
        let shortcut = testShortcut(keyCode: UInt32(kVK_F9))
        let monitor = GlobalShortcutMonitor(defaults: defaults) {}
        defer { monitor.stop() }
        XCTAssertEqual(monitor.update(to: shortcut), .updated(shortcut))

        monitor.beginRecording { _ in }
        var probe: EventHotKeyRef?
        XCTAssertEqual(
            RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers,
                EventHotKeyID(signature: 0x42535454, id: 91),
                GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive),
                &probe
            ),
            OSStatus(eventHotKeyExistsErr)
        )
        if let probe { UnregisterEventHotKey(probe) }
        monitor.endRecording()
    }

    private func testShortcut(keyCode: UInt32) -> KeyboardShortcutValue {
        KeyboardShortcutValue(
            keyCode: keyCode,
            modifiers: UInt32(controlKey | optionKey | shiftKey)
        )
    }
}
