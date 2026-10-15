import CHMBCodecs

extension EnginePrimitives {
    /// "libjxl 0.11.2 · jpegli (libjxl 0.11.2) · libwebp 1.6.0", read from the linked libraries (provenance for
    /// bench reports and the About box).
    public static var codecVersions: String { String(cString: hmb_codec_versions()) }
}
