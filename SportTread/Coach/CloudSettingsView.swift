import SwiftUI

/// Setup › Cloud AI for workouts: which services to ask, with their keys. Off by default.
struct CloudSettingsView: View {
    @ObservedObject private var settings = CloudSettings.shared

    var body: some View {
        List {
            Section {
                Toggle("Use cloud AI for new workouts", isOn: $settings.useCloud)
                Toggle("Send my recent workouts and readiness", isOn: $settings.sendHistory)
                    .disabled(!settings.useCloud)
            } footer: {
                Text("With this on, a request to create a workout goes to the services below, in order, before Apple Intelligence. They see the request (minutes, type, intensity), your note, your comfortable speed, and, if the second switch is on, your last five workouts and the readiness line (resting heart rate, HRV). Never your name, weight, location or Health records. If a service is off, out of free calls or slow, the next one is tried, then Apple Intelligence, then the built-in rules.")
            }
            .listRowBackground(glassRow)

            ForEach($settings.providers) { $provider in
                ProviderSection(provider: $provider, settings: settings)
            }
        }
        .sportList()
        .navigationTitle("Cloud AI")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }.fontWeight(.semibold)
            }
        }
    }
}

private struct ProviderSection: View {
    @Binding var provider: CloudProvider
    let settings: CloudSettings
    @ObservedObject private var live = CloudSettings.shared
    @State private var keyText = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Section {
            Toggle(provider.name, isOn: $provider.enabled).font(.headline)
            if provider.id == "home" {
                TextField("Address", text: $provider.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 14, design: .monospaced))
            }
            TextField("Model", text: $provider.model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14, design: .monospaced))
            if provider.needsKey {
                HStack {
                    SecureField(settings.hasKey(provider.id) ? "Key saved. Paste a new one to replace it" : "Paste your API key", text: $keyText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save") {
                        settings.setKey(keyText, for: provider.id)
                        keyText = ""
                        hideKeyboard()
                    }
                    .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if settings.hasKey(provider.id) {
                    HStack {
                        Label("Key saved in the Keychain", systemImage: "key.fill").font(.footnote).foregroundStyle(Theme.lime)
                        Spacer()
                        Button("Remove", role: .destructive) { settings.setKey("", for: provider.id) }.font(.footnote)
                    }
                }
            }
            Button {
                testing = true
                testResult = nil
                Task {
                    testResult = await settings.test(provider)
                    testing = false
                }
            } label: {
                HStack {
                    Label("Test", systemImage: "checkmark.circle")
                    if testing { ProgressView() }
                }
            }
            .disabled(testing)
            if let testResult {
                Text(testResult).font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            Text(provider.about)
        }
        .listRowBackground(glassRow)
    }
}
