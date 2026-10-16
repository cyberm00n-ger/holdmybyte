// `JPEGEncoding` via the in-process jpegli encoder (`hmb_jpegli_encode`): progressive level 2, adaptive
// quantisation on, optimised Huffman tables; the output carries exactly the given APPn/COM markers, in order.
import CHMBCodecs
import Foundation
import HMBModel

public struct JpegliEncoder: TunableJPEGEncoding {
    /// Progressive level of every delivered and probed JPEG (§3.0 E3). Exposed for the equivalence test.
    public var progressiveLevel: Int32 = 2

    public init() {}

    public func encode(_ image: PixelImage, distance: Double, subsampling: ChromaSubsampling,
                       markers: [JPEGMarker]) throws -> Data {
        try encode(image, knobs: JPEGKnobs(distance: distance, sampling: subsampling == .s444 ? .s444 : .s420),
                   markers: markers)
    }

    /// Level 2's coefficients in the minimal progressive scan script (`HMB_JPEGLI_SCAN_PROXY`: 4 scans instead of
    /// 15): about half the tokenisation and a faster ImageIO decode, and ImageIO's progressive decoder produces the
    /// same pixels from the same coefficients whatever the scan script (`ScanScriptEquivalenceTests`). Used for the
    /// search mosaic, whose bytes are never delivered; only its score matters.
    public func encodeForScoring(_ image: PixelImage, distance: Double, subsampling: ChromaSubsampling) throws -> Data {
        var knobs = JPEGKnobs(distance: distance, sampling: subsampling == .s444 ? .s444 : .s420)
        knobs.scoringOnly = true
        return try encode(image, knobs: knobs, markers: [])
    }

    /// The extended encoder (`hmb_jpegli_encode_opts`): separate chroma distance, 4:2:2, adaptive quantisation off,
    /// the proxy scan script for scoring-only candidates. `JPEGKnobs(distance:sampling:)` with the defaults is
    /// byte-identical to `encode(_:distance:subsampling:markers:)`.
    public func encode(_ image: PixelImage, knobs: JPEGKnobs, markers: [JPEGMarker]) throws -> Data {
        let distance = knobs.distance
        guard distance.isFinite, (0...25).contains(distance) else { throw PrimitiveError("jpegli: invalid distance \(distance)") }
        let chroma = knobs.chromaDistance
        guard chroma.isFinite, (0...25).contains(chroma) else { throw PrimitiveError("jpegli: invalid chroma distance \(chroma)") }
        var options = hmb_jpegli_options(distance: Float(distance), chroma_distance: Float(chroma),
                                         sampling: knobs.sampling.code, adaptive_quantization: knobs.adaptiveQuantization ? 1 : 0,
                                         progressive_level: knobs.scoringOnly && progressiveLevel == 2 ? HMB_JPEGLI_SCAN_PROXY : progressiveLevel,
                                         luma_tilt: Float(knobs.lumaTilt),
                                         chroma_tilt: Float(knobs.chromaTilt), dc_ratio: Float(knobs.dcRatio))
        // All payloads in one contiguous array, so a single pointer stays valid for the whole C call.
        var storage = [UInt8]()
        storage.reserveCapacity(markers.reduce(0) { $0 + $1.payload.count })
        var ranges: [(offset: Int, count: Int)] = []
        for marker in markers {
            ranges.append((storage.count, marker.payload.count))
            storage.append(contentsOf: marker.payload)
        }
        return try storage.withUnsafeBufferPointer { all in
            let cMarkers = zip(markers, ranges).map { marker, range in
                hmb_marker(code: marker.code,
                           payload: hmb_bytes(data: range.count > 0 ? all.baseAddress! + range.offset : nil, size: range.count))
            }
            return try cMarkers.withUnsafeBufferPointer { cMarkers in
                try CodecBridge.call("jpegli encode") { out, err, errLen in
                    hmb_jpegli_encode_opts(image.bytes, UInt32(image.width), UInt32(image.height), image.bytesPerRow,
                                           &options, cMarkers.baseAddress, cMarkers.count, out, err, errLen)
                }
            }
        }
    }
}

/// jpegli settings beyond the frozen `JPEGEncoding` call. Every combination is a standard (baseline-decodable,
/// progressive) JPEG; only the quantisation tables and the sampling factors change.
public struct JPEGKnobs: Sendable, Hashable {
    public enum Sampling: String, Sendable, Hashable {
        case s420 = "4:2:0", s422 = "4:2:2", s444 = "4:4:4"
        var code: Int32 { switch self { case .s420: 0; case .s444: 1; case .s422: 2 } }
    }
    public var distance: Double
    /// Distance of the Cb/Cr tables; equal to `distance` by default.
    public var chromaDistance: Double
    public var sampling: Sampling
    public var adaptiveQuantization: Bool
    /// High-frequency tilt of the luma / chroma tables (AC at row + col ≥ 4 × exp(tilt·(f − 3)/11)); 0 = jpegli's tables.
    public var lumaTilt = 0.0
    public var chromaTilt = 0.0
    /// DC entries of all tables taken at distance × this (luma and chroma alike); 1 = jpegli's tables.
    public var dcRatio = 1.0
    /// A candidate that is only scored, never delivered: level 2's coefficients in the minimal scan script
    /// (`HMB_JPEGLI_SCAN_PROXY`). Changes bytes, never the decoded pixels.
    public var scoringOnly = false

    public init(distance: Double, chromaDistance: Double? = nil, sampling: Sampling = .s420, adaptiveQuantization: Bool = true) {
        self.distance = distance
        self.chromaDistance = chromaDistance ?? distance
        self.sampling = sampling
        self.adaptiveQuantization = adaptiveQuantization
    }
}

/// A JPEG encoder that takes `JPEGKnobs` (jpegli). The frozen `JPEGEncoding` call is the knob-free special case.
public protocol TunableJPEGEncoding: JPEGEncoding {
    func encode(_ image: PixelImage, knobs: JPEGKnobs, markers: [JPEGMarker]) throws -> Data
}

extension JPEGEncoding {
    /// Encodes with the search's table tuning (Docs/ENGINE.md §3.5). The identity tuning, and any encoder that takes no
    /// knobs (the fakes), use the frozen call, so their bytes are unchanged.
    public func encode(_ image: PixelImage, distance: Double, subsampling: ChromaSubsampling, tuning: JPEGTuning,
                       markers: [JPEGMarker]) throws -> Data {
        if !tuning.isIdentity, let tunable = self as? any TunableJPEGEncoding {
            return try tunable.encode(image, knobs: tuning.knobs(distance: distance, subsampling: subsampling), markers: markers)
        }
        return try encode(image, distance: distance, subsampling: subsampling, markers: markers)
    }

    /// `encodeForScoring` with the search's table tuning: the tuned coefficients in the proxy scan script.
    public func encodeForScoring(_ image: PixelImage, distance: Double, subsampling: ChromaSubsampling,
                                 tuning: JPEGTuning) throws -> Data {
        if !tuning.isIdentity, let tunable = self as? any TunableJPEGEncoding {
            var knobs = tuning.knobs(distance: distance, subsampling: subsampling)
            knobs.scoringOnly = true
            return try tunable.encode(image, knobs: knobs, markers: [])
        }
        return try encodeForScoring(image, distance: distance, subsampling: subsampling)
    }
}
