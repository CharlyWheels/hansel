import SwiftUI
import SwiftData

/// Meetings recorded by Meeting Notes: a list by day, and the selected meeting's notes,
/// proposals and transcript.
struct MeetingsView: View {
    @Query(sort: [SortDescriptor(\MeetingRecord.startedAt, order: .reverse)])
    private var meetings: [MeetingRecord]
    @Query(TodoProposal.pendingDescriptor)
    private var pending: [TodoProposal]

    @Environment(MainWindowRouter.self) private var router
    @Environment(MeetingImporter.self) private var importer
    @State private var selectedID: UUID?
    @State private var search = ""

    private var filtered: [MeetingRecord] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return meetings }
        return meetings.filter {
            $0.title.lowercased().contains(q)
                || $0.summary.lowercased().contains(q)
                || $0.participantNames.contains { $0.lowercased().contains(q) }
        }
    }

    private var byDay: [(day: Date, meetings: [MeetingRecord])] {
        let groups = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.startedAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            Group {
                if let id = selectedID, let meeting = meetings.first(where: { $0.id == id }) {
                    MeetingDetailView(meeting: meeting)
                        .id(meeting.id)
                } else {
                    empty
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Meetings")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await importer.scan() }
                } label: {
                    Label("Scan archive", systemImage: "arrow.clockwise")
                }
                .disabled(importer.isScanning)
                .help("Read new meetings from the Meeting Notes archive now")
            }
        }
        .onAppear(perform: takeRoutedMeeting)
        .onChange(of: router.meetingID) { _, _ in takeRoutedMeeting() }
    }

    private func takeRoutedMeeting() {
        if let id = router.meetingID {
            selectedID = id
            router.meetingID = nil
        } else if selectedID == nil {
            selectedID = meetings.first?.id
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            TextField("Search meetings", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List(selection: $selectedID) {
                ForEach(byDay, id: \.day) { group in
                    Section(group.day.formatted(date: .complete, time: .omitted)) {
                        ForEach(group.meetings) { meeting in
                            row(meeting).tag(meeting.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            if let error = importer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(_ meeting: MeetingRecord) -> some View {
        let open = pending.filter { $0.meetingID == meeting.id }.count
        return VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title).lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.startedAt.formatted(date: .omitted, time: .shortened))
                if let d = meeting.duration { Text("· \(DurationFormat.hoursMinutes(d))") }
                if open > 0 {
                    Text("\(open) to review")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.tertiary)
            Text(meetings.isEmpty ? "No meetings yet" : "Select a meeting")
                .font(.headline)
            if meetings.isEmpty {
                Text("Meetings recorded with Meeting Notes appear here a couple of minutes after they finish.\nArchive: \(MeetingNotesArchive.resolvedRoot().path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}
