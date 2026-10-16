// SSIMULACRA2 on Metal: the engine's metric (Docs/SPEC.md §3.0 E5, Docs/METRIC.md).
//
// A port of jpegos/Sources/SqueezeCore/Metrics/MetalSSIMULACRA2.swift with the same algorithm and constants (it must
// agree with the CPU oracle `SSIMULACRA2` within 0.02), restructured for speed:
// - Reference session (old audit #1): `prepareReference` builds the reference's XYB pyramid once; every candidate
//   reuses it. Unlike the old port nothing else is cached: mu1/sigma11 are recomputed inside the fused tile kernel,
//   where they cost no extra memory traffic, so a 45 MP reference holds 0.73 GB instead of 2.2 GB.
// - Buffer pools per geometry (audit #2): no per-call allocation or zero-fill of the working set.
// - pow(BIAS, 1/3) hoisted to a constant, sRGB linearisation by the oracle's own 256-entry table (audit #3).
// - Two dispatches per scale instead of ~44 (audit #4), a threadgroup-staged vertical blur (audit #6), the error maps
//   fused into the blur and reduced on the GPU to 6 floats per 32×32 tile (audit #5): the CPU sums ~1.1 M partials
//   in double at 45 MP instead of 4.2 M, and no intermediate plane is written besides the candidate's XYB.
// - Candidate pixels are wrapped without a copy when their storage is page-aligned (audit #7); otherwise copied
//   into a pooled buffer in parallel.
// Work is submitted to one command queue and waited for synchronously; concurrent callers are safe (each call takes
// its own pooled working set). WP2's MetricLane serialises the GPU work anyway (§3.9).
import Foundation
import Metal

public final class MetalSSIMULACRA2: PerceptualMetric, @unchecked Sendable {

    /// nil when Metal is unavailable or the shaders do not compile.
    public static let shared: MetalSSIMULACRA2? = try? MetalSSIMULACRA2()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let rgbaPipeline: MTLComputePipelineState
    private let planesPipeline: MTLComputePipelineState
    private let tilePipeline: MTLComputePipelineState
    private let lutBuffer: MTLBuffer
    private let weightsBuffer: MTLBuffer
    private let biasRoot: Float = cbrtf(SSIMULACRA2.opsinBias)
    private let pageSize = Int(getpagesize())

