import Foundation
import FluidAudio

/// `Diarizer` on FluidAudio's offline pipeline. Runs on this Mac only; the models
/// (about 20 MB) are downloaded once to ~/Library/Application Support/FluidAudio.
actor FluidAudioDiarizer: Diarizer {
    private var manager: OfflineDiarizerManager?

    func diarize(_ url: URL) async throws -> DiarizationOutput {
        let manager = try await preparedManager()
        let result = try await manager.process(url)
        let segments = result.segments.map {
            DiarizationOutput.Segment(start: Double($0.startTimeSeconds),
                                      end: Double($0.endTimeSeconds),
                                      cluster: $0.speakerId)
        }
        return DiarizationOutput(segments: segments, embeddings: result.speakerDatabase ?? [:])
    }

    private func preparedManager() async throws -> OfflineDiarizerManager {
        if let manager { return manager }
        let created = OfflineDiarizerManager(config: .default)
        try await created.prepareModels()
        manager = created
        return created
    }
}
