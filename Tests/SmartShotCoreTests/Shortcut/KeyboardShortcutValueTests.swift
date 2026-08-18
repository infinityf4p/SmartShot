import Carbon
import XCTest
@testable import SmartShotCore

final class KeyboardShortcutValueTests: XCTestCase {
    func testCodableRoundTripPersistsOnlyStableValues() throws {
        let shortcut = KeyboardShortcutValue(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(cmdKey | optionKey) | 0x8000_0000
        )

        let data = try JSONEncoder().encode(shortcut)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(KeyboardShortcutValue.self, from: data)

        XCTAssertEqual(Set(object.keys), ["schemaVersion", "keyCode", "modifiers"])
        XCTAssertEqual(decoded, shortcut)
        XCTAssertEqual(decoded.modifiers, UInt32(cmdKey | optionKey))
    }

    func testNormalizationKeepsOnlySupportedCarbonModifiers() {
        let allSupported = UInt32(cmdKey | optionKey | controlKey | shiftKey)

        XCTAssertEqual(
            KeyboardShortcutValue.normalizedModifiers(allSupported | 0x8000_0000),
            allSupported
        )
    }

    func testDefaultsAndDisplayNames() throws {
        let defaultShortcut = KeyboardShortcutValue.defaultCapture
        let fallbackShortcut = KeyboardShortcutValue.fallbackCapture

        XCTAssertEqual(defaultShortcut.schemaVersion, KeyboardShortcutValue.currentSchemaVersion)
        XCTAssertEqual(defaultShortcut.keyCode, UInt32(kVK_ANSI_2))
        XCTAssertEqual(defaultShortcut.modifiers, UInt32(controlKey | shiftKey))
        XCTAssertEqual(defaultShortcut.displayName, "⌃⇧2")
        XCTAssertEqual(defaultShortcut.accessibilityDisplayName, "Control Shift 2")
        XCTAssertEqual(fallbackShortcut.keyCode, UInt32(kVK_ANSI_2))
        XCTAssertEqual(fallbackShortcut.modifiers, UInt32(controlKey | optionKey))
        XCTAssertEqual(fallbackShortcut.displayName, "⌃⌥2")
        XCTAssertNoThrow(try defaultShortcut.validate())
        XCTAssertNoThrow(try fallbackShortcut.validate())
    }

    func testValidLetterArrowSpecialAndFunctionKeyCombinations() {
        let keyCodes = [
            UInt32(kVK_ANSI_A), UInt32(kVK_ANSI_7), UInt32(kVK_LeftArrow),
            UInt32(kVK_Space), UInt32(kVK_Return), UInt32(kVK_Delete),
            UInt32(kVK_Tab), UInt32(kVK_F1), UInt32(kVK_F12),
        ]

        for keyCode in keyCodes {
            let shortcut = KeyboardShortcutValue(
                keyCode: keyCode,
                modifiers: UInt32(controlKey | optionKey)
            )
            XCTAssertNoThrow(try shortcut.validate(), "Expected key code \(keyCode) to be valid")
        }
    }

    func testInsufficientModifiersAreRejected() {
        assertValidationError(
            .insufficientModifiers,
            for: KeyboardShortcutValue(
                keyCode: UInt32(kVK_ANSI_A),
                modifiers: UInt32(controlKey)
            )
        )
    }

    func testEscapeIsRejected() {
        assertValidationError(
            .escapeNotAllowed,
            for: KeyboardShortcutValue(
                keyCode: UInt32(kVK_Escape),
                modifiers: UInt32(controlKey | shiftKey)
            )
        )
    }

    func testUnknownKeyCodeIsRejected() {
        let unknownKeyCode = UInt32.max
        assertValidationError(
            .unsupportedKeyCode(unknownKeyCode),
            for: KeyboardShortcutValue(
                keyCode: unknownKeyCode,
                modifiers: UInt32(controlKey | shiftKey)
            )
        )
    }

    func testDangerousCommandCombinationsAreRejectedEvenWithExtraModifiers() {
        let keyCodes = [
            UInt32(kVK_ANSI_Q),
            UInt32(kVK_ANSI_H),
            UInt32(kVK_ANSI_M),
            UInt32(kVK_ANSI_W),
        ]

        for keyCode in keyCodes {
            assertValidationError(
                .dangerousSystemShortcut(keyCode),
                for: KeyboardShortcutValue(
                    keyCode: keyCode,
                    modifiers: UInt32(cmdKey | shiftKey)
                )
            )
        }
    }

    func testUnsupportedSchemaVersionIsRejected() {
        assertValidationError(
            .unsupportedSchemaVersion(99),
            for: KeyboardShortcutValue(
                schemaVersion: 99,
                keyCode: UInt32(kVK_ANSI_A),
                modifiers: UInt32(controlKey | shiftKey)
            )
        )
    }

    private func assertValidationError(
        _ expectedError: KeyboardShortcutValidationError,
        for shortcut: KeyboardShortcutValue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try shortcut.validate(), file: file, line: line) { error in
            XCTAssertEqual(error as? KeyboardShortcutValidationError, expectedError, file: file, line: line)
        }
    }
}
