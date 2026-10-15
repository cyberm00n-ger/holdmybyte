// WP0 stub; WP1 owns this file and implements `live()` with ImageIO, vImage, jpegli, libwebp, libjxl and Metal.
import Foundation

extension EnginePrimitives {
    public static func live() throws -> EnginePrimitives {
        throw PrimitiveError("EnginePrimitives.live() is not implemented yet (WP1); linked codecs: \(codecVersions)")
    }
}
