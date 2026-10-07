import Foundation
import Observation
import SwiftData

/// Finds who spoke in each recorded meeting and recognises voices it has heard before.
///
/// Meeting Notes records this Mac's microphone and the call audio as separate files, so
/// each track is diarised on its own: on a call the system track holds only the other
/// side. Runs on this Mac (FluidAudio on the Neural Engine, seconds per meeting); no
/// audio or voiceprint leaves it.
@Observable
@MainActor
final class DiarizationService {
    static let enabledKey = "speakers.enabled"
    static let tracks = ["microphone", "system"]
    /// Older meetings are only processed on request, like proposals.
    static let automaticWindow: TimeInterval = 14 * 86_400

    private(set) var processing: Set<UUID> = []
    private(set) var lastError: String?

    /// Called after a meeting's speakers were found (or found impossible).
    @ObservationIgnored var onFinished: ((MeetingRecord) -> Void)?

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let diarizer: Diarizer

    init(modelContext: ModelContext, diarizer: Diarizer = FluidAudioDiarizer()) {
        self.modelContext = modelContext
        self.diarizer = diarizer
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func audioURL(_ record: MeetingRecord, track: String) -> URL? {
        let url = record.folderURL.appending(path: "\(track).wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Whether this meeting can still be processed (its audio has not been deleted).
    static func hasAudio(_ record: MeetingRecord) -> Bool {
        tracks.contains { audioURL(record, track: $0) != nil }
    }

    /// Whether the meeting is waiting for automatic processing.
    static func isPending(_ record: MeetingRecord, now: Date = Date()) -> Bool {
        isEnabled && record.diarizedAt == nil && record.diarizationError == nil && hasAudio(record)
            && now.timeIntervalSince(record.startedAt) <= automaticWindow
    }

    /// Processes a meeting automatically if it qualifies; otherwise reports it finished
    /// so whatever waits on speakers carries on.
    func meetingReady(_ record: MeetingRecord) {
        guard Self.isPending(record) else {
            onFinished?(record)
            return
        }
        Task { await process(record) }
    }

    /// Picks up meetings imported before speakers were identified, or whose first run was
    /// interrupted. One at a time: the Neural Engine is shared with Meeting Notes.
    func retryDue(now: Date = Date()) {
        guard Self.isEnabled, processing.isEmpty else { return }
        let since = now.addingTimeInterval(-Self.automaticWindow)
        let records = (try? modelContext.fetch(FetchDescriptor<MeetingRecord>(
            predicate: #Predicate { $0.diarizedAt == nil && $0.startedAt >= since },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        ))) ?? []
        guard let next = records.first(where: { Self.isPending($0, now: now) }) else { return }
        Task { await process(next) }
    }

    /// Diarises both tracks and recognises voices. `force` re-runs a processed meeting.
    func process(_ record: MeetingRecord, force: Bool = false, now: Date = Date()) async {
        guard !processing.contains(record.id), force || record.diarizedAt == nil else { return }
        processing.insert(record.id)
        defer { processing.remove(record.id) }

        var outputs: [String: DiarizationOutput] = [:]
        do {
            for track in Self.tracks {
                guard let url = Self.audioURL(record, track: track) else { continue }
                outputs[track] = try await diarizer.diarize(url)
            }
        } catch {
            record.diarizationError = error.localizedDescription
            lastError = error.localizedDescription
            AppLogger.log("meetings", level: .error, "diarization_failed \(error.localizedDescription)")
            save()
            onFinished?(record)
            return
        }

        store(outputs, for: record, now: now)
        AppLogger.log("meetings", level: .info,
                      "diarized speakers=\(speakers(of: record.id).count) tracks=\(outputs.count)")
        onFinished?(record)
    }

    /// Saves segments and speakers, and matches each voice against known people. Split
    /// from `process` so tests can drive it with a fixed diarization.
    func store(_ outputs: [String: DiarizationOutput], for record: MeetingRecord, now: Date = Date()) {
        for old in speakers(of: record.id) { modelContext.delete(old) }

        var segments: [SpeakerTimeline.Segment] = []
        for (track, output) in outputs {
            segments += output.segments.map {
                SpeakerTimeline.Segment(track: track, start: $0.start, end: $0.end, cluster: $0.cluster)
            }
        }
        record.speakerSegments = SpeakerTimeline.encode(segments)

        let profiles = (try? modelContext.fetch(FetchDescriptor<SpeakerProfile>())) ?? []
        let known = profiles.map { (id: $0.id, embedding: $0.embedding) }
        let isCall = !(outputs["system"].map(SpeakerMatching.voices(in:)) ?? []).isEmpty
        var ordinal = 0
        var created: [MeetingSpeaker] = []

        // Microphone first, so the user is usually "Speaker 1".
        for track in Self.tracks {
            guard let output = outputs[track] else { continue }
            let voices = SpeakerMatching.voices(in: output)
                .sorted { output.speechSeconds(of: $0) > output.speechSeconds(of: $1) }
            for (index, cluster) in voices.enumerated() {
                ordinal += 1
                let speaker = MeetingSpeaker(
                    meetingID: record.id, track: track, clusterID: cluster,
                    embedding: output.embeddings[cluster] ?? [],
                    speechSeconds: output.speechSeconds(of: cluster), ordinal: ordinal
                )
                if let match = SpeakerMatching.bestMatch(for: speaker.embedding, among: known) {
                    if match.isRecognised {
                        speaker.profileID = match.profileID
                        speaker.matchScore = match.score
                        speaker.assignment = .auto
                    } else {
                        speaker.suggestedProfileID = match.profileID
                        speaker.suggestedName = profiles.first { $0.id == match.profileID }?.name
                        speaker.suggestionEvidence = "Similar voice (\(Int((match.score * 100).rounded()))%)"
                    }
                } else if track == "microphone", isCall, index == 0 {
                    // On a call, the main voice on this Mac's microphone is its user.
                    let me = profiles.first(where: \.isMe)
                    speaker.suggestedProfileID = me?.id
                    speaker.suggestedName = me?.name ?? "Me"
                    speaker.suggestionEvidence = "Main voice on your microphone during a call"
                    speaker.suggestsMe = true
                }
                modelContext.insert(speaker)
                created.append(speaker)
            }
        }

        record.diarizedAt = now
        record.diarizationError = nil
        refreshParticipants(record, speakers: created)
        save()
    }

    // MARK: - Naming

    /// Assigns a speaker to a known person and teaches that person's voiceprint.
    func assign(_ speaker: MeetingSpeaker, to profile: SpeakerProfile) {
        speaker.profileID = profile.id
        speaker.assignment = .user
        speaker.matchScore = 1
        clearSuggestion(speaker)
        if !speaker.embedding.isEmpty { profile.learn(speaker.embedding) }
        afterNaming(speaker)
    }

    /// Creates a person from a speaker.
    @discardableResult
    func createPerson(named name: String, from speaker: MeetingSpeaker, isMe: Bool = false) -> SpeakerProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = SpeakerProfile(name: trimmed.isEmpty ? "Unnamed" : trimmed, isMe: isMe)
        modelContext.insert(profile)
        assign(speaker, to: profile)
        return profile
    }

    /// "This is me": the user's own profile, created on first use.
    func markAsMe(_ speaker: MeetingSpeaker) {
        if let me = (try? modelContext.fetch(FetchDescriptor<SpeakerProfile>(
            predicate: #Predicate { $0.isMe == true }
        )))?.first {
            assign(speaker, to: me)
        } else {
            createPerson(named: OwnerMatcher.userNames().first ?? "Me", from: speaker, isMe: true)
        }
    }

    /// Accepts the pending suggestion (voice match, "probably you", or the model's guess).
    func acceptSuggestion(_ speaker: MeetingSpeaker) {
        if let id = speaker.suggestedProfileID, let profile = profile(id) {
            assign(speaker, to: profile)
        } else if speaker.suggestsMe {
            markAsMe(speaker)
        } else if let name = speaker.suggestedName {
            if let existing = profile(named: name) { assign(speaker, to: existing) }
            else { createPerson(named: name, from: speaker) }
        }
    }

    func rejectSuggestion(_ speaker: MeetingSpeaker) {
        clearSuggestion(speaker)
        save()
    }

    /// "Not sure": forgets who this was, without touching anyone's voiceprint.
    func unassign(_ speaker: MeetingSpeaker) {
        speaker.profileID = nil
        speaker.assignment = .none
        speaker.matchScore = 0
        afterNaming(speaker)
    }

    // MARK: - Reads

    func speakers(of meetingID: UUID) -> [MeetingSpeaker] {
        (try? modelContext.fetch(FetchDescriptor<MeetingSpeaker>(
            predicate: #Predicate { $0.meetingID == meetingID },
            sortBy: [SortDescriptor(\.ordinal)]
        ))) ?? []
    }

    func profile(_ id: UUID) -> SpeakerProfile? {
        try? modelContext.fetch(FetchDescriptor<SpeakerProfile>(predicate: #Predicate { $0.id == id })).first
    }

    private func profile(named name: String) -> SpeakerProfile? {
        let target = name.lowercased()
        return ((try? modelContext.fetch(FetchDescriptor<SpeakerProfile>())) ?? [])
            .first { $0.name.lowercased() == target }
    }

    /// The meeting's timeline with every voice named: the person's name, or "Speaker N".
    func timeline(for record: MeetingRecord) -> SpeakerTimeline? {
        Self.timeline(for: record, context: modelContext)
    }

    static func timeline(for record: MeetingRecord, context: ModelContext) -> SpeakerTimeline? {
        let segments = SpeakerTimeline.decode(record.speakerSegments)
        guard !segments.isEmpty else { return nil }
        let recordID = record.id
        let speakers = (try? context.fetch(FetchDescriptor<MeetingSpeaker>(
            predicate: #Predicate { $0.meetingID == recordID }
        ))) ?? []
        let profiles = Dictionary(
            ((try? context.fetch(FetchDescriptor<SpeakerProfile>())) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        var names: [String: String] = [:]
        for s in speakers {
            names[s.key] = s.profileID.flatMap { profiles[$0]?.name } ?? "Speaker \(s.ordinal)"
        }
        return SpeakerTimeline(segments: segments, names: names)
    }

    // MARK: - Private

    private func clearSuggestion(_ speaker: MeetingSpeaker) {
        speaker.suggestedProfileID = nil
        speaker.suggestedName = nil
        speaker.suggestionEvidence = nil
        speaker.suggestsMe = false
    }

    private func afterNaming(_ speaker: MeetingSpeaker) {
        let meetingID = speaker.meetingID
        if let record = try? modelContext.fetch(FetchDescriptor<MeetingRecord>(
            predicate: #Predicate { $0.id == meetingID }
        )).first {
            refreshParticipants(record, speakers: speakers(of: meetingID))
            onNamesChanged?(record)
        }
        save()
    }

    /// Called whenever who-is-who changes for a meeting, to update what depends on it.
    @ObservationIgnored var onNamesChanged: ((MeetingRecord) -> Void)?

    /// Named people join the participant list when the calendar gave none.
    private func refreshParticipants(_ record: MeetingRecord, speakers: [MeetingSpeaker]) {
        guard record.participantEmails.isEmpty else { return }
        let names = speakers.compactMap { $0.profileID.flatMap(profile)?.name }
        var seen = Set<String>()
        record.participantNames = names.filter { seen.insert($0.lowercased()).inserted }
    }

    private func save() {
        try? modelContext.save()
    }
}
