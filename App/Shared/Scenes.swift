import SwiftUI
import AppIntents
import WoodruffKit

// Scenes: several things at once ("Movie Night", "Bedtime") from Home, Siri, Shortcuts and Control Center.

/// A scene: which TVs to turn on or off, how bright each room's lights should be, the thermostat, and Sonos.
struct HomeScene: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var tvsOn: [String] = []          // TV ids
    var tvsOff: [String] = []         // TV ids
    var allTVsOff = false
    /// Room name → 0 (off) or a brightness 1–100; the room "" is every light.
    var lights: [String: Int] = [:]
    /// The thermostat's temperature (°F): the heat or the cool setting, whichever it's on.
    var thermostat: Double?
    var pauseSonos = false
    /// Shown as a button on Home (only when added there; missing from scenes saved before it was asked).
    var onHome: Bool? = nil

    var showsOnHome: Bool { onHome ?? false }

    static let movieNight = "movie-night"
    static let bedtime = "bedtime"
}

/// The family's scenes, kept on this device.
@Observable @MainActor
final class SceneStore {
    static let shared = SceneStore()

    private(set) var scenes: [HomeScene]

    private init() {
        scenes = Saved.load("scenes", as: [HomeScene].self) ?? [
            HomeScene(id: HomeScene.movieNight, name: "Movie Night", lights: ["Living Room": 15]),
            HomeScene(id: HomeScene.bedtime, name: "Bedtime", allTVsOff: true, lights: ["": 0], pauseSonos: true),
        ]
    }

    func scene(_ id: String) -> HomeScene? { scenes.first { $0.id == id } }

    /// The scenes came from another device.
    func reload() {
        guard let list = Saved.load("scenes", as: [HomeScene].self), list != scenes else { return }
        scenes = list
        WoodruffShortcuts.updateAppShortcutParameters()
    }

    func save(_ s: HomeScene) {
        if let i = scenes.firstIndex(where: { $0.id == s.id }) {
            guard scenes[i] != s else { return }
            scenes[i] = s
        } else {
            scenes.append(s)
        }
        persist()
    }

    func delete(_ id: String) {
        scenes.removeAll { $0.id == id }
        persist()
    }

    func move(from: IndexSet, to: Int) {
        scenes.move(fromOffsets: from, toOffset: to)
        persist()
    }

    /// Movie Night starts with no TV until the TVs are known: the living room's, once there is one.
    func fillDefaults() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "scenes.filled"),
              var s = scene(HomeScene.movieNight), s.tvsOn.isEmpty,
              let tv = Fleet.shared.tvs.first(where: { !$0.isUnpaired && $0.name.localizedCaseInsensitiveContains("living") })
        else { return }
        s.tvsOn = [tv.id]
        save(s)
        d.set(true, forKey: "scenes.filled")
    }

    private func persist() {
        Saved.save("scenes", scenes)
        WoodruffShortcuts.updateAppShortcutParameters()   // Siri learns the scenes' names
    }
}

// MARK: - Running a scene

@MainActor
enum SceneRunner {
    /// Runs the scene with [id] (Control Center's buttons). What didn't work; empty when everything did.
    @discardableResult
    static func run(id: String) async -> [String] {
        guard let s = SceneStore.shared.scene(id) else { return ["That scene isn’t here any more."] }
        return await run(s)
    }

