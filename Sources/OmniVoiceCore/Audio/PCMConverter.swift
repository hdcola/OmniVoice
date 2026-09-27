import AVFoundation
import CoreMedia

/// Converts an arbitrary-format `CMSampleBuffer` (as delivered by
/// `AVCaptureAudioDataOutput` or `SCStream`) into mono Float32 PCM samples at
/// a fixed intermediate sample rate — the common format the mic/system-audio
/// captures and `AudioMixer` operate in. Ported unchanged (as `internal`,
/// this module's own capture types are its only callers) from
/// `mac-poc-hybrid/Sources/R2T2HybridPOC/Audio/PCMConverter.swift`.
final class PCMConverter {
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var lastSourceFormat: AVAudioFormat?

    init(targetSampleRate: Double, targetChannels: AVAudioChannelCount) {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        )!
    }

    func convert(sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let sourceFormat = AVAudioFormat(streamDescription: asbd)
        else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        let maxBuffers = max(Int(sourceFormat.channelCount), 1)
        let listPointer = AudioBufferList.allocate(maximumBuffers: maxBuffers)
        defer { free(listPointer.unsafeMutablePointer) }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: maxBuffers),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr,
              let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                bufferListNoCopy: listPointer.unsafeMutablePointer,
                deallocator: nil
              )
        else {
            return nil
        }
        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)

        if converter == nil || lastSourceFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            lastSourceFormat = sourceFormat
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frameCount) * ratio) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?
        let conversionStatus = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        guard conversionStatus != .error,
              conversionError == nil,
              let floatData = outputBuffer.floatChannelData
        else {
            return nil
        }
        // Keep the CMBlockBuffer-backed memory alive through the synchronous
        // conversion above; sourceBuffer only wraps it, it does not own a copy.
        withExtendedLifetime(blockBuffer) {}
        return Array(UnsafeBufferPointer(start: floatData[0], count: Int(outputBuffer.frameLength)))
    }
}
