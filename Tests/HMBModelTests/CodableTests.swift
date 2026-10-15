import CoreGraphics
import Foundation
import HMBModel
import Testing

/// Every Codable shared type survives a JSON round trip unchanged.
@Suite struct CodableRoundTripTests {
    static let date = Date(timeIntervalSince1970: 1_783_850_000.5)
    static let url = URL(fileURLWithPath: "/Users/s/Weddings/Finn und Lissy/fertig/DSC01207.jpg")

    func roundTrip<T: Codable & Equatable>(_ value: T, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        #expect(decoded == value, sourceLocation: sourceLocation)
    }

    static var photo: SourcePhoto {
        SourcePhoto(id: PhotoID(7), url: url, relativePath: "DSC01207.jpg", byteCount: 21_000_000, pixelWidth: 9504,
                    pixelHeight: 6336, captureDate: date, camera: "ILCE-7RM5", kind: .jpeg, modified: date)
    }

    static var request: JobRequest {
        JobRequest(wedding: WeddingID(), name: "Finn und Lissy", photos: [photo], sourceRoots: [url.deletingLastPathComponent()],
                   deliveries: DeliveryPreset.builtIns, outputFolder: URL(fileURLWithPath: "/tmp/out"), naming: .default,
                   processorUse: .gentle, onlyPhotos: [PhotoID(7)], appendToExistingFolder: true)
    }

    static var results: [PhotoResult] {
        [PhotoResult(photo: PhotoID(7), delivery: .couple, status: .done, score: 74.52, target: 74.1, inBytes: 21_000_000,
                     outBytes: 2_500_000, outRelativePath: "Couple/Finn-und-Lissy-0008.jpg", outPixelWidth: 9504,
                     outPixelHeight: 6336, encoder: "jpegli", chroma: .s420, byteExact: nil, probes: 2, seconds: 0.41),
         PhotoResult(photo: PhotoID(7), delivery: .archive, status: .done, inBytes: 21_000_000, outBytes: 16_000_000,
                     encoder: "libjxl", byteExact: true),
         PhotoResult(photo: PhotoID(8), delivery: .website, status: .failed(.encodeFailed), inBytes: 1),
         PhotoResult(photo: PhotoID(9), delivery: .couple, status: .keptOriginal, inBytes: 5, outBytes: 5, encoder: "copy"),
         PhotoResult(photo: PhotoID(10), delivery: .couple, status: .queued, inBytes: 5),
         PhotoResult(photo: PhotoID(11), delivery: .couple, status: .working, inBytes: 5, chroma: .s444)]
    }

    @Test func identifiers() throws {
        try roundTrip(WeddingID())
        try roundTrip(PhotoID(535))
        try roundTrip(DeliveryID.newCustom())
        try roundTrip(DeliveryID.couple)
    }

    @Test func deliveryTypes() throws {
        for preset in DeliveryPreset.builtIns { try roundTrip(preset) }
        try roundTrip(OutputSize.longEdge(2560))
        try roundTrip(OutputSize.full)
        for level in QualityLevel.allCases { try roundTrip(level) }
        for format in OutputFormat.allCases { try roundTrip(format) }
        try roundTrip(ColourHandling.convertToSRGB)
        try roundTrip(MetadataPolicy.removeLocation)
        try roundTrip(ChromaSubsampling.s444)
    }

    @Test func sourceTypes() throws {
        try roundTrip(Self.photo)
        try roundTrip(SourceKind.heic)
        try roundTrip(NoticeSeverity.block)
        let notices: [ScanNotice] = [
            .skippedNonPhotos(count: 3, extensions: ["mov", "xmp"]), .skippedRaw(count: 535), .cmyk(count: 2),
            .alreadyCompressed(count: 12, of: 535), .holdMyByteOutput(count: 4), .convertedToJPEG(count: 1),
            .outputFolderExists(existing: "A – Deliveries", used: "A – Deliveries 2"),
            .notEnoughSpace(volume: "Macintosh HD", needed: 2_000_000_000, available: 1_000_000_000),
            .notWritable(volume: "Wedding SSD"), .outputInsideSource,
        ]
        for notice in notices { try roundTrip(notice) }
        try roundTrip(ScanResult(photos: [Self.photo], sourceRoots: [Self.url.deletingLastPathComponent()],
                                 suggestedName: "Finn und Lissy", weddingDate: Self.date, camera: "ILCE-7RM5",
                                 totalBytes: 21_000_000, rawCount: 2, notices: notices))
    }

