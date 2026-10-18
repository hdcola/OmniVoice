import Testing
@testable import OmniVoiceCore

struct SherpaOnnxTranscriberTests {
    @Test func droppingAnUnloadedTranscriberDoesNotCrash() {
        var transcriber: SherpaOnnxTranscriber? = SherpaOnnxTranscriber()
        #expect(transcriber != nil)
        transcriber = nil
        #expect(transcriber == nil)
    }
}
