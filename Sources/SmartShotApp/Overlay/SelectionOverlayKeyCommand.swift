import Carbon.HIToolbox

enum SelectionOverlayKeyCommand: Equatable {
    case cancel
    case confirm
    case cycle(Int)
    case passThrough

    static func command(for keyCode: UInt16) -> Self {
        switch Int(keyCode) {
        case kVK_Escape:
            .cancel
        case kVK_Return, kVK_ANSI_KeypadEnter:
            .confirm
        case kVK_LeftArrow, kVK_DownArrow:
            .cycle(-1)
        case kVK_RightArrow, kVK_UpArrow:
            .cycle(1)
        default:
            .passThrough
        }
    }
}
