// WP4 acceptance 4 (Docs/SPEC.md §5.4): every validation rule disables Save with the exact message; Restore Default
// restores the built-in exactly; the Settings intents persist through the stores.
import Foundation
import HMBFixtures
import HMBModel
@testable import HMBUI
import Testing

@Suite struct EditDeliveryFormTests {
    static let jxlMessage = "JPEG XL deliveries are lossless, full size and keep everything."
    static let balancedMessage = "Balanced is available for full-size JPEG only."
    static let edgeMessage = "Long edge must be between 400 and 12000 px."
    static let nameMessage = "Enter a name and a folder name."

    static func expectInvalid(_ form: EditDeliveryForm, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(form.validationError == message, sourceLocation: sourceLocation)
        #expect(!form.canSave, sourceLocation: sourceLocation)
    }

    @Test func everyBuiltInRoundTripsAndIsValid() {
        for preset in DeliveryPreset.builtIns {
            let form = EditDeliveryForm(preset)
            #expect(form.preset == preset)
            #expect(form.canSave && form.validationError == nil)
            #expect(form.isAtDefault)
        }
    }

    @Test func jpegXLRules() {
        var form = EditDeliveryForm(DeliveryPreset.builtIns[3])          // Archive
        #expect(form.quality == .lossless && !form.isQualityPickerEnabled && form.qualityOptions == [.lossless])
        #expect(!form.isLongEdgeEnabled && !form.isConvertToSRGBEnabled && !form.isMetadataRemovalEnabled)
        form.sizeChoice = .longEdge
        Self.expectInvalid(form, Self.jxlMessage)
        form.sizeChoice = .full
        form.colour = .convertToSRGB
        Self.expectInvalid(form, Self.jxlMessage)
        form.colour = .keepProfile
        form.metadata = .removeLocation
        Self.expectInvalid(form, Self.jxlMessage)
        form.metadata = .keepAll
        #expect(form.canSave)
        // Website → JPEG XL: the resized, converted, location-removing combination is reported, not corrected.
        var website = EditDeliveryForm(DeliveryPreset.builtIns[1])
        website.format = .jxlLossless
        Self.expectInvalid(website, Self.jxlMessage)
        #expect(website.sizeChoice == .longEdge && website.colour == .convertToSRGB && website.metadata == .removeLocation)
        // Lossless with a lossy format (only reachable from stored data) is reported too.
        let broken = DeliveryPreset(id: .newCustom(), name: "X", symbol: "photo", format: .jpeg, size: .full, quality: .lossless,
                                    colour: .keepProfile, metadata: .keepAll, folderName: "X")
        #expect(broken.validationError == Self.jxlMessage)
    }

    @Test func leavingJPEGXLBringsBackTheLossyQuality() {
        var form = EditDeliveryForm(DeliveryPreset.builtIns[2])          // Social: High
        form.format = .jxlLossless
        #expect(form.quality == .lossless)
        form.format = .jpeg
        #expect(form.quality == .high)
        var archive = EditDeliveryForm(DeliveryPreset.builtIns[3])
        archive.format = .jpeg
        #expect(archive.quality == .high && archive.canSave)
    }

    @Test func balancedRules() {
        var form = EditDeliveryForm(DeliveryPreset.builtIns[0])          // Couple: Balanced, full, JPEG
        #expect(form.isEnabled(.balanced))
        form.format = .webp
        #expect(!form.isEnabled(.balanced))
        Self.expectInvalid(form, Self.balancedMessage)
        form.format = .jpeg
        form.sizeChoice = .longEdge
        #expect(!form.isEnabled(.balanced))
        Self.expectInvalid(form, Self.balancedMessage)
        form.lossyQuality = .high
        #expect(form.canSave)
    }

