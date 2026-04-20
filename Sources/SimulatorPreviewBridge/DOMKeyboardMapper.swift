import AppKit

enum DOMKeyboardMapper {
    static func keyCode(for code: String, key: String) -> UInt16? {
        switch code {
        case "KeyA": return 0x00
        case "KeyS": return 0x01
        case "KeyD": return 0x02
        case "KeyF": return 0x03
        case "KeyH": return 0x04
        case "KeyG": return 0x05
        case "KeyZ": return 0x06
        case "KeyX": return 0x07
        case "KeyC": return 0x08
        case "KeyV": return 0x09
        case "KeyB": return 0x0B
        case "KeyQ": return 0x0C
        case "KeyW": return 0x0D
        case "KeyE": return 0x0E
        case "KeyR": return 0x0F
        case "KeyY": return 0x10
        case "KeyT": return 0x11
        case "Digit1": return 0x12
        case "Digit2": return 0x13
        case "Digit3": return 0x14
        case "Digit4": return 0x15
        case "Digit6": return 0x16
        case "Digit5": return 0x17
        case "Equal": return 0x18
        case "Digit9": return 0x19
        case "Digit7": return 0x1A
        case "Minus": return 0x1B
        case "Digit8": return 0x1C
        case "Digit0": return 0x1D
        case "BracketRight": return 0x1E
        case "KeyO": return 0x1F
        case "KeyU": return 0x20
        case "BracketLeft": return 0x21
        case "KeyI": return 0x22
        case "KeyP": return 0x23
        case "Enter": return 0x24
        case "KeyL": return 0x25
        case "KeyJ": return 0x26
        case "Quote": return 0x27
        case "KeyK": return 0x28
        case "Semicolon": return 0x29
        case "Backslash": return 0x2A
        case "Comma": return 0x2B
        case "Slash": return 0x2C
        case "KeyN": return 0x2D
        case "KeyM": return 0x2E
        case "Period": return 0x2F
        case "Tab": return 0x30
        case "Space": return 0x31
        case "Backquote": return 0x32
        case "Backspace": return 0x33
        case "Escape": return 0x35
        case "MetaLeft": return 0x37
        case "ShiftLeft", "ShiftRight": return 0x38
        case "CapsLock": return 0x39
        case "AltLeft", "AltRight": return 0x3A
        case "ControlLeft", "ControlRight": return 0x3B
        case "ArrowRight": return 0x7C
        case "ArrowLeft": return 0x7B
        case "ArrowDown": return 0x7D
        case "ArrowUp": return 0x7E
        default:
            if key.count == 1,
               let scalar = key.lowercased().unicodeScalars.first {
                switch scalar {
                case "a"..."z":
                    return keyCode(for: "Key\(String(scalar).uppercased())", key: key)
                case "0"..."9":
                    return keyCode(for: "Digit\(String(scalar))", key: key)
                default:
                    return nil
                }
            }
            return nil
        }
    }

    static func characters(for key: String) -> String {
        switch key {
        case "Enter":
            return "\r"
        case "Tab":
            return "\t"
        case "Backspace":
            return String(UnicodeScalar(NSBackspaceCharacter)!)
        case "Escape":
            return String(UnicodeScalar(0x1B)!)
        case "ArrowUp":
            return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "ArrowDown":
            return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case "ArrowLeft":
            return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "ArrowRight":
            return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case "Space":
            return " "
        default:
            return key == "Unidentified" ? "" : key
        }
    }

    static func modifierFlags(from modifiers: PreviewKeyModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.shift { flags.insert(.shift) }
        if modifiers.control { flags.insert(.control) }
        if modifiers.option { flags.insert(.option) }
        if modifiers.command { flags.insert(.command) }
        return flags
    }
}
