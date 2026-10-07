import Foundation
import Observation
import SwiftData

/// Asks the model to turn a meeting's proposals into well-formed todos: a clear title,
/// the project when the catalog rules found none, a due date when one was said, and
/// whether the task is the user's at all. With no action item list (the summary failed),
/// it finds the tasks in the transcript instead.
///
/// Off by default: it sends meeting content to the configured AI provider.
@Observable
@MainActor
final class MeetingTaskEnricher {
    static let enabledKey = "meetingAI.enabled"
    static let includeTranscriptKey = "meetingAI.includeTranscript"
    static let budgetKey = "meetingAI.budget.timestamps"
    static let maxAttempts = 3

    /// A meeting is one call; a busy day has fewer than ten. The cap is a guard against
    /// a loop, not a constraint on normal use.
    static let budgetLimits = LLMBudget(maxPerHour: 12, maxPerDay: 25, minimumSpacingSeconds: 0,
                                        reservedForHardBoundaries: 0)

    private(set) var inFlight: Set<UUID> = []

    /// Past decisions to show the model; filled in by `ProposalLearning`.
    @ObservationIgnored var examples: (() -> (declined: [String], corrections: [(from: String, to: String)]))?

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let provider: () -> AIProvider?
    @ObservationIgnored private var budget: LLMBudget
    @ObservationIgnored private let defaults: UserDefaults