    @Test func longEdgeRange() {
        var form = EditDeliveryForm(DeliveryPreset.builtIns[1])
        for (edge, valid) in [(399, false), (400, true), (2560, true), (12000, true), (12001, false), (0, false)] {
            form.longEdge = edge
            if valid { #expect(form.canSave, "\(edge)") } else { Self.expectInvalid(form, Self.edgeMessage) }
        }
        // The field is validated as typed: empty, partial or non-numeric text disables Save with the range message.
        for text in ["", "25", "2 560", "2560px", "abc", "99999999999999999999"] {
            form.longEdgeText = text
            Self.expectInvalid(form, Self.edgeMessage)
        }
        form.longEdgeText = " 2048 "
        #expect(form.canSave && form.preset.size == .longEdge(2048))
        // Full size ignores the remembered edge.
        form.longEdge = 5
        form.sizeChoice = .full
        #expect(form.canSave)
    }

    @Test func nameAndFolderRules() {
        var form = EditDeliveryForm(DeliveryPreset.builtIns[1])
        form.name = "   "
        Self.expectInvalid(form, Self.nameMessage)
        form.name = "Gallery"
        form.folderName = ""
        Self.expectInvalid(form, Self.nameMessage)
        form.folderName = "Web/Gallery"
        Self.expectInvalid(form, Self.nameMessage)
        form.folderName = "Web:Gallery"
        Self.expectInvalid(form, Self.nameMessage)
        form.folderName = "  Gallery  "
        #expect(form.canSave && form.preset.folderName == "Gallery")
    }

    @Test func restoreDefaultRestoresTheBuiltInExactly() {
        for builtIn in DeliveryPreset.builtIns {
            var form = EditDeliveryForm(builtIn)
            form.name = "Renamed"
            form.symbol = "star"
            form.folderName = "Elsewhere"
            if builtIn.format != .jxlLossless {
                form.format = builtIn.format == .jpeg ? .webp : .jpeg
                form.sizeChoice = .longEdge
                form.longEdge = 999
                form.lossyQuality = .highest
                form.colour = builtIn.colour == .keepProfile ? .convertToSRGB : .keepProfile
                form.metadata = .removeAll
            }
            #expect(!form.isAtDefault && form.canRestoreDefault)
            form.restoreDefault()
            #expect(form.preset == builtIn)
            #expect(form.isAtDefault)
        }
        var custom = EditDeliveryForm(AppModel.newCustomPreset(existing: DeliveryPreset.builtIns))
        #expect(!custom.canRestoreDefault)
        custom.name = "X"
        custom.restoreDefault()
        #expect(custom.name == "X")
    }

    @Test func copy() {
        #expect(EditDeliveryForm.symbols.count == 12)
        #expect(EditDeliveryCopy.formatTitle(.jxlLossless) == "JPEG XL (lossless, from JPEG)")
        #expect(EditDeliveryCopy.metadataTitle(.removeLocation) == "Remove location and camera serial")
        #expect(EditDeliveryCopy.metadataTitle(.removeAll) == "Remove all except copyright")
        #expect(EditDeliveryCopy.colourTitle(.keepProfile) == "Keep original profile")
        #expect(EditDeliveryCopy.colourFooter == "Use sRGB for websites and social media.")
        var state = AppState()
        state.records = Fixtures.history
        #expect(state.records.count == 38)
        #expect(SettingsCopy.clearHistoryTitle(in: state, locale: Locale(identifier: "en_DE")) == "Clear the history of all 38 weddings?")
        state.records = [Fixtures.finnUndLissy]
        #expect(SettingsCopy.clearHistoryTitle(in: state, locale: Locale(identifier: "en_DE")) == "Clear the history of 1 wedding?")
        #expect(SettingsCopy.clearHistoryMessage == "Delivered photos are not touched.")
        #expect(GeneralSettingsTab.namingPreview("{wedding}-{number}") == "Finn-und-Lissy-0001.jpg")
    }
}

@MainActor @Suite struct SettingsModelTests {
    static let print = DeliveryPreset(id: DeliveryID(rawValue: "custom-print"), name: "Album Print", symbol: "printer",
                                      format: .jpeg, size: .full, quality: .highest, colour: .keepProfile,
                                      metadata: .removeAll, folderName: "Print")

    @Test func editAndAddOpenTheSheet() {
        let model = makeModel()
        model.editDelivery(DeliveryPreset.builtIns[1])
        #expect(model.state.sheet == .editDelivery(DeliveryPreset.builtIns[1], isNew: false))
        model.addDelivery()
        guard case .editDelivery(let new, true) = model.state.sheet else { Issue.record("no new sheet"); return }
        #expect(new.name == "New Delivery" && !new.isBuiltIn && new.validationError == nil)
        model.state.presets.append(new)
        #expect(AppModel.newCustomPreset(existing: model.state.presets).name == "New Delivery 2")
    }

    @Test func savePresetInsertsReplacesPersistsAndClosesTheSheet() {
        let store = InMemoryPresets()
        let model = makeModel(presets: store)
        model.state.draft = SetupDraft(name: "Finn und Lissy", scan: .ready(Fixtures.scanResult),
                                       enabled: [.couple: true, .website: true], naming: .default)
        model.state.sheet = .editDelivery(Self.print, isNew: true)
        model.savePreset(Self.print)
        #expect(model.state.presets.last == Self.print)
        #expect(model.state.sheet == nil)
        #expect(model.state.draft?.enabled[Self.print.id] == true)     // a new delivery is checked in the open setup
        #expect(store.load().presets == model.state.presets)
        var edited = DeliveryPreset.builtIns[1]
        edited.size = .longEdge(2048)
        model.savePreset(edited)
        #expect(model.state.presets[1] == edited && store.load().presets[1] == edited)
        var invalid = edited
        invalid.quality = .balanced
        model.savePreset(invalid)
        #expect(model.state.presets[1] == edited)
    }