    /// Everything in [s] at once. What didn't work; empty when everything did.
    static func run(_ s: HomeScene) async -> [String] {
        let fleet = Fleet.shared
        let home = SmartHome.shared
        SceneStore.shared.fillDefaults()
        var problems: [String] = []

        // The lights and speakers (and Apple Home's lights on iPhone), in case this started Woodruff just now.
        home.start()
        #if os(iOS) || os(tvOS)
        if home.homeControl == nil { HomeKitLights.shared.start() }
        #endif
        let usesTVs = !s.tvsOn.isEmpty || !s.tvsOff.isEmpty || s.allTVsOff
        if usesTVs, fleet.refreshedAt.map({ Date().timeIntervalSince($0) > 5 }) ?? true { await fleet.refresh() }

        // TVs
        for id in s.tvsOn {
            guard let tv = fleet.tvs.first(where: { $0.id == id }) else { continue }
            if !tv.online { fleet.wake(tv) }
        }
        let off = fleet.tvs.filter { tv in
            tv.online && !tv.isUnpaired && !s.tvsOn.contains(tv.id) && (s.allTVsOff || s.tvsOff.contains(tv.id))
        }
        problems += await turnOffAll(off).problems

        // Lights
        if !s.lights.isEmpty {
            if home.lights.isEmpty { try? await Task.sleep(nanoseconds: 1_500_000_000) }   // just started: a moment to find them
            // Every light's room worked out once (not looked up afresh for each light in each room).
            let roomOf = home.roomIndex
            for (room, level) in s.lights.sorted(by: { $0.key < $1.key }) {
                let list = room.isEmpty ? home.lights : home.lights.filter { l in
                    roomOf[l.id].map { $0.caseInsensitiveCompare(room) == .orderedSame } ?? false
                }
                for l in list where !l.isOffline {
                    if level <= 0 {
                        if l.on { home.setOn(l, false) }
                    } else {
                        // One change: a brightness turns a light that's off on at that level (a separate "on" first
                        // raced it, and was a second command to every light).
                        home.setBrightness(l, min(100, level))
                    }
                }
            }
        }

        // Thermostat
        if let temp = s.thermostat {
            if let t = AccessoryStore.shared.thermostat {
                // The scene keeps °F; the thermostat controls take °C (70 °F was being sent as 70 °C).
                let c = (temp - 32) * 5 / 9
                if !t.reachable {
                    problems.append("\(t.name) isn’t responding.")
                } else {
                    AccessoryStore.shared.send(t, t.thermostatMode == "cool" ? .coolTo(c) : .heatTo(c))
                }
            } else {
                problems.append("The thermostat isn’t connected.")
            }
        }

        // Sonos
        if s.pauseSonos {
            if home.speakers.isEmpty { await home.findSonos() }
            for r in home.speakers where r.isCoordinator && r.isPlaying { await home.playPause(r) }
        }

        if usesTVs {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await fleet.refresh()
        }
        return problems
    }

    /// Turns every one of [tvs] off at once (one after another, a house of TVs took seconds), in their order: the
    /// names of those that went off, and what went wrong with the rest.
    static func turnOffAll(_ tvs: [FleetTV]) async -> (done: [String], problems: [String]) {
        var results: [Int: String?] = [:]
        await withTaskGroup(of: (Int, String?).self) { group in
            for (i, tv) in tvs.enumerated() {
                group.addTask {
                    let p = await SceneRunner.turnOff(tv)
                    return (i, p)
                }
            }
            for await (i, p) in group { results[i] = p }
        }
        var done: [String] = [], problems: [String] = []
        for (i, tv) in tvs.enumerated() {
            if let p = results[i] ?? nil { problems.append(p) } else { done.append(tv.name) }
        }
        return (done, problems)
    }

    /// Turns [tv] off: LG TVs through their own remote connection, the others through the TV's server.
    static func turnOff(_ tv: FleetTV) async -> String? {
        let fleet = Fleet.shared
        if let lg = fleet.lg(for: tv) {
            do { try await lg.turnOff(); return nil } catch { return "Couldn’t turn off \(tv.name)." }
        }
        if let c = fleet.client(for: tv) {
            do { try await c.key("power"); return nil } catch { return "Couldn’t turn off \(tv.name)." }
        }
        return "Couldn’t reach \(tv.name)."
    }
}

// MARK: - Home's scene buttons

/// One glass button per scene, under Home's greeting. A tap runs it; a touch and hold edits it.
struct ScenesStrip: View {
    private let store = SceneStore.shared
    @Environment(Fleet.self) private var fleet
    @State private var running: String?
    @State private var done: String?
    @State private var editing: HomeScene?

