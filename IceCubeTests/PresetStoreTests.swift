// PresetStoreTests.swift — the saved-curve catalog, including the paths that exist to stop user data vanishing.

import Foundation
import IceCubeKit
import Testing

/// `PresetStore` measured 0% covered, and the reason was not neglect — it was
/// unsafe to test. `init()` loads unconditionally from a hardcoded
/// `~/Library/Application Support/IceCube/presets.json`, and `IceCubeTests` is
/// a host-less, unsandboxed bundle, so a naive suite would have overwritten the
/// developer's own saved curves and moved them aside as "corrupt".
///
/// The seam added alongside these tests (`init(file:)`) is what makes them
/// possible. Every test here runs against a unique directory under
/// `temporaryDirectory` and deletes it, so the no-leftovers rule this project
/// enforced after the 1,097-plist incident still holds.
///
/// The load branches are the point. Two of them exist specifically to stop a
/// single unreadable file turning into permanent, invisible loss of every
/// curve a user ever saved.
@MainActor
@Suite("PresetStore — the catalog, and what happens to a file it cannot read")
struct PresetStoreTests {
    /// Runs `body` against a preset file in a directory that is removed
    /// afterwards, whatever happens.
    private func withTempFile(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IceCubePresetTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("presets.json"))
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    // MARK: - Built-ins