    @Test func aDeliveryAddedInSettingsIsNotCheckedInTheOpenSetup() {
        let model = makeModel()
        model.state.draft = SetupDraft(name: "Finn und Lissy", scan: .ready(Fixtures.scanResult),
                                       enabled: [.couple: true, .website: true], naming: .default)
        // Settings ▸ Deliveries ▸ + presents its own sheet; `state.sheet` is untouched.
        model.savePreset(Self.print)
        #expect(model.state.presets.last == Self.print)
        #expect(model.state.draft?.enabled[Self.print.id] == nil)
        #expect(model.state.draft?.enabled == [.couple: true, .website: true])
    }

    @Test func deleteMoveDefaultOnAndRestore() {
        let store = InMemoryPresets()
        let model = makeModel(presets: store)
        model.savePreset(Self.print)
        model.setDefaultOn(Self.print.id, true)
        #expect(model.state.defaultOn == [.couple, .website, Self.print.id])
        model.deletePreset(.couple)                                     // built-in: refused
        #expect(model.state.presets.count == 5)
        model.movePresets(from: [4], to: 0)                             // Album Print first
        #expect(model.state.presets.map(\.id) == [Self.print.id, .couple, .website, .social, .archive])
        #expect(model.state.defaultOn == [Self.print.id, .couple, .website])
        #expect(store.load().presets.map(\.id) == model.state.presets.map(\.id))
        #expect(store.load().defaultOn == model.state.defaultOn)
        model.setDefaultOn(.couple, false)
        model.setDefaultOn(.archive, true)
        #expect(model.state.defaultOn == [Self.print.id, .website, .archive])

        var website = DeliveryPreset.builtIns[1]
        website.name = "Gallery"
        model.savePreset(website)
        model.restoreDefaultDeliveries()
        #expect(model.state.presets == DeliveryPreset.builtIns + [Self.print])
        #expect(model.state.defaultOn == DeliveryPreset.defaultOnIDs)
        #expect(store.load().presets == model.state.presets)

        model.deletePreset(Self.print.id)
        #expect(model.state.presets == DeliveryPreset.builtIns)
        #expect(store.load().presets == DeliveryPreset.builtIns)
    }

    @Test func updateSettingsPersists() {
        let store = InMemorySettings()
        let model = makeModel(settings: store)
        model.updateSettings { $0.processorUse = .gentle; $0.folderNamePattern = "{date} {wedding}" }
        #expect(model.state.settings.processorUse == .gentle)
        #expect(store.load() == model.state.settings)
    }

    @Test func clearHistoryRemovesOnlyFinishedWeddings() async throws {
        let history = InMemoryHistory(Fixtures.history + [Fixtures.annaUndBen])
        let model = makeModel(records: Fixtures.history + [Fixtures.annaUndBen], history: history)
        model.state.selection = .wedding(Fixtures.finnUndLissyID)
        model.openCompare(CompareRoute(wedding: Fixtures.finnUndLissyID, delivery: .couple, start: PhotoID(0), spotCheck: false))
        #expect(model.clearableHistoryCount == 38)
        model.clearHistory()
        #expect(model.state.records.map(\.id) == [Fixtures.annaUndBenID])
        #expect(model.state.selection == .newWedding)
        #expect(model.state.compare == nil && model.state.detailPath.isEmpty)
        for _ in 0..<200 where try await history.loadAll().count > 1 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(try await history.loadAll().map(\.id) == [Fixtures.annaUndBenID])
    }

    @Test func resetLearnedEstimatesClearsOnlyItsKeys() {
        // Must equal HMBEngine's `LearnedEstimates.keyPrefix` (the keys the engine reads); with the old
        // "holdmybyte.learned." prefix the button removed nothing.
        #expect(AppModel.learnedEstimatesKeyPrefix == "holdmybyte.estimate.")
        let defaults = UserDefaults.standard
        let learned = AppModel.learnedEstimatesKeyPrefix + "kappa.fullSize.wp4test"
        let other = "holdmybyte.wp4test.keep"
        defaults.set(1.07, forKey: learned)
        defaults.set(true, forKey: other)
        defer { defaults.removeObject(forKey: other) }
        let model = makeModel()
        let counter = PostCounter()
        let observer = NotificationCenter.default.addObserver(forName: AppModel.learnedEstimatesResetNotification,
                                                              object: nil, queue: nil) { _ in counter.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        model.resetLearnedEstimates()
        #expect(defaults.object(forKey: learned) == nil)
        #expect(defaults.bool(forKey: other))
        #expect(counter.value == 1)
    }
}

final class PostCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
