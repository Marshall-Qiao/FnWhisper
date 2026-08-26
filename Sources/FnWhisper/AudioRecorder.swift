import AVFoundation
import Foundation

enum AudioRecorderError: LocalizedError {
    case microphonePermissionDenied
    case invalidInputFormat
    case notRecording
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "没有麦克风权限。请在系统设置的隐私与安全性中允许 FnWhisper 使用麦克风。"
        case .invalidInputFormat:
            return "当前麦克风没有可用的音频输入格式。"
        case .notRecording:
            return "当前没有正在进行的录音。"
        case let .conversionFailed(message):
            return "无法把录音转换成 Whisper 所需格式：\(message)"
        }
    }
}

final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var recordingFile: AVAudioFile?

    static func duration(of audioURL: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: audioURL),
              file.processingFormat.sampleRate > 0
        else {
            return nil
        }
        return Double(file.length) / file.processingFormat.sampleRate
    }
    private var nativeRecordingURL: URL?
    private var recordingError: Error?
    private var hasInstalledTap = false

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    func start() throws {
        if hasInstalledTap {
            _ = try? stop()
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.invalidInputFormat
        }

        let nativeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FnWhisper-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        var fileSettings = inputFormat.settings
        fileSettings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(
            forWriting: nativeURL,
            settings: fileSettings,
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        )

        recordingError = nil
        recordingFile = file
        nativeRecordingURL = nativeURL

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: inputFormat
        ) { [weak self] buffer, _ in
            guard let self, let recordingFile = self.recordingFile else {
                return
            }
            do {
                try recordingFile.write(from: buffer)
            } catch {
                self.recordingError = error
            }
        }
        hasInstalledTap = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
            recordingFile = nil
            nativeRecordingURL = nil
            try? FileManager.default.removeItem(at: nativeURL)
            throw error
        }
    }

    func stop() throws -> URL {
        guard hasInstalledTap, let nativeRecordingURL else {
            throw AudioRecorderError.notRecording
        }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        hasInstalledTap = false
        recordingFile = nil
        self.nativeRecordingURL = nil

        if let recordingError {
            self.recordingError = nil
            try? FileManager.default.removeItem(at: nativeRecordingURL)
            throw recordingError
        }

        let whisperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FnWhisper-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        do {
            try Self.convertToWhisperWAV(
                sourceURL: nativeRecordingURL,
                destinationURL: whisperURL
            )
            try? FileManager.default.removeItem(at: nativeRecordingURL)
            return whisperURL
        } catch {
            try? FileManager.default.removeItem(at: nativeRecordingURL)
            try? FileManager.default.removeItem(at: whisperURL)
            throw error
        }
    }

    static func convertToWhisperWAV(
        sourceURL: URL,
        destinationURL: URL
    ) throws {
        let inputFile = try AVAudioFile(forReading: sourceURL)
        let inputFormat = inputFile.processingFormat
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: destinationURL,
                settings: fileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AudioRecorderError.conversionFailed(
                "创建输出文件失败：\(error.localizedDescription)"
            )
        }
        let outputFormat = outputFile.processingFormat
        guard let converter = AVAudioConverter(
            from: inputFormat,
            to: outputFormat
        ) else {
            throw AudioRecorderError.conversionFailed("无法创建 16 kHz 单声道转换器")
        }
        converter.downmix = true
        let inputFrameCapacity: AVAudioFrameCount = 4_096
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            ceil(Double(inputFrameCapacity) * ratio) + 32
        )
        var reachedEnd = false
        var readError: Error?

        while !reachedEnd {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputFrameCapacity
            ) else {
                throw AudioRecorderError.conversionFailed("无法分配输出缓冲区")
            }

            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { requestedPackets, inputStatus in
                guard !reachedEnd else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                let remainingFrames = inputFile.length - inputFile.framePosition
                guard remainingFrames > 0 else {
                    inputStatus.pointee = .endOfStream
                    reachedEnd = true
                    return nil
                }

                let requestedFrames = min(
                    AVAudioFrameCount(remainingFrames),
                    max(1, AVAudioFrameCount(requestedPackets))
                )
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: requestedFrames
                ) else {
                    inputStatus.pointee = .endOfStream
                    reachedEnd = true
                    return nil
                }

                do {
                    try inputFile.read(into: inputBuffer, frameCount: requestedFrames)
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    reachedEnd = true
                    return nil
                }

                if inputBuffer.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    reachedEnd = true
                    return nil
                }

                inputStatus.pointee = .haveData
                return inputBuffer
            }

            if let readError {
                throw AudioRecorderError.conversionFailed(
                    "读取输入文件失败：\(readError.localizedDescription)"
                )
            }
            if let conversionError {
                throw AudioRecorderError.conversionFailed(
                    conversionError.localizedDescription
                )
            }
            if outputBuffer.frameLength > 0 {
                do {
                    try outputFile.write(from: outputBuffer)
                } catch {
                    throw AudioRecorderError.conversionFailed(
                        "写入输出文件失败：\(error.localizedDescription)"
                    )
                }
            }

            switch status {
            case .endOfStream:
                reachedEnd = true
            case .error:
                throw AudioRecorderError.conversionFailed("AVAudioConverter 返回错误")
            case .haveData, .inputRanDry:
                break
            @unknown default:
                throw AudioRecorderError.conversionFailed("未知转换状态")
            }
        }
    }
}
