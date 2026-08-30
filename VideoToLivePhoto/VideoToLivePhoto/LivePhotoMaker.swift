import Foundation
import AVFoundation
import Photos
import ImageIO
import UniformTypeIdentifiers
import CoreMedia

struct LivePhotoResources {
    let photoURL: URL
    let pairedVideoURL: URL
}

enum LivePhotoError: LocalizedError {
    case couldNotLoadVideo
    case noVideoTrack
    case imageGenerationFailed
    case imageWriteFailed
    case readerFailed
    case writerFailed(String)
    case metadataFailed
    case photoAccessDenied

    var errorDescription: String? {
        switch self {
        case .couldNotLoadVideo:
            return "Не удалось загрузить выбранное видео."
        case .noVideoTrack:
            return "В выбранном файле нет видеодорожки."
        case .imageGenerationFailed:
            return "Не удалось получить кадр для обложки Live Photo."
        case .imageWriteFailed:
            return "Не удалось создать фотографию с метаданными Live Photo."
        case .readerFailed:
            return "Не удалось прочитать видеодорожку."
        case .writerFailed(let details):
            return "Не удалось создать paired video. \(details)"
        case .metadataFailed:
            return "Не удалось записать метаданные Live Photo."
        case .photoAccessDenied:
            return "Нет разрешения на сохранение в приложение «Фото»."
        }
    }
}