    @Test func jobTypes() throws {
        try roundTrip(ProcessorUse.automatic)
        try roundTrip(NamingScheme.default)
        try roundTrip(Self.request)
        try roundTrip(Preflight(outputFolder: URL(fileURLWithPath: "/tmp/out 2"), estimatedBytes: 1_600_000_000,
                                notices: [.outputFolderExists(existing: "out", used: "out 2")]))
        try roundTrip(DeliveryEstimate(bytes: 1_400_000_000, fractionOfSource: 0.128, secondsPerPhoto: 0.46))
        for failure in [PhotoFailure.unreadable, .cmykUnsupported, .encodeFailed, .writeFailed, .sourceMissing, .qualityUnreachable] {
            try roundTrip(failure)
            try roundTrip(PhotoStatus.failed(failure))
        }
        for result in Self.results { try roundTrip(result) }
        let summary = DeliverySummary.make(preset: DeliveryPreset.builtIns[0], photos: [Self.photo], results: Self.results)
        #expect(summary.targetRange != nil)
        try roundTrip(summary)
        let reasons: [PauseReason] = [.user, .sourceUnavailable(volume: "Wedding SSD"),
                                      .diskFull(volume: "Macintosh HD", neededBytes: 600_000_000), .outputNotWritable(path: "/x")]
        for reason in reasons { try roundTrip(reason); try roundTrip(JobPhase.paused(reason)) }
        let phases: [JobPhase] = [.queued(position: 2), .running, .stopped, .interrupted, .finished, .failed(reason: "gone")]
        for phase in phases { try roundTrip(phase) }
        try roundTrip(UnfinishedJob(request: Self.request, results: Self.results))
    }

    @Test func recordAndSettings() throws {
        let record = WeddingRecord(
            id: WeddingID(), name: "Finn und Lissy", createdAt: Self.date, weddingDate: Self.date, camera: "ILCE-7RM5",
            sourceRoots: [Self.url.deletingLastPathComponent()], sourceBookmarks: [Data([1, 2, 3])], photos: [Self.photo],
            deliveries: DeliveryPreset.builtIns, deliveryCompletedAt: ["couple": Self.date],
            outputFolder: URL(fileURLWithPath: "/tmp/out"), outputBookmark: Data([4]), naming: .default,
            phase: .paused(.sourceUnavailable(volume: "Wedding SSD")), results: Self.results, startedAt: Self.date,
            finishedAt: nil, activeSeconds: 12.5, viewed: false)
        try roundTrip(record)
        var settings = AppSettings()
        try roundTrip(settings)
        settings.saveLocation = .folder(URL(fileURLWithPath: "/Users/s/Deliveries"))
        settings.folderNamePattern = "{year} {wedding}"
        settings.naming = NamingScheme(renameByCaptureTime: false, pattern: "{number}")
        settings.notifyWhenFinished = false
        settings.playSound = true
        settings.menuBarWhileClosed = false
        settings.processorUse = .gentle
        settings.detailedLogs = true
        try roundTrip(settings)
        try roundTrip(SaveLocation.nextToOriginals)
    }

    @Test func settingsDefaults() {
        let s = AppSettings()
        #expect(s.saveLocation == .nextToOriginals)
        #expect(s.folderNamePattern == "{wedding} – Deliveries")
        #expect(s.naming == NamingScheme(renameByCaptureTime: true, pattern: "{wedding}-{number}"))
        #expect(s.notifyWhenFinished && !s.playSound && s.menuBarWhileClosed && !s.detailedLogs)
        #expect(s.processorUse == .automatic)
    }

    @Test func sendableImageIdentity() {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let a = context.makeImage()!, b = context.makeImage()!
        #expect(SendableImage(a) == SendableImage(a))
        #expect(SendableImage(a) != SendableImage(b))
        let pair = ComparePair(original: nil, delivered: SendableImage(a), originalBytes: 10, deliveredBytes: 2,
                               comparedAtLongEdge: 2560, unavailableVolume: "Wedding SSD")
        #expect(pair.original == nil && pair.unavailableVolume == "Wedding SSD")
    }
}
