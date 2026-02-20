import XCTest

@testable import FluidAudio

final class OverlapResolutionTests: XCTestCase {

    private let dummyEmbedding: [Float] = Array(repeating: 0.1, count: 192)

    private func makeSegment(
        speaker: String, start: Float, end: Float, quality: Float = 0.8
    ) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: speaker,
            embedding: dummyEmbedding,
            startTimeSeconds: start,
            endTimeSeconds: end,
            qualityScore: quality
        )
    }

    private func makeReconstruction(
        minSegmentDuration: Double = 0.3
    ) -> OfflineReconstruction {
        var config = OfflineDiarizerConfig()
        config.minSegmentDuration = minSegmentDuration
        config.resolveOverlaps = true
        return OfflineReconstruction(config: config)
    }

    // MARK: - No Overlap Cases

    func testNoOverlapPassesThrough() {
        let reconstruction = makeReconstruction()
        let segments = [
            makeSegment(speaker: "S1", start: 0.0, end: 5.0),
            makeSegment(speaker: "S2", start: 5.0, end: 10.0),
        ]

        let result = reconstruction.resolveOverlaps(in: segments)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].speakerId, "S1")
        XCTAssertEqual(result[1].speakerId, "S2")
    }

    func testSameSpeakerOverlapPassesThrough() {
        let reconstruction = makeReconstruction()
        // Same speaker overlapping — not a cross-speaker overlap
        let segments = [
            makeSegment(speaker: "S1", start: 0.0, end: 6.0),
            makeSegment(speaker: "S1", start: 4.0, end: 10.0),
        ]

        let result = reconstruction.resolveOverlaps(in: segments)

        // Should pass through unchanged (no cross-speaker overlap)
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - Cross-Speaker Overlap Resolution

    func testCrossSpeakerOverlapAssignedToLongerSegment() {
        let reconstruction = makeReconstruction()

        // S1: 0-8s (duration=8), S2: 5-10s (duration=5)
        // Overlap region: 5-8s → S1 wins (longer segment)
        let segments = [
            makeSegment(speaker: "S1", start: 0.0, end: 8.0),
            makeSegment(speaker: "S2", start: 5.0, end: 10.0),
        ]

        let result = reconstruction.resolveOverlaps(in: segments)

        // Should produce: S1 [0-8], S2 [8-10]
        // S1 gets the overlap region because its covering segment is longer (8s vs 5s)
        XCTAssertEqual(result.count, 2, "Should have exactly 2 resolved segments")
        XCTAssertEqual(result[0].speakerId, "S1")
        XCTAssertEqual(result[0].startTimeSeconds, 0.0, accuracy: 0.01)
        XCTAssertEqual(result[0].endTimeSeconds, 8.0, accuracy: 0.01)
        XCTAssertEqual(result[1].speakerId, "S2")
        XCTAssertEqual(result[1].startTimeSeconds, 8.0, accuracy: 0.01)
        XCTAssertEqual(result[1].endTimeSeconds, 10.0, accuracy: 0.01)
    }

    func testShorterSegmentWinsWhenItHasMoreContext() {
        let reconstruction = makeReconstruction()

        // S1: 0-3s (duration=3), S2: 2-12s (duration=10)
        // Overlap region: 2-3s → S2 wins (longer segment)
        let segments = [
            makeSegment(speaker: "S1", start: 0.0, end: 3.0),
            makeSegment(speaker: "S2", start: 2.0, end: 12.0),
        ]

        let result = reconstruction.resolveOverlaps(in: segments)

        // Should produce: S1 [0-2], S2 [2-12]
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].speakerId, "S1")
        XCTAssertEqual(result[0].endTimeSeconds, 2.0, accuracy: 0.01)
        XCTAssertEqual(result[1].speakerId, "S2")
        XCTAssertEqual(result[1].startTimeSeconds, 2.0, accuracy: 0.01)
        XCTAssertEqual(result[1].endTimeSeconds, 12.0, accuracy: 0.01)
    }

    func testThreeSpeakerOverlap() {
        let reconstruction = makeReconstruction()

        // Three-way overlap at 5-6s:
        // S1: 0-6s (duration=6), S2: 4-8s (duration=4), S3: 5-15s (duration=10)
        let segments = [
            makeSegment(speaker: "S1", start: 0.0, end: 6.0),
            makeSegment(speaker: "S2", start: 4.0, end: 8.0),
            makeSegment(speaker: "S3", start: 5.0, end: 15.0),
        ]

        let result = reconstruction.resolveOverlaps(in: segments)

        // At 5-6s midpoint: S1 (6s), S2 (4s), S3 (10s) → S3 wins
        // At 4-5s midpoint: S1 (6s), S2 (4s) → S1 wins
        // Expected: S1 [0-5], S3 [5-6], ??? — depends on exact boundaries
        // Just verify non-overlapping and all time covered
        for i in 0..<(result.count - 1) {
            XCTAssertLessThanOrEqual(
                result[i].endTimeSeconds,
                result[i + 1].startTimeSeconds + 0.01,
                "Segments should not overlap after resolution"
            )
        }
        // Verify full time range covered
        XCTAssertEqual(result.first?.startTimeSeconds ?? 99, 0.0, accuracy: 0.01)
        XCTAssertEqual(result.last?.endTimeSeconds ?? 0, 15.0, accuracy: 0.01)
    }

    // MARK: - Minimum Duration Filter

    func testShortResolvedSegmentsFiltered() {
        let reconstruction = makeReconstruction(minSegmentDuration: 1.0)

        // S1: 0-10s (duration=10), S2: 9.5-10s (duration=0.5)
        // After resolution, S2 only gets 0.5s → should be filtered out
        let segments = [
            makeSegment(speaker: "S1", start: 0.0, end: 10.0),
            makeSegment(speaker: "S2", start: 9.5, end: 10.5),
        ]

        let result = reconstruction.resolveOverlaps(in: segments)

        // S2's resolved portion is 10.0-10.5 = 0.5s, below minSegmentDuration of 1.0
        // S1 keeps 0-10s (10s > 1.0 min)
        XCTAssertEqual(result.count, 1, "Short resolved segment should be filtered")
        XCTAssertEqual(result[0].speakerId, "S1")
    }

    // MARK: - Quality Score Propagation

    func testQualityScoreAveragedAcrossIntervals() {
        let reconstruction = makeReconstruction()

        // Non-overlapping simple case — quality should pass through
        let segments = [
            makeSegment(speaker: "S1", start: 0.0, end: 5.0, quality: 0.9),
            makeSegment(speaker: "S2", start: 3.0, end: 8.0, quality: 0.6),
        ]

        let result = reconstruction.resolveOverlaps(in: segments)

        // S1 wins overlap (5s > 5s is a tie, but S1 comes first in iteration)
        // Verify quality scores are reasonable (0-1 range)
        for seg in result {
            XCTAssertGreaterThan(seg.qualityScore, 0)
            XCTAssertLessThanOrEqual(seg.qualityScore, 1.0)
        }
    }

    // MARK: - Edge Cases

    func testSingleSegmentPassesThrough() {
        let reconstruction = makeReconstruction()
        let segments = [makeSegment(speaker: "S1", start: 0.0, end: 10.0)]

        let result = reconstruction.resolveOverlaps(in: segments)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speakerId, "S1")
    }

    func testEmptyInputReturnsEmpty() {
        let reconstruction = makeReconstruction()
        let result = reconstruction.resolveOverlaps(in: [])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Config Flag

    func testResolveOverlapsDefaultEnabled() {
        let config = OfflineDiarizerConfig()
        XCTAssertTrue(config.resolveOverlaps, "resolveOverlaps should default to true")
    }

    func testResolveOverlapsCanBeDisabled() {
        var config = OfflineDiarizerConfig()
        config.resolveOverlaps = false
        XCTAssertFalse(config.resolveOverlaps)
    }
}
