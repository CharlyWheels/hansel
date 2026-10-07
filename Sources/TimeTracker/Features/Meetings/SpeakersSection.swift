import SwiftUI
import SwiftData

/// "Who spoke": the voices found in a meeting, with their names, talk time, a few
/// samples to listen to and the controls to name them. Naming a voice teaches Hansel
/// to recognise it next time.
struct SpeakersSection: View {
    let meeting: MeetingRecord
    /// Transcript lines, so samples can be whole phrases shown as they play.
    let lines: [SpeakerClips.Line]

    @Environment(DiarizationService.self) private var diarization
    @Query private var speakers: [MeetingSpeaker]
    @Query(sort: [SortDescriptor(\SpeakerProfile.name)]) private var people: [SpeakerProfile]

    @State private var naming: MeetingSpeaker?
    @State private var newName = ""
    @State private var player = SpeakerClipPlayer()

    init(meeting: MeetingRecord, lines: [SpeakerClips.Line] = []) {
        self.meeting = meeting
        self.lines = lines
        let id = meeting.id
        _speakers = Query(filter: #Predicate<MeetingSpeaker> { $0.meetingID == id },
                          sort: [SortDescriptor(\MeetingSpeaker.ordinal)])
    }

    private var totalSeconds: Double { speakers.reduce(0) { $0 + $1.speechSeconds } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Who spoke").font(.headline)
                Spacer()
                if diarization.processing.contains(meeting.id) {
                    ProgressView().controlSize(.small)
                    Text("Listening…").font(.caption).foregroundStyle(.secondary)
                } else if DiarizationService.hasAudio(meeting) {
                    Button(meeting.diarizedAt == nil ? "Identify speakers" : "Run again") {
                        Task { await diarization.process(meeting, force: true) }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            if let error = meeting.diarizationError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if speakers.isEmpty {
                Text(emptyMessage).font(.callout).foregroundStyle(.secondary)
            } else {
                let segments = SpeakerTimeline.decode(meeting.speakerSegments)
                ForEach(speakers) { speaker in row(speaker, segments: segments) }
                Text("Voices are recognised on this Mac only. Naming one teaches Hansel that voice.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .onDisappear { player.stop() }
        .alert("Who is this?", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let speaker = naming { diarization.createPerson(named: newName, from: speaker) }
                naming = nil
            }
            Button("Cancel", role: .cancel) { naming = nil }
        }
    }

    private var emptyMessage: String {
        if meeting.diarizedAt != nil { return "No clear voices were found." }
        if !DiarizationService.hasAudio(meeting) { return "The recording is no longer available, so speakers can't be identified." }
        return DiarizationService.isEnabled
            ? "Speakers are identified shortly after the meeting is imported."
            : "Speaker identification is off (Settings → Meetings)."
    }

    @ViewBuilder
    private func row(_ speaker: MeetingSpeaker, segments: [SpeakerTimeline.Segment]) -> some View {
        let person = speaker.profileID.flatMap { id in people.first { $0.id == id } }
        let samples = SpeakerClips.samples(
            track: speaker.track, cluster: speaker.clusterID, segments: segments, lines: lines
        )
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color(for: speaker)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(person?.name ?? "Speaker \(speaker.ordinal)")
                        .font(.callout.weight(person == nil ? .regular : .semibold))
                    Text(speaker.track == "system" ? "on the call" : "on your microphone")
                        .font(.caption).foregroundStyle(.secondary)
                    if speaker.assignment == .auto {
                        Text("recognised \(Int((speaker.matchScore * 100).rounded()))%")
                            .font(.caption2).foregroundStyle(.green)
                    }
                }
                if !samples.isEmpty { listenRow(samples) }
                if person == nil, let suggestion = speaker.suggestedName {
                    HStack(spacing: 6) {
                        Text("\(suggestion)?").font(.caption.weight(.medium))
                        if let evidence = speaker.suggestionEvidence {
                            Text(evidence).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Button { diarization.acceptSuggestion(speaker) } label: { Image(systemName: "checkmark") }
                            .buttonStyle(.borderless).help("Yes")
                        Button { diarization.rejectSuggestion(speaker) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("No")
                    }
                }
            }
            Spacer()
            Text("\(DurationFormat.hoursMinutes(speaker.speechSeconds)) · \(share(speaker))%")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Menu {
                if !people.isEmpty {
                    ForEach(people) { p in
                        Button(p.isMe ? "\(p.name) (me)" : p.name) { diarization.assign(speaker, to: p) }
                    }
                    Divider()
                }
                Button("New person…") { newName = ""; naming = speaker }
                Button("This is me") { diarization.markAsMe(speaker) }
                if person != nil {
                    Divider()
                    Button("Not sure") { diarization.unassign(speaker) }
                }
            } label: {
                Image(systemName: "person.crop.circle.badge.questionmark")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    /// One button per sample; the phrase being played is shown under them.
    @ViewBuilder
    private func listenRow(_ samples: [SpeakerClip]) -> some View {
        HStack(spacing: 4) {
            Text("Listen").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(samples.enumerated()), id: \.element.id) { index, clip in
                let isPlaying = player.playing == clip
                Button {
                    if isPlaying {
                        player.stop()
                    } else if let url = DiarizationService.audioURL(meeting, track: clip.track) {
                        player.play(clip, from: url)
                    }
                } label: {
                    Label("\(index + 1)", systemImage: isPlaying ? "stop.circle.fill" : "play.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(clip.text.map { "\u{201C}\($0)\u{201D}" } ?? "Play a sample of this voice")
            }
        }
        if let playing = player.playing, samples.contains(playing), let text = playing.text {
            Text("\u{201C}\(text)\u{201D}")
                .font(.caption).italic().foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    private func share(_ speaker: MeetingSpeaker) -> Int {
        totalSeconds > 0 ? Int((speaker.speechSeconds / totalSeconds * 100).rounded()) : 0
    }

    private func color(for speaker: MeetingSpeaker) -> Color {
        Color(hue: StableHash.unitInterval(speaker.profileID?.uuidString ?? speaker.key), saturation: 0.6, brightness: 0.8)
    }
}
