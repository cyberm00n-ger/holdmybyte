// Variant "postpass": the lossless scan rewrite, scripted encodes and minified XMP never change what a reader sees.
import CoreGraphics
import Foundation
@testable import HMBEngine
import HMBFixtures
import HMBModel
import ImageIO
import Testing

@Suite struct PostPassTests {
    let decoder = ImageIODecoder()
    let jpeg = JpegliEncoder()

    func images() throws -> [(String, PixelImage)] {
        var out = Synthetic.Kind.allCases.map { ("\($0)", Synthetic.image($0, width: 517, height: 389)) }
        for url in [TestFixtureFiles.gradientSRGB, TestFixtureFiles.mosaicSource] + LocalData.samplePhotos.prefix(2) {
            out.append((url.lastPathComponent, try decoder.decode(decoder.inspect(url))))
        }
        return out
    }

    @Test func rewriteKeepsPixelsAndMarkersAndNeverGrows() throws {
        let markers = CodecTests.markers(icc: MetadataEditor.srgbICC)
        for (name, image) in try images() {
            for chroma in [ChromaSubsampling.s420, .s444] {
                let data = try jpeg.encode(image, distance: 1.7, subsampling: chroma, markers: markers)
                // The level-2 rewrite reproduces jpegli's own bytes exactly (coefficient read/write + marker copy).
                #expect(try JPEGPostPass.rewrite(data, minK: 0, minRun: 0, componentMask: 0, optimizeScans: false) == data, "\(name) \(chroma)")
                guard let smaller = try JPEGPostPass.optimizeScans(data) else { continue }
                #expect(smaller.count < data.count)
                #expect(ImageCompare.identical(try decoder.decode(encoded: data), try decoder.decode(encoded: smaller)), "\(name) \(chroma)")
                let before = try JPEGContainer.parse(data).segments.filter { (0xE0...0xEF).contains($0.code) || $0.code == 0xFE }
                let after = try JPEGContainer.parse(smaller).segments.filter { (0xE0...0xEF).contains($0.code) || $0.code == 0xFE }
                #expect(before.map(\.code) == after.map(\.code) && before.map(\.payload) == after.map(\.payload), "\(name) \(chroma)")
            }
        }
    }

    @Test func scriptedEncodeHasTheSamePixels() throws {
        for (name, image) in try images().prefix(5) {
            let base = try jpeg.encode(image, distance: 2.3, subsampling: .s420, markers: [])
            let basePixels = try decoder.decode(encoded: base)
            for choice in [JPEGScanChoice(y: 1, cb: 2, cr: 2), JPEGScanChoice(y: 2, cb: 3, cr: 1), JPEGScanChoice(y: 3, cb: 3, cr: 3)] {
                let scripted = try jpeg.encode(image, distance: 2.3, subsampling: .s420, markers: [], scans: choice)
                #expect(ImageCompare.identical(basePixels, try decoder.decode(encoded: scripted)), "\(name) \(choice)")
                // The same script chosen afterwards by the rewrite gives the same bytes as encoding with it.
                #expect(try JPEGPostPass.rewrite(base, minK: 0, minRun: 0, componentMask: 0, optimizeScans: false, force: choice) == scripted)
            }
            #expect(try jpeg.encode(image, distance: 2.3, subsampling: .s420, markers: [], scans: .level2) == base)
            let chosen = try #require(try jpeg.chooseScans(base))
            #expect([chosen.y, chosen.cb, chosen.cr].allSatisfy { (0...3).contains($0) })
        }
    }

    @Test func foreignJPEGsAreLeftAlone() throws {
        // Baseline (sequential) JPEG from ImageIO: not a progressive jpegli output → no rewrite.
        let image = Synthetic.image(.waves)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        let cg = try #require(CGContext(data: image.pixels.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                        bytesPerRow: image.bytesPerRow, space: image.colorSpace,
                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
        CGImageDestinationAddImage(destination, cg, nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(try JPEGPostPass.optimizeScans(data as Data) == nil)
        #expect(try JPEGPostPass.optimizeScans(Data([0xFF, 0xD8, 0xFF])) == nil)
        #expect(try JPEGPostPass.rewrite(data as Data, minK: 10, minRun: 2, componentMask: 7, optimizeScans: true) == nil)
        #expect(try JPEGPostPass.rewrite(Data("not a jpeg".utf8), minK: 10, minRun: 2, componentMask: 7, optimizeScans: true) == nil)
    }

    @Test func zeroingOnlyRemovesCoefficients() throws {
        let image = Synthetic.image(.noise, width: 640, height: 480)
        let data = try jpeg.encode(image, distance: 1.0, subsampling: .s420, markers: CodecTests.markers(icc: nil))
        var previous = data.count
        for k in [40, 20, 10, 5] {                         // lower start → more zeroed → never larger
            let zeroed = try #require(try JPEGPostPass.rewrite(data, minK: k, minRun: 1, componentMask: 7, optimizeScans: true))
            #expect(zeroed.count <= previous, "K \(k)")
            previous = zeroed.count
        }
        #expect(previous < data.count)
    }

    static let prettyXMP = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        crs:Exposure2012="+0.35">
       <dc:creator>
        <rdf:Seq>
         <rdf:li>SEBASTIAN HAAS</rdf:li>
        </rdf:Seq>
       </dc:creator>
       <dc:rights>
        <rdf:Alt>
         <rdf:li xml:lang="x-default">© 2026  two  spaces</rdf:li>
        </rdf:Alt>
       </dc:rights>
       <dc:title> </dc:title>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    \(String(repeating: " ", count: 100))
    \(String(repeating: " ", count: 100))
    <?xpacket end="w"?>
    """

    @Test func minifiedXMPReadsTheSame() throws {
        let xmp = Data(Self.prettyXMP.utf8)
        let small = try #require(XMPMinify.minified(xmp))
        #expect(small.count < xmp.count - 250)
        #expect(XMPMinify.tags(small) == XMPMinify.tags(xmp))
        let text = String(decoding: small, as: UTF8.self)
        #expect(text.contains("© 2026  two  spaces") && text.contains("<dc:title> </dc:title>"))
        #expect(XMPMinify.minified(small) == nil)                         // nothing left to drop
        let literal = Data(Self.prettyXMP.replacingOccurrences(of: "<dc:title> </dc:title>",
                                                               with: "<dc:title rdf:parseType=\"Literal\">\n <b>x</b>\n</dc:title>").utf8)
        #expect(XMPMinify.minified(literal) == nil)
        #expect(XMPLayout.minifiedUnlessKeepAll.minifies(.removeLocation) && !XMPLayout.minifiedUnlessKeepAll.minifies(.keepAll))
    }
}
