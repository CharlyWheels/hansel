import XCTest
@testable import TimeTracker

/// The meeting part of the arbiter end to end: a call starts, meetings follow one
/// another, the user listens without typing, the call ends. Modelled on a real
/// afternoon where three back-to-back meetings became five entries named after the
/// first one.
@MainActor
final class MeetingLifecycleTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    // The simulated world.
    private var running: EntryContext?
    private var closed: [(title: String, start: Date, end: Date)] = []
    private var joined: (MeetingWindow, Date)?
    private var inCall = false
    private var callEndedAt: Date?
    private var isIdle = false
    private var locked = false
    private var autoStop = true
    private var resumeAllowed = true
    private var resumedIDs: [UUID] = []

    override func setUp() {
        super.setUp()
        clock = t0
        running = nil; closed = []; joined = nil; resumeAllowed = true; resumedIDs = []
        inCall = false; callEndedAt = nil; isIdle = false; locked = false; autoStop = true
    }

    private func makeArbiter() -> FocusArbiter {
        var deps = FocusArbiter.Dependencies(
            buildContext: { _ in nil },
            consult: { _ in throw AIError.emptyResponse },
            apply: { [weak self] action, _, _ in
                guard let self, case let .switchTo(proposal) = action else { return }
                if let current = self.running {
                    self.closed.append((current.title, current.startAt, proposal.boundaryAt))
                }
                self.running = EntryContext(id: UUID(), title: proposal.title ?? "", startAt: proposal.boundaryAt)
            },
            record: { _ in }
        )
        deps.now = { [weak self] in self?.clock ?? Date() }
        deps.currentEntry = { [weak self] in self?.running }
        deps.isIdle = { [weak self] in self?.isIdle ?? false }
        deps.isLockedOrAsleep = { [weak self] in self?.locked ?? false }
        deps.joinedMeeting = { [weak self] in self?.joined.map { (meeting: $0.0, since: $0.1) } }
        deps.inCall = { [weak self] in self?.inCall ?? false }
        deps.callEndedAt = { [weak self] in self?.callEndedAt }
        deps.autoStopOnMeetingEnd = { [weak self] in self?.autoStop ?? true }
        deps.stopMeetingEntry = { [weak self] id, at in
            guard let self, let current = self.running, current.id == id else { return }
            self.closed.append((current.title, current.startAt, at))
            self.running = nil
        }
        deps.resumeEntry = { [weak self] id in
            guard let self, self.resumeAllowed, self.running == nil,
                  let index = self.closed.lastIndex(where: { _ in true }) else { return false }
            let last = self.closed.remove(at: index)
            self.running = EntryContext(id: id, title: last.title, startAt: last.start)
            self.resumedIDs.append(id)
            return true
        }
        return FocusArbiter(dependencies: deps)
    }

    private func meeting(_ title: String, at minutes: Double, for length: Double = 30) -> MeetingWindow {
        MeetingWindow(eventId: "\(title)#\(minutes)", title: title,
                      start: t0.addingTimeInterval(minutes * 60),
                      end: t0.addingTimeInterval((minutes + length) * 60),
                      attendance: .accepted, attendeeCount: 3)
    }

    private func at(_ minutes: Double) { clock = t0.addingTimeInterval(minutes * 60) }

    // MARK: - Tests

    func test_backToBackMeetingsEachGetTheirOwnEntryNamedAfterTheCalendar() async {
        let arbiter = makeArbiter()
        running = EntryContext(id: UUID(), title: "Reading Confluence", startAt: t0.addingTimeInterval(-3600))

        // Call starts at 0:01 for the 0:00 meeting.
        at(1); inCall = true
        let callStart = t0.addingTimeInterval(60)
        joined = (meeting("Solution engineers meetup", at: 0), callStart)
        await arbiter.tick()
        XCTAssertEqual(running?.title, "Solution engineers meetup")
        XCTAssertEqual(running?.startAt, callStart)

        // The user listens without typing: HID idle, screen unlocked. The next meeting
        // still takes over at its scheduled start.
        isIdle = true
        at(31)
        joined = (meeting("CR <> SS", at: 30), callStart)
        await arbiter.tick()
        XCTAssertEqual(running?.title, "CR <> SS")
        XCTAssertEqual(running?.startAt, t0.addingTimeInterval(30 * 60))

        at(61)
        joined = (meeting("Meet Up LP", at: 60, for: 60), callStart)
        await arbiter.tick()
        XCTAssertEqual(running?.title, "Meet Up LP")

        XCTAssertEqual(closed.map(\.title), ["Reading Confluence", "Solution engineers meetup", "CR <> SS"])
    }

    func test_joiningWithNothingRunningStartsTheMeeting() async {
        let arbiter = makeArbiter()
        at(2); inCall = true
        joined = (meeting("Daily standup", at: 0), t0.addingTimeInterval(90))
        await arbiter.tick()
        XCTAssertEqual(running?.title, "Daily standup")
        XCTAssertEqual(running?.startAt, t0.addingTimeInterval(90))
    }

    func test_hangingUpClosesTheMeetingWhereTheCallEnded() async {
        let arbiter = makeArbiter()
        at(1); inCall = true
        joined = (meeting("Daily standup", at: 0), t0)
        await arbiter.tick()

        at(25); inCall = false; joined = nil
        callEndedAt = t0.addingTimeInterval(23 * 60)
        await arbiter.tick()
        XCTAssertNil(running)
        XCTAssertEqual(closed.last?.title, "Daily standup")
        XCTAssertEqual(closed.last?.end, callEndedAt)
    }

    func test_hangingUpLeavesAloneAnEntryTheUserStartedThemselves() async {
        let arbiter = makeArbiter()
        at(1); inCall = true
        joined = (meeting("Daily standup", at: 0), t0)
        await arbiter.tick()

        // The user moved on by hand during the call.
        running = EntryContext(id: UUID(), title: "Writing the proposal", startAt: clock)
        at(25); inCall = false; joined = nil; callEndedAt = clock
        await arbiter.tick()
        XCTAssertEqual(running?.title, "Writing the proposal")
    }

    func test_hangingUpDoesNothingWhenTheSettingIsOff() async {
        autoStop = false
        let arbiter = makeArbiter()
        at(1); inCall = true
        joined = (meeting("Daily standup", at: 0), t0)
        await arbiter.tick()
        at(25); inCall = false; joined = nil; callEndedAt = clock
        await arbiter.tick()
        XCTAssertEqual(running?.title, "Daily standup")
    }

    func test_aCallThatComesBackResumesTheSameEntry() async {
        let arbiter = makeArbiter()
        at(1); inCall = true
        let standup = meeting("Daily standup", at: 0)
        joined = (standup, t0)
        await arbiter.tick()
        let entry = running

        at(10); inCall = false; joined = nil; callEndedAt = clock
        await arbiter.tick()
        XCTAssertNil(running)

        at(12); inCall = true; joined = (standup, clock)
        await arbiter.tick()
        XCTAssertEqual(resumedIDs, [entry?.id].compactMap { $0 })
        XCTAssertEqual(running?.id, entry?.id, "same entry, not a second one with the same name")
    }

    func test_aMeetingIsNeverStartedTwice() async {
        let arbiter = makeArbiter()
        resumeAllowed = false
        at(1); inCall = true
        let standup = meeting("Daily standup", at: 0)
        joined = (standup, t0)
        await arbiter.tick()
        at(10); inCall = false; joined = nil; callEndedAt = clock
        await arbiter.tick()

        // Resume refused (something else happened): still no duplicate.
        at(12); inCall = true; joined = (standup, clock)
        await arbiter.tick()
        XCTAssertNil(running)
    }

    func test_noDriftQuestionsDuringTheMeetingsCall() async {
        var consults = 0
        var deps = FocusArbiter.Dependencies(
            buildContext: { _ in nil },
            consult: { _ in consults += 1; throw AIError.emptyResponse },
            apply: { [weak self] action, _, _ in
                guard let self, case let .switchTo(p) = action else { return }
                self.running = EntryContext(id: UUID(), title: p.title ?? "", startAt: p.boundaryAt)
            },
            record: { _ in }
        )
        deps.now = { [weak self] in self?.clock ?? Date() }
        deps.currentEntry = { [weak self] in self?.running }
        deps.joinedMeeting = { [weak self] in self?.joined.map { (meeting: $0.0, since: $0.1) } }
        deps.inCall = { [weak self] in self?.inCall ?? false }
        var samplesAsked = false
        deps.samples = { _, _ in samplesAsked = true; return [] }
        let arbiter = FocusArbiter(dependencies: deps)

        at(1); inCall = true
        joined = (meeting("Daily standup", at: 0), t0)
        await arbiter.tick()
        at(5)
        await arbiter.tick()
        XCTAssertFalse(samplesAsked, "the segmenter is not even run during the call")
        XCTAssertEqual(consults, 0)
    }

    func test_lockedScreenDoesNotSwitch() async {
        let arbiter = makeArbiter()
        running = EntryContext(id: UUID(), title: "Reading", startAt: t0.addingTimeInterval(-600))
        locked = true; isIdle = true
        at(1); inCall = true
        joined = (meeting("Daily standup", at: 0), t0)
        await arbiter.tick()
        XCTAssertEqual(running?.title, "Reading")
    }
}
