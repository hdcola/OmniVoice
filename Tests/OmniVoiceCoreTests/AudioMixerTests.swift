import Foundation
import Testing
@testable import OmniVoiceCore

/// `AudioMixer` does all its real work on a private serial background
/// queue (`submitMic`/`submitSystemAudio` are both `queue.async`), so every
/// test here gives that queue a brief moment to actually run before
/// asserting on `onPCMChunk`/`onLevel` — there's no public "flush"/"sync"
/// hook to await instead, and the work itself (array arithmetic on small
/// buffers) is fast enough that a short sleep is not flaky in practice.
struct AudioMixerTests {
    private static let settleDelay: UInt64 = 50_000_000 // 50ms

    @Test func micOnlyModeEmitsMicSamplesUnchanged() async {
        let mixer = AudioMixer(includeSystemAudio: false)
        var received: [Float]?
        mixer.onPCMChunk = { received = $0 }

        mixer.submitMic([0.1, 0.2, 0.3])
        try? await Task.sleep(nanoseconds: Self.settleDelay)

        #expect(received == [0.1, 0.2, 0.3])
    }

    @Test func mixesMicAndSystemAudioWithClipping() async {
        let mixer = AudioMixer(includeSystemAudio: true)
        var received: [Float]?
        mixer.onPCMChunk = { received = $0 }

        // A serial queue preserves call order, so the system-audio sample
        // is guaranteed buffered before `submitMic` mixes it in.
        mixer.submitSystemAudio([0.3])
        mixer.submitMic([0.5])
        try? await Task.sleep(nanoseconds: Self.settleDelay)

        #expect(received?.count == 1)
        #expect(abs((received?[0] ?? 0) - 0.8) < 0.0001)
    }

    @Test func clipsAMixThatWouldExceedFullScale() async {
        let mixer = AudioMixer(includeSystemAudio: true)
        var received: [Float]?
        mixer.onPCMChunk = { received = $0 }

        mixer.submitSystemAudio([0.9])
        mixer.submitMic([0.9])
        try? await Task.sleep(nanoseconds: Self.settleDelay)

        #expect(received?.first == 1.0)
    }

    /// `micEnabled: false` — see `AudioInputDevice.none`'s doc — puts
    /// system audio in direct control of the output cadence instead of
    /// buffering it for a mic callback that will never come.
    @Test func withMicDisabledSystemAudioEmitsDirectly() async {
        let mixer = AudioMixer(includeSystemAudio: true, micEnabled: false)
        var received: [Float]?
        mixer.onPCMChunk = { received = $0 }

        mixer.submitSystemAudio([0.4, 0.5])
        try? await Task.sleep(nanoseconds: Self.settleDelay)

        #expect(received == [0.4, 0.5])
    }

    /// Defensive guard (see `submitMic`'s doc) — nothing calls this in
    /// `micEnabled: false` mode today, but it should still be a safe no-op,
    /// not mixed in, if something did.
    @Test func withMicDisabledSubmitMicIsANoOp() async {
        let mixer = AudioMixer(includeSystemAudio: true, micEnabled: false)
        var receivedCount = 0
        mixer.onPCMChunk = { _ in receivedCount += 1 }

        mixer.submitMic([0.5])
        try? await Task.sleep(nanoseconds: Self.settleDelay)

        #expect(receivedCount == 0)
    }

    @Test func systemAudioIsIgnoredWhenNotIncluded() async {
        let mixer = AudioMixer(includeSystemAudio: false)
        var received: [Float]?
        mixer.onPCMChunk = { received = $0 }

        mixer.submitSystemAudio([0.9]) // should never be buffered/mixed in
        mixer.submitMic([0.1])
        try? await Task.sleep(nanoseconds: Self.settleDelay)

        #expect(received == [0.1])
    }

    @Test func levelIsZeroForSilence() async {
        let mixer = AudioMixer(includeSystemAudio: false)
        var level: Float?
        mixer.onLevel = { level = $0 }

        mixer.submitMic([0, 0, 0])
        try? await Task.sleep(nanoseconds: Self.settleDelay)

        #expect(level == 0)
    }

    @Test func levelIsPositiveForALoudSample() async {
        let mixer = AudioMixer(includeSystemAudio: false)
        var level: Float?
        mixer.onLevel = { level = $0 }

        mixer.submitMic([1.0])
        try? await Task.sleep(nanoseconds: Self.settleDelay)

        #expect((level ?? 0) > 0)
    }

    @Test func emptySamplesEmitNothing() async {
        let mixer = AudioMixer(includeSystemAudio: false)
        var callCount = 0
        mixer.onPCMChunk = { _ in callCount += 1 }

        mixer.submitMic([])
        try? await Task.sleep(nanoseconds: Self.settleDelay)

        #expect(callCount == 0)
    }
}