    /// - Parameters:
    ///   - workingSetRetention: pooled per-call working sets kept per geometry (0.72 GB each at 45 MP). One suffices
    ///     behind WP2's single MetricLane; a cold working set costs ~30 ms more per score.
    ///   - referenceRetention: spare reference pyramids kept per geometry after `release` (0.73 GB each at 45 MP);
    ///     reusing one saves ~35 ms per `prepareReference`. 0 trades that time for memory.
    ///   - poolByteLimit: pooled bytes kept over all geometries (least recently used geometries go first). The
    ///     default holds one 45 MP working set and reference (1.45 GB) plus the resized and mosaic geometries of a
    ///     job (~0.35 GB), so the pools stop reallocating across a four-delivery job (D-ENG-10).
    public init(workingSetRetention: Int = 1, referenceRetention: Int = 1, poolByteLimit: Int = 2_000_000_000) throws {
        self.workingSetRetention = max(0, workingSetRetention)
        self.referenceRetention = max(0, referenceRetention)
        self.poolByteLimit = max(0, poolByteLimit)
        guard let device = MTLCreateSystemDefaultDevice() else { throw PrimitiveError("Metal is not available") }
        guard let queue = device.makeCommandQueue() else { throw PrimitiveError("Metal: no command queue") }
        let options = MTLCompileOptions()
        options.mathMode = .safe
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: MetalShaders.source, options: options) } catch {
            throw PrimitiveError("Metal: SSIMULACRA2 shaders do not compile: \(error)")
        }
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw PrimitiveError("Metal: no function \(name)") }
            return try device.makeComputePipelineState(function: function)
        }
        rgbaPipeline = try pipeline("xyb_down_rgba")
        planesPipeline = try pipeline("xyb_down_planes")
        tilePipeline = try pipeline("ssim_tile")
        guard tilePipeline.maxTotalThreadsPerThreadgroup >= MetalShaders.tileWidth * MetalShaders.threadsY,
              tilePipeline.threadExecutionWidth == 32 else {
            throw PrimitiveError("Metal: the tile kernel needs 256-thread threadgroups and 32-wide SIMD groups")
        }
        guard let lut = device.makeBuffer(bytes: SSIMULACRA2.linearTable, length: 256 * 4, options: .storageModeShared),
              let weights = device.makeBuffer(bytes: SSIMULACRA2.blurKernel, length: SSIMULACRA2.blurKernel.count * 4,
                                              options: .storageModeShared) else {
            throw PrimitiveError("Metal: constant buffers")
        }
        self.device = device
        self.queue = queue
        self.lutBuffer = lut
        self.weightsBuffer = weights
    }

    // MARK: - Geometry

    struct Geometry: Hashable {
        let width: Int, height: Int
        var sizes: [(width: Int, height: Int)] { SSIMULACRA2.pyramidSizes(width: width, height: height) }
        /// Pools are keyed orientation-free: a transposed geometry has the same plane sizes at every scale and the
        /// same tile count (square tiles), so landscape and portrait photos share one working set and one reference.
        var poolKey: Geometry { Geometry(width: max(width, height), height: min(width, height)) }
        /// Bytes of one working set (excluding the upload buffer) plus one reference pyramid of this geometry.
        var pooledBytes: Int {
            let sizes = self.sizes
            let count = { (scale: Int) -> Int in scale < sizes.count ? sizes[scale].width * sizes[scale].height : 1 }
            let pyramid = sizes.reduce(0) { $0 + 3 * $1.width * $1.height }
            return 4 * (pyramid + 3 * (count(0) + count(1) + count(2)) + MetalSSIMULACRA2.tileLayout(sizes).total)
        }
    }

    /// Tiles per channel at each scale, and the float offset of each scale's partials.
    static func tileLayout(_ sizes: [(width: Int, height: Int)]) -> (tilesX: [Int], tilesPerChannel: [Int], offsets: [Int], total: Int) {
        var tilesX: [Int] = [], perChannel: [Int] = [], offsets: [Int] = []
        var cursor = 0
        for size in sizes {
            let tx = (size.width + MetalShaders.tileWidth - 1) / MetalShaders.tileWidth
            let ty = (size.height + MetalShaders.tileHeight - 1) / MetalShaders.tileHeight
            tilesX.append(tx); perChannel.append(tx * ty); offsets.append(cursor)
            cursor += 3 * tx * ty * MetalShaders.partialsPerTile
        }
        return (tilesX, perChannel, offsets, cursor)
    }

    // MARK: - Reference

    public final class Reference: MetricReference, @unchecked Sendable {
        public let width: Int, height: Int
        let geometry: Geometry
        let sizes: [(width: Int, height: Int)]
        private let lock = NSLock()
        /// XYB planes (X, Y, B contiguous) per scale; handed back to the pool once released and no score uses them.
        private var xyb: [MTLBuffer]
        private var released = false
        private var scoring = 0

        fileprivate init(geometry: Geometry, xyb: [MTLBuffer]) {
            self.width = geometry.width; self.height = geometry.height
            self.geometry = geometry; self.sizes = geometry.sizes
            self.xyb = xyb
        }
        /// Marks a score in flight and returns the buffers, or nil once released.
        fileprivate func beginUse() -> [MTLBuffer]? {
            lock.withLock {
                guard !released else { return nil }
                scoring += 1
                return xyb
            }
        }
        /// Ends a score; returns the buffers when this was the last user of a released reference.
        fileprivate func endUse() -> [MTLBuffer]? {
            lock.withLock {
                scoring -= 1
                return released && scoring == 0 ? takeLocked() : nil
            }
        }
        /// Marks the reference released; returns the buffers unless a score still uses them (`endUse` returns them).
        fileprivate func markReleased() -> [MTLBuffer]? {
            lock.withLock {
                guard !released else { return nil }
                released = true
                return scoring == 0 ? takeLocked() : nil
            }
        }
        private func takeLocked() -> [MTLBuffer]? {
            guard !xyb.isEmpty else { return nil }
            defer { xyb = [] }
            return xyb
        }
        /// GPU memory held, in bytes (0 once released).
        public var byteCount: Int { lock.withLock { xyb.reduce(0) { $0 + $1.length } } }
    }

    public func prepareReference(_ image: PixelImage) throws -> any MetricReference {
        let geometry = try Self.validate(image)
        let sizes = geometry.sizes
        let xyb = try acquireReferenceStorage(geometry)
        let set = try acquireWorkingSet(geometry)
        defer { recycleWorkingSet(set) }
        let (input, rowBytes) = try upload(image, into: set)
        try run { encoder in
            encodePyramid(encoder, input: input, rowBytes: rowBytes, sizes: sizes, set: set,
                          xybTarget: { xyb[$0] }, afterScale: nil)
        }
        return Reference(geometry: geometry, xyb: xyb)
    }

    public func release(_ reference: any MetricReference) {
        guard let reference = reference as? Reference, let buffers = reference.markReleased() else { return }
        recycleReferenceStorage(buffers, geometry: reference.geometry)
    }

    // MARK: - Scoring

    public func score(_ candidate: PixelImage, against reference: any MetricReference) throws -> Double {
        guard let reference = reference as? Reference else { throw PrimitiveError("SSIMULACRA2: foreign metric reference") }
        guard candidate.width == reference.width, candidate.height == reference.height else {
            throw PrimitiveError("SSIMULACRA2: candidate \(candidate.width)×\(candidate.height) does not match the reference \(reference.width)×\(reference.height)")
        }
        guard let referenceXYB = reference.beginUse() else { throw PrimitiveError("SSIMULACRA2: the reference was released") }
        defer {
            if let buffers = reference.endUse() { recycleReferenceStorage(buffers, geometry: reference.geometry) }
        }
        let geometry = reference.geometry
        let sizes = reference.sizes
        let layout = Self.tileLayout(sizes)
        let set = try Spans.measure("metal.acquire") { try acquireWorkingSet(geometry) }
        defer { recycleWorkingSet(set) }
        let (input, rowBytes) = try Spans.measure("metal.upload") { try upload(candidate, into: set) }

        try Spans.measure("metal.run") { try run { encoder in
            encodePyramid(encoder, input: input, rowBytes: rowBytes, sizes: sizes, set: set,
                          xybTarget: { _ in set.xyb }) { scale in
                self.encodeTiles(encoder, scale: scale, sizes: sizes, layout: layout, reference: referenceXYB, set: set)
            }
        } }
        Spans.gpu(lastGPUSeconds)
        return Spans.measure("metal.combine") { Self.combine(partials: set.partials, sizes: sizes, layout: layout) }
    }

    /// `prepareReference(reference)`, `score(candidate, against:)` and `release` in one command buffer: the reference
    /// pyramid is built into pooled storage and both pyramids and the tile pass run back to back, so a deferred
    /// full-resolution score (MetricLane) waits for the GPU once instead of twice. The same kernels on the same
    /// buffers in the same order: bit-identical to the three calls.
    public func score(_ candidate: PixelImage, againstImage referenceImage: PixelImage) throws -> Double {
        let geometry = try Self.validate(referenceImage)
        guard candidate.width == referenceImage.width, candidate.height == referenceImage.height else {
            throw PrimitiveError("SSIMULACRA2: candidate \(candidate.width)×\(candidate.height) does not match the reference \(referenceImage.width)×\(referenceImage.height)")
        }
        let sizes = geometry.sizes
        let layout = Self.tileLayout(sizes)
        let referenceXYB = try acquireReferenceStorage(geometry)
        defer { recycleReferenceStorage(referenceXYB, geometry: geometry) }
        let set = try acquireWorkingSet(geometry)
        defer { recycleWorkingSet(set) }
        // Both inputs are wrapped (page-aligned) or copied; a copied reference must not share the upload buffer with
        // the candidate, so a reference that cannot be wrapped goes through its own pooled working set first.
        let (referenceInput, referenceRowBytes): (MTLBuffer, Int)
        var referenceSet: WorkingSet?
        if let wrapped = wrap(referenceImage) {
            (referenceInput, referenceRowBytes) = wrapped
        } else {
            let extra = try acquireWorkingSet(geometry)
            referenceSet = extra
            (referenceInput, referenceRowBytes) = try upload(referenceImage, into: extra)
        }
        defer { if let referenceSet { recycleWorkingSet(referenceSet) } }
        let (input, rowBytes) = try upload(candidate, into: set)
        try run { encoder in
            encodePyramid(encoder, input: referenceInput, rowBytes: referenceRowBytes, sizes: sizes, set: set,
                          xybTarget: { referenceXYB[$0] }, afterScale: nil)
            encodePyramid(encoder, input: input, rowBytes: rowBytes, sizes: sizes, set: set,
                          xybTarget: { _ in set.xyb }) { scale in
                self.encodeTiles(encoder, scale: scale, sizes: sizes, layout: layout, reference: referenceXYB, set: set)
            }
        }
        Spans.gpu(lastGPUSeconds)
        return Self.combine(partials: set.partials, sizes: sizes, layout: layout)
    }

    private func encodeTiles(_ encoder: MTLComputeCommandEncoder, scale: Int, sizes: [(width: Int, height: Int)],
                             layout: (tilesX: [Int], tilesPerChannel: [Int], offsets: [Int], total: Int),
                             reference: [MTLBuffer], set: WorkingSet) {
        let size = sizes[scale]
        var params = TileParams(size: SIMD2(UInt32(size.width), UInt32(size.height)),
                                planeStride: UInt32(size.width * size.height),
                                tilesX: UInt32(layout.tilesX[scale]),
                                tilesPerChannel: UInt32(layout.tilesPerChannel[scale]))
        encoder.setComputePipelineState(tilePipeline)
        encoder.setBuffer(reference[scale], offset: 0, index: 0)
        encoder.setBuffer(set.xyb, offset: 0, index: 1)
        encoder.setBuffer(set.partials, offset: layout.offsets[scale] * 4, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<TileParams>.stride, index: 3)
        encoder.setBuffer(weightsBuffer, offset: 0, index: 4)
        let tilesY = layout.tilesPerChannel[scale] / layout.tilesX[scale]
        encoder.dispatchThreadgroups(MTLSize(width: layout.tilesX[scale], height: tilesY, depth: 3),
                                     threadsPerThreadgroup: MTLSize(width: MetalShaders.tileWidth,
                                                                    height: MetalShaders.threadsY, depth: 1))
    }

    /// Sums the per-tile partials in double and applies the oracle's weighting stage.
    static func combine(partials: MTLBuffer, sizes: [(width: Int, height: Int)],
                        layout: (tilesX: [Int], tilesPerChannel: [Int], offsets: [Int], total: Int)) -> Double {
        let floats = partials.contents().bindMemory(to: Float.self, capacity: max(1, layout.total))
        var scales: [SSIMULACRA2.ScaleMeasurements] = []
        for (scale, size) in sizes.enumerated() {
            let perPixel = 1.0 / Double(size.width * size.height)
            var m = SSIMULACRA2.ScaleMeasurements()
            for channel in 0..<3 {
                var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0, s5 = 0.0
                var p = floats + layout.offsets[scale] + channel * layout.tilesPerChannel[scale] * 6
                for _ in 0..<layout.tilesPerChannel[scale] {
                    s0 += Double(p[0]); s1 += Double(p[1]); s2 += Double(p[2])
                    s3 += Double(p[3]); s4 += Double(p[4]); s5 += Double(p[5])
                    p += 6
                }
                let sums = (s0, s1, s2, s3, s4, s5)
                m.ssim[channel * 2] = perPixel * sums.0
                m.ssim[channel * 2 + 1] = (perPixel * sums.1).squareRoot().squareRoot()
                m.edgeDiff[channel * 4] = perPixel * sums.2
                m.edgeDiff[channel * 4 + 1] = (perPixel * sums.3).squareRoot().squareRoot()
                m.edgeDiff[channel * 4 + 2] = perPixel * sums.4
                m.edgeDiff[channel * 4 + 3] = (perPixel * sums.5).squareRoot().squareRoot()
            }
            scales.append(m)
        }
        return SSIMULACRA2.combine(scales)
    }

    // MARK: - Encoding

    struct ScaleParams {
        var size: SIMD2<UInt32>
        var nextSize: SIMD2<UInt32>
        var writeNext: UInt32
        var planeStride: UInt32
        var nextStride: UInt32
        var xybStride: UInt32
        var rowBytes: UInt32
        var biasRoot: Float
    }

    struct TileParams {
        var size: SIMD2<UInt32>
        var planeStride: UInt32
        var tilesX: UInt32
        var tilesPerChannel: UInt32
    }

    /// Linear planes of scale s ≥ 1 live in `linear[s % 2]` (odd scales in the larger buffer).
    private func encodePyramid(_ encoder: MTLComputeCommandEncoder, input: MTLBuffer, rowBytes: Int,
                               sizes: [(width: Int, height: Int)], set: WorkingSet,
                               xybTarget: (Int) -> MTLBuffer, afterScale: ((Int) -> Void)?) {
        for (scale, size) in sizes.enumerated() {
            let hasNext = scale + 1 < sizes.count
            let next = hasNext ? sizes[scale + 1] : (width: 1, height: 1)
            var params = ScaleParams(size: SIMD2(UInt32(size.width), UInt32(size.height)),
                                     nextSize: SIMD2(UInt32(next.width), UInt32(next.height)),
                                     writeNext: hasNext ? 1 : 0,
                                     planeStride: UInt32(size.width * size.height),
                                     nextStride: UInt32(next.width * next.height),
                                     xybStride: UInt32(size.width * size.height),
                                     rowBytes: UInt32(rowBytes), biasRoot: biasRoot)
            if scale == 0 {
                encoder.setComputePipelineState(rgbaPipeline)
                encoder.setBuffer(input, offset: 0, index: 0)
                encoder.setBuffer(lutBuffer, offset: 0, index: 4)
            } else {
                encoder.setComputePipelineState(planesPipeline)
                encoder.setBuffer(set.linear[scale % 2], offset: 0, index: 0)
            }
            encoder.setBuffer(xybTarget(scale), offset: 0, index: 1)
            encoder.setBuffer(set.linear[(scale + 1) % 2], offset: 0, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<ScaleParams>.stride, index: 3)
            let grid = MTLSize(width: (size.width + 1) / 2, height: (size.height + 1) / 2, depth: 1)
            encoder.dispatchThreads(grid, threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
            afterScale?(scale)
        }
    }

    private func run(_ encode: (MTLComputeCommandEncoder) throws -> Void) throws {
        guard let commandBuffer = queue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PrimitiveError("Metal: could not create a command buffer")
        }
        do { try encode(encoder) } catch { encoder.endEncoding(); throw error }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw PrimitiveError("Metal: SSIMULACRA2 command buffer failed: \(commandBuffer.error.map { "\($0)" } ?? "unknown")")
        }
        let gpu = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
        statsLock.withLock { lastGPUSecondsStorage = gpu }
    }

    private let statsLock = NSLock()
    private var lastGPUSecondsStorage: Double = 0
    private var lastUploadWrappedStorage = false
    /// Whether the most recent input was wrapped in place (true) or copied (false); for benchmarks.
    public var lastUploadWasWrapped: Bool { statsLock.withLock { lastUploadWrappedStorage } }
    /// GPU execution time of the most recent command buffer (any caller); for benchmarks and Docs/METRIC.md.
    public var lastGPUSeconds: Double { statsLock.withLock { lastGPUSecondsStorage } }

    // MARK: - Input

    static func validate(_ image: PixelImage) throws -> Geometry {
        guard image.width >= 8, image.height >= 8 else { throw PrimitiveError("SSIMULACRA2: images must be at least 8×8 pixels") }
        guard image.width < 65_536, image.height < 65_536, image.bytesPerRow < Int(UInt32.max) else {
            throw PrimitiveError("SSIMULACRA2: image too large")
        }
        return Geometry(width: image.width, height: image.height)
    }

    /// The image's pixels as a GPU buffer: wrapped in place when page-aligned (no copy), else copied into `set.upload`.
    private func upload(_ image: PixelImage, into set: WorkingSet) throws -> (MTLBuffer, Int) {
        if let wrapped = wrap(image) { return wrapped }
        let length = image.bytesPerRow * image.height
        let base = image.pixels.baseAddress!
        statsLock.withLock { lastUploadWrappedStorage = false }
        let upload = try set.uploadBuffer(device: device, length: length)
        // Addresses travel as integers: raw pointers are not Sendable, and the copy is joined before returning.
        let destination = UInt(bitPattern: upload.contents()), source = UInt(bitPattern: base)
        let rowBytes = image.bytesPerRow, height = image.height
        let chunks = 8
        let rowsPerChunk = (height + chunks - 1) / chunks
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let start = chunk * rowsPerChunk
            let end = min(height, start + rowsPerChunk)
            guard start < end, let to = UnsafeMutableRawPointer(bitPattern: destination + UInt(start * rowBytes)),
                  let from = UnsafeRawPointer(bitPattern: source + UInt(start * rowBytes)) else { return }
            to.copyMemory(from: from, byteCount: (end - start) * rowBytes)
        }
        return (upload, image.bytesPerRow)
    }

    /// The image's pixels wrapped in place as a GPU buffer (no copy) when page-aligned, else nil.
    private func wrap(_ image: PixelImage) -> (MTLBuffer, Int)? {
        let length = image.bytesPerRow * image.height
        let base = image.pixels.baseAddress!
        guard Int(bitPattern: base) % pageSize == 0 else { return nil }
        let rounded = (length + pageSize - 1) / pageSize * pageSize
        guard let wrapped = device.makeBuffer(bytesNoCopy: base, length: rounded, options: .storageModeShared,
                                              deallocator: nil) else { return nil }
        statsLock.withLock { lastUploadWrappedStorage = true }
        return (wrapped, image.bytesPerRow)
    }

    // MARK: - Pools (old audit #2)

    /// Per-call scratch for one geometry: candidate XYB (sized for scale 0, reused per scale), two linear ping-pong
    /// buffers, the partials and (when the input cannot be wrapped) an upload buffer.
    final class WorkingSet: @unchecked Sendable {
        let geometry: Geometry
        let xyb: MTLBuffer
        let linear: [MTLBuffer]
        let partials: MTLBuffer
        private var upload: MTLBuffer?
        init(geometry: Geometry, xyb: MTLBuffer, linear: [MTLBuffer], partials: MTLBuffer) {
            self.geometry = geometry; self.xyb = xyb; self.linear = linear; self.partials = partials
        }
        func uploadBuffer(device: MTLDevice, length: Int) throws -> MTLBuffer {
            if let upload, upload.length >= length { return upload }
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw PrimitiveError("Metal: could not allocate \(length) bytes")
            }
            upload = buffer
            return buffer
        }
    }

    private let poolLock = NSLock()
    private var workingSets: [Geometry: [WorkingSet]] = [:]
    private var referencePool: [Geometry: [[MTLBuffer]]] = [:]
    /// Pool keys (`Geometry.poolKey`), least recently used first.
    private var recentGeometries: [Geometry] = []
    private let workingSetRetention: Int
    static let smallGeometryBytes = 256 << 20
    static let smallWorkingSetRetention = 8
    private let referenceRetention: Int
    private let poolByteLimit: Int
    /// Upper bound on the geometries kept, whatever their size.
    private let geometryRetention = 8

    /// Marks `key` as used now and evicts the least recently used other keys while the geometries kept would hold
    /// more than `poolByteLimit` (counting each key at its full working set + reference).
    private func notePool(_ key: Geometry) {
        recentGeometries.removeAll { $0 == key }
        recentGeometries.append(key)
        func retainedBytes() -> Int { recentGeometries.reduce(0) { $0 + $1.pooledBytes } }
        while recentGeometries.count > 1,
              recentGeometries.count > geometryRetention || retainedBytes() > poolByteLimit {
            let evicted = recentGeometries.removeFirst()
            workingSets[evicted] = nil
            referencePool[evicted] = nil
        }
    }

    private func makePrivate(_ floats: Int) throws -> MTLBuffer {
        guard let buffer = device.makeBuffer(length: max(1, floats) * 4, options: .storageModePrivate) else {
            throw PrimitiveError("Metal: could not allocate \(floats * 4) bytes")
        }
        return buffer
    }

    private func acquireWorkingSet(_ geometry: Geometry) throws -> WorkingSet {
        let pooled: WorkingSet? = poolLock.withLock {
            notePool(geometry.poolKey)
            return workingSets[geometry.poolKey]?.popLast()
        }
        if let pooled { return pooled }
        let sizes = geometry.sizes
        let count = { (scale: Int) -> Int in scale < sizes.count ? sizes[scale].width * sizes[scale].height : 1 }
        let layout = Self.tileLayout(sizes)
        guard let partials = device.makeBuffer(length: max(1, layout.total) * 4, options: .storageModeShared) else {
            throw PrimitiveError("Metal: could not allocate the partials")
        }
        return WorkingSet(geometry: geometry.poolKey, xyb: try makePrivate(3 * count(0)),
                          linear: [try makePrivate(3 * count(2)), try makePrivate(3 * count(1))], partials: partials)
    }

    private func recycleWorkingSet(_ set: WorkingSet) {
        poolLock.withLock {
            var sets = workingSets[set.geometry] ?? []
            // Small geometries (the search mosaic, resized deliveries) are scored concurrently outside the lane's lock
            // (MetricLane), so keep a few of their working sets instead of reallocating them per score.
            let retention = set.geometry.pooledBytes <= Self.smallGeometryBytes
                ? max(workingSetRetention, Self.smallWorkingSetRetention) : workingSetRetention
            if sets.count < retention, recentGeometries.contains(set.geometry) {
                sets.append(set)
                workingSets[set.geometry] = sets
            }
        }
    }

    private func acquireReferenceStorage(_ geometry: Geometry) throws -> [MTLBuffer] {
        let pooled: [MTLBuffer]? = poolLock.withLock {
            notePool(geometry.poolKey)
            return referencePool[geometry.poolKey]?.popLast()
        }
        if let pooled { return pooled }
        return try geometry.sizes.map { try makePrivate(3 * $0.width * $0.height) }
    }

    private func recycleReferenceStorage(_ buffers: [MTLBuffer], geometry: Geometry) {
        let key = geometry.poolKey
        poolLock.withLock {
            var stored = referencePool[key] ?? []
            if stored.count < referenceRetention, recentGeometries.contains(key) {
                stored.append(buffers)
                referencePool[key] = stored
            }
        }
    }

    /// Releases every pooled buffer (live references are unaffected). Call when a job settles.
    public func drainPools() {
        poolLock.withLock {
            workingSets.removeAll()
            referencePool.removeAll()
            recentGeometries.removeAll()
        }
    }
}
