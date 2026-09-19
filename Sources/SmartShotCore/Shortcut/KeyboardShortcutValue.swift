import Carbon
import Foundation

public struct KeyboardShortcutValue: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public static let defaultCapture = KeyboardShortcutValue(
        keyCode: UInt32(kVK_ANSI_2),
        modifiers: UInt32(controlKey | shiftKey)
    )

    public static let fallbackCapture = KeyboardShortcutValue(
        keyCode: UInt32(kVK_ANSI_2),
        modifiers: UInt32(controlKey | optionKey)
    )

    public let schemaVersion: Int
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        keyCode: UInt32,
        modifiers: UInt32
    ) {
        self.schemaVersion = schemaVersion
        self.keyCode = keyCode
        self.modifiers = Self.normalizedModifiers(modifiers)
    }

    public static func normalizedModifiers(_ modifiers: UInt32) -> UInt32 {
        modifiers & supportedModifierMask
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw KeyboardShortcutValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard keyCode != UInt32(kVK_Escape) else {
            throw KeyboardShortcutValidationError.escapeNotAllowed
        }
        guard Self.keyNames[keyCode] != nil else {
            throw KeyboardShortcutValidationError.unsupportedKeyCode(keyCode)
        }
        if modifiers & UInt32(cmdKey) != 0, Self.dangerousCommandKeyCodes.contains(keyCode) {
            throw KeyboardShortcutValidationError.dangerousSystemShortcut(keyCode)
        }
        guard modifiers.nonzeroBitCount >= 2 else {
            throw KeyboardShortcutValidationError.insufficientModifiers
        }
    }

    public var displayName: String {
        Self.modifierNames
            .compactMap { modifiers & $0.mask == 0 ? nil : $0.compact }
            .joined() + (Self.keyNames[keyCode]?.compact ?? "Key \(keyCode)")
    }

    public var accessibilityDisplayName: String {
        let modifierParts = Self.modifierNames.compactMap {
            modifiers & $0.mask == 0 ? nil : $0.accessibility
        }
        return (modifierParts + [Self.keyNames[keyCode]?.accessibility ?? "Key \(keyCode)"])
            .joined(separator: " ")
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case keyCode
        case modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            keyCode: try container.decode(UInt32.self, forKey: .keyCode),
            modifiers: try container.decode(UInt32.self, forKey: .modifiers)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
    }
}

public enum KeyboardShortcutValidationError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case insufficientModifiers
    case escapeNotAllowed
    case unsupportedKeyCode(UInt32)
    case dangerousSystemShortcut(UInt32)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            L10n.format("Shortcut data version %@ is not supported.", String(describing: version))
        case .insufficientModifiers:
            L10n.text("Use at least two of Command, Option, Control, or Shift.")
        case .escapeNotAllowed:
            L10n.text("Escape cannot be used as a global shortcut.")
        case let .unsupportedKeyCode(keyCode):
            L10n.format("Key code %@ is not supported.", String(describing: keyCode))
        case .dangerousSystemShortcut:
            L10n.text("That shortcut is reserved for a common macOS window or application command.")
        }
    }
}

private extension KeyboardShortcutValue {
    struct KeyName: Sendable {
        let compact: String
        let accessibility: String

        init(_ compact: String, accessibility: String? = nil) {
            self.compact = compact
            self.accessibility = accessibility ?? compact
        }
    }

    static let supportedModifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    static let modifierNames: [(mask: UInt32, compact: String, accessibility: String)] = [
        (UInt32(controlKey), "⌃", "Control"),
        (UInt32(optionKey), "⌥", "Option"),
        (UInt32(shiftKey), "⇧", "Shift"),
        (UInt32(cmdKey), "⌘", "Command"),
    ]

    static let dangerousCommandKeyCodes: Set<UInt32> = [
        UInt32(kVK_ANSI_Q),
        UInt32(kVK_ANSI_H),
        UInt32(kVK_ANSI_M),
        UInt32(kVK_ANSI_W),
    ]

