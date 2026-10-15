import Foundation
import HMBModel
import Testing

@Suite struct WeddingNamingTests {
    static let genericNames = ["export", "exports", "final", "finals", "fertig", "jpg", "jpeg", "jpgs", "selects", "edited",
                               "bearbeitet", "output", "delivery", "lieferung", "web", "highres", "full"]

    @Test func genericListIsExactlyTheSpecList() {
        #expect(WeddingNaming.genericFolderNames == Set(Self.genericNames))
    }

    @Test func usesTheDroppedFolderName() {
        #expect(WeddingNaming.suggestedName(for: [URL(fileURLWithPath: "/Users/s/Weddings/Finn und Lissy")]) == "Finn und Lissy")
    }

    @Test(arguments: genericNames + ["Fertig", "EXPORT", "Jpg", "Selects"])
    func genericNameDefersToParent(name: String) {
        #expect(WeddingNaming.suggestedName(for: [URL(fileURLWithPath: "/Users/s/Weddings/Finn und Lissy/\(name)")]) == "Finn und Lissy")
    }

    @Test func nestedGenericNamesWalkUp() {
        #expect(WeddingNaming.suggestedName(for: [URL(fileURLWithPath: "/Volumes/Wedding SSD/Anna und Ben/Export/JPG")]) == "Anna und Ben")
    }

    @Test func looseFilesUseTheirCommonParent() {
        // The caller passes the common parent of loose files; several folders resolve to their common ancestor.
        let folders = [URL(fileURLWithPath: "/Users/s/Weddings/Mia und Elias/Ceremony"),
                       URL(fileURLWithPath: "/Users/s/Weddings/Mia und Elias/Party")]
        #expect(WeddingNaming.suggestedName(for: folders) == "Mia und Elias")
        let generic = [URL(fileURLWithPath: "/Users/s/Weddings/Mia und Elias/fertig/a"),
                       URL(fileURLWithPath: "/Users/s/Weddings/Mia und Elias/fertig/b")]
        #expect(WeddingNaming.suggestedName(for: generic) == "Mia und Elias")
    }

    @Test func fallbacks() {
        #expect(WeddingNaming.suggestedName(for: []) == "Untitled Wedding")
        #expect(WeddingNaming.suggestedName(for: [URL(fileURLWithPath: "/")]) == "Untitled Wedding")
        #expect(WeddingNaming.suggestedName(for: [URL(fileURLWithPath: "/Volumes/export")]) == "Untitled Wedding")
    }

    @Test(arguments: [
        ("Finn und Lissy", "Finn-und-Lissy"),
        ("  Anna   und\tBen ", "Anna-und-Ben"),
        ("A/B:C\\D", "ABCD"),
        ("Zoë & Jürgen", "Zoë-&-Jürgen"),
        ("", ""),
    ])
    func slug(input: String, expected: String) {
        #expect(WeddingNaming.slug(input) == expected)
    }
}
