import SwiftUI
import WoodruffKit

/// How Home is arranged: which sections show and in what order, and the order of the tiles in each.
@Observable @MainActor
final class HomeLayout {
    static let shared = HomeLayout()

    static let allSections = ["status", "rooms", "cameras", "tvs", "speakers", "lights", "devices"]
    static func title(_ key: String) -> String {
        switch key {
        case "status": return "Status"
        case "rooms": return "Rooms"
        case "tvs": return "TVs"
        case "speakers": return "Speakers"
        case "lights": return "Lights"
        case "cameras": return "Cameras"
        case "devices": return "Devices"
        default: return key
        }
    }

    var sections: [String] { didSet { save() } }
    var hiddenSections: Set<String> { didSet { save() } }
    /// Section → tile ids, in the order chosen.
    var order: [String: [String]] { didSet { save() } }
    var hiddenItems: Set<String> { didSet { save() } }
    /// Home split up by room, like the Home app (otherwise by kind: Cameras, TVs, Speakers…).
    var groupByRoom: Bool { didSet { save() } }
    /// The rooms that get their own button in Home's room bar (the rest are under More).
    var pinnedRooms: [String] { didSet { save() } }

    /// The pinned rooms that exist, by their real names, in the pinned order.
    func pinned(in rooms: [String]) -> [String] {
        pinnedRooms.compactMap { p in rooms.first { $0.caseInsensitiveCompare(p) == .orderedSame } }
    }

    func togglePinned(_ room: String) {
        if let i = pinnedRooms.firstIndex(where: { $0.caseInsensitiveCompare(room) == .orderedSame }) { pinnedRooms.remove(at: i) }
        else { pinnedRooms.append(room) }
    }