    static let keyNames: [UInt32: KeyName] = [
        UInt32(kVK_ANSI_A): KeyName("A"),
        UInt32(kVK_ANSI_B): KeyName("B"),
        UInt32(kVK_ANSI_C): KeyName("C"),
        UInt32(kVK_ANSI_D): KeyName("D"),
        UInt32(kVK_ANSI_E): KeyName("E"),
        UInt32(kVK_ANSI_F): KeyName("F"),
        UInt32(kVK_ANSI_G): KeyName("G"),
        UInt32(kVK_ANSI_H): KeyName("H"),
        UInt32(kVK_ANSI_I): KeyName("I"),
        UInt32(kVK_ANSI_J): KeyName("J"),
        UInt32(kVK_ANSI_K): KeyName("K"),
        UInt32(kVK_ANSI_L): KeyName("L"),
        UInt32(kVK_ANSI_M): KeyName("M"),
        UInt32(kVK_ANSI_N): KeyName("N"),
        UInt32(kVK_ANSI_O): KeyName("O"),
        UInt32(kVK_ANSI_P): KeyName("P"),
        UInt32(kVK_ANSI_Q): KeyName("Q"),
        UInt32(kVK_ANSI_R): KeyName("R"),
        UInt32(kVK_ANSI_S): KeyName("S"),
        UInt32(kVK_ANSI_T): KeyName("T"),
        UInt32(kVK_ANSI_U): KeyName("U"),
        UInt32(kVK_ANSI_V): KeyName("V"),
        UInt32(kVK_ANSI_W): KeyName("W"),
        UInt32(kVK_ANSI_X): KeyName("X"),
        UInt32(kVK_ANSI_Y): KeyName("Y"),
        UInt32(kVK_ANSI_Z): KeyName("Z"),
        UInt32(kVK_ANSI_0): KeyName("0"),
        UInt32(kVK_ANSI_1): KeyName("1"),
        UInt32(kVK_ANSI_2): KeyName("2"),
        UInt32(kVK_ANSI_3): KeyName("3"),
        UInt32(kVK_ANSI_4): KeyName("4"),
        UInt32(kVK_ANSI_5): KeyName("5"),
        UInt32(kVK_ANSI_6): KeyName("6"),
        UInt32(kVK_ANSI_7): KeyName("7"),
        UInt32(kVK_ANSI_8): KeyName("8"),
        UInt32(kVK_ANSI_9): KeyName("9"),
        UInt32(kVK_LeftArrow): KeyName("←", accessibility: "Left Arrow"),
        UInt32(kVK_RightArrow): KeyName("→", accessibility: "Right Arrow"),
        UInt32(kVK_UpArrow): KeyName("↑", accessibility: "Up Arrow"),
        UInt32(kVK_DownArrow): KeyName("↓", accessibility: "Down Arrow"),
        UInt32(kVK_Space): KeyName("Space"),
        UInt32(kVK_Return): KeyName("↩", accessibility: "Return"),
        UInt32(kVK_Delete): KeyName("⌫", accessibility: "Delete"),
        UInt32(kVK_Tab): KeyName("⇥", accessibility: "Tab"),
        UInt32(kVK_F1): KeyName("F1"),
        UInt32(kVK_F2): KeyName("F2"),
        UInt32(kVK_F3): KeyName("F3"),
        UInt32(kVK_F4): KeyName("F4"),
        UInt32(kVK_F5): KeyName("F5"),
        UInt32(kVK_F6): KeyName("F6"),
        UInt32(kVK_F7): KeyName("F7"),
        UInt32(kVK_F8): KeyName("F8"),
        UInt32(kVK_F9): KeyName("F9"),
        UInt32(kVK_F10): KeyName("F10"),
        UInt32(kVK_F11): KeyName("F11"),
        UInt32(kVK_F12): KeyName("F12"),
    ]
}
