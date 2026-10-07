import Foundation
import SwiftData

/// A person Hansel can recognise by voice across meetings.
///
/// The embedding is a voiceprint: biometric data, so it stays on this Mac, is never sent
/// to a model, and can be deleted from Settings → Meetings.
@Model
final class SpeakerProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    /// The user themself.
    var isMe: Bool = false
    /// Running mean of every confirmed sample of this voice.
    var embedding: [Float] = []
    var sampleCount: Int = 0
    var customerID: UUID? = nil
    var email: String? = nil
    var createdAt: Date

    init(id: UUID = UUID(), name: String, isMe: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.isMe = isMe
        self.createdAt = createdAt
    }

    /// Folds one more confirmed sample into the voiceprint.
    func learn(_ sample: [Float]) {
        embedding = SpeakerMatching.runningMean(embedding, count: sampleCount, adding: sample)
        sampleCount += 1
    }
}

/// One voice found in one track of one meeting.
@Model
final class MeetingSpeaker {
    @Attribute(.unique) var id: UUID
    var meetingID: UUID
    /// "microphone" or "system", as in Meeting Notes' transcript.
    var track: String
    /// The diarizer's label within the track ("S1", "S2"…).
    var clusterID: String
    var embedding: [Float] = []
    var speechSeconds: Double = 0
    /// Who this is, once known.
    var profileID: UUID? = nil
    /// Similarity to `profileID`'s voiceprint when matched automatically.
    var matchScore: Double = 0
    /// How `profileID` was set.
    var assignmentRaw: String = Assignment.none.rawValue
    /// A name to confirm: a close voice match, "probably you", or the model's guess.
    var suggestedProfileID: UUID? = nil
    var suggestedName: String? = nil
    var suggestionEvidence: String? = nil
    /// The suggestion is "this is you" (main microphone voice on a call).
    var suggestsMe: Bool = false
    /// Number shown to the user while unnamed ("Speaker 2").
    var ordinal: Int = 0

    enum Assignment: String { case none, auto, user }

    init(id: UUID = UUID(), meetingID: UUID, track: String, clusterID: String,
         embedding: [Float], speechSeconds: Double, ordinal: Int) {
        self.id = id
        self.meetingID = meetingID
        self.track = track
        self.clusterID = clusterID
        self.embedding = embedding
        self.speechSeconds = speechSeconds
        self.ordinal = ordinal
    }

    var assignment: Assignment {
        get { Assignment(rawValue: assignmentRaw) ?? .none }
        set { assignmentRaw = newValue.rawValue }
    }

    /// "S1@system": unique within a meeting.
    var key: String { "\(clusterID)@\(track)" }
}
