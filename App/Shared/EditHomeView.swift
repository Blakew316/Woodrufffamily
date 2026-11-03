import SwiftUI
import WoodruffKit

/// How Home is arranged: which sections show and in what order, and the order of the tiles in each.
@Observable @MainActor
final class HomeLayout {
    static let shared = HomeLayout()

    static let allSections = ["status", "rooms", "tvs", "cameras", "speakers", "lights", "devices"]
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

    private struct Stored: Codable {
        var sections: [String]
        var hiddenSections: [String]
        var order: [String: [String]]
        var hiddenItems: [String]
    }

    init() {
        let s = Saved.load("homeLayout", as: Stored.self)
        var secs = s?.sections ?? Self.allSections
        for k in Self.allSections where !secs.contains(k) { secs.append(k) }
        sections = secs.filter { Self.allSections.contains($0) }
        hiddenSections = Set(s?.hiddenSections ?? [])
        order = s?.order ?? [:]
        hiddenItems = Set(s?.hiddenItems ?? [])
    }

    private func save() {
        Saved.save("homeLayout", Stored(sections: sections, hiddenSections: Array(hiddenSections), order: order, hiddenItems: Array(hiddenItems)))
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
    }
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

    private func shown(section key: String) -> Binding<Bool> {
        Binding(get: { !layout.hiddenSections.contains(key) },
                set: { on in if on { layout.hiddenSections.remove(key) } else { layout.hiddenSections.insert(key) } })
    }

    private func shown(item id: String) -> Binding<Bool> {
        Binding(get: { !layout.hiddenItems.contains(id) },
                set: { on in if on { layout.hiddenItems.remove(id) } else { layout.hiddenItems.insert(id) } })
    }
}
