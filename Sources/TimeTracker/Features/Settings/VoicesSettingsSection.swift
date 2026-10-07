import SwiftUI
import SwiftData

/// Settings → Meetings → Voices: the people Hansel recognises, and the off switch.
struct VoicesSettingsSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\SpeakerProfile.name)]) private var people: [SpeakerProfile]
    @Query(sort: [SortDescriptor(\Customer.name)]) private var customers: [Customer]
    @AppStorage(DiarizationService.enabledKey) private var enabled = true
    @State private var confirmForget = false

    var body: some View {
        Section("Voices") {
            Toggle("Identify who speaks in meetings (on this Mac)", isOn: $enabled)
            if people.isEmpty {
                Text("No voices yet. Name a speaker on a meeting's page and Hansel will recognise them next time.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(people) { person in row(person) }
                Button("Forget all voices…", role: .destructive) { confirmForget = true }
            }
            Text("Each meeting's microphone and call audio are split into voices on this Mac (about 20 MB of models, downloaded once). Voiceprints never leave it and are never sent to the AI provider; only names are. Speaker identification uses the recordings Meeting Notes keeps, so it works while they exist.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Forget every voice?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive, action: forgetAll)
        } message: {
            Text("Known people and their voiceprints are deleted, and meetings show \"Speaker 1, 2…\" again.")
        }
    }

    private func row(_ person: SpeakerProfile) -> some View {
        HStack {
            TextField("Name", text: Binding(get: { person.name }, set: { person.name = $0; save() }))
                .textFieldStyle(.plain)
            if person.isMe { Text("me").font(.caption).foregroundStyle(.secondary) }
            Text("\(person.sampleCount) sample\(person.sampleCount == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Customer", selection: Binding(
                get: { person.customerID },
                set: { person.customerID = $0; save() }
            )) {
                Text("No customer").tag(UUID?.none)
                ForEach(customers) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
            Menu {
                ForEach(people.filter { $0.id != person.id }) { other in
                    Button("Merge into \(other.name)") { merge(person, into: other) }
                }
                Divider()
                Button("Delete", role: .destructive) { delete(person) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    /// Two entries for the same person: keep one, combine the voiceprints.
    private func merge(_ source: SpeakerProfile, into target: SpeakerProfile) {
        if !source.embedding.isEmpty {
            for _ in 0..<max(1, source.sampleCount) { target.learn(source.embedding) }
        }
        target.isMe = target.isMe || source.isMe
        let sourceID: UUID? = source.id
        let speakers = (try? modelContext.fetch(FetchDescriptor<MeetingSpeaker>(
            predicate: #Predicate { $0.profileID == sourceID }
        ))) ?? []
        for s in speakers { s.profileID = target.id }
        modelContext.delete(source)
        save()
    }

    private func delete(_ person: SpeakerProfile) {
        let personID: UUID? = person.id
        let speakers = (try? modelContext.fetch(FetchDescriptor<MeetingSpeaker>(
            predicate: #Predicate { $0.profileID == personID }
        ))) ?? []
        for s in speakers { s.profileID = nil; s.assignment = .none }
        modelContext.delete(person)
        save()
    }

    private func forgetAll() {
        for person in people { delete(person) }
    }

    private func save() { try? modelContext.save() }
}
