// Metal kernels of the SSIMULACRA2 port (Docs/METRIC.md). Swift string, compiled once at runtime (§4.1: SwiftPM does
// not compile .metal files). Safe math mode; every constant is the CPU oracle's (`SSIMULACRA2.swift`).
//
// Per scale, two dispatches:
//   1. `xyb_down_rgba` / `xyb_down_planes`: one thread per pixel of the NEXT scale. It linearises (8-bit input via
//      the oracle's 256-entry table) or reads the 2×2 linear source pixels, writes their XYB values at this scale and
//      the box-filtered linear value at the next scale (clamped like the oracle: odd sizes reuse the last row/column).
//   2. `ssim_tile`: one threadgroup per 32×32 output tile and channel. Phase 1 stages the horizontal 13-tap blur of
//      a, b, a², b², a·b for the 44 rows the tile's vertical blur needs in threadgroup memory (rows clamped = edge
//      extension); phase 2 finishes the vertical blur, evaluates the SSIM error and the two edge maps, and reduces
//      their 1- and 4-power sums to 6 floats per tile. The CPU sums those partials in double.
// Nothing reference-side is blurred ahead of time: the reference only keeps its XYB pyramid (0.73 GB at 45 MP
// instead of 2.2 GB for XYB + mu + sigma), because a·a and a are free once a·b is being staged anyway.
enum MetalShaders {
    static let tileWidth = 32
    static let tileHeight = 32
    static let threadsY = 8
    /// Floats written per tile: Σd, Σd⁴, Σartifact, Σartifact⁴, Σdetail, Σdetail⁴.
    static let partialsPerTile = 6

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant float C2 = 0.0009f;
    constant float M00 = 0.30f;
    constant float M01 = 0.622f;
    constant float M02 = 0.078f;
    constant float M10 = 0.23f;
    constant float M11 = 0.692f;
    constant float M12 = 0.078f;
    constant float M20 = 0.24342268924547819f;
    constant float M21 = 0.20476744424496821f;
    constant float M22 = 0.5518098702595336f;
    constant float BIAS = 0.0037930732552754493f;

    constant int RADIUS = 6;
    constant uint TILE_W = \(tileWidth);
    constant uint TILE_H = \(tileHeight);
    constant uint THREADS_Y = \(threadsY);
    constant uint STAGED_ROWS = TILE_H + 2 * RADIUS;

    struct ScaleParams {
        uint2 size;        // this scale
        uint2 nextSize;    // the next scale (ignored when writeNext == 0)
        uint writeNext;    // 1: also write the downsampled linear planes
        uint planeStride;  // elements between the R, G and B planes of the linear input (planes kernel)
        uint nextStride;   // elements between the planes of the linear output
        uint xybStride;    // elements between the X, Y and B planes of the XYB output
        uint rowBytes;     // RGBA input row stride in bytes (rgba kernel)
        float biasRoot;    // cbrt(BIAS), hoisted (old audit #3)
    };

    static inline void write_xyb(float r, float g, float b, device float *xyb, uint index, uint stride, float biasRoot) {
        float m0 = fmax(M00 * r + M01 * g + M02 * b + BIAS, 0.0f);
        float m1 = fmax(M10 * r + M11 * g + M12 * b + BIAS, 0.0f);
        float m2 = fmax(M20 * r + M21 * g + M22 * b + BIAS, 0.0f);
        m0 = pow(m0, 1.0f / 3.0f) - biasRoot;
        m1 = pow(m1, 1.0f / 3.0f) - biasRoot;
        m2 = pow(m2, 1.0f / 3.0f) - biasRoot;
        float x = 0.5f * (m0 - m1);
        float y = 0.5f * (m0 + m1);
        xyb[index] = x * 14.0f + 0.42f;
        xyb[stride + index] = y + 0.01f;
        xyb[2 * stride + index] = (m2 - y) + 0.55f;   // B from the pre-offset Y
    }