    /// Starred things (any kind), in the order shown under Favorites.
    var favorites: [String] { didSet { save() } }

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }
    func toggleFavorite(_ id: String) {
        if let i = favorites.firstIndex(of: id) { favorites.remove(at: i) } else { favorites.append(id) }
    }
    /// Just the favourites from [items], in the favourites' order.
    func favoritesOnly<T: Identifiable>(_ items: [T]) -> [T] where T.ID == String {
        items.filter { favorites.contains($0.id) }.sorted { (favorites.firstIndex(of: $0.id) ?? 0) < (favorites.firstIndex(of: $1.id) ?? 0) }
    }

    private struct Stored: Codable {
        var sections: [String]
        var hiddenSections: [String]
        var order: [String: [String]]
        var hiddenItems: [String]
        var version: Int?
        var groupByRoom: Bool?
        var favorites: [String]?
        var pinnedRooms: [String]?
    }

    init() {
        let s = Saved.load("homeLayout", as: Stored.self)
        var secs = s?.sections ?? Self.allSections
        for k in Self.allSections where !secs.contains(k) { secs.append(k) }
        // Cameras go first, right under the status and room bars.
        if (s?.version ?? 1) < 2 {
            secs.removeAll { $0 == "cameras" }
            let at = (secs.lastIndex { $0 == "status" || $0 == "rooms" }).map { $0 + 1 } ?? 0
            secs.insert("cameras", at: at)
        }
        sections = secs.filter { Self.allSections.contains($0) }
        hiddenSections = Set(s?.hiddenSections ?? [])
        order = s?.order ?? [:]
        hiddenItems = Set(s?.hiddenItems ?? [])
        groupByRoom = s?.groupByRoom ?? true
        favorites = s?.favorites ?? []
        pinnedRooms = s?.pinnedRooms ?? ["Kitchen", "Front Yard", "Living Room", "Backyard"]
        if (s?.version ?? 1) < 2 { save() }
    }

    private func save() {
        Saved.save("homeLayout", Stored(sections: sections, hiddenSections: Array(hiddenSections), order: order, hiddenItems: Array(hiddenItems), version: 2, groupByRoom: groupByRoom, favorites: favorites, pinnedRooms: pinnedRooms))
    }

    var visibleSections: [String] { sections.filter { !hiddenSections.contains($0) } }

    /// [items] in the chosen order (new ones at the end, as they came), without hidden ones.
    func arrange<T: Identifiable>(_ items: [T], in section: String, includeHidden: Bool = false) -> [T] where T.ID == String {
        let o = order[section] ?? []
        let ranked = items.enumerated().sorted { a, b in
            let ia = o.firstIndex(of: a.element.id) ?? (o.count + a.offset)
            let ib = o.firstIndex(of: b.element.id) ?? (o.count + b.offset)
            return ia < ib
        }.map(\.element)
        return includeHidden ? ranked : ranked.filter { !hiddenItems.contains($0.id) }
    }

    func move<T: Identifiable>(_ items: [T], in section: String, from: IndexSet, to: Int) where T.ID == String {
        var ids = arrange(items, in: section, includeHidden: true).map(\.id)
        ids.move(fromOffsets: from, toOffset: to)
        order[section] = ids
    }

    func reset() {
        sections = Self.allSections
        hiddenSections = []
        order = [:]
        hiddenItems = []
        groupByRoom = true
    }

    /// Rooms in the order chosen (new ones after, alphabetically).
    func arrangeRooms(_ rooms: [String]) -> [String] {
        let o = order["roomOrder"] ?? []
        return rooms.sorted { a, b in
            let ia = o.firstIndex(of: a) ?? Int.max, ib = o.firstIndex(of: b) ?? Int.max
            return ia != ib ? ia < ib : a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    func moveRooms(_ rooms: [String], from: IndexSet, to: Int) {
        var r = arrangeRooms(rooms)
        r.move(fromOffsets: from, toOffset: to)
        order["roomOrder"] = r
    }
}

/// The Favorites choice in Home's room bar.
let favoritesKey = "\u{1}favorites"

/// "Add to Favorites" / "Remove from Favorites", for any tile's menu.
struct FavoriteButton: View {
    var id: String
    var body: some View {
        let fav = HomeLayout.shared.isFavorite(id)
        Button(fav ? "Remove from Favorites" : "Add to Favorites", systemImage: fav ? "star.slash" : "star") {
            withAnimation(.smooth) { HomeLayout.shared.toggleFavorite(id) }
        }
    }
}

/// Every room something is in: the TVs' rooms, and the rooms of cameras, speakers, lights and devices.
@MainActor func homeRooms(_ fleet: Fleet) -> [String] {
    let h = SmartHome.shared
    let tvRooms = fleet.tvs.filter { !$0.isUnpaired }.map { h.rooms[$0.id] ?? $0.name }
    let deviceRooms = (h.speakers.map(\.id) + h.lights.map(\.id) + AccessoryStore.shared.all.map(\.id)).compactMap { h.room(of: $0) }
    let cameraRooms = NestCameras.shared.cameras.compactMap { h.rooms[$0.id] ?? $0.room }
    return Array(Set(tvRooms + deviceRooms + cameraRooms).filter { !$0.isEmpty }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

/// Matches a thing's room against the room wanted; ``noRoom`` asks for things with none.
let noRoom = "\u{1}none"
func roomMatches(_ actual: String?, _ wanted: String) -> Bool {
    wanted == noRoom ? (actual ?? "").isEmpty : actual == wanted
}

/// Edit Home: drag sections and tiles into the order you want, and turn off what you don't want on Home.
struct EditHomeView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    private let layout = HomeLayout.shared
    private let home = SmartHome.shared

    var body: some View {
        @Bindable var layout = layout
        NavigationStack {
            List {
                Section {
                    ForEach(layout.sections, id: \.self) { key in
                        Toggle(HomeLayout.title(key), isOn: shown(section: key))
                    }
                    .onMove { layout.sections.move(fromOffsets: $0, toOffset: $1) }
                } header: { Text("Sections") } footer: {
                    Text("Drag to change the order of Home. Turn one off to hide it.")
                }

                Section {
                    if layout.favorites.isEmpty {
                        Text("Touch and hold anything on Home and choose Add to Favorites.").foregroundStyle(.secondary)
                    }
                    ForEach(layout.favorites, id: \.self) { id in Text(favoriteName(id)) }
                        .onMove { layout.favorites.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { layout.favorites.remove(atOffsets: $0) }
                } header: { Text("Favorites") } footer: {
                    Text("Favorites come first on Home. Drag to reorder; swipe to remove.")
                }

                Section {
                    ForEach(homeRooms(fleet), id: \.self) { r in
                        Toggle(r, isOn: Binding(get: { layout.pinned(in: [r]).count == 1 }, set: { _ in layout.togglePinned(r) }))
                    }
                } header: { Text("Room Bar") } footer: {
                    Text("The rooms with their own button on Home, after Favorites. Every other room is under More.")
                }

                Section {
                    Toggle("Group by Room", isOn: $layout.groupByRoom)
                    if layout.groupByRoom {
                        ForEach(layout.arrangeRooms(homeRooms(fleet)), id: \.self) { r in Text(r) }
                            .onMove { layout.moveRooms(homeRooms(fleet), from: $0, to: $1) }
                    }
                } header: { Text("Rooms") } footer: {
                    Text(layout.groupByRoom ? "Home shows each room with everything in it. Drag rooms into the order you want." : "Home shows Cameras, TVs, Speakers, Lights and Devices each together.")
                }

                let tvs = fleet.tvs.filter { !$0.isUnpaired }
                if !tvs.isEmpty {
                    Section("TVs") {
                        ForEach(layout.arrange(tvs, in: "tvs", includeHidden: true)) { tv in
                            Toggle(tv.name, isOn: shown(item: tv.id))
                        }
                        .onMove { layout.move(tvs, in: "tvs", from: $0, to: $1) }
                    }
                }
                if !home.speakers.isEmpty {
                    Section("Speakers") {
                        ForEach(layout.arrange(home.speakers, in: "speakers", includeHidden: true)) { r in
                            Toggle(r.name, isOn: shown(item: r.id))
                        }
                        .onMove { layout.move(home.speakers, in: "speakers", from: $0, to: $1) }
                    }
                }
                if !home.lights.isEmpty {
                    Section("Lights") {
                        ForEach(layout.arrange(home.lights, in: "lights", includeHidden: true)) { l in
                            Toggle(l.name, isOn: shown(item: l.id))
                        }
                        .onMove { layout.move(home.lights, in: "lights", from: $0, to: $1) }
                    }
                }
                let cams = NestCameras.shared.cameras
                if !cams.isEmpty {
                    Section("Cameras") {
                        ForEach(layout.arrange(cams, in: "cameras", includeHidden: true)) { c in
                            Toggle(c.name, isOn: shown(item: c.id))
                        }
                        .onMove { layout.move(cams, in: "cameras", from: $0, to: $1) }
                    }
                }
                let devices = AccessoryStore.shared.all
                if !devices.isEmpty {
                    Section("Devices") {
                        ForEach(layout.arrange(devices, in: "devices", includeHidden: true)) { d in
                            Toggle(d.name, isOn: shown(item: d.id))
                        }
                        .onMove { layout.move(devices, in: "devices", from: $0, to: $1) }
                    }
                }
                Section {
                    Button("Reset to Default", role: .destructive) { withAnimation { layout.reset() } }
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle("Edit Home")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    private func favoriteName(_ id: String) -> String {
        if let t = fleet.tv(id) { return t.name }
        if let c = NestCameras.shared.cameras.first(where: { $0.id == id }) { return c.name }
        if let r = home.speaker(id) { return r.name }
        if let l = home.light(id) { return l.name }
        if let d = AccessoryStore.shared.device(id) { return d.name }
        return "Unavailable"
    }

    private func shown(section key: String) -> Binding<Bool> {
        Binding(get: { !layout.hiddenSections.contains(key) },
                set: { on in if on { layout.hiddenSections.remove(key) } else { layout.hiddenSections.insert(key) } })
    }

    private func shown(item id: String) -> Binding<Bool> {
        Binding(get: { !layout.hiddenItems.contains(id) },
                set: { on in if on { layout.hiddenItems.remove(id) } else { layout.hiddenItems.insert(id) } })
    }
}
