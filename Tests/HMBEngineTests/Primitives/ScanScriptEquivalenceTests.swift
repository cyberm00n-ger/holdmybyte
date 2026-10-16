// The search mosaic is encoded with the minimal progressive scan script (`JpegliEncoder.encodeForScoring`) instead of
// level 2. That is only allowed because the candidate's *pixels* — what the metric sees — are the same: jpegli's
// coefficients do not depend on the scan script, and ImageIO's progressive decoder reconstructs the same pixels from
// the same coefficients (Docs/variants/speed.md). This test checks it on real photos at the distances the searches
// use, for the mosaic and (HMB_SCAN_CHECK_FULL=1) the full-resolution image. Needs HMB_HOLDOUT or HMB_TEST_PHOTOS.
import Foundation
@testable import HMBEngine
import HMBModel
import Testing

@Suite(.serialized) struct ScanScriptEquivalenceTests {
    static var photos: [URL] {
        var urls = LocalData.samplePhotos
        if LocalData.env["HMB_SCAN_CHECK_HOLDOUT"] == "1", let holdout = LocalData.holdout { urls += LocalData.jpegs(in: holdout.path) }
        return urls
    }

    @Test(.enabled(if: LocalData.hasSamples))
    func proxyScanScriptDecodesToTheSamePixels() throws {
        let decoder = ImageIODecoder()
        let processing = VImageProcessing()
        let encoder = JpegliEncoder()
        let full = LocalData.env["HMB_SCAN_CHECK_FULL"] == "1"
        var checked = 0
        for url in Self.photos {
            let source = try decoder.decode(try decoder.inspect(url))
            var images: [(String, PixelImage)] = []
            if let mosaic = processing.mosaic(source) { images.append(("mosaic", mosaic)) }
            images.append(("1440", processing.resized(source, longEdge: 1440)))
            if full { images.append(("full", source)) }
            for (label, image) in images {
                for chroma in [ChromaSubsampling.s420, .s444] {
                    for distance in [0.5, 0.77, 1.03, 1.6, 2.0, 2.0846, 2.45, 3.2, 5.0] where full ? label != "full" || [1.6, 2.0846].contains(distance) : true {
                        let delivered = try encoder.encode(image, distance: distance, subsampling: chroma, markers: [])
                        let proxy = try encoder.encodeForScoring(image, distance: distance, subsampling: chroma)
                        let a = try decoder.decode(encoded: delivered), b = try decoder.decode(encoded: proxy)
                        #expect(Measure.identical(a, b), "\(url.lastPathComponent) \(label) d\(distance) \(chroma)")
                        checked += 1
                    }
                }
                print(String(format: "[scan-eq] %@ %@ ok (%d checks so far)", url.lastPathComponent, label, checked))
            }
        }
        print("[scan-eq] \(checked) pairs compared")
    }

    /// The combined engine (eng-v3, Docs/DECISIONS.md D-ENG-11) uses three scripts for one set of coefficients: the
    /// proxy script for the mosaic, level 2, and the post-pass's per-component script chosen from the mosaic — with
    /// the search's tuned tables (full size) and with chroma 0.7 / AQ off (resized). All must decode to the same pixels.
    @Test(.enabled(if: LocalData.hasSamples))
    func tunedTablesDecodeToTheSamePixelsInEveryScript() throws {
        let decoder = ImageIODecoder()
        let processing = VImageProcessing()
        let encoder = JpegliEncoder()
        var checked = 0
        for url in LocalData.samplePhotos {
            let source = try decoder.decode(try decoder.inspect(url))
            var images: [(String, PixelImage, JPEGTuning)] = []
            if let mosaic = processing.mosaic(source) { images.append(("mosaic", mosaic, .fullSize)) }
            images.append(("1440", processing.resized(source, longEdge: 1440), .resized))
            for (label, image, tuning) in images {
                for chroma in [ChromaSubsampling.s420, .s444] {
                    for distance in [0.7, 1.6, 2.45] {
                        let delivered = try encoder.encode(image, distance: distance, subsampling: chroma, tuning: tuning, markers: [])
                        let proxy = try encoder.encodeForScoring(image, distance: distance, subsampling: chroma, tuning: tuning)
                        let choice = try #require(try encoder.chooseScans(proxy))
                        let scripted = try encoder.encode(image, distance: distance, subsampling: chroma, tuning: tuning,
                                                          markers: [], scans: choice)
                        #expect(delivered != proxy)
                        let a = try decoder.decode(encoded: delivered)
                        for (name, other) in [("proxy", proxy), ("scripted \(choice)", scripted)] {
                            #expect(Measure.identical(a, try decoder.decode(encoded: other)),
                                    "\(url.lastPathComponent) \(label) d\(distance) \(chroma) \(name)")
                            checked += 1
                        }
                    }
                }
            }
        }
        print("[scan-eq] tuned: \(checked) pairs compared")
    }
}