    init(
        modelContext: ModelContext,
        provider: @escaping () -> AIProvider? = { ProviderRegistry.defaultProvider() },
        defaults: UserDefaults = .standard
    ) {
        self.modelContext = modelContext
        self.provider = provider
        self.defaults = defaults
        self.budget = LLMBudget.loadPersisted(defaults: defaults, key: Self.budgetKey, budget: Self.budgetLimits)
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var includesTranscript: Bool {
        UserDefaults.standard.object(forKey: includeTranscriptKey) as? Bool ?? true
    }

    // MARK: - Triggers

    func meetingReady(_ record: MeetingRecord, document: MeetingNotesDocument) {
        guard Self.isEnabled, record.aiEnrichedAt == nil, record.aiAttempts < Self.maxAttempts,
              !inFlight.contains(record.id) else { return }
        Task { await enrich(record, document: document) }
    }

    /// Retries meetings whose enrichment failed or was postponed, from the last three
    /// days only: past that the user has likely handled the proposals by hand.
    func retryDue(now: Date = Date()) {
        guard Self.isEnabled else { return }
        let since = now.addingTimeInterval(-3 * 86_400)
        let records = (try? modelContext.fetch(FetchDescriptor<MeetingRecord>(
            predicate: #Predicate { $0.aiEnrichedAt == nil && $0.startedAt >= since }
        ))) ?? []
        for record in records where record.aiAttempts < Self.maxAttempts && !inFlight.contains(record.id) {
            // Wait for speakers, so the model sees who said what.
            if DiarizationService.isPending(record, now: now) { continue }
            guard let document = try? MeetingNotesArchive.load(record.folderURL) else { continue }
            guard record.proposalsCreatedAt != nil || document.insights == nil else { continue }
            Task { await enrich(record, document: document) }
        }
    }

    // MARK: - The call

    func enrich(_ record: MeetingRecord, document: MeetingNotesDocument, now: Date = Date()) async {
        guard !inFlight.contains(record.id) else { return }
        let pending = pendingProposals(for: record)
        let extracting = document.actionItems.isEmpty
        // Nothing left to refine: either everything was decided already or there were no
        // items and no transcript to look in.
        if !extracting && pending.isEmpty { record.aiEnrichedAt = now; save(); return }
        if extracting && (document.transcript.isEmpty || !Self.includesTranscript) { record.aiEnrichedAt = now; save(); return }
        guard let provider = provider() else {
            record.aiLastError = AIError.noProviderConfigured.localizedDescription
            save()
            return
        }
        // A spent budget is not a failure; the next scan tries again.
        guard budget.consume(at: now, isHard: true) else { return }
        budget.persist(defaults: defaults, key: Self.budgetKey)

        inFlight.insert(record.id)
        defer { inFlight.remove(record.id) }

        let projects = catalog()
        let input = makeInput(record: record, document: document, pending: pending, projects: projects)
        let (system, user) = MeetingTaskPrompt.build(input)
        do {
            let text = try await provider.inspectedComplete(kind: .meetingTasks, system: system, user: user,
                                                            effort: .low, maxTokens: 8192)
            let tasks = try MeetingTaskParser.parse(text, itemKeys: Set(input.items.map(\.key)), projects: projects)
            if extracting {
                createExtracted(tasks, record: record, document: document)
            } else {
                // Re-read: the user may have decided some while the model was thinking.
                Self.apply(tasks, to: pendingProposals(for: record), keyFor: itemKeyByProposal(document: document),
                           projects: projects)
            }
            record.aiEnrichedAt = Date()
            record.aiLastError = nil
            AppLogger.log("meetings", level: .info, "ai_enriched tasks=\(tasks.count) extracting=\(extracting)")
        } catch {
            record.aiAttempts += 1
            record.aiLastError = error.localizedDescription
            AppLogger.log("meetings", level: .error, "ai_failed attempt=\(record.aiAttempts) \(error.localizedDescription)")
        }
        save()
    }

    // MARK: - Applying the answer

    /// Updates proposals the user has not touched. A field the user edited, or a project
    /// that came from the user's own data, is never overwritten.
    static func apply(
        _ tasks: [MeetingTaskParser.ParsedTask],
        to proposals: [TodoProposal],
        keyFor: (TodoProposal) -> String?,
        projects: [MeetingTaskPrompt.CatalogProject]
    ) {
        let byKey = Dictionary(tasks.compactMap { t in t.itemKey.map { ($0, t) } }, uniquingKeysWith: { a, _ in a })
        for proposal in proposals where proposal.isPending {
            guard let key = keyFor(proposal), let task = byKey[key] else { continue }
            let untouched = proposal.title == proposal.suggestedTitle
                && proposal.projectID == proposal.suggestedProjectID
                && proposal.dueAt == proposal.suggestedDueAt
            guard untouched else { continue }
            fill(proposal, with: task)
        }
    }

    static func fill(_ proposal: TodoProposal, with task: MeetingTaskParser.ParsedTask) {
        proposal.title = task.title
        if proposal.projectID == nil, let projectID = task.projectID {
            proposal.projectID = projectID
        }
        if proposal.dueAt == nil { proposal.dueAt = task.due }
        switch task.forMe {
        case .yes:
            proposal.likelyForSomeoneElse = false
            if proposal.hint?.hasPrefix("The summary assigns") == true { proposal.hint = nil }
        case .no:
            proposal.likelyForSomeoneElse = true
            proposal.hint = task.reason.map { "Probably not yours: \($0)" } ?? "Probably someone else's task."
        case .unclear:
            break
        }
        if let notes = task.notes, !proposal.notes.hasPrefix(notes) {
            proposal.notes = notes + "\n\n" + proposal.notes
        }
        proposal.enrichment = .ai
        proposal.markCurrentAsSuggested()
    }

    // MARK: - Helpers

    private func makeInput(
        record: MeetingRecord,
        document: MeetingNotesDocument,
        pending: [TodoProposal],
        projects: [MeetingTaskPrompt.CatalogProject]
    ) -> MeetingTaskPrompt.Input {
        let withTranscript = Self.includesTranscript && !document.transcript.isEmpty
        let speakers = DiarizationService.timeline(for: record, context: modelContext)
        let keyFor = itemKeyByProposal(document: document)
        let pendingKeys = Set(pending.compactMap(keyFor))
        let items: [MeetingTaskPrompt.Item] = document.actionItems.enumerated().compactMap { index, item in
            let key = "A\(index + 1)"
            guard pendingKeys.contains(key) else { return nil }
            return MeetingTaskPrompt.Item(
                key: key, text: item.text, owner: item.owner, timestamp: item.timestamp,
                excerpt: withTranscript
                    ? item.timestamp.map { TranscriptGrouping.excerpt(document.transcript, around: $0, speakers: speakers) }
                    : nil
            )
        }
        let transcript: String? = items.isEmpty && withTranscript
            ? TranscriptGrouping.paragraphs(document.transcript, speakers: speakers).map { p in
                let who = p.speaker.label.isEmpty ? "" : "\(p.speaker.label): "
                return "[\(TranscriptGrouping.timestamp(p.start)) = \(Int(p.start))s] \(who)\(p.text)"
            }.joined(separator: "\n")
            : nil
        let learned = examples?()
        return MeetingTaskPrompt.Input(
            userNames: OwnerMatcher.userNames(),
            meetingTitle: record.title,
            meetingStart: record.startedAt,
            participants: record.participantNames,
            summary: document.insights?.summary ?? "",
            items: items,
            transcript: transcript,
            projects: AISettingsStore.loadContextFields().includeCatalog ? projects : [],
            declinedExamples: learned?.declined ?? [],
            titleCorrections: learned?.corrections ?? []
        )
    }

    /// Proposals from action items have source keys "<meeting>#<index>"; the prompt
    /// calls item `index` "A<index+1>".
    private func itemKeyByProposal(document: MeetingNotesDocument) -> (TodoProposal) -> String? {
        let count = document.actionItems.count
        return { proposal in
            guard let raw = proposal.sourceKey.split(separator: "#").last, let index = Int(raw),
                  index < count else { return nil }
            return "A\(index + 1)"
        }
    }

    /// Tasks found in the transcript get source keys from 1000 up, so they can never
    /// collide with action item indexes if a summary appears later.
    private func createExtracted(_ tasks: [MeetingTaskParser.ParsedTask], record: MeetingRecord, document: MeetingNotesDocument) {
        let decisions = ProposalLearning.decisions(context: modelContext)
        let resolution = MeetingContextResolver.resolve(
            record: record,
            learnedProjectID: ProposalLearning.learnedProjectID(forMeetingTitle: record.title, decisions: decisions),
            context: modelContext)
        let input = ProposalFactory.Input(record: record, document: document, resolution: resolution,
                                          userNames: OwnerMatcher.userNames())
        let existing = Set(((try? modelContext.fetch(FetchDescriptor<TodoProposal>())) ?? [])
            .filter { $0.meetingID == record.id }.map(\.sourceKey))
        for (offset, task) in tasks.prefix(MeetingTaskPrompt.maxExtractedTasks).enumerated() {
            let proposal = ProposalFactory.make(index: 1000 + offset, title: task.title,
                                                evidence: task.notes ?? task.title, owner: nil,
                                                timestamp: task.timestamp, input: input)
            guard !existing.contains(proposal.sourceKey) else { continue }
            proposal.notes = proposal.notes.replacingOccurrences(of: "“\(proposal.evidence)”", with: "")
            Self.fill(proposal, with: task)
            modelContext.insert(proposal)
        }
        record.proposalsCreatedAt = record.proposalsCreatedAt ?? Date()
    }

    private func pendingProposals(for record: MeetingRecord) -> [TodoProposal] {
        let id = record.id
        return ((try? modelContext.fetch(FetchDescriptor<TodoProposal>(
            predicate: #Predicate { $0.meetingID == id }
        ))) ?? []).filter(\.isPending)
    }

    private func catalog() -> [MeetingTaskPrompt.CatalogProject] {
        let projects = ((try? modelContext.fetch(FetchDescriptor<Project>())) ?? []).sorted { $0.name < $1.name }
        return projects.enumerated().map { i, p in
            MeetingTaskPrompt.CatalogProject(key: "P\(i + 1)", id: p.id, name: p.name,
                                             customer: p.customer?.name, details: p.details)
        }
    }

    private func save() { try? modelContext.save() }
}