    kernel void xyb_down_rgba(
        device const uchar *rgba        [[buffer(0)]],
        device float *xyb               [[buffer(1)]],
        device float *next              [[buffer(2)]],
        constant ScaleParams &p         [[buffer(3)]],
        constant float *lut             [[buffer(4)]],
        uint2 o [[thread_position_in_grid]])
    {
        uint2 grid = uint2((p.size.x + 1) / 2, (p.size.y + 1) / 2);
        if (o.x >= grid.x || o.y >= grid.y) return;
        float sr = 0.0f, sg = 0.0f, sb = 0.0f;
        for (uint dy = 0; dy < 2; dy++) {
            uint sy = 2 * o.y + dy;
            uint y = min(sy, p.size.y - 1);
            for (uint dx = 0; dx < 2; dx++) {
                uint sx = 2 * o.x + dx;
                uint x = min(sx, p.size.x - 1);
                device const uchar *px = rgba + y * p.rowBytes + x * 4;
                float r = lut[px[0]], g = lut[px[1]], b = lut[px[2]];
                if (sx < p.size.x && sy < p.size.y) write_xyb(r, g, b, xyb, y * p.size.x + x, p.xybStride, p.biasRoot);
                sr += r; sg += g; sb += b;
            }
        }
        if (p.writeNext != 0) {
            uint n = o.y * p.nextSize.x + o.x;
            next[n] = sr * 0.25f;
            next[p.nextStride + n] = sg * 0.25f;
            next[2 * p.nextStride + n] = sb * 0.25f;
        }
    }

    kernel void xyb_down_planes(
        device const float *lin         [[buffer(0)]],
        device float *xyb               [[buffer(1)]],
        device float *next              [[buffer(2)]],
        constant ScaleParams &p         [[buffer(3)]],
        uint2 o [[thread_position_in_grid]])
    {
        uint2 grid = uint2((p.size.x + 1) / 2, (p.size.y + 1) / 2);
        if (o.x >= grid.x || o.y >= grid.y) return;
        float sr = 0.0f, sg = 0.0f, sb = 0.0f;
        for (uint dy = 0; dy < 2; dy++) {
            uint sy = 2 * o.y + dy;
            uint y = min(sy, p.size.y - 1);
            for (uint dx = 0; dx < 2; dx++) {
                uint sx = 2 * o.x + dx;
                uint x = min(sx, p.size.x - 1);
                uint i = y * p.size.x + x;
                float r = lin[i], g = lin[p.planeStride + i], b = lin[2 * p.planeStride + i];
                if (sx < p.size.x && sy < p.size.y) write_xyb(r, g, b, xyb, i, p.xybStride, p.biasRoot);
                sr += r; sg += g; sb += b;
            }
        }
        if (p.writeNext != 0) {
            uint n = o.y * p.nextSize.x + o.x;
            next[n] = sr * 0.25f;
            next[p.nextStride + n] = sg * 0.25f;
            next[2 * p.nextStride + n] = sb * 0.25f;
        }
    }

    struct TileParams {
        uint2 size;
        uint planeStride;     // elements between channel planes of both XYB inputs
        uint tilesX;
        uint tilesPerChannel;
    };

