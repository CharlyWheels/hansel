import SwiftUI
import SwiftData
import AppKit

/// One meeting: where its time went, what it asks of the user, and what was said.
struct MeetingDetailView: View {
    let meeting: MeetingRecord

    @Query private var proposals: [TodoProposal]
    @Query private var projects: [Project]
    @Query private var customers: [Customer]
    @Environment(\.modelContext) private var modelContext
    @Environment(ProposalService.self) private var service
    @Environment(MeetingTaskEnricher.self) private var enricher

    @State private var document: MeetingNotesDocument?
    @State private var loadError: String?
    @State private var showTranscript = false
    @State private var transcriptFilter = ""
    @State private var editingEntry: TimeEntry?

    init(meeting: MeetingRecord) {
        self.meeting = meeting
        let id = meeting.id
        _proposals = Query(filter: #Predicate<TodoProposal> { $0.meetingID == id },
                           sort: [SortDescriptor(\TodoProposal.sourceKey)])
    }

    private var linkedEntry: TimeEntry? {
        guard let id = meeting.linkedEntryID else { return nil }
        return try? modelContext.fetch(FetchDescriptor<TimeEntry>(predicate: #Predicate { $0.id == id })).first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                contextSection
                SpeakersSection(meeting: meeting)
                proposalsSection
                if let error = loadError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let insights = document?.insights {
                    insightsSections(insights)
                } else if document != nil {
                    Text("Meeting Notes has not written a summary for this meeting.")
                        .foregroundStyle(.secondary)
                }
                transcriptSection
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .textSelection(.enabled)
        }
        .task(id: meeting.fileModifiedAt) { await load() }
        .sheet(item: $editingEntry) { entry in
            EntryEditorView(entry: entry)
                .frame(minWidth: 480, minHeight: 520)
        }
    }

    private func load() async {
        let folder = meeting.folderURL
        do {
            document = try await Task.detached(priority: .userInitiated) {
                try MeetingNotesArchive.load(folder)
            }.value
            loadError = nil
        } catch {
            loadError = "Could not read the meeting file: \(error.localizedDescription)"
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.title).font(.title2.weight(.semibold))
            HStack(spacing: 6) {
                Text(meeting.startedAt.formatted(date: .complete, time: .shortened))
                if let end = meeting.endedAt {
                    Text("– \(end.formatted(date: .omitted, time: .shortened))")
                }
                if let d = meeting.duration { Text("· \(DurationFormat.hoursMinutes(d))") }
            }
            .foregroundStyle(.secondary)
            if !meeting.participantNames.isEmpty {
                Text(meeting.participantNames.joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    NSWorkspace.shared.open(meeting.folderURL.appending(path: MeetingNotesArchive.notesFileName))
                } label: { Label("Open notes", systemImage: "doc.text") }
                Button {
                    NSWorkspace.shared.open(meeting.folderURL.appending(path: MeetingNotesArchive.transcriptFileName))
                } label: { Label("Open transcript", systemImage: "text.quote") }
                .disabled(!meeting.hasTranscript)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([meeting.folderURL])
                } label: { Label("Show in Finder", systemImage: "folder") }
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
    }

    // MARK: - Context

    private var contextSection: some View {
        let learned = ProposalLearning.learnedProjectID(
            forMeetingTitle: meeting.title, decisions: ProposalLearning.decisions(context: modelContext))
        let resolution = MeetingContextResolver.resolve(record: meeting, learnedProjectID: learned, context: modelContext)
        let project = projects.first { $0.id == resolution.projectID }
        let customer = customers.first { $0.id == resolution.customerID }
        return GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label(project?.name ?? "No project", systemImage: "folder")
                        .foregroundStyle(project?.displayColor ?? .secondary)
                    if let customer { Label(customer.name, systemImage: "person.2") }
                    if let source = resolution.source {
                        Text(source.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let entry = linkedEntry {
                    HStack {
                        Image(systemName: "clock")
                        Text(entry.title.isEmpty ? "(untitled entry)" : entry.title)
                        Text(entryTimes(entry)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Edit entry") { editingEntry = entry }
                            .controlSize(.small)
                    }
                    .font(.callout)
                } else {
                    Label("No time entry covers this meeting", systemImage: "clock.badge.questionmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func entryTimes(_ entry: TimeEntry) -> String {
        let start = entry.startAt.formatted(date: .omitted, time: .shortened)
        let end = entry.endAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "now"
        return "\(start)–\(end)"
    }

    // MARK: - Proposals

    @ViewBuilder
    private var proposalsSection: some View {
        if !proposals.isEmpty || meeting.aiLastError != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    sectionTitle("Proposed todos")
                    if enricher.inFlight.contains(meeting.id) {
                        ProgressView().controlSize(.small)
                        Text("Refining with AI…").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if MeetingTaskEnricher.isEnabled, meeting.aiEnrichedAt == nil,
                       !enricher.inFlight.contains(meeting.id), let document,
                       proposals.contains(where: \.isPending) {
                        Button("Refine with AI") {
                            meeting.aiAttempts = 0
                            Task { await enricher.enrich(meeting, document: document) }
                        }
                        .controlSize(.small)
                    }
                    if proposals.contains(where: \.isPending) {
                        Button("Decline remaining") { service.declineAll(forMeeting: meeting.id) }
                            .controlSize(.small)
                    }
                }
                ForEach(proposals) { proposal in
                    ProposalRow(proposal: proposal, projects: projects, customers: customers, showsMeeting: false)
                    if proposal.id != proposals.last?.id { Divider() }
                }
                if let error = meeting.aiLastError {
                    Label("The model could not refine these: \(error)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Notes

    @ViewBuilder
    private func insightsSections(_ insights: MeetingNotesDocument.Insights) -> some View {
        if !insights.summary.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Summary")
                Text(insights.summary)
            }
        }
        evidenceList("Decisions", insights.decisions, systemImage: "checkmark.seal")
        evidenceList("Open questions", insights.openQuestions, systemImage: "questionmark.bubble")
        if !insights.topics.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Topics")
                ForEach(Array(insights.topics.enumerated()), id: \.offset) { _, topic in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(topic.title).font(.callout.weight(.medium))
                            if let start = topic.start {
                                Text(TranscriptGrouping.timestamp(start))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let summary = topic.summary, !summary.isEmpty {
                            Text(summary).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func evidenceList(_ title: String, _ items: [MeetingNotesDocument.Evidence], systemImage: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(title)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: systemImage).foregroundStyle(.secondary)
                        Text(item.text)
                        if let t = item.timestamp {
                            Text(TranscriptGrouping.timestamp(t))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptSection: some View {
        if let turns = document?.transcript, !turns.isEmpty {
            DisclosureGroup(isExpanded: $showTranscript) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Find in transcript", text: $transcriptFilter)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    let q = transcriptFilter.lowercased()
                    let paragraphs = TranscriptGrouping.paragraphs(
                        turns, speakers: DiarizationService.timeline(for: meeting, context: modelContext)
                    )
                        .filter { q.isEmpty || $0.text.lowercased().contains(q) }
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(paragraphs) { p in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(TranscriptGrouping.timestamp(p.start))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .trailing)
                                if !p.speaker.label.isEmpty {
                                    Text(p.speaker.label)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(p.speaker == .me ? Color.accentColor : .secondary)
                                        .frame(width: 72, alignment: .leading)
                                        .lineLimit(1)
                                }
                                Text(p.text).font(.callout)
                            }
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                sectionTitle("Transcript")
            }
        } else if document != nil, meeting.hasTranscript == false {
            Text("The word-for-word transcript is no longer available (Meeting Notes may have deleted it on schedule).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline)
    }
}
