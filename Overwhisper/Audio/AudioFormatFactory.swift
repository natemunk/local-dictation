import AVFoundation
import AudioToolbox

enum AudioFormatFactory {
    static func noninterleavedFloat32(
        sampleRate: Double,
        channels: AVAudioChannelCount
    ) -> AVAudioFormat? {
        guard sampleRate > 0, channels > 0 else { return nil }
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        if channels > 2 {
            let tag = kAudioChannelLayoutTag_DiscreteInOrder | channels
            guard let layout = AVAudioChannelLayout(layoutTag: tag) else { return nil }
            return AVAudioFormat(streamDescription: &description, channelLayout: layout)
        }
        return AVAudioFormat(streamDescription: &description)
    }
}
