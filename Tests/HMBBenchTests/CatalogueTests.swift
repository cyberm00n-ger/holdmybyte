import Foundation
import Testing

/// The snapshot catalogue must contain exactly the §5.5 ids (§5.5: "It must contain exactly these ids").
/// HMBSnapshot is an executable target, so this compares the two source texts.
@Suite struct CatalogueTests {
    static func specIDs() throws -> [String] {
        let spec = try String(contentsOf: repositoryRoot.appending(path: "Docs/SPEC.md"), encoding: .utf8)
        let start = try #require(spec.range(of: "**State catalogue**"))
        let end = try #require(spec.range(of: "**`hmb` CLI**", range: start.upperBound..<spec.endIndex))
        let block = spec[start.upperBound..<end.lowerBound]
        let lines = block.split(separator: "\n").filter { $0.hasPrefix("- **") }
        return lines.flatMap { line -> [String] in
            let afterColon = line.split(separator: ":", maxSplits: 1).last ?? ""
            return afterColon.split(separator: "`").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        }
    }

    static func catalogueIDs() throws -> [String] {
        let source = try String(contentsOf: repositoryRoot.appending(path: "Sources/HMBSnapshot/StateCatalogue.swift"), encoding: .utf8)
        let regex = try Regex(#"CatalogueEntry\("([a-z0-9-]+)""#)
        return source.matches(of: regex).compactMap { $0.output[1].substring.map(String.init) }
    }

    @Test func catalogueMatchesTheSpecExactly() throws {
        let spec = try Self.specIDs()
        let catalogue = try Self.catalogueIDs()
        #expect(spec.count == 42, "the spec lists \(spec.count) ids")
        #expect(catalogue == spec, "catalogue and §5.5 differ: missing \(Set(spec).subtracting(catalogue).sorted()), extra \(Set(catalogue).subtracting(spec).sorted())")
    }
}