    @Test("The four built-ins are all curves, in display order")
    func builtins() {
        let names = PresetStore.builtins.map(\.name)
        #expect(names == ["Quiet", "Balanced", "Cold", "Max"])
        for preset in PresetStore.builtins {
            #expect(
                preset.config.mode == .curve,
                "\(preset.name) must be a curve — every built-in means Ice Cube is driving"
            )
        }
        #expect(!PresetStore.builtins.contains { $0.kind == .custom })
    }

    /// The removed "macOS"/"Auto" preset handed the fans back, and its absence
    /// is a product decision (2026-07-26) rather than an oversight.
    @Test("No built-in hands the fans back to macOS")
    func noAutoBuiltin() {
        #expect(!PresetStore.builtins.contains { $0.config.mode == .auto })
    }

    // MARK: - Saving

    @Test("A saved curve survives being reloaded by a second store")
    func savedCurveRoundTrips() throws {
        try withTempFile { url in
            let store = PresetStore(file: url)
            store.saveUserPreset(named: "Silent Night", curve: .quiet)
            let reloaded = PresetStore(file: url)
            #expect(reloaded.userPresets.map(\.name) == ["Silent Night"])
            #expect(reloaded.userPresets.first?.config.mode == .curve)
        }
    }

    @Test("Surrounding whitespace is trimmed from the name")
    func nameIsTrimmed() throws {
        try withTempFile { url in
            let store = PresetStore(file: url)
            store.saveUserPreset(named: "  Padded  ", curve: .balanced)
            #expect(store.userPresets.map(\.name) == ["Padded"])
        }
    }

    @Test("A blank name saves nothing rather than creating an unnameable preset", arguments: ["", "   ", "\t"])
    func blankNameIsRefused(name: String) throws {
        try withTempFile { url in
            let store = PresetStore(file: url)
            store.saveUserPreset(named: name, curve: .balanced)
            #expect(store.userPresets.isEmpty)
            #expect(
                !FileManager.default.fileExists(atPath: url.path),
                "a refused save must not even create the file"
            )
        }
    }

    @Test("Saving the same name twice replaces rather than duplicating")
    func sameNameReplaces() throws {
        try withTempFile { url in
            let store = PresetStore(file: url)
            store.saveUserPreset(named: "Mine", curve: .quiet)
            let firstID = store.userPresets.first?.id
            store.saveUserPreset(named: "Mine", curve: .max)
            #expect(store.userPresets.count == 1)
            #expect(store.userPresets.first?.id != firstID, "the replacement is a new preset, not a mutation")
        }
    }

    // MARK: - Removing

    /// Save dedupes by name but remove matches by id. That asymmetry is only
    /// visible when a hand-edited file contains two presets sharing a name.
    @Test("Removal matches by identity, so a same-named sibling survives")
    func removalMatchesByIdentity() throws {
        try withTempFile { url in
            let twins = [
                Preset(name: "Twin", kind: .custom, config: .curve(.quiet)),
                Preset(name: "Twin", kind: .custom, config: .curve(.max)),
            ]
            try write(JSONEncoder().encode(twins), to: url)
            let store = PresetStore(file: url)
            #expect(store.userPresets.count == 2)
            store.removeUserPreset(store.userPresets[0])
            #expect(store.userPresets.count == 1)
        }
    }

    @Test("Removing a preset the store never had changes nothing")
    func removingAStrangerIsANoOp() throws {
        try withTempFile { url in
            let store = PresetStore(file: url)
            store.saveUserPreset(named: "Keep", curve: .quiet)
            store.removeUserPreset(Preset(name: "Ghost", kind: .custom, config: .curve(.max)))
            #expect(store.userPresets.map(\.name) == ["Keep"])
        }
    }

    // MARK: - Loading

    @Test("A first run with no file is empty and reports no failure")
    func firstRunIsQuiet() throws {
        try withTempFile { url in
            let store = PresetStore(file: url)
            #expect(store.userPresets.isEmpty)
            #expect(store.loadFailure == nil, "an absent file is a first run, not an error")
        }
    }

    /// The pre-versioning on-disk shape was a bare array. Existing installs
    /// must keep their curves across the change, and the migration must be
    /// written back so the next read takes the fast path.
    @Test("A legacy bare-array file is read and migrated forward on disk")
    func legacyFileMigrates() throws {
        try withTempFile { url in
            let legacy = [Preset(name: "Old", kind: .custom, config: .curve(.balanced))]
            try write(JSONEncoder().encode(legacy), to: url)

            let store = PresetStore(file: url)
            #expect(store.userPresets.map(\.name) == ["Old"])

            let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            let envelope = try #require(onDisk as? [String: Any])
            #expect(envelope["schemaVersion"] as? Int == 1, "the file must be rewritten in the current shape")
        }
    }

    /// Manual mode is never a persisted default. A file that somehow contains
    /// one must not resurrect fixed-RPM control.
    @Test("A manual preset in the file is not loaded")
    func manualPresetsAreFilteredOut() throws {
        try withTempFile { url in
            let sneaky = [
                Preset(name: "Manual", kind: .custom, config: FanConfig(mode: .manual, manualTargets: [0: 6000])),
                Preset(name: "Fine", kind: .custom, config: .curve(.quiet)),
            ]
            try write(JSONEncoder().encode(sneaky), to: url)
            #expect(PresetStore(file: url).userPresets.map(\.name) == ["Fine"])
        }
    }

    /// The branch that exists because the alternative was silent data loss:
    /// an unreadable file used to stay put and be overwritten by the next save.
    @Test("An unreadable file is moved aside rather than overwritten, and the move is reported")
    func corruptFileIsQuarantined() throws {
        try withTempFile { url in
            try write(Data("this is not JSON".utf8), to: url)

            let store = PresetStore(file: url)
            #expect(store.userPresets.isEmpty)
            let failure = try #require(store.loadFailure, "a quarantine must be visible in the UI")
            #expect(failure.hasPrefix("presets.corrupt-"))

            #expect(
                !FileManager.default.fileExists(atPath: url.path),
                "the unreadable file must be moved, not left to be overwritten"
            )
            let siblings = try FileManager.default.contentsOfDirectory(
                atPath: url.deletingLastPathComponent().path
            )
            #expect(siblings.contains(failure), "the user's bytes must still be on disk under the reported name")
        }
    }

    @Test("Quarantining preserves the original bytes exactly")
    func quarantineDoesNotAlterTheData() throws {
        try withTempFile { url in
            let original = Data("{ not json but precious }".utf8)
            try write(original, to: url)

            let store = PresetStore(file: url)
            let backup = try url.deletingLastPathComponent()
                .appendingPathComponent(#require(store.loadFailure))
            #expect(try Data(contentsOf: backup) == original)
        }
    }

    // MARK: - Saved presets are pickable, not just bookmarks

    /// Until 2026-08-08 `userPresets` was read by exactly one UI site — the
    /// curve editor's Load menu — while nine surfaces named `builtins`
    /// directly. `all` is the accessor those surfaces use now.
    @Test("Saved presets join the built-ins, and the built-ins keep their order")
    func allIncludesSavedPresets() throws {
        try withTempFile { file in
            let store = PresetStore(file: file)
            #expect(store.all.map(\.name) == ["Quiet", "Balanced", "Cold", "Max"])

            store.saveUserPreset(named: "Desk", curve: .cold)
            #expect(store.all.map(\.name) == ["Quiet", "Balanced", "Cold", "Max", "Desk"])
            #expect(
                store.all.prefix(4).map(\.name) == PresetStore.builtins.map(\.name),
                "⌥-cycling and muscle memory must not shift for someone who saved nothing"
            )
        }
    }

    /// The reason the Settings picker had to stop tagging by `Preset.Kind`:
    /// every saved preset is `.custom`, so a kind-tagged picker cannot tell two
    /// of them apart. Ids can.
    @Test("Saved presets share a kind but never an id")
    func savedPresetsAreDistinguishableById() throws {
        try withTempFile { file in
            let store = PresetStore(file: file)
            store.saveUserPreset(named: "Desk", curve: .cold)
            store.saveUserPreset(named: "Lap", curve: .quiet)

            let saved = store.userPresets
            #expect(saved.allSatisfy { $0.kind == .custom }, "which is why kind cannot be the tag")
            #expect(Set(saved.map(\.id)).count == saved.count, "ids must be unique")
        }
    }

    /// `PresetHighlight` decides "which preset is active" by comparing configs,
    /// so a saved curve highlights with no new state — this is the property
    /// that made the change cheap, and it is worth pinning.
    @Test("An applied saved curve highlights as the active preset")
    func savedPresetHighlights() throws {
        try withTempFile { file in
            let store = PresetStore(file: file)
            store.saveUserPreset(named: "Desk", curve: .cold)
            let saved = try #require(store.userPresets.first)

            let matched = PresetHighlight.matching(store.all, applied: saved.config)
            #expect(matched?.config == saved.config)
        }
    }

    // MARK: - Deleting, which had no caller at all

    @Test("A saved preset can be removed, and stays removed across a reload")
    func removeSurvivesReload() throws {
        try withTempFile { file in
            let store = PresetStore(file: file)
            store.saveUserPreset(named: "Desk", curve: .cold)
            store.saveUserPreset(named: "Lap", curve: .quiet)
            try store.removeUserPreset(#require(store.userPresets.first { $0.name == "Desk" }))

            #expect(store.userPresets.map(\.name) == ["Lap"])
            #expect(PresetStore(file: file).userPresets.map(\.name) == ["Lap"], "the delete was persisted")
        }
    }

    @Test("Removing never touches the built-ins")
    func removeLeavesBuiltinsAlone() throws {
        try withTempFile { file in
            let store = PresetStore(file: file)
            store.saveUserPreset(named: "Desk", curve: .cold)
            try store.removeUserPreset(#require(store.userPresets.first))
            #expect(store.all.map(\.name) == PresetStore.builtins.map(\.name))
        }
    }

    // MARK: - Saving over a name

    /// Saving under an existing name replaces it outright, and that is also the
    /// only way to edit a preset — so the behaviour stays and the caller asks
    /// first instead.
    @Test("A colliding name is reported before it destroys anything")
    func collisionIsDetectable() throws {
        try withTempFile { file in
            let store = PresetStore(file: file)
            store.saveUserPreset(named: "Desk", curve: .cold)

            #expect(store.wouldReplace(name: "Desk"))
            #expect(store.wouldReplace(name: "  Desk  "), "the same name, trimmed, is the same name")
            #expect(!store.wouldReplace(name: "Lap"))
            #expect(!store.wouldReplace(name: "Quiet"), "a built-in is not replaced — a save adds beside it")
        }
    }

    @Test("Replacing keeps one preset, with the new curve")
    func replacingDoesNotDuplicate() throws {
        try withTempFile { file in
            let store = PresetStore(file: file)
            store.saveUserPreset(named: "Desk", curve: .quiet)
            store.saveUserPreset(named: "Desk", curve: .max)

            #expect(store.userPresets.count == 1)
            #expect(store.userPresets.first?.config.sharedCurve == FanCurve.max)
        }
    }
}
