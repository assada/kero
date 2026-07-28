//
//  ShellSettingsView.swift
//  kero
//

import SwiftUI

/// Terminal startup controls used by the Settings form.
struct ShellSettingsView: View {
    @Binding var startup: TerminalStartup
    @FocusState private var isProgramFieldFocused: Bool

    private let installedShells: [String]

    init(startup: Binding<TerminalStartup>) {
        _startup = startup
        installedShells = ShellCatalog.installedPaths()
    }

    var body: some View {
        Picker("Shell", selection: choice) {
            Text("Login shell (\(ShellConfiguration.defaultPath))")
                .tag(Choice.loginShell)

            ForEach(selectableShells, id: \.self) { path in
                Text(verbatim: path).tag(Choice.installed(path))
            }

            Divider()
            Text("Custom command…").tag(Choice.customCommand)
        }

        if case .customCommand = startup {
            TextField(
                "Executable",
                text: customProgram,
                prompt: Text(verbatim: ShellConfiguration.defaultPath)
            )
            .disableAutocorrection(true)
            .focused($isProgramFieldFocused)
            .onSubmit { isProgramFieldFocused = false }

            LabeledContent("Arguments") {
                ShellArgumentsField(arguments: customArguments)
            }

            if !isProgramFieldFocused,
               let message = ShellConfiguration.validationMessage(
                for: customProgram.wrappedValue,
                required: true
               ) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }

        Text("Changes apply to new terminals.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private enum Choice: Hashable {
        case loginShell
        case installed(String)
        case customCommand
    }

    private var choice: Binding<Choice> {
        Binding(
            get: {
                switch startup {
                case .loginShell:
                    return .loginShell
                case .shell(let path):
                    return .installed(path)
                case .customCommand:
                    return .customCommand
                }
            },
            set: { newChoice in
                switch newChoice {
                case .loginShell:
                    startup = .loginShell
                case .installed(let path):
                    startup = .shell(path: path)
                case .customCommand:
                    startup = startup.asCustomCommand(
                        defaultProgram: ShellConfiguration.defaultPath
                    )
                }
            }
        )
    }

    /// Keep an existing path visible even if it was configured manually and
    /// isn't part of today's shell discovery results.
    private var selectableShells: [String] {
        guard case .shell(let path) = startup,
              !installedShells.contains(path)
        else {
            return installedShells
        }
        return [path] + installedShells
    }

    private var customProgram: Binding<String> {
        Binding(
            get: {
                guard case .customCommand(let program, _) = startup else {
                    return ""
                }
                return program
            },
            set: { program in
                guard case .customCommand(_, let arguments) = startup else {
                    return
                }
                startup = .customCommand(program: program, arguments: arguments)
            }
        )
    }

    private var customArguments: Binding<[String]> {
        Binding(
            get: {
                guard case .customCommand(_, let arguments) = startup else {
                    return []
                }
                return arguments
            },
            set: { arguments in
                guard case .customCommand(let program, _) = startup else {
                    return
                }
                startup = .customCommand(program: program, arguments: arguments)
            }
        )
    }
}

private extension TerminalStartup {
    func asCustomCommand(defaultProgram: String) -> TerminalStartup {
        switch self {
        case .loginShell:
            return .customCommand(program: defaultProgram, arguments: [])
        case .shell(let path):
            return .customCommand(program: path, arguments: [])
        case .customCommand:
            return self
        }
    }
}
