import Foundation

/// The parts of a Meeting Notes `.meeting.json` that Hansel reads.
///
/// That file is Meeting Notes' private state, not a published format, so every field is
/// optional and every list skips elements it cannot read. A new version adding, renaming
/// or dropping a field must cost us that field, never the whole meeting.
struct MeetingNotesDocument: Decodable, Equatable {
    var id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var status: String?
    var calendar: CalendarInfo?
    var transcript: [Turn]
    var insights: Insights?

    struct Participant: Decodable, Equatable {
        var name: String?
        var email: String?
        var role: String?
    }

    struct CalendarInfo: Decodable, Equatable {
        var eventIdentifier: String?
        var organizer: Participant?
        var participants: [Participant]

        enum CodingKeys: String, CodingKey { case eventIdentifier, organizer, participants }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            eventIdentifier = try? c.decodeIfPresent(String.self, forKey: .eventIdentifier)
            organizer = try? c.decodeIfPresent(Participant.self, forKey: .organizer)
            participants = c.lossyArray(Participant.self, forKey: .participants)
        }
    }

    struct Turn: Decodable, Equatable {
        /// Seconds from the start of the recording.
        var start: TimeInterval
        /// Seconds from the start of the recording, when Meeting Notes gives it.
        var end: TimeInterval?
        var text: String
        /// "microphone" (this Mac's user and the room) or "system" (the far end of a call).
        var source: String?
    }

    struct Evidence: Decodable, Equatable {
        var text: String
        /// Seconds from the start of the recording.
        var timestamp: TimeInterval?
        /// Who the summariser thinks owns it. Meeting Notes does not identify speakers,
        /// so this is a guess from what was said, often missing.
        var owner: String?
    }

    struct Topic: Decodable, Equatable {
        var title: String
        var summary: String?
        var start: TimeInterval?
    }

    struct Insights: Decodable, Equatable {
        var summary: String
        var topics: [Topic]
        var decisions: [Evidence]
        var actionItems: [Evidence]
        var openQuestions: [Evidence]

        enum CodingKeys: String, CodingKey { case summary, topics, decisions, actionItems, openQuestions }

        init(summary: String = "", topics: [Topic] = [], decisions: [Evidence] = [],
             actionItems: [Evidence] = [], openQuestions: [Evidence] = []) {
            self.summary = summary
            self.topics = topics
            self.decisions = decisions
            self.actionItems = actionItems
            self.openQuestions = openQuestions
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
            topics = c.lossyArray(Topic.self, forKey: .topics)
            decisions = c.lossyArray(Evidence.self, forKey: .decisions)
            actionItems = c.lossyArray(Evidence.self, forKey: .actionItems)
            openQuestions = c.lossyArray(Evidence.self, forKey: .openQuestions)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, startedAt, endedAt, status, calendar, transcript, insights
    }

    init(id: UUID, title: String, startedAt: Date, endedAt: Date? = nil, status: String? = nil,
         calendar: CalendarInfo? = nil, transcript: [Turn] = [], insights: Insights? = nil) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.calendar = calendar
        self.transcript = transcript
        self.insights = insights
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Only these two are required: without them there is nothing to show or link.
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Untitled meeting"
        endedAt = try? c.decodeIfPresent(Date.self, forKey: .endedAt)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        calendar = try? c.decodeIfPresent(CalendarInfo.self, forKey: .calendar)
        transcript = c.lossyArray(Turn.self, forKey: .transcript)
        insights = try? c.decodeIfPresent(Insights.self, forKey: .insights)
    }

    /// Every attendee with an email, organizer included, without duplicates.
    var participants: [Participant] {
        guard let calendar else { return [] }
        var seen = Set<String>()
        return ([calendar.organizer].compactMap { $0 } + calendar.participants).filter {
            let key = ($0.email ?? $0.name ?? "").lowercased()
            guard !key.isEmpty else { return false }
            return seen.insert(key).inserted
        }
    }

    var actionItems: [Evidence] { insights?.actionItems ?? [] }

    static func decode(_ data: Data) throws -> MeetingNotesDocument {
        try decoder.decode(MeetingNotesDocument.self, from: data)
    }

    /// Meeting Notes writes `.iso8601` without fractional seconds; accept both in case
    /// that ever changes.
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = plainISO.date(from: raw) ?? fractionalISO.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Not an ISO 8601 date: \(raw)"))
        }
        return d
    }()

    private static let plainISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
    /// The elements that decode; the rest are skipped instead of failing the list.
    fileprivate func lossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        ((try? decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }
}
