import SwiftUI

struct MenuBarView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Text(state.statusMessage)
            .font(.caption)

        Divider()

        Toggle("Enabled", isOn: $state.isEnabled)

        Divider()

        if state.availableDisplays.isEmpty {
            Text("No external displays found")
                .foregroundStyle(.secondary)
        } else {
            Menu("Display") {
                ForEach(state.availableDisplays) { display in
                    Button {
                        state.selectDisplay(display.id)
                    } label: {
                        HStack {
                            Text(display.name)
                            if display.id == state.selectedDisplayID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Picker("Resolution", selection: $state.selectedResolution) {
                Text("Native (auto)").tag("")
                ForEach(state.availableResolutions) { res in
                    Text(res.label).tag(res.id)
                }
            }

            Picker("Sleep Hz", selection: $state.lowHz) {
                ForEach(state.availableRates, id: \.self) { rate in
                    Text("\(Int(rate)) Hz").tag(rate)
                }
            }

            Picker("Wake Hz", selection: $state.highHz) {
                ForEach(state.availableRates, id: \.self) { rate in
                    Text("\(Int(rate)) Hz").tag(rate)
                }
            }

            Text("Current: \(Int(state.currentRate)) Hz")
                .foregroundStyle(.secondary)
        }

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { state.launchAtLogin },
            set: { state.setLaunchAtLogin($0) }
        ))

        Button("About Refreshing…") {
            let alert = NSAlert()
            alert.messageText = "Refreshing v0.1.0"
            alert.informativeText = "https://github.com/m4rkw/refreshing"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