enum LivePhotoMaker {
    static func make(from sourceURL: URL, targetDuration: Double = 3.0) async throws -> LivePhotoResources {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else {
            throw LivePhotoError.couldNotLoadVideo
        }

        let clipDurationSeconds = min(targetDuration, duration.seconds)
        let clipDuration = CMTime(seconds: clipDurationSeconds, preferredTimescale: 600)
        let clipStartSeconds = max(0, (duration.seconds - clipDurationSeconds) / 2.0)
        let clipStart = CMTime(seconds: clipStartSeconds, preferredTimescale: 600)
        let clipRange = CMTimeRange(start: clipStart, duration: clipDuration)
        let stillTime = CMTimeAdd(clipStart, CMTimeMultiplyByFloat64(clipDuration, multiplier: 0.5))

        let identifier = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("livephoto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let photoURL = directory.appendingPathComponent("IMG_\(identifier).jpg")
        let videoURL = directory.appendingPathComponent("IMG_\(identifier).mov")

        try makeKeyPhoto(asset: asset, time: stillTime, identifier: identifier, destination: photoURL)
        try await makePairedVideo(
            asset: asset,
            clipRange: clipRange,
            stillTime: stillTime,
            identifier: identifier,
            destination: videoURL
        )

        return LivePhotoResources(photoURL: photoURL, pairedVideoURL: videoURL)
    }

    static func saveToPhotoLibrary(_ resources: LivePhotoResources) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw LivePhotoError.photoAccessDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()

                let photoOptions = PHAssetResourceCreationOptions()
                photoOptions.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: resources.photoURL, options: photoOptions)

                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.shouldMoveFile = false
                request.addResource(with: .pairedVideo, fileURL: resources.pairedVideoURL, options: videoOptions)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: LivePhotoError.writerFailed("Photos не подтвердил сохранение."))
                }
            }
        }
    }

    private static func makeKeyPhoto(asset: AVAsset, time: CMTime, identifier: String, destination: URL) throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var actualTime = CMTime.zero
        let cgImage: CGImage
        do {
            cgImage = try generator.copyCGImage(at: time, actualTime: &actualTime)
        } catch {
            throw LivePhotoError.imageGenerationFailed
        }

        guard let destinationRef = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw LivePhotoError.imageWriteFailed
        }

        let properties: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: ["17": identifier]
        ]
        CGImageDestinationAddImage(destinationRef, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destinationRef) else {
            throw LivePhotoError.imageWriteFailed
        }
    }

    private static func makePairedVideo(
        asset: AVAsset,
        clipRange: CMTimeRange,
        stillTime: CMTime,
        identifier: String,
        destination: URL
    ) async throws {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw LivePhotoError.noVideoTrack
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        try? FileManager.default.removeItem(at: destination)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        writer.metadata = [contentIdentifierMetadata(identifier)]

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = clipRange

        guard let videoFormat = try await videoTrack.load(.formatDescriptions).first else {
            throw LivePhotoError.readerFailed
        }

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw LivePhotoError.readerFailed }
        reader.add(videoOutput)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw LivePhotoError.writerFailed("Видеокодек исходника нельзя записать в MOV без перекодирования.")
        }
        writer.add(videoInput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack, let audioFormat = try await audioTrack.load(.formatDescriptions).first {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = false

            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audioOutput = output
                audioInput = input
            }
        }

        let metadataAdaptor = try stillImageTimeMetadataAdaptor()
        guard writer.canAdd(metadataAdaptor.assetWriterInput) else {
            throw LivePhotoError.metadataFailed
        }
        writer.add(metadataAdaptor.assetWriterInput)

        guard writer.startWriting() else {
            throw LivePhotoError.writerFailed(writer.error?.localizedDescription ?? "Неизвестная ошибка AVAssetWriter.")
        }
        writer.startSession(atSourceTime: clipRange.start)

        guard reader.startReading() else {
            throw LivePhotoError.readerFailed
        }

        let metadataItem = stillImageTimeMetadataItem()
        let metadataDuration = CMTime(value: 1, timescale: 30)
        let metadataRange = CMTimeRange(start: stillTime, duration: metadataDuration)
        let group = AVTimedMetadataGroup(items: [metadataItem], timeRange: metadataRange)
        guard metadataAdaptor.append(group) else {
            throw LivePhotoError.metadataFailed
        }
        metadataAdaptor.assetWriterInput.markAsFinished()

        try await writeSamples(
            videoOutput: videoOutput,
            videoInput: videoInput,
            audioOutput: audioOutput,
            audioInput: audioInput,
            reader: reader,
            writer: writer
        )
    }

    private static func writeSamples(
        videoOutput: AVAssetReaderTrackOutput,
        videoInput: AVAssetWriterInput,
        audioOutput: AVAssetReaderTrackOutput?,
        audioInput: AVAssetWriterInput?,
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            let lock = NSLock()
            var failure: Error?

            func setFailure(_ error: Error) {
                lock.lock()
                if failure == nil { failure = error }
                lock.unlock()
            }

            group.enter()
            let videoQueue = DispatchQueue(label: "videotolive.video.writer")
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        if !videoInput.append(sample) {
                            setFailure(LivePhotoError.writerFailed(writer.error?.localizedDescription ?? "Ошибка записи видео."))
                            videoInput.markAsFinished()
                            group.leave()
                            return
                        }
                    } else {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            if let audioOutput, let audioInput {
                group.enter()
                let audioQueue = DispatchQueue(label: "videotolive.audio.writer")
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInput.isReadyForMoreMediaData {
                        if let sample = audioOutput.copyNextSampleBuffer() {
                            if !audioInput.append(sample) {
                                setFailure(LivePhotoError.writerFailed(writer.error?.localizedDescription ?? "Ошибка записи звука."))
                                audioInput.markAsFinished()
                                group.leave()
                                return
                            }
                        } else {
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                if let failure {
                    reader.cancelReading()
                    writer.cancelWriting()
                    continuation.resume(throwing: failure)
                    return
                }

                guard reader.status == .completed else {
                    writer.cancelWriting()
                    continuation.resume(throwing: reader.error ?? LivePhotoError.readerFailed)
                    return
                }

                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume(returning: ())
                    } else {
                        continuation.resume(throwing: LivePhotoError.writerFailed(writer.error?.localizedDescription ?? "Неизвестная ошибка завершения записи."))
                    }
                }
            }
        }
    }

    private static func contentIdentifierMetadata(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataContentIdentifier
        item.value = identifier as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    private static func stillImageTimeMetadataAdaptor() throws -> AVAssetWriterInputMetadataAdaptor {
        let specification: [NSString: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as NSString:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as NSString:
                kCMMetadataBaseDataType_SInt8
        ]

        var formatDescription: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let formatDescription else {
            throw LivePhotoError.metadataFailed
        }

        let input = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = false
        return AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
    }

    private static func stillImageTimeMetadataItem() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.still-image-time" as NSString
        item.keySpace = .quickTimeMetadata
        item.value = NSNumber(value: 0)
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        return item
    }
}
