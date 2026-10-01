import SwiftUI
import UIKit

/// A password field that deliberately blocks pasting — entering a password here must
/// always be a fresh manual keystroke, never a paste of something already sitting on
/// the clipboard (which could be stale, copied for something else, or simply wrong).
/// SwiftUI's `SecureField` has no API to disable Paste, so this drops to a `UITextField`
/// subclass that removes it from the edit menu directly. Also explicitly opts out of
/// `textContentType` (an empty content type, not just `nil`) — iOS otherwise still
/// heuristically treats a secure field like this as a login form's password and offers
/// its own "Save Password" prompt on leaving the screen, `textContentType(.password)`
/// or not.
struct ManualEntrySecureField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeUIView(context: Context) -> NoPasteTextField {
        let textField = NoPasteTextField()
        textField.isSecureTextEntry = true
        textField.placeholder = placeholder
        textField.font = .preferredFont(forTextStyle: .body)
        textField.borderStyle = .none
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.textContentType = UITextContentType(rawValue: "")
        textField.delegate = context.coordinator
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textChanged), for: .editingChanged)
        return textField
    }

    func updateUIView(_ uiView: NoPasteTextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func textChanged(_ textField: UITextField) {
            text.wrappedValue = textField.text ?? ""
        }
    }
}

/// Removes Paste from the field's edit menu — `UITextField` has no higher-level API
/// for this, so it has to be done by overriding the action-validation entry point
/// every edit-menu item is routed through.
final class NoPasteTextField: UITextField {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

/// The username counterpart to `ManualEntrySecureField`. SwiftUI's `TextField` exposes
/// `textContentType` only as a view modifier, which doesn't reliably reach the
/// underlying `UITextField` — leaving this field unsuppressed is enough on its own for
/// iOS to treat it and the secure field below as a login form and offer "Save
/// Password". Dropping to `UITextField` directly makes the override actually land.
struct ManualEntryTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.placeholder = placeholder
        textField.font = .preferredFont(forTextStyle: .body)
        textField.borderStyle = .none
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.textContentType = UITextContentType(rawValue: "")
        textField.delegate = context.coordinator
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textChanged), for: .editingChanged)
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func textChanged(_ textField: UITextField) {
            text.wrappedValue = textField.text ?? ""
        }
    }
}
