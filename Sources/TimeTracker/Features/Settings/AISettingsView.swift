import SwiftUI

struct AISettingsView: View {
    @State private var providers: [AIProviderConfig] = AISettingsStore.loadProviders()
    @State private var selection: AIProviderConfig.ID?
    @State private var fields: ContextFieldSelection = AISettingsStore.loadContextFields()

    var body: some View {
        HSplitView {
            providersList
                .frame(minWidth: 220, idealWidth: 240)
            detail
                .frame(minWidth: 380)
        }
        // Save as edits happen: the background services read the store, and a quit
        // with Settings open used to lose every change.
        .onChange(of: providers) { _, _ in persist() }
        .onChange(of: fields) { _, _ in persist() }
        .onDisappear(perform: persist)
    }

    // MARK: - List

    private var providersList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Providers") {
                    ForEach(providers) { p in
                        providerRow(p).tag(p.id)
                    }
                }
                Section("Presets") {
                    ForEach(AIProviderConfig.presets) { p in
                        Button(p.name) { addFromPreset(p) }
                            .buttonStyle(.plain)
                    }
                }
            }
            Divider()
            HStack {
                Button {
                    let new = AIProviderConfig(name: "New provider", kind: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini")
                    providers.append(new)
                    selection = new.id
                    persist()
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    guard let sel = selection, let idx = providers.firstIndex(where: { $0.id == sel }) else { return }
                    KeychainStore.delete(AISettingsStore.keychainKey(for: sel))
                    providers.remove(at: idx)
                    selection = providers.first?.id
                    persist()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                Spacer()
            }
            .padding(8)
        }
    }

    private func providerRow(_ p: AIProviderConfig) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name)
                Text(p.model).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if p.isDefault {
                Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selection, let idx = providers.firstIndex(where: { $0.id == selection }) {
            providerDetail(index: idx)
        } else {
            contextFieldsEditor
        }
    }

    @ViewBuilder
    private func providerDetail(index: Int) -> some View {
        let binding = Binding(
            get: { providers[index] },
            set: { new in
                var updated = providers
                updated[index] = new
                // enforce single default
                if new.isDefault {
                    for i in updated.indices where i != index {
                        updated[i].isDefault = false
                    }
                }
                providers = updated
            }
        )
        Form {
            Section("Provider") {
                TextField("Name", text: binding.name)
                Picker("Kind", selection: binding.kind) {
                    ForEach(AIProviderConfig.Kind.allCases) { k in Text(k.label).tag(k) }
                }
                if binding.wrappedValue.kind == .openAICompatible {
                    TextField("Base URL", text: Binding(
                        get: { binding.wrappedValue.baseURL ?? "" },
                        set: { binding.wrappedValue.baseURL = $0.isEmpty ? nil : $0 }
                    ))
                }
                TextField("Model", text: binding.model)
                apiKeyField(for: binding.wrappedValue.id)
                Toggle("Default for auto-start", isOn: binding.isDefault)
            }
            Section("Test") {
                Button("Save and test connection") {
                    persist()
                    Task { await test(provider: binding.wrappedValue) }
                }
            }
            Divider()
            Section("Context fields sent to this provider") {
                contextFieldToggles
            }
        }
        .formStyle(.grouped)
    }

    private func apiKeyField(for id: UUID) -> some View {
        APIKeyRow(key: AISettingsStore.keychainKey(for: id))
            .id(id)
    }

    private func test(provider config: AIProviderConfig) async {
        guard let provider = ProviderRegistry.build(config) else { return }
        let now = Date()
        let ctx = SuggestionContext(
            windowStart: now.addingTimeInterval(-600),
            windowEnd: now,
            samples: [],
            idleIntervals: [],
            recentEntries: [],
            projects: [],
            customers: [],
            roles: [],
            calendarEventTitle: "Connection test",
            fields: ContextFieldSelection(),
            ruleHints: RuleEngine.Hints(),
            activeTodos: []
        )
        do {
            _ = try await provider.draft(ctx)
            showAlert("Success", "\(provider.displayName) responded.")
        } catch {
            showAlert("Failed", error.localizedDescription)
        }
    }

    @MainActor
    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private var contextFieldsEditor: some View {
        Form {
            Section("Context fields sent to AI") {
                contextFieldToggles
            }
        }
        .formStyle(.grouped)
    }

    private var contextFieldToggles: some View {
        Group {
            Toggle("App usage samples", isOn: $fields.includeAppSamples)
            Toggle("Browser URLs", isOn: $fields.includeBrowserURLs)
                .disabled(!fields.includeAppSamples)
            Toggle("Calendar event title (when calendar-triggered)", isOn: $fields.includeCalendarTitle)
            Toggle("Last 50 confirmed entries", isOn: $fields.includeRecentEntries)
            Toggle("Catalog (roles/projects/customers)", isOn: $fields.includeCatalog)
            Toggle("Time of day", isOn: $fields.includeTimeOfDay)
            Toggle("Day of week", isOn: $fields.includeDayOfWeek)
        }
        .onChange(of: fields) { _, _ in AISettingsStore.saveContextFields(fields) }
    }

    // MARK: - Helpers

    private func addFromPreset(_ preset: AIProviderConfig) {
        var copy = preset
        copy.id = UUID()
        providers.append(copy)
        selection = copy.id
        persist()
    }

    private func persist() {
        AISettingsStore.saveProviders(providers)
        AISettingsStore.saveContextFields(fields)
    }
}

/// Shows whether a key is stored, without ever reading the secret into the view.
///
/// It used to read the key from the Keychain on every render into a `.constant`
/// binding, and since that value was not state, Set/Clear did not refresh the buttons.
private struct APIKeyRow: View {
    let key: String
    @State private var hasKey = false
    @State private var saveFailed = false

    var body: some View {
        HStack {
            Text(hasKey ? "Key stored in Keychain" : "No key set")
                .foregroundStyle(hasKey ? .primary : .secondary)
            Spacer()
            Button(hasKey ? "Replace..." : "Set...") { promptForKey() }
            if hasKey {
                Button("Clear") {
                    KeychainStore.delete(key)
                    hasKey = KeychainStore.contains(key)
                }
            }
        }
        .onAppear { hasKey = KeychainStore.contains(key) }
        .alert("Could not save the key to the Keychain", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private func promptForKey() {
        let alert = NSAlert()
        alert.messageText = "Enter API key"
        alert.informativeText = "Stored securely in macOS Keychain."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "sk-..."
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { saveFailed = !KeychainStore.set(value, for: key) }
        }
        hasKey = KeychainStore.contains(key)
    }
}