    var body: some View {
        let shown = store.scenes.filter(\.showsOnHome)
        if !shown.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(shown) { s in
                        Button { run(s) } label: {
                            HStack(spacing: 6) {
                                if running == s.id {
                                    ProgressView().controlSize(.small)
                                } else if done == s.id {
                                    Image(systemName: "checkmark").font(.footnote.weight(.bold))
                                }
                                Text(s.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .glass(Capsule(), interactive: true)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        // Not on Apple TV: a button the remote is on that's switched off loses the focus, which jumped
                        // somewhere else on Home while the scene ran (a press meanwhile does nothing; see `run`).
                        #if !os(tvOS)
                        .disabled(running != nil)
                        #endif
                        .contextMenu {
                            Button("Edit Scene") { editing = s }
                            Button("Remove from Home") {
                                var changed = s
                                changed.onHome = false
                                withAnimation(.smooth(duration: 0.3)) { store.save(changed) }
                            }
                        }
                        .accessibilityHint("Runs the scene")
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            #if os(tvOS)
            // The whole width is the scenes', so Up and Down stop at them from anywhere (they sit at the left, and from
            // the right the remote went straight past them).
            .focusSection()
            #endif
            .sheet(item: $editing) { s in
                NavigationStack {
                    SceneEditor(scene: s, isNew: false)
                        #if os(iOS)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { editing = nil } } }
                        #elseif os(macOS)
                        // The Mac's sheet had no way out. (Changes keep as they're made.)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { editing = nil }.keyboardShortcut(.cancelAction) } }
                        #endif
                }
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 560)
                    #endif
            }
        }
    }

    private func run(_ s: HomeScene) {
        // One scene at a time.
        guard running == nil else { return }
        #if os(iOS) || os(tvOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        withAnimation(.smooth(duration: 0.25)) { running = s.id; done = nil }
        Task {
            let problems = await SceneRunner.run(s)
            withAnimation(.smooth(duration: 0.25)) { running = nil; done = s.id }
            if !problems.isEmpty { fleet.say(s.name, problems.joined(separator: " ")) }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if done == s.id { withAnimation(.smooth(duration: 0.3)) { done = nil } }
        }
    }
}

// MARK: - Settings → Scenes

/// The scenes, to add, change, reorder or delete.
struct ScenesSettingsView: View {
    private let store = SceneStore.shared
    @State private var adding: HomeScene?

    var body: some View {
        Form {
            Section {
                ForEach(store.scenes) { s in
                    PageLink(s.name) { SceneEditor(scene: s, isNew: false) } label: {
                        IconRow(symbol: "", color: .clear, title: s.name, value: SceneSummary.text(s))
                    }
                }
                // The ids first: deleting one moves the rest up, so indexes read after it point at the wrong scene.
                .onDelete { idx in
                    let ids = idx.compactMap { store.scenes.indices.contains($0) ? store.scenes[$0].id : nil }
                    for id in ids { store.delete(id) }
                }
                .onMove { store.move(from: $0, to: $1) }
                Button("Add a Scene") {
                    adding = HomeScene(id: UUID().uuidString, name: "")
                }
            } footer: {
                Text("Scenes run from Control Center, Shortcuts, or Siri: “Movie Night with Woodruff”. Turn on Add to Home in a scene to show it on Home.")
            }
        }
        .familyFormStyle()
        .navigationTitle("Scenes")
        .inlineTitle()
        .sheet(item: $adding) { s in
            NavigationStack { SceneEditor(scene: s, isNew: true) }
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 560)
                #endif
        }
        .onAppear { store.fillDefaults() }
    }
}

enum SceneSummary {
    /// "2 TVs · Lights · Thermostat".
    static func text(_ s: HomeScene) -> String {
        var parts: [String] = []
        let tvs = s.tvsOn.count + s.tvsOff.count
        if s.allTVsOff { parts.append("TVs Off") } else if tvs > 0 { parts.append(tvs == 1 ? "1 TV" : "\(tvs) TVs") }
        if !s.lights.isEmpty { parts.append("Lights") }
        if s.thermostat != nil { parts.append("Thermostat") }
        if s.pauseSonos { parts.append("Sonos") }
        return parts.isEmpty ? "Nothing yet" : parts.joined(separator: " · ")
    }
}

/// One scene's settings. Changes keep as they're made; a new scene is kept with Add.
struct SceneEditor: View {
    @State var scene: HomeScene
    var isNew: Bool
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.macPanePush) private var panePush
    #endif
    @Environment(Fleet.self) private var fleet
    private let store = SceneStore.shared
    private let home = SmartHome.shared

