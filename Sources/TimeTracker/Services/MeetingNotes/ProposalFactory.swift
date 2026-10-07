import Foundation

/// Decides whether an action item's owner is the user, from names alone.
///
/// Meeting Notes does not identify speakers, so `owner` is the summariser's reading of
/// the conversation ("Carlos will send…"), often absent. Only a named someone else
/// counts against the user; a missing or collective owner stays undecided.
enum OwnerMatcher {
    enum Verdict: Equatable { case me, someoneElse, unknown }

    static let namesDefaultsKey = "meetingNotes.myNames"

    private static let collective: Set<String> = [
        "unassigned", "unknown", "team", "everyone", "all", "tbd", "n/a", "none", "nobody",
        "we", "us", "both", "group", "equipo", "todos", "sin asignar", "nadie", "iedereen", "allen"
    ]

    /// The names the user goes by: the setting if filled, else the macOS account name.
    static func userNames(defaults: UserDefaults = .standard) -> [String] {
        let raw = defaults.string(forKey: namesDefaultsKey) ?? ""
        let configured = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return configured.isEmpty ? [NSFullUserName()] : configured
    }

    static func classify(owner: String?, userNames: [String]) -> Verdict {
        let owner = (owner ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !owner.isEmpty, !collective.contains(owner) else { return .unknown }
        let ownerTokens = tokens(owner)
        let mine = Set(userNames.flatMap { tokens($0.lowercased()) })
        if !ownerTokens.isDisjoint(with: mine) { return .me }
        if ownerTokens.isSubset(of: collective) { return .unknown }
        return .someoneElse
    }

    /// Name parts long enough to mean something ("Carlos", "Rueda"), so "de" or an
    /// initial cannot make a stranger look like the user.
    private static func tokens(_ s: String) -> Set<String> {
        Set(s.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 3 })
    }
}

/// Builds proposals from a meeting's action items with catalog rules only. The model
/// may refine them afterwards (`MeetingTaskEnricher`).
enum ProposalFactory {

    struct Input {
        var record: MeetingRecord
        var document: MeetingNotesDocument
        var resolution: MeetingContextResolver.Resolution
        var userNames: [String]
        /// A warning learned from past decisions on this recurring meeting, if any.
        var meetingHint: String? = nil
    }

    static func makeProposals(_ input: Input, now: Date = Date()) -> [TodoProposal] {
        input.document.actionItems.enumerated().compactMap { index, item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return make(
                index: index,
                title: cleanTitle(text),
                evidence: text,
                owner: item.owner,
                timestamp: item.timestamp,
                input: input,
                now: now
            )
        }
    }

    static func make(
        index: Int,
        title: String,
        evidence: String,
        owner: String?,
        timestamp: TimeInterval?,
        input: Input,
        now: Date = Date()
    ) -> TodoProposal {
        let record = input.record
        let proposal = TodoProposal(
            meetingID: record.id,
            sourceKey: sourceKey(meetingID: record.id, index: index),
            meetingTitle: record.title,
            meetingStartedAt: record.startedAt,
            title: title,
            projectID: input.resolution.projectID,
            customerID: input.resolution.customerID,
            evidence: evidence,
            owner: owner.flatMap { $0.isEmpty ? nil : $0 },
            timestampSeconds: timestamp,
            createdAt: now
        )
        proposal.notes = notes(evidence: evidence, owner: proposal.owner, timestamp: timestamp, record: record)
        switch OwnerMatcher.classify(owner: owner, userNames: input.userNames) {
        case .someoneElse:
            proposal.likelyForSomeoneElse = true
            proposal.hint = "The summary assigns this to \(owner ?? "someone else")."
        case .me, .unknown:
            proposal.hint = input.meetingHint
        }
        proposal.markCurrentAsSuggested()
        return proposal
    }

    /// Records who was speaking when each item came up. Only a hint for the user and
    /// the model: whoever says a task is often asking someone else to do it.
    static func applySpeakers(_ timeline: SpeakerTimeline?, to proposals: [TodoProposal]) {
        for proposal in proposals where proposal.isPending {
            proposal.saidBy = proposal.timestampSeconds.flatMap { timeline?.name(at: $0) }
        }
    }

    static func sourceKey(meetingID: UUID, index: Int) -> String {
        "\(meetingID.uuidString)#\(index)"
    }

    /// A todo title reads as an instruction: no trailing full stop, first letter capital,
    /// and short enough for one line. The full sentence stays in the notes.
    static func cleanTitle(_ text: String, limit: Int = 90) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, last == "." || last == ";" { t.removeLast() }
        if let first = t.first { t = first.uppercased() + t.dropFirst() }
        if t.count > limit {
            let cut = t.prefix(limit)
            t = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
        }
        return t
    }

    static func notes(evidence: String, owner: String?, timestamp: TimeInterval?, record: MeetingRecord) -> String {
        var lines: [String] = []
        let when = noteDate.string(from: record.startedAt)
        let at = timestamp.map { " at \(TranscriptGrouping.timestamp($0))" } ?? ""
        lines.append("From the meeting \"\(record.title)\" (\(when))\(at).")
        lines.append("")
        lines.append("“\(evidence)”")
        if let owner { lines.append("Owner according to the summary: \(owner)") }
        lines.append("")
        lines.append("Notes: \(record.folderURL.appending(path: MeetingNotesArchive.notesFileName).path)")
        return lines.joined(separator: "\n")
    }

    private static let noteDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
