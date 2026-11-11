import SwiftUI
import UIKit

/// An invisible first responder that forwards every keystroke (software or
/// hardware keyboard) straight to the guest, like a real terminal.
struct TerminalInputView: UIViewRepresentable {
    @Binding var isFocused: Bool
    var onText: (String) -> Void
    var onBytes: ([UInt8]) -> Void

    func makeUIView(context: Context) -> KeyInputView {
        let view = KeyInputView()
        view.onText = onText
        view.onBytes = onBytes
        view.onFocusChange = { focused in
            DispatchQueue.main.async {
                if isFocused != focused { isFocused = focused }
            }
        }
        return view
    }

    func updateUIView(_ view: KeyInputView, context: Context) {
        view.onText = onText
        view.onBytes = onBytes
        if isFocused && !view.isFirstResponder {
            DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        } else if !isFocused && view.isFirstResponder {
            DispatchQueue.main.async { _ = view.resignFirstResponder() }
        }
    }
}

final class KeyInputView: UIView, UIKeyInput {
    var onText: (String) -> Void = { _ in }
    var onBytes: ([UInt8]) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }

    // UITextInputTraits: a terminal wants raw input.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var returnKeyType: UIReturnKeyType = .default

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChange(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocusChange(false) }
        return result
    }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        onText(text)
    }

    func deleteBackward() {
        onBytes([0x7f])
    }

    // MARK: Hardware keyboard

    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(arrow(_:))),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(arrow(_:))),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(arrow(_:))),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(arrow(_:))),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape(_:))),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tab(_:))),
        ]
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            let key = String(letter)
            commands.append(UIKeyCommand(input: key, modifierFlags: .control, action: #selector(control(_:))))
        }
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func arrow(_ command: UIKeyCommand) {
        switch command.input {
        case UIKeyCommand.inputUpArrow: onBytes(TerminalKeys.up)
        case UIKeyCommand.inputDownArrow: onBytes(TerminalKeys.down)
        case UIKeyCommand.inputRightArrow: onBytes(TerminalKeys.right)
        case UIKeyCommand.inputLeftArrow: onBytes(TerminalKeys.left)
        default: break
        }
    }

    @objc private func escape(_ command: UIKeyCommand) { onBytes([0x1b]) }
    @objc private func tab(_ command: UIKeyCommand) { onBytes([0x09]) }

    @objc private func control(_ command: UIKeyCommand) {
        guard let input = command.input, let byte = TerminalKeys.control(input) else { return }
        onBytes([byte])
    }
}

enum TerminalKeys {
    static let up: [UInt8] = [0x1b, 0x5b, 0x41]
    static let down: [UInt8] = [0x1b, 0x5b, 0x42]
    static let right: [UInt8] = [0x1b, 0x5b, 0x43]
    static let left: [UInt8] = [0x1b, 0x5b, 0x44]

    /// Ctrl+letter → ASCII control code (Ctrl-C = 0x03, ...).
    static func control(_ key: String) -> UInt8? {
        guard let scalar = key.lowercased().unicodeScalars.first, key.count == 1 else { return nil }
        switch scalar {
        case "a"..."z": return UInt8(scalar.value - 0x60)
        case "[": return 0x1b
        case "\\": return 0x1c
        case "]": return 0x1d
        default: return nil
        }
    }

    /// Converts text typed on the iOS keyboard into the bytes a serial
    /// terminal sends (Return → CR).
    static func bytes(for text: String) -> [UInt8] {
        var out: [UInt8] = []
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": out.append(0x0d)
            case "\u{201C}", "\u{201D}": out.append(0x22)   // smart quotes
            case "\u{2018}", "\u{2019}": out.append(0x27)
            default: out.append(contentsOf: Array(String(scalar).utf8))
            }
        }
        return out
    }
}