    private enum TVChoice: String, CaseIterable { case leave = "Leave", on = "Turn On", off = "Turn Off" }
    private struct Level: Identifiable { var name: String; var value: Int?; var id: String { name } }
    private static let levels = [Level(name: "Leave", value: nil), Level(name: "Off", value: 0), Level(name: "10%", value: 10),
                                 Level(name: "25%", value: 25), Level(name: "50%", value: 50), Level(name: "75%", value: 75),
                                 Level(name: "100%", value: 100)]

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $scene.name)
                Toggle("Add to Home", isOn: Binding(get: { scene.showsOnHome }, set: { scene.onHome = $0 }))
            } footer: {
                Text("Shows the scene as a button on Home.")
            }
            Section("TVs") {
                Toggle("Turn Off Every TV", isOn: $scene.allTVsOff)
                ForEach(fleet.tvs.filter { !$0.isUnpaired }) { tv in
                    Picker(tv.name, selection: tvChoice(tv.id)) {
                        ForEach(TVChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
            }
            Section("Lights") {
                Picker("Every Light", selection: level("")) { levelOptions }
                ForEach(rooms, id: \.self) { room in
                    Picker(room, selection: level(room)) { levelOptions }
                }
            }
            Section("Thermostat") {
                Toggle("Set the Temperature", isOn: Binding(
                    get: { scene.thermostat != nil },
                    set: { scene.thermostat = $0 ? (scene.thermostat ?? 70) : nil }))
                if let t = scene.thermostat {
                    Stepper(value: Binding(get: { t }, set: { scene.thermostat = $0 }), in: 55...85, step: 1) {
                        LabeledContent("Temperature", value: "\(Int(t))°")
                    }
                }
            }
            Section("Sonos") {
                Toggle("Pause Sonos", isOn: $scene.pauseSonos)
            }
            if !isNew {
                Section {
                    Button("Delete Scene", role: .destructive) {
                        store.delete(scene.id)
                        #if os(macOS)
                        // In Mac Settings' right-hand side this page is the window's own root: `dismiss` there
                        // closed the whole window. It goes back to Scenes instead.
                        if let panePush { panePush.pop() } else { dismiss() }
                        #else
                        dismiss()
                        #endif
                    }
                }
            }
        }
        .familyFormStyle()
        .navigationTitle(isNew ? "New Scene" : (scene.name.isEmpty ? "Scene" : scene.name))
        .inlineTitle()
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { store.save(trimmed); dismiss() }
                        .disabled(scene.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onChange(of: scene) { _, now in
            if !isNew, !now.name.trimmingCharacters(in: .whitespaces).isEmpty { store.save(trimmed) }
        }
    }

    private var trimmed: HomeScene {
        var s = scene
        s.name = s.name.trimmingCharacters(in: .whitespaces)
        return s
    }

    @ViewBuilder private var levelOptions: some View {
        ForEach(Self.levels) { Text($0.name).tag($0.value) }
    }

    /// The rooms that have lights, by name.
    private var rooms: [String] {
        let roomOf = home.roomIndex
        return Array(Set(home.lights.compactMap { roomOf[$0.id] })).sorted()
    }

    private func level(_ room: String) -> Binding<Int?> {
        Binding(get: { scene.lights[room] }, set: { scene.lights[room] = $0 })
    }

    private func tvChoice(_ id: String) -> Binding<TVChoice> {
        Binding(get: {
            scene.tvsOn.contains(id) ? .on : (scene.tvsOff.contains(id) ? .off : .leave)
        }, set: { choice in
            scene.tvsOn.removeAll { $0 == id }
            scene.tvsOff.removeAll { $0 == id }
            if choice == .on { scene.tvsOn.append(id) }
            if choice == .off { scene.tvsOff.append(id) }
        })
    }
}

// MARK: - Siri and Shortcuts

/// A scene, as Siri and Shortcuts see it.
struct SceneEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scene"
    static let defaultQuery = SceneQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct SceneQuery: EntityQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [SceneEntity] {
        SceneStore.shared.scenes.filter { identifiers.contains($0.id) }.map { SceneEntity(id: $0.id, name: $0.name) }
    }
    @MainActor func suggestedEntities() async throws -> [SceneEntity] {
        SceneStore.shared.scenes.map { SceneEntity(id: $0.id, name: $0.name) }
    }
}

