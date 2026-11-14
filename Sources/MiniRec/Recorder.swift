import AVFoundation
import ScreenCaptureKit

/// Captures one area of one display with ScreenCaptureKit and writes it to an H.264 MP4.
/// All sample buffers arrive on `queue`, so the writer state needs no other locking.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let url: URL
    var onStreamError: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "MiniRec.recorder")
    private var stream: SCStream?
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var lastFrame: CMSampleBuffer?
    private var lastTime = CMTime.zero

    init(url: URL, width: Int, height: Int, settings: Settings) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // About 0.05 bits per pixel per frame: screen text stays sharp, and a 1440×900 area
        // at 30 fps stays under about 15 MB per minute. Static screens use much less.
        let bitRate = min(max(Double(width * height * settings.fps) * 0.05, 1_000_000), 12_000_000)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: settings.fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        if settings.systemAudio {
            audioInput = Recorder.aacInput(channels: 2, bitRate: 128_000)
            writer.add(audioInput!)
        }
        if !settings.microphoneID.isEmpty {
            micInput = Recorder.aacInput(channels: 1, bitRate: 64_000)
            writer.add(micInput!)
        }
        super.init()
    }

    private static func aacInput(channels: Int, bitRate: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    /// `rect` is in the display's points, with the origin at its top-left corner.
    func start(displayID: CGDirectDisplayID, rect: CGRect, width: Int, height: Int, settings: Settings) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "MiniRec", code: 1, userInfo: [NSLocalizedDescriptionKey: "The display is not available."])
        }
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = settings.showCursor
        config.queueDepth = 6
        config.capturesAudio = settings.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        if !settings.microphoneID.isEmpty {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = settings.microphoneID
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if settings.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if micInput != nil { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }

        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid, writer.status == .writing else { return }
        let time = buffer.presentationTimeStamp
        switch type {
        case .screen:
            // ScreenCaptureKit also sends idle frames when nothing changed; they carry no image.
            guard let info = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete
            else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: time)
                sessionStarted = true
            }
            if videoInput.isReadyForMoreMediaData, videoInput.append(buffer) {
                lastFrame = buffer
                lastTime = max(lastTime, time)
            }
        case .audio:
            append(buffer, to: audioInput)
        case .microphone:
            append(buffer, to: micInput)
        @unknown default:
            break
        }
    }

    private func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard sessionStarted, let input, input.isReadyForMoreMediaData else { return }
        if input.append(buffer) { lastTime = max(lastTime, buffer.presentationTimeStamp) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStreamError?(error) }
    }

    /// Stops capture and finishes the file. Throws when no frame was recorded.
    func stop() async throws -> URL {
        try? await stream?.stopCapture()
        stream = nil
        try await finish()
        if audioInput != nil, micInput != nil { try await Recorder.mergeAudioTracks(in: url) }
        return url
    }

    private func finish() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard sessionStarted, writer.status == .writing else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    cont.resume(throwing: writer.error ?? NSError(domain: "MiniRec", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "No video was recorded."]))
                    return
                }
                // The screen may not change at the end. Repeat the last frame at the stop
                // time, so the video is as long as the recording.
                let end = max(lastTime, CMClockGetTime(CMClockGetHostTimeClock()))
                if let lastFrame, end > lastFrame.presentationTimeStamp, videoInput.isReadyForMoreMediaData {
                    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: end, decodeTimeStamp: .invalid)
                    var copy: CMSampleBuffer?
                    CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: lastFrame,
                                                          sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                          sampleBufferOut: &copy)
                    if let copy { videoInput.append(copy) }
                }
                lastFrame = nil
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                micInput?.markAsFinished()
                writer.endSession(atSourceTime: end)
                writer.finishWriting { [self] in
                    if writer.status == .completed { cont.resume() }
                    else { cont.resume(throwing: writer.error ?? CocoaError(.fileWriteUnknown)) }
                }
            }
        }
    }

    /// Many players play only the first audio track, so mix system sound and microphone
    /// into one track. The video is copied without re-encoding.
    private static func mergeAudioTracks(in url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.count > 1, let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { return }

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        ])
        reader.add(videoOut)
        reader.add(audioOut)

        let merged = url.deletingLastPathComponent().appendingPathComponent(".merging-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: merged, fileType: .mp4)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                         sourceFormatHint: try await videoTrack.load(.formatDescriptions).first)
        let audioIn = aacInput(channels: 2, bitRate: 128_000)
        audioIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        writer.add(audioIn)

        guard reader.startReading(), writer.startWriting() else {
            throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for (input, output) in [(videoIn, videoOut as AVAssetReaderOutput), (audioIn, audioOut)] {
                group.enter()
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "MiniRec.merge")) {
                    while input.isReadyForMoreMediaData {
                        guard let buffer = output.copyNextSampleBuffer(), input.append(buffer) else {
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }
            group.notify(queue: .global()) { cont.resume() }
        }
        await writer.finishWriting()
        guard reader.status == .completed, writer.status == .completed else {
            try? FileManager.default.removeItem(at: merged)
            throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: merged)
    }
}
