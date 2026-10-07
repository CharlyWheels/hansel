import XCTest
import SwiftData
@testable import TimeTracker

/// Who spoke: matching voices, aligning the transcript, and what the names feed.
@MainActor
final class SpeakerDiarizationTests: XCTestCase {

    // MARK: - Voices and matching

    private func seg(_ start: Double, _ end: Double, _ cluster: String) -> DiarizationOutput.Segment {
        .init(start: start, end: end, cluster: cluster)
    }

    func test_shortClustersAreNotTreatedAsPeople() {
        // As on the real call: one remote voice plus chimes/echo heard on both tracks.
        let output = DiarizationOutput(
            segments: [seg(0, 341, "S2"), seg(400, 420, "S1"), seg(500, 514, "S3")],
            embeddings: [:]
        )
        XCTAssertEqual(SpeakerMatching.voices(in: output), ["S2"])
    }

    func test_matchingThresholds() {
        let elena: [Float] = [1, 0, 0]
        let known = [(id: UUID(), embedding: elena)]
        XCTAssertTrue(SpeakerMatching.bestMatch(for: [0.95, 0.1, 0], among: known)?.isRecognised == true)
        let near = SpeakerMatching.bestMatch(for: [0.6, 0.8, 0], among: known)   // cosine 0.60
        XCTAssertNotNil(near)
        XCTAssertFalse(near!.isRecognised, "close but not certain: a suggestion")
        XCTAssertNil(SpeakerMatching.bestMatch(for: [0, 1, 0], among: known))
    }

    func test_voiceprintIsARunningMean() {
        let profile = SpeakerProfile(name: "Elena")
        profile.learn([1, 0])
        profile.learn([0, 1])
        XCTAssertEqual(profile.embedding, [0.5, 0.5])
        XCTAssertEqual(profile.sampleCount, 2)
    }

    // MARK: - Timeline

    private let timeline = SpeakerTimeline(
        segments: [
            .init(track: "microphone", start: 0, end: 30, cluster: "S1"),
            .init(track: "system", start: 30, end: 60, cluster: "S2"),
            .init(track: "system", start: 60, end: 90, cluster: "S3"),
        ],
        names: ["S1@microphone": "Carlos", "S2@system": "Elena", "S3@system": "Speaker 3"]
    )

    func test_turnsTakeTheVoiceOfTheirOwnTrack() {
        XCTAssertEqual(timeline.name(track: "system", start: 40, end: 45), "Elena")
        XCTAssertEqual(timeline.name(track: "system", start: 58, end: 70), "Speaker 3", "most overlap wins")
        XCTAssertEqual(timeline.name(track: "microphone", start: 10, end: 12), "Carlos")
        XCTAssertNil(timeline.name(track: "microphone", start: 40, end: 45), "no voice on that track then")
        XCTAssertEqual(timeline.name(track: "system", start: 90.5, end: nil), "Speaker 3", "within a second")
    }

    func test_actionItemMomentPicksWhoeverWasTalking() {
        XCTAssertEqual(timeline.name(at: 45), "Elena")
        XCTAssertEqual(timeline.name(at: 10), "Carlos")
    }

    func test_paragraphsUseNamesAndBreakOnSpeakerChange() {
        let turns = [
            MeetingNotesDocument.Turn(start: 31, end: 35, text: "Hola", source: "system"),
            MeetingNotesDocument.Turn(start: 61, end: 65, text: "¿Qué tal?", source: "system"),
            MeetingNotesDocument.Turn(start: 70, end: 72, text: "Bien", source: "microphone"),
        ]
        let paragraphs = TranscriptGrouping.paragraphs(turns, speakers: timeline)
        XCTAssertEqual(paragraphs.map(\.speaker.label), ["Elena", "Speaker 3", "Me"])
    }

    // MARK: - Service

    private struct FakeDiarizer: Diarizer {
        let outputs: [String: DiarizationOutput]
        func diarize(_ url: URL) async throws -> DiarizationOutput {
            outputs[url.deletingPathExtension().lastPathComponent] ?? DiarizationOutput(segments: [], embeddings: [:])
        }
    }

    private func callOutputs() -> [String: DiarizationOutput] {
        [
            "microphone": DiarizationOutput(segments: [seg(0, 600, "S1")], embeddings: ["S1": [1, 0, 0]]),
            "system": DiarizationOutput(segments: [seg(600, 900, "S1"), seg(900, 1000, "S2")],
                                        embeddings: ["S1": [0, 1, 0], "S2": [0, 0, 1]]),
        ]
    }

    func test_storeFindsVoicesRecognisesKnownPeopleAndSuggestsMe() throws {
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let elena = SpeakerProfile(name: "Elena")
        elena.learn([0, 0.98, 0.05])
        ctx.insert(elena)
        let record = MeetingRecord(id: UUID(), title: "Sync", startedAt: Date(), folderPath: "/tmp/x",
                                   fileModifiedAt: Date())
        ctx.insert(record)
        try ctx.save()

        let service = DiarizationService(modelContext: ctx, diarizer: FakeDiarizer(outputs: [:]))
        service.store(callOutputs(), for: record)

        let speakers = service.speakers(of: record.id)
        XCTAssertEqual(speakers.count, 3)
        let mic = try XCTUnwrap(speakers.first { $0.track == "microphone" })
        XCTAssertTrue(mic.suggestsMe, "main microphone voice on a call is probably the user")
        let recognised = try XCTUnwrap(speakers.first { $0.clusterID == "S1" && $0.track == "system" })
        XCTAssertEqual(recognised.profileID, elena.id)
        XCTAssertEqual(recognised.assignment, .auto)
        XCTAssertNotNil(record.diarizedAt)
        XCTAssertEqual(service.timeline(for: record)?.name(at: 700), "Elena")
    }