struct RunSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "Run a Scene"
    static let description = IntentDescription("Runs a Woodruff scene, like Movie Night or Bedtime.")
    @Parameter(title: "Scene") var scene: SceneEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let s = SceneStore.shared.scene(scene.id) else { return .result(dialog: "I can’t find \(scene.name).") }
        let problems = await SceneRunner.run(s)
        return .result(dialog: "\(problems.isEmpty ? "\(s.name) is set." : problems.joined(separator: " "))")
    }
}

/// "Play The Office on the Living Room with Woodruff": the family's library, on a TV.
struct PlayOnTVIntent: AppIntent {
    static let title: LocalizedStringResource = "Play on a TV"
    static let description = IntentDescription("Finds a movie or show in the family’s library and plays it on a TV.")
    @Parameter(title: "Movie or Show", requestValueDialog: "What do you want to watch?") var name: String
    @Parameter(title: "TV") var tv: TVEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let fleet = Fleet.shared
        if fleet.refreshedAt == nil { await fleet.refresh() }
        guard let target = fleet.tvs.first(where: { $0.id == tv.id }), !target.isUnpaired,
              let c = fleet.hubClient(for: target) ?? fleet.hubClient() else {
            return .result(dialog: "I can’t reach \(tv.name).")
        }
        guard let found = try? await c.search(name) else { return .result(dialog: "I couldn’t search the library just now.") }
        let all = found.movies + found.shows
        let want = name.lowercased()
        let hit = all.first { $0.title.lowercased() == want } ?? all.first { $0.title.lowercased().hasPrefix(want) } ?? all.first
        guard let title = hit, let action = title.play else { return .result(dialog: "I couldn’t find \(name) in the library.") }
        if !target.online { fleet.wake(target) }
        do {
            let r = try await c.start(action, on: target.id == c.hub.id ? "this" : target.id)
            if r.started?.bool == false { return .result(dialog: "\(title.title) is ready on \(target.name). Open Woodruff on the TV to start it.") }
        } catch {
            return .result(dialog: "Couldn’t start \(title.title) on \(target.name).")
        }
        return .result(dialog: "Playing \(title.title) on \(target.name).")
    }
}

/// "Turn off the Living Room with Woodruff", or every TV that's on.
struct TurnOffTVsIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off a TV"
    static let description = IntentDescription("Turns off a TV, or every TV that’s on.")
    @Parameter(title: "TV") var tv: TVEntity?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let fleet = Fleet.shared
        await fleet.refresh()
        let list = fleet.tvs.filter { t in !t.isUnpaired && (tv.map { $0.id == t.id } ?? t.online) }
        guard !list.isEmpty else { return .result(dialog: tv == nil ? "Every TV is already off." : "I can’t find \(tv?.name ?? "that TV").") }
        let (done, problems) = await SceneRunner.turnOffAll(list)
        var said: [String] = []
        if !done.isEmpty { said.append("Turned off \(done.joined(separator: ", ")).") }
        said += problems
        return .result(dialog: "\(said.joined(separator: " "))")
    }
}