    kernel void ssim_tile(
        device const float *ref         [[buffer(0)]],   // reference XYB at this scale (3 planes)
        device const float *dist        [[buffer(1)]],   // candidate XYB at this scale (3 planes)
        device float *partials          [[buffer(2)]],
        constant TileParams &p          [[buffer(3)]],
        constant float *w               [[buffer(4)]],   // 13 taps
        uint3 tg  [[threadgroup_position_in_grid]],
        uint3 lid [[thread_position_in_threadgroup]],
        uint sid  [[simdgroup_index_in_threadgroup]],
        uint lane [[thread_index_in_simdgroup]])
    {
        threadgroup float hA[STAGED_ROWS][TILE_W];
        threadgroup float hB[STAGED_ROWS][TILE_W];
        threadgroup float hAA[STAGED_ROWS][TILE_W];
        threadgroup float hBB[STAGED_ROWS][TILE_W];
        threadgroup float hAB[STAGED_ROWS][TILE_W];
        threadgroup float reduce[THREADS_Y][6];

        const uint channel = tg.z;
        const int W = int(p.size.x), H = int(p.size.y);
        device const float *a = ref + channel * p.planeStride;
        device const float *b = dist + channel * p.planeStride;
        const int x = int(tg.x * TILE_W + lid.x);
        const int y0 = int(tg.y * TILE_H);

        // Phase 1: horizontal blur of the five quantities for the staged rows (edge-extended in x and y).
        if (x < W) {
            for (uint r = lid.y; r < STAGED_ROWS; r += THREADS_Y) {
                int row = clamp(y0 - RADIUS + int(r), 0, H - 1);
                device const float *ra = a + row * W;
                device const float *rb = b + row * W;
                float sa = 0.0f, sb = 0.0f, saa = 0.0f, sbb = 0.0f, sab = 0.0f;
                for (int k = -RADIUS; k <= RADIUS; k++) {
                    int xx = clamp(x + k, 0, W - 1);
                    float va = ra[xx], vb = rb[xx], wk = w[k + RADIUS];
                    sa += va * wk;
                    sb += vb * wk;
                    saa += (va * va) * wk;
                    sbb += (vb * vb) * wk;
                    sab += (va * vb) * wk;
                }
                hA[r][lid.x] = sa; hB[r][lid.x] = sb; hAA[r][lid.x] = saa; hBB[r][lid.x] = sbb; hAB[r][lid.x] = sab;
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        // Phase 2: vertical blur, error maps, per-thread sums.
        float d1 = 0.0f, d4 = 0.0f, a1 = 0.0f, a4 = 0.0f, l1 = 0.0f, l4 = 0.0f;
        if (x < W) {
            for (uint oy = lid.y; oy < TILE_H; oy += THREADS_Y) {
                int y = y0 + int(oy);
                if (y >= H) break;
                float mu1 = 0.0f, mu2 = 0.0f, s11 = 0.0f, s22 = 0.0f, s12 = 0.0f;
                for (int k = 0; k <= 2 * RADIUS; k++) {
                    float wk = w[k];
                    uint r = oy + uint(k);
                    mu1 += hA[r][lid.x] * wk;
                    mu2 += hB[r][lid.x] * wk;
                    s11 += hAA[r][lid.x] * wk;
                    s22 += hBB[r][lid.x] * wk;
                    s12 += hAB[r][lid.x] * wk;
                }
                float numM = 1.0f - (mu1 - mu2) * (mu1 - mu2);
                float numS = 2.0f * (s12 - mu1 * mu2) + C2;
                float den = (s11 - mu1 * mu1) + (s22 - mu2 * mu2) + C2;
                float d = fmax(1.0f - numM * numS / den, 0.0f);
                float dd = d * d;
                d1 += d; d4 += dd * dd;

                float i1 = a[y * W + x], i2 = b[y * W + x];
                float ratio = (1.0f + fabs(i2 - mu2)) / (1.0f + fabs(i1 - mu1)) - 1.0f;
                float art = fmax(ratio, 0.0f), det = fmax(-ratio, 0.0f);
                float aa = art * art, ll = det * det;
                a1 += art; a4 += aa * aa;
                l1 += det; l4 += ll * ll;
            }
        }
        d1 = simd_sum(d1); d4 = simd_sum(d4); a1 = simd_sum(a1);
        a4 = simd_sum(a4); l1 = simd_sum(l1); l4 = simd_sum(l4);
        if (lane == 0) {
            reduce[sid][0] = d1; reduce[sid][1] = d4; reduce[sid][2] = a1;
            reduce[sid][3] = a4; reduce[sid][4] = l1; reduce[sid][5] = l4;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (lid.x < 6 && lid.y == 0) {
            float s = 0.0f;
            for (uint g = 0; g < THREADS_Y; g++) s += reduce[g][lid.x];
            uint tile = tg.y * p.tilesX + tg.x;
            partials[(channel * p.tilesPerChannel + tile) * 6 + lid.x] = s;
        }
    }
    """
}