    func test_namingTeachesTheVoiceAndFeedsParticipants() throws {
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let record = MeetingRecord(id: UUID(), title: "Sync", startedAt: Date(), folderPath: "/tmp/x",
                                   fileModifiedAt: Date())
        ctx.insert(record)
        let service = DiarizationService(modelContext: ctx, diarizer: FakeDiarizer(outputs: [:]))
        service.store(callOutputs(), for: record)
        let other = try XCTUnwrap(service.speakers(of: record.id).first { $0.clusterID == "S2" })

        let profile = service.createPerson(named: "Peter", from: other)
        XCTAssertEqual(profile.embedding, [0, 0, 1])
        XCTAssertEqual(profile.sampleCount, 1)
        XCTAssertEqual(record.participantNames, ["Peter"])

        let mic = try XCTUnwrap(service.speakers(of: record.id).first { $0.track == "microphone" })
        service.acceptSuggestion(mic)
        let me = try XCTUnwrap(try ctx.fetch(FetchDescriptor<SpeakerProfile>()).first { $0.isMe })
        XCTAssertEqual(mic.profileID, me.id)
    }

    // MARK: - Uses

    func test_saidByComesFromTheTimeline() {
        let proposal = TodoProposal(meetingID: UUID(), sourceKey: "m#0", meetingTitle: "Sync",
                                    meetingStartedAt: Date(), title: "Send deck", evidence: "Send deck",
                                    timestampSeconds: 45)
        ProposalFactory.applySpeakers(timeline, to: [proposal])
        XCTAssertEqual(proposal.saidBy, "Elena")
    }

    func test_customerComesFromWhoSpokeNotFromMe() {
        let acme = Customer(name: "Acme")
        acme.emailDomains = "acme.com"
        let globex = Customer(name: "Globex")
        let me = SpeakerProfile(name: "Carlos", isMe: true)
        me.customerID = globex.id
        let ana = SpeakerProfile(name: "Ana")
        ana.email = "ana@acme.com"
        let customer = MeetingContextResolver.customerFromSpeakers(
            [(profile: me, seconds: 2000), (profile: ana, seconds: 300)], customers: [acme, globex]
        )
        XCTAssertEqual(customer?.name, "Acme")
    }

    func test_parsesNameSuggestions() {
        let text = """
        Here you go: {"speakers": [{"label": "Speaker 2", "name": "Elena", "confidence": 0.8, "evidence": "gracias, Elena"},
        {"label": "Speaker 3", "name": null, "confidence": 0.2, "evidence": null}]}
        """
        let parsed = SpeakerNameSuggester.parse(text)
        XCTAssertEqual(parsed, [.init(label: "Speaker 2", name: "Elena", confidence: 0.8, evidence: "gracias, Elena")])
    }

    // MARK: - Names reach everything

    func test_namingUpdatesSaidByOnDecidedProposalsToo() throws {
        let container = try AppModelContainer.inMemory()
        let ctx = container.mainContext
        let record = MeetingRecord(id: UUID(), title: "Sync", startedAt: Date(), folderPath: "/tmp/x",
                                   fileModifiedAt: Date())
        ctx.insert(record)
        let declined = TodoProposal(meetingID: record.id, sourceKey: "m#0", meetingTitle: "Sync",
                                    meetingStartedAt: Date(), title: "Check API", evidence: "Check API",
                                    timestampSeconds: 950)
        declined.statusRaw = TodoProposal.Status.declined.rawValue
        ctx.insert(declined)
        let service = DiarizationService(modelContext: ctx, diarizer: FakeDiarizer(outputs: [:]))
        service.store(callOutputs(), for: record)
        XCTAssertEqual(declined.saidBy, "Speaker 3")

        let s2 = try XCTUnwrap(service.speakers(of: record.id).first { $0.clusterID == "S2" })
        service.createPerson(named: "Pablo Lopez", from: s2)
        XCTAssertEqual(declined.saidBy, "Pablo Lopez", "a name given later reaches decided proposals")

        service.unassign(s2)
        XCTAssertEqual(declined.saidBy, "Speaker 3", "and goes away again with 'not sure'")
    }

    func test_unidentifiedOwnersAreNotSomeoneElse() {
        for owner in ["Interlocutor no identificado", "Unknown speaker", "Speaker 2", "Participante desconocido"] {
            XCTAssertEqual(OwnerMatcher.classify(owner: owner, userNames: ["Carlos"]), .unknown, owner)
        }
        XCTAssertEqual(OwnerMatcher.classify(owner: "Diogo", userNames: ["Carlos"]), .someoneElse)
    }

    func test_refreshClearsAWrongSomeoneElseFlag() {
        let proposal = TodoProposal(meetingID: UUID(), sourceKey: "m#0", meetingTitle: "Sync",
                                    meetingStartedAt: Date(), title: "Prepare demo", evidence: "Prepare demo",
                                    owner: "Interlocutor no identificado")
        proposal.likelyForSomeoneElse = true
        proposal.hint = "The summary assigns this to Interlocutor no identificado."
        ProposalFactory.applySpeakers(nil, to: [proposal], userNames: ["Carlos"])
        XCTAssertFalse(proposal.likelyForSomeoneElse)
        XCTAssertNil(proposal.hint)
    }
}
