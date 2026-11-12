import Carbon
import Foundation

/// Produces a display label for a printable physical key in the keyboard
/// layout that is active at the instant of the call.  It intentionally keeps
/// no cache: an input-source change must be reflected by the next redraw.
enum NativeHotkeyLabels {
    /// ANSI/ISO main-section physical keys whose display value is a printable
    /// layout character.  Navigation, function, keypad, Space, Tab, Return,
    /// Delete, and Escape retain their caller-owned stable labels.
    private static let printableMainKeyboardKeyCodes: Set<UInt32> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 37, 38,
        39, 40, 41, 42, 43, 44, 45, 46, 47, 50
    ]

    static func label(for keyCode: UInt32) -> String? {
        guard printableMainKeyboardKeyCodes.contains(keyCode),
              let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        // The property is documented as a CFData containing native-endian
        // `uchr` data.  The source owns the property for this scope, so the
        // conversion is explicitly unretained.
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length > 0, length <= characters.count else { return nil }

            let value = String(utf16CodeUnits: characters, count: length)
            guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            if value.unicodeScalars.count == 1, let scalar = value.unicodeScalars.first,
               (0x61...0x7A).contains(scalar.value) {
                return String(UnicodeScalar(scalar.value - 0x20)!)
            }
            return value
        }
    }
}
