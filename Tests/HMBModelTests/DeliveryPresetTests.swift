import Foundation
@testable import HMBModel
import Testing

func custom(format: OutputFormat = .jpeg, size: OutputSize = .full, quality: QualityLevel = .high,
            colour: ColourHandling = .keepProfile, metadata: MetadataPolicy = .keepAll,
            name: String = "Album", folder: String = "Album") -> DeliveryPreset {
    DeliveryPreset(id: DeliveryID(rawValue: "custom-test"), name: name, symbol: "book", format: format, size: size,
                   quality: quality, colour: colour, metadata: metadata, folderName: folder)
}

let jxlMessage = "JPEG XL deliveries are lossless, full size and keep everything."
let balancedMessage = "Balanced is available for full-size JPEG only."
let edgeMessage = "Long edge must be between 400 and 12000 px."
let nameMessage = "Enter a name and a folder name."

@Suite struct DeliveryPresetTests {
    @Test func builtInsAreValid() {
        for preset in DeliveryPreset.builtIns { #expect(preset.validationError == nil, "\(preset.name)") }
        #expect(DeliveryPreset.builtIns.map(\.id) == [.couple, .website, .social, .archive])
        #expect(DeliveryPreset.defaultOnIDs == [.couple, .website])
        #expect(DeliveryPreset.builtIns.allSatisfy { $0.isBuiltIn })
    }

    @Test(arguments: [
        // JPEG XL ⇔ lossless, and then full size, keep profile, keep all
        (custom(format: .jxlLossless, quality: .high), jxlMessage),
        (custom(format: .jpeg, quality: .lossless), jxlMessage),
        (custom(format: .webp, quality: .lossless), jxlMessage),
        (custom(format: .jxlLossless, size: .longEdge(2000), quality: .lossless), jxlMessage),
        (custom(format: .jxlLossless, quality: .lossless, colour: .convertToSRGB), jxlMessage),
        (custom(format: .jxlLossless, quality: .lossless, metadata: .removeLocation), jxlMessage),
        (custom(format: .jxlLossless, quality: .lossless, metadata: .removeAll), jxlMessage),
        // Balanced ⇒ full-size JPEG
        (custom(format: .webp, quality: .balanced), balancedMessage),
        (custom(format: .jpeg, size: .longEdge(2560), quality: .balanced), balancedMessage),
        // long edge range
        (custom(size: .longEdge(399)), edgeMessage),
        (custom(size: .longEdge(12001)), edgeMessage),
        (custom(size: .longEdge(0)), edgeMessage),
        // names
        (custom(name: "   "), nameMessage),
        (custom(folder: ""), nameMessage),
        (custom(folder: " \n "), nameMessage),
        (custom(folder: "Web/Large"), nameMessage),
        (custom(folder: "Web:Large"), nameMessage),
    ] as [(DeliveryPreset, String)])
    func validationRules(preset: DeliveryPreset, message: String) {
        #expect(preset.validationError == message)
    }

    @Test(arguments: [
        custom(), custom(size: .longEdge(400)), custom(size: .longEdge(12000)),
        custom(format: .jpeg, quality: .balanced), custom(format: .webp, size: .longEdge(2048), quality: .web),
        custom(format: .jxlLossless, quality: .lossless), custom(folder: "Album – Print (2026)"),
    ])
    func validPresets(preset: DeliveryPreset) {
        #expect(preset.validationError == nil)
    }

    @Test func ruleOrderReportsTheFirstViolation() {
        // JPEG XL with a long edge and an empty name: the JPEG XL rule comes first.
        #expect(custom(format: .jxlLossless, size: .longEdge(100), quality: .lossless, name: "").validationError == jxlMessage)
        // Balanced WebP with a bad long edge: the Balanced rule comes before the long-edge rule.
        #expect(custom(format: .webp, size: .longEdge(100), quality: .balanced).validationError == balancedMessage)
    }

    @Test func builtInSpecLines() {
        let lines = DeliveryPreset.builtIns.map(\.specLine)
        #expect(lines == ["Full size · JPEG · Balanced", "2560 px · WebP · location removed",
                          "1440 px · JPEG · sRGB", "Lossless · JPEG XL · byte-exact"])
    }

    @Test func customSpecLines() {
        #expect(custom().specLine == "Full size · JPEG · High")
        #expect(custom(quality: .highest, colour: .convertToSRGB).specLine == "Full size · JPEG · Highest · sRGB")
        #expect(custom(format: .webp, size: .longEdge(2048), quality: .web, colour: .convertToSRGB, metadata: .removeLocation).specLine
                == "2048 px · WebP · Web · sRGB · location removed")
        #expect(custom(size: .longEdge(1080), metadata: .removeAll).specLine == "1080 px · JPEG · High · metadata removed")
        #expect(custom(size: .longEdge(12000)).specLine == "12000 px · JPEG · High")
        #expect(custom(format: .jxlLossless, quality: .lossless).specLine == "Lossless · JPEG XL · byte-exact")
    }

    @Test func editedBuiltInDescribesItself() {
        var website = DeliveryPreset.builtIns[1]
        website.size = .longEdge(2048)
        #expect(website.specLine == "2048 px · WebP · Web · sRGB · location removed")
        var couple = DeliveryPreset.builtIns[0]
        couple.name = "Album"            // renaming does not change what it produces
        #expect(couple.specLine == "Full size · JPEG · Balanced")
    }

    @Test func derivedProperties() {
        #expect(DeliveryPreset.builtIns.map(\.isFullSize) == [true, false, false, true])
        #expect(DeliveryPreset.builtIns.map(\.isLossy) == [true, true, true, false])
        #expect(OutputSize.longEdge(2560).longEdge == 2560)
        #expect(OutputSize.full.longEdge == nil)
        #expect(OutputFormat.allCases.map(\.fileExtension) == ["jpg", "webp", "jxl"])
        #expect(OutputFormat.allCases.map(\.displayName) == ["JPEG", "WebP", "JPEG XL"])
        #expect(QualityLevel.allCases.map(\.floor) == [90, 85, nil, 70, nil])
        #expect(QualityLevel.allCases.map(\.displayName) == ["Highest", "High", "Balanced", "Web", "Lossless"])
        #expect(QualityLevel.high.levelDescription.hasPrefix("Indistinguishable from the original"))
        #expect(ChromaSubsampling.s420.rawValue == "4:2:0")
        #expect(PhotoFailure.allRetryable == [.encodeFailed, .writeFailed, .sourceMissing])
    }

    @Test func customIDsAreUnique() {
        let a = DeliveryID.newCustom(), b = DeliveryID.newCustom()
        #expect(a != b)
        #expect(a.rawValue.hasPrefix("custom-"))
        #expect(a.rawValue == a.rawValue.lowercased())
    }
}

extension PhotoFailure {
    static var allRetryable: [PhotoFailure] {
        [.unreadable, .cmykUnsupported, .encodeFailed, .writeFailed, .sourceMissing, .qualityUnreachable].filter(\.isRetryable)
    }
}
