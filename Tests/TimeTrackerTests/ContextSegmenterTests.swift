import XCTest
@testable import TimeTracker

/// The calibration table from the design is the acceptance criterion for the segmenter.
/// Every test here is a scenario the tracker gets wrong today.
final class ContextSegmenterTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // fixed clock

    // MARK: - The calibration table

    func test_appSwitchSameTopic_producesNoCandidate() {
        // Moving between an editor and a terminal on the same work is not a task change.
        let samples =
            stream(from: 0, to: 1800, bundle: "com.microsoft.VSCode", title: "acme api main")
            + stream(from: 1800, to: 3000, bundle: "com.apple.Terminal", title: "acme api main")

        let out = evaluate(samples: samples, nowOffset: 3000)
        XCTAssertTrue(out.candidates.isEmpty, "scored \(out.candidates.map(\.score))")
    }

    func test_appTopicAndHostAllChange_producesAskLevelCandidate() {
        let samples =
            stream(from: 0, to: 1800, bundle: "com.google.Chrome",
                   title: "acme api ticket", url: "https://acme.atlassian.net/browse/ACME-1")
            + stream(from: 1800, to: 3000, bundle: "com.microsoft.VSCode",
                     title: "globex invoicing migration", url: "https://globex.github.io/docs")

        let out = evaluate(samples: samples, nowOffset: 3000)
        let candidate = try? XCTUnwrap(out.candidates.first)
        XCTAssertNotNil(candidate)
        guard let candidate else { return }
        XCTAssertEqual(candidate.at.timeIntervalSince(t0), 1800, accuracy: 60)
        XCTAssertGreaterThanOrEqual(candidate.score, 0.45)
        XCTAssertLessThan(candidate.score, 0.75, "should ask, not act unilaterally")
        XCTAssertFalse(candidate.isHard)
        XCTAssertTrue(candidate.reasons.contains(.appSwitch))
        XCTAssertTrue(candidate.reasons.contains(.topicShift))
    }

    func test_longIdleThenDifferentApp_producesCandidateCitingTheGap() {
        // 15 minutes away, then work resumes in a different app.
        let samples =
            stream(from: 0, to: 900, bundle: "com.microsoft.VSCode", title: "acme api main")
            + stream(from: 1800, to: 3000, bundle: "com.apple.Preview", title: "acme api main")
        let idle = [IdleSpan(start: t0 + 900, end: t0 + 1800)]

        let out = evaluate(samples: samples, idleSpans: idle, nowOffset: 3000)
        guard let candidate = out.candidates.first else { return XCTFail("no candidate") }
        XCTAssertEqual(candidate.at.timeIntervalSince(t0), 1800, accuracy: 60)
        XCTAssertGreaterThanOrEqual(candidate.score, 0.45)
        XCTAssertTrue(candidate.reasons.contains(.idleGap))
    }

    func test_acceptedMeetingCorroboratedByMic_isHardBoundary() {
        // This is the reported worst case: a meeting starts while another task runs.
        let samples =
            stream(from: 0, to: 1800, bundle: "com.microsoft.VSCode", title: "acme api main")
            + stream(from: 1800, to: 3000, bundle: "us.zoom.xos", title: "Zoom Meeting",
                     flags: [.micActive, .videoCallApp])
        let meeting = MeetingWindow(
            eventId: "evt-1", title: "Weekly Nedap",
            start: t0 + 1800, end: t0 + 3600,
            attendance: .accepted, attendeeCount: 6, hasConferenceURL: true
        )

        let out = evaluate(samples: samples, meetings: [meeting], nowOffset: 3000)
        guard let candidate = out.candidates.first else { return XCTFail("no candidate") }
        XCTAssertTrue(candidate.isHard, "score=\(candidate.score)")
        XCTAssertEqual(candidate.meetingEventId, "evt-1")
        XCTAssertTrue(candidate.reasons.contains(.meetingStart))
    }

    func test_declinedAllDayEvent_producesNothing() {
        let samples = stream(from: 0, to: 3000, bundle: "com.microsoft.VSCode", title: "acme api main")
        let offsite = MeetingWindow(
            eventId: "evt-2", title: "Company Offsite",
            start: t0 + 1800, end: t0 + 1800 + 28_800,
            isAllDay: true, attendance: .declined
        )

        let out = evaluate(samples: samples, meetings: [offsite], nowOffset: 3000)
        XCTAssertTrue(out.candidates.isEmpty)
    }

    func test_focusTimeHoldDoesNotReachAskThreshold_onItsOwn() {
        // A "free" hold with no corroboration must not yank the timer.
        let samples = stream(from: 0, to: 3000, bundle: "com.microsoft.VSCode", title: "acme api main")
        let hold = MeetingWindow(
            eventId: "evt-3", title: "Focus time",
            start: t0 + 1800, end: t0 + 3600,
            showsAsFree: true, attendance: .accepted
        )

        let out = evaluate(samples: samples, meetings: [hold], nowOffset: 3000)
        XCTAssertTrue(out.candidates.isEmpty, "scored \(out.candidates.map(\.score))")
    }

    // MARK: - False-positive suppression

    func test_briefExcursionIsIgnoredButSustainedSwitchIsNot() {
        let base = stream(from: 0, to: 1800, bundle: "com.microsoft.VSCode", title: "acme api main")

        // 60 seconds in Slack, then straight back to the same work.
        let peek = base
            + stream(from: 1800, to: 1860, bundle: "com.tinyspeck.slackmacgap", title: "globex chat")
            + stream(from: 1860, to: 3000, bundle: "com.microsoft.VSCode", title: "acme api main")
        XCTAssertTrue(
            evaluate(samples: peek, nowOffset: 3000).candidates.isEmpty,
            "a 60 s glance at Slack is not a task change"
        )

        // The same switch, sustained.
        let sustained = base
            + stream(from: 1800, to: 3000, bundle: "com.tinyspeck.slackmacgap",
                     title: "globex invoicing incident triage")
        XCTAssertFalse(
            evaluate(samples: sustained, nowOffset: 3000).candidates.isEmpty,
            "a sustained switch must still be caught"
        )
    }

    func test_recentBoundaryIsProvisionalUntilItPersists() {
        // Boundary 30 s ago: real or not, we cannot know yet.
        let samples =
            stream(from: 0, to: 1800, bundle: "com.google.Chrome",
                   title: "acme api ticket", url: "https://acme.atlassian.net/browse/ACME-1")
            + stream(from: 1800, to: 1830, bundle: "com.microsoft.VSCode",
                     title: "globex invoicing migration", url: "https://globex.github.io/docs")

        let out = evaluate(samples: samples, nowOffset: 1830)
        XCTAssertTrue(
            out.candidates.allSatisfy(\.isProvisional),
            "nothing inside the dwell window may be actionable"
        )
    }

    func test_suppressedTransitionIsNotProposed() {
        var config = ContextSegmenter.Config.default
        config.suppressedTransitions = ["com.google.Chrome>com.microsoft.VSCode"]
        let samples =
            stream(from: 0, to: 1800, bundle: "com.google.Chrome",
                   title: "acme api ticket", url: "https://acme.atlassian.net/browse/ACME-1")
            + stream(from: 1800, to: 3000, bundle: "com.microsoft.VSCode",
                     title: "globex invoicing migration", url: "https://globex.github.io/docs")

        let out = evaluate(samples: samples, nowOffset: 3000, config: config)
        XCTAssertTrue(out.candidates.isEmpty, "learned suppression should silence this")
    }

    func test_nonMaximumSuppressionKeepsOneCandidatePerNeighbourhood() {
        // Several rapid changes in the same few minutes must not yield a burst.
        var samples: [SignalSample] = []
        samples += stream(from: 0, to: 1800, bundle: "com.microsoft.VSCode", title: "acme api main")
        samples += stream(from: 1800, to: 1900, bundle: "com.google.Chrome",
                          title: "globex invoicing", url: "https://globex.com/a")
        samples += stream(from: 1900, to: 2000, bundle: "com.apple.Preview", title: "globex invoicing pdf")
        samples += stream(from: 2000, to: 3200, bundle: "com.google.Chrome",
                          title: "globex invoicing migration", url: "https://globex.com/a")

        let out = evaluate(samples: samples, nowOffset: 3200)
        let withinFiveMinutes = out.candidates.filter {
            abs($0.at.timeIntervalSince(self.t0 + 1900)) < 300
        }
        XCTAssertLessThanOrEqual(withinFiveMinutes.count, 1)
    }

    func test_boundaryNeverPrecedesMinimumSegmentAfterEntryStart() {
        let samples =
            stream(from: 0, to: 60, bundle: "com.microsoft.VSCode", title: "acme api main")
            + stream(from: 60, to: 1200, bundle: "com.google.Chrome",
                     title: "globex invoicing", url: "https://globex.com/a")
        let entry = EntryContext(id: UUID(), title: "Acme API", startAt: t0)

        let out = evaluate(samples: samples, currentEntry: entry, nowOffset: 1200)
        XCTAssertTrue(
            out.candidates.allSatisfy { $0.at >= self.t0.addingTimeInterval(180) },
            "must never carve a sliver off the start of the running entry"
        )
    }

    // MARK: - Helpers

    private func stream(
        from: TimeInterval,
        to: TimeInterval,
        bundle: String,
        title: String,
        url: String? = nil,
        flags: SignalFlags = [],
        every: TimeInterval = 30
    ) -> [SignalSample] {
        stride(from: from, to: to, by: every).map { offset in
            SignalSample(
                timestamp: t0.addingTimeInterval(offset),
                bundleId: bundle,
                appName: bundle,
                windowTitle: title,
                url: url,
                flags: flags
            )
        }
    }

    private func evaluate(
        samples: [SignalSample],
        idleSpans: [IdleSpan] = [],
        meetings: [MeetingWindow] = [],
        currentEntry: EntryContext? = nil,
        nowOffset: TimeInterval,
        config: ContextSegmenter.Config = .default
    ) -> ContextSegmenter.Output {
        ContextSegmenter.evaluate(
            ContextSegmenter.Input(
                now: t0.addingTimeInterval(nowOffset),
                samples: samples,
                idleSpans: idleSpans,
                meetings: meetings,
                currentEntry: currentEntry,
                config: config
            )
        )
    }
}
