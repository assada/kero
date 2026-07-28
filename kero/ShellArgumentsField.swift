//
//  ShellArgumentsField.swift
//  kero
//

import AppKit
import SwiftUI

/// Native token entry for an argv. Each token is one argument, so spaces in an
/// argument remain data instead of introducing shell-like parsing rules.
struct ShellArgumentsField: NSViewRepresentable {
    @Binding var arguments: [String]

    func makeCoordinator() -> Coordinator {
        Coordinator(arguments: $arguments)
    }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        field.tokenizingCharacterSet = .newlines
        field.objectValue = arguments
        field.placeholderString = "-l"
        field.toolTip = String(
            localized: "Press Return after each argument.",
            comment: "Help for custom terminal command arguments."
        )
        field.setAccessibilityLabel(
            String(localized: "Arguments", comment: "Custom terminal command arguments.")
        )
        field.setAccessibilityHelp(
            String(
                localized: "Press Return after each argument.",
                comment: "Accessibility help for custom terminal command arguments."
            )
        )
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.arguments = $arguments
        guard field.currentEditor() == nil,
              Coordinator.values(in: field) != arguments
        else {
            return
        }
        field.objectValue = arguments
    }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var arguments: Binding<[String]>

        init(arguments: Binding<[String]>) {
            self.arguments = arguments
        }

        @objc func commit(_ sender: NSTokenField) {
            arguments.wrappedValue = Self.values(in: sender)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            arguments.wrappedValue = Self.values(in: field)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField,
                  field.currentEditor()?.string.isEmpty == true
            else {
                return
            }
            arguments.wrappedValue = Self.values(in: field)
        }

        static func values(in field: NSTokenField) -> [String] {
            if let values = field.objectValue as? [String] {
                return values
            }
            if let values = field.objectValue as? [Any] {
                return values.compactMap { $0 as? String }
            }
            return field.stringValue.isEmpty ? [] : [field.stringValue]
        }
    }
}
