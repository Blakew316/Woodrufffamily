import SwiftUI
import WoodruffKit

// MARK: - What a Home tab shows

/// One tile on a Home tab.
enum HomeTile: Identifiable {
    case camera(NestCameras.Camera)
    case tv(FleetTV)
    case speaker(SonosRoom)
    case light(GoveeLight)
    case device(HomeDevice)

    var id: String {
        switch self {
        case .camera(let c): return c.id
        case .tv(let t): return t.id
        case .speaker(let r): return r.id
        case .light(let l): return l.id
        case .device(let d): return d.id
        }
    }

    /// Cameras, TVs and the small tiles (speakers, lights, devices) each have their own sizes.
    enum Kind { case camera, tv, small }

    var kind: Kind {
        switch self {
        case .camera: return .camera
        case .tv: return .tv
        case .speaker, .light, .device: return .small
        }
    }
}

/// A tile's size on the grid: columns across, rows down.
struct TileSpan: Equatable {
    var w: Int
    var h: Int
}

extension HomeTile.Kind {
    /// Its size until it's resized.
    var standard: TileSpan {
        #if os(macOS)
        switch self {
        case .camera: return TileSpan(w: 3, h: 3)
        case .tv: return TileSpan(w: 4, h: 3)
        case .small: return TileSpan(w: 2, h: 1)
        }
        #else
        switch self {
        case .camera: return TileSpan(w: 2, h: 2)
        case .tv: return TileSpan(w: 4, h: 3)
        case .small: return TileSpan(w: 2, h: 1)
        }
        #endif
    }

    /// The smallest it goes (what's on it still fits).
    var smallest: TileSpan {
        switch self {
        case .camera: return TileSpan(w: 2, h: 2)
        case .tv: return TileSpan(w: 3, h: 3)
        case .small: return TileSpan(w: 2, h: 1)
        }
    }

    /// The most rows it can take.
    var mostRows: Int {
        switch self {
        case .camera: return 8
        case .tv: return 6
        case .small: return 2
        }
    }
}

// MARK: - The grid

/// The grid a tab's tiles sit on: as many columns as fit the width (four on an iPhone held upright, seven or so in
/// a Mac window), all the same size, so tiles line up however they're sized.
struct BoardMetrics: Equatable {
    var columns: Int
    /// A column's width.
    var cell: CGFloat
    /// A row's height.
    var row: CGFloat
    var gap: CGFloat

    init(width: CGFloat) {
        #if os(macOS)
        let smallest: CGFloat = 104, gap: CGFloat = 14, tall: CGFloat = 0.72
        #else
        let smallest: CGFloat = 76, gap: CGFloat = 10, tall: CGFloat = 0.92
        #endif
        let w = max(width, 160)
        columns = max(2, Int((w + gap) / (smallest + gap)))
        self.gap = gap
        cell = (w - gap * CGFloat(columns - 1)) / CGFloat(columns)
        row = (cell * tall).rounded()
    }

    func size(_ s: TileSpan) -> CGSize {
        CGSize(width: CGFloat(s.w) * cell + CGFloat(max(0, s.w - 1)) * gap,
               height: CGFloat(s.h) * row + CGFloat(max(0, s.h - 1)) * gap)
    }

    func origin(_ col: Int, _ row: Int) -> CGPoint {
        CGPoint(x: CGFloat(col) * (cell + gap), y: CGFloat(row) * (self.row + gap))
    }

    func height(rows: Int) -> CGFloat {
        rows > 0 ? CGFloat(rows) * row + CGFloat(rows - 1) * gap : 0
    }

    /// The span nearest a size (a corner being dragged).
    func span(nearest s: CGSize) -> TileSpan {
        TileSpan(w: Int(((s.width + gap) / (cell + gap)).rounded()), h: Int(((s.height + gap) / (row + gap)).rounded()))
    }
}

/// Where a tile sits.
struct BoardSlot: Equatable {
    var col: Int
    var row: Int
    var span: TileSpan
}

/// Where every tile goes: in order, each in the first place it fits at or after the tile before it, reading left to
/// right and down, so the grid reads in the order arranged (small tiles fill in beside a big one, like app icons
/// around a widget).
func packBoard(_ items: [(id: String, span: TileSpan)], columns: Int) -> (slots: [String: BoardSlot], rows: Int) {
    var taken = Set<Int>()
    var slots: [String: BoardSlot] = [:]
    var rows = 0
    var cursor = 0
    func fits(_ r: Int, _ c: Int, _ s: TileSpan) -> Bool {
        guard c + s.w <= columns else { return false }
        for y in r..<(r + s.h) {
            for x in c..<(c + s.w) where taken.contains(y * columns + x) { return false }
        }
        return true
    }
    for item in items where slots[item.id] == nil {
        let s = TileSpan(w: max(1, min(item.span.w, columns)), h: max(1, item.span.h))
        var i = cursor
        while !fits(i / columns, i % columns, s) { i += 1 }
        let r = i / columns, c = i % columns
        for y in r..<(r + s.h) {
            for x in c..<(c + s.w) { taken.insert(y * columns + x) }
        }
        slots[item.id] = BoardSlot(col: c, row: r, span: s)
        rows = max(rows, r + s.h)
        cursor = i
    }
    return (slots, rows)
}

// MARK: - Scrolling while a tile is dragged

/// Home's scroll view, so a tile dragged to the top or bottom edge scrolls the page under it.
@Observable @MainActor
final class HomeScroller {
    var position = ScrollPosition(edge: .top)
    /// How far down the page is scrolled, and how far it can go.
    @ObservationIgnored var offset: CGFloat = 0
    @ObservationIgnored var maxOffset: CGFloat = 0
    /// Where the page is on screen, and what its top and bottom edges have over them (the status bar, Woodruff's
    /// bar, the tab bar). Kept without redrawing anything (they change all the time while scrolling).
    @ObservationIgnored var frame: CGRect = .zero
    @ObservationIgnored private var insetTop: CGFloat = 0
    @ObservationIgnored private var insetBottom: CGFloat = 0
    /// The part of the screen the page shows (screen coordinates).
    var visibleTop: CGFloat { frame.minY + insetTop }
    var visibleBottom: CGFloat { frame.maxY - insetBottom }

    func take(_ spot: HomeScrollSpot) {
        offset = spot.offset
        maxOffset = spot.maxOffset
        insetTop = spot.insetTop
        insetBottom = spot.insetBottom
    }

    /// Scrolls by [dy] points (false at the top or bottom already).
    @discardableResult func scroll(by dy: CGFloat) -> Bool {
        let y = min(max(0, offset + dy), max(0, maxOffset))
        guard abs(y - offset) >= 0.5 else { return false }
        offset = y
        position.scrollTo(y: y)
        return true
    }
}

/// How Home's scroll view reports itself.
struct HomeScrollSpot: Equatable {
    var offset: CGFloat
    var maxOffset: CGFloat
    var insetTop: CGFloat
    var insetBottom: CGFloat

    init(_ g: ScrollGeometry) {
        offset = g.contentOffset.y + g.contentInsets.top
        let visible = g.containerSize.height - g.contentInsets.top - g.contentInsets.bottom
        maxOffset = max(0, g.contentSize.height - visible)
        insetTop = g.contentInsets.top
        insetBottom = g.contentInsets.bottom
    }
}

// MARK: - Environment

private struct HomeArrangingKey: EnvironmentKey { static let defaultValue = false }
private struct InHomeBoardKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Home's tiles are being arranged: a tile's own hover lift and tilt rest.
    var homeArranging: Bool {
        get { self[HomeArrangingKey.self] }
        set { self[HomeArrangingKey.self] = newValue }
    }
    /// The tile is on a Home tab that can be arranged (its menu offers Edit Home).
    var inHomeBoard: Bool {
        get { self[InHomeBoardKey.self] }
        set { self[InHomeBoardKey.self] = newValue }
    }
}

/// Edit Home in a tile's menu (touch and hold on iPhone, right-click on the Mac), like the Home Screen's.
struct ArrangeHomeButton: View {
    @Environment(\.inHomeBoard) private var inBoard
    var body: some View {
        if inBoard {
            Button("Edit Home") { HomeLayout.shared.startArranging() }
        }
    }
}

// MARK: - A tab's tiles

/// A Home tab's tiles (Favorites, or a room) on a grid, like the iPhone's Home Screen: in the order arranged, each at
/// the size chosen. Edit (or press and hold) and they jiggle: drag one anywhere and the others move out of its way,
/// drag its corner to make it bigger or smaller, − to take it off the tab. Kept with the Home layout, so it's the
/// same on every device.
struct HomeBoard: View {
    var page: String
    var tiles: [HomeTile]
    /// What tapping a TV does (the iPhone opens its player; the Mac grows the tile into the TV's page).
    var openTV: (String) -> Void
    /// The Mac's TV zoom, on room tabs (a TV that's also in Favorites zooms from one place only).
    var zoom: Namespace.ID? = nil
    var zoomed: String? = nil

    @Environment(HomeScroller.self) private var scroller: HomeScroller?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let layout = HomeLayout.shared

    #if os(macOS)
    @State private var width: CGFloat = 900
    #else
    @State private var width: CGFloat = 361
    #endif
    /// The order while a tile is being dragged (kept when it's let go).
    @State private var liveOrder: [String]?
    @State private var drag: Drag?
    /// iPhone: held long enough to pick up, not moved yet.
    @State private var lifted: String?
    @State private var resize: Resize?
    /// Where the board is on screen, kept without redrawing for it (it changes all the time while scrolling).
    @State private var place = Place()
    @State private var scrolling: Task<Void, Never>?
    /// Back to false by themselves if a drag is cut short (a call coming in, the window losing focus), so nothing is
    /// left half-picked-up.
    @GestureState private var moving = false
    @GestureState private var sizing = false
    @State private var openSpeaker: SonosRoom?
    @State private var openLight: GoveeLight?
    @State private var openDevice: HomeDevice?
    @State private var openCamera: NestCameras.Camera?

    private struct Drag: Equatable {
        var id: String
        /// Where in the tile it was picked up, from its top-left corner.
        var grab: CGSize
        /// The pointer, on screen.
        var pointer: CGPoint
        /// The board's top-left on screen (it moves when the page scrolls under the tile).
        var board: CGPoint
        /// The tile it last moved past, so a tile of another size doesn't swap back and forth under the pointer.
        var over: String?
    }

    private struct Resize: Equatable {
        var id: String
        var startSize: CGSize
        var span: TileSpan
        /// The outline that follows the pointer exactly while the tile snaps to the grid.
        var ghost: CGSize
    }

    private final class Place {
        var origin: CGPoint = .zero
    }

    var body: some View {
        let m = BoardMetrics(width: width)
        let byID = Dictionary(tiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let order = currentOrder()
        let plan = packBoard(order.map { (id: $0, span: span(of: $0, byID[$0], m)) }, columns: m.columns)
        let arranging = layout.arranging
        ZStack(alignment: .topLeading) {
            backdrop(arranging)
            ForEach(order, id: \.self) { id in
                if let tile = byID[id], let slot = plan.slots[id] {
                    cell(tile, slot, m, arranging)
                }
            }
            if let r = resize, let slot = plan.slots[r.id] {
                let o = m.origin(slot.col, slot.row)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.75), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .frame(width: r.ghost.width, height: r.ghost.height)
                    .offset(x: o.x, y: o.y)
                    .allowsHitTesting(false)
                    .zIndex(20)
            }
        }
        .frame(height: m.height(rows: plan.rows), alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            if abs(w - width) > 0.5 { width = w }
        }
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { p in
            place.origin = p
            if drag != nil { followPage() }
        }
        .environment(\.inHomeBoard, true)
        .environment(\.homeArranging, arranging)
        .onChange(of: arranging) { _, on in
            if !on { drop(); finishResize() }
        }
        .onChange(of: moving) { _, now in if !now { drop() } }
        .onChange(of: sizing) { _, now in if !now { finishResize() } }
        .onDisappear { scrolling?.cancel(); scrolling = nil }
        .sheet(item: $openSpeaker) { r in
            NavigationStack { SpeakerDetailView(speakerID: r.id, inSheet: true) }.presentationBackground(.clear).macResizable()
        }
        .sheet(item: $openLight) { l in LightSheet(lightID: l.id).macResizable(width: 520, height: 640) }
        .sheet(item: $openDevice) { d in NavigationStack { DeviceDetailView(deviceID: d.id, inSheet: true) }.macResizable() }
        .cameraPresenter($openCamera)
    }

    // MARK: Tiles

    @ViewBuilder private func cell(_ tile: HomeTile, _ slot: BoardSlot, _ m: BoardMetrics, _ arranging: Bool) -> some View {
        let size = m.size(slot.span)
        let home = m.origin(slot.col, slot.row)
        let dragged = drag?.id == tile.id
        let up = dragged || lifted == tile.id
        let at = dragged ? dragPoint() : home
        tileView(tile, size)
            .frame(width: size.width, height: size.height)
            // While arranging, a tile's own buttons and taps rest; the layer over it takes the drags.
            .allowsHitTesting(!arranging)
            .overlay { if arranging { editLayer(tile, size, m) } }
            .modifier(Jiggle(active: arranging && !up && !reduceMotion, seed: seed(tile.id), size: size))
            .scaleEffect(up ? 1.05 : 1)
            .shadow(color: .black.opacity(up ? 0.45 : 0), radius: up ? 24 : 0, y: up ? 14 : 0)
            .offset(x: at.x, y: at.y)
            .zIndex(dragged ? 10 : (up ? 5 : 0))
            #if os(macOS)
            // Press and hold a tile to start arranging (right-click has its menu).
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in beginArranging() },
                                 including: arranging ? .none : .all)
            #endif
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    @ViewBuilder private func tileView(_ tile: HomeTile, _ size: CGSize) -> some View {
        switch tile {
        case .camera(let cam):
            LiveCameraTile(camera: cam, compact: size.width < 260, fill: true) { openCamera = cam }
        case .tv(let tv):
            HomeTVTile(tv: tv, height: size.height) { openTV(tv.id) }
                .modifier(TVZoom(id: tv.id, zoom: zoom, zoomed: zoomed))
        case .speaker(let r):
            SpeakerTile(room: r) { openSpeaker = r }
        case .light(let l):
            LightTile(light: l) { openLight = l }
        case .device(let d):
            DeviceTile(device: d) { openDevice = d }
        }
    }

    /// Over each tile while arranging: drag anywhere on it to move it, − to take it off the tab, the corner to resize.
    private func editLayer(_ tile: HomeTile, _ size: CGSize, _ m: BoardMetrics) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(moveGesture(tile.id))
            Button { remove(tile.id) } label: { RemoveBadge() }
                .buttonStyle(PressScale(scale: 0.85))
                .offset(x: -16, y: -16)
                .accessibilityLabel(page == favoritesKey ? "Remove from Favorites" : "Hide from Home")
            ResizeGrip(trailing: true, shown: true, active: resize?.id == tile.id)
                .gesture(resizeGesture(tile, size, m))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .accessibilityLabel("Resize")
        }
    }

    /// The board's empty space: press and hold to start arranging; a tap there while arranging stops.
    private func backdrop(_ arranging: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(TapGesture().onEnded { layout.stopArranging() }, including: arranging ? .all : .none)
            .gesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in beginArranging() }, including: arranging ? .none : .all)
    }

    // MARK: Order and size

    private func currentOrder() -> [String] {
        let ids = tiles.map(\.id)
        guard let live = liveOrder else { return layout.boardOrder(page, ids) }
        let present = Set(ids)
        var seen = Set<String>()
        var out = live.filter { present.contains($0) && seen.insert($0).inserted }
        for id in ids where seen.insert(id).inserted { out.append(id) }
        return out
    }

    private func span(of id: String, _ tile: HomeTile?, _ m: BoardMetrics) -> TileSpan {
        guard let tile else { return TileSpan(w: 2, h: 1) }
        if let r = resize, r.id == id { return r.span }
        let kind = tile.kind
        let saved = layout.span(page, id).flatMap { $0.count == 2 ? TileSpan(w: $0[0], h: $0[1]) : nil }
        return clamp(saved ?? kind.standard, kind, m)
    }

    private func clamp(_ s: TileSpan, _ kind: HomeTile.Kind, _ m: BoardMetrics) -> TileSpan {
        TileSpan(w: min(max(s.w, kind.smallest.w), m.columns), h: min(max(s.h, kind.smallest.h), kind.mostRows))
    }

    private func frames(_ order: [String], _ m: BoardMetrics) -> [String: CGRect] {
        let byID = Dictionary(tiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let plan = packBoard(order.map { (id: $0, span: span(of: $0, byID[$0], m)) }, columns: m.columns)
        return plan.slots.mapValues { CGRect(origin: m.origin($0.col, $0.row), size: m.size($0.span)) }
    }

    // MARK: Moving a tile

    private func moveGesture(_ id: String) -> some Gesture {
        #if os(iOS)
        // A short hold, then drag: a quick swipe still scrolls the page.
        return LongPressGesture(minimumDuration: 0.15, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($moving) { _, state, _ in state = true }
            .onChanged { value in
                switch value {
                case .second(true, .none): lift(id)
                case .second(true, .some(let d)): dragged(id, d)
                default: break
                }
            }
            .onEnded { _ in drop() }
        #else
        return DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($moving) { _, state, _ in state = true }
            .onChanged { dragged(id, $0) }
            .onEnded { _ in drop() }
        #endif
    }

    private func lift(_ id: String) {
        guard drag == nil, lifted != id else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { lifted = id }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    private func dragged(_ id: String, _ v: DragGesture.Value) {
        if drag?.id == id {
            drag?.pointer = v.location
        } else {
            let m = BoardMetrics(width: width)
            let order = currentOrder()
            guard let frame = frames(order, m)[id] else { return }
            let board = place.origin
            let start = CGPoint(x: v.startLocation.x - board.x, y: v.startLocation.y - board.y)
            if lifted != id {
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #else
                MacFeedback.snap()
                #endif
            }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                drag = Drag(id: id, grab: CGSize(width: start.x - frame.minX, height: start.y - frame.minY), pointer: v.location, board: board)
                liveOrder = order
                lifted = nil
            }
            layout.draggingTile = id
        }
        reorder()
        edgeScroll()
    }

    /// Where the dragged tile is drawn: under the pointer, where it was picked up.
    private func dragPoint() -> CGPoint {
        guard let d = drag else { return .zero }
        return CGPoint(x: d.pointer.x - d.board.x - d.grab.width, y: d.pointer.y - d.board.y - d.grab.height)
    }

    /// The page scrolled under the tile (it stays under the pointer; what's under the pointer changed).
    private func followPage() {
        guard var d = drag, d.board != place.origin else { return }
        d.board = place.origin
        drag = d
        reorder()
    }

    /// Moves the dragged tile to where the pointer is: over another tile, it takes that tile's place and the rest
    /// move out of the way; below them all, it goes last.
    private func reorder() {
        guard var d = drag, var order = liveOrder, let from = order.firstIndex(of: d.id) else { return }
        let m = BoardMetrics(width: width)
        let f = frames(order, m)
        let p = CGPoint(x: d.pointer.x - d.board.x, y: d.pointer.y - d.board.y)
        var to: Int?
        if let over = order.first(where: { $0 != d.id && f[$0]?.contains(p) == true }) {
            if over != d.over { to = order.firstIndex(of: over) }
            d.over = over
        } else {
            d.over = nil
            let bottom = f.filter { $0.key != d.id }.map { $0.value.maxY }.max() ?? 0
            if p.y > bottom + 6 && from != order.count - 1 { to = order.count - 1 }
        }
        if d.over != drag?.over { drag = d }
        guard let to, to != from else { return }
        order.remove(at: from)
        order.insert(d.id, at: min(to, order.count))
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { liveOrder = order }
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    /// Let go: the tile settles into its place, and the new order is kept (and goes to the family's other devices).
    private func drop() {
        scrolling?.cancel()
        scrolling = nil
        if drag != nil, let order = liveOrder {
            let shown = currentOrder()
            if shown != layout.boardOrder(page, tiles.map(\.id)) || layout.boards[page] == nil { layout.setBoard(page, order) }
        }
        guard drag != nil || lifted != nil || liveOrder != nil else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            drag = nil
            lifted = nil
            liveOrder = nil
        }
        if resize == nil { layout.draggingTile = nil }
    }

    // MARK: Scrolling at the edges

    /// How fast to scroll for where the pointer is: faster the closer it is to the top or bottom edge.
    private func edgeSpeed() -> CGFloat {
        guard let scroller, let d = drag else { return 0 }
        let y = d.pointer.y, zone: CGFloat = 90
        let top = scroller.visibleTop, bottom = scroller.visibleBottom
        guard bottom - top > zone * 2 else { return 0 }
        if y < top + zone { return -max(3, (top + zone - y) / zone * 20) }
        if y > bottom - zone { return max(3, (y - (bottom - zone)) / zone * 20) }
        return 0
    }

    private func edgeScroll() {
        guard edgeSpeed() != 0 else {
            scrolling?.cancel()
            scrolling = nil
            return
        }
        guard scrolling == nil else { return }
        scrolling = Task { @MainActor in
            while !Task.isCancelled {
                let speed = edgeSpeed()
                guard speed != 0, let scroller, scroller.scroll(by: speed) else { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            scrolling = nil
        }
    }

    // MARK: Resizing a tile

    private func resizeGesture(_ tile: HomeTile, _ size: CGSize, _ m: BoardMetrics) -> some Gesture {
        return DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .updating($sizing) { _, state, _ in state = true }
            .onChanged { v in
                let kind = tile.kind
                let start = resize?.id == tile.id ? (resize?.startSize ?? size) : size
                let least = m.size(clamp(kind.smallest, kind, m))
                let most = m.size(TileSpan(w: m.columns, h: kind.mostRows))
                let ghost = CGSize(width: min(max(start.width + v.translation.width, least.width), most.width),
                                   height: min(max(start.height + v.translation.height, least.height), most.height))
                let span = clamp(m.span(nearest: ghost), kind, m)
                if resize?.id != tile.id {
                    resize = Resize(id: tile.id, startSize: size, span: clamp(m.span(nearest: size), kind, m), ghost: ghost)
                    layout.draggingTile = tile.id
                }
                resize?.ghost = ghost
                if span != resize?.span {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { resize?.span = span }
                    #if os(iOS)
                    UISelectionFeedbackGenerator().selectionChanged()
                    #else
                    MacFeedback.snap()
                    #endif
                }
            }
            .onEnded { _ in finishResize() }
    }

    private func finishResize() {
        guard let r = resize else { return }
        layout.setSpan(page, r.id, [r.span.w, r.span.h])
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { resize = nil }
        if drag == nil { layout.draggingTile = nil }
    }

    // MARK: Other

    private func remove(_ id: String) {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        layout.removeFromBoard(page, id)
    }

    private func beginArranging() {
        guard !layout.arranging else { return }
        layout.startArranging()
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #else
        MacFeedback.snap()
        #endif
    }

    /// The same small number for a tile every time, so each jiggles a little differently from its neighbours.
    private func seed(_ id: String) -> Int {
        id.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    }
}

// MARK: - Pieces

/// The gentle wobble of tiles being arranged, like app icons in jiggle mode. Big tiles wobble less.
private struct Jiggle: ViewModifier {
    var active: Bool
    var seed: Int
    var size: CGSize

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: nil, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = Double(seed % 628) / 100
            let speed = 24 + Double(seed % 9)
            let amount = active ? min(1.5, max(0.45, 170 / Double(max(size.width, size.height, 1)))) : 0
            content
                .rotationEffect(.degrees(sin(t * speed + phase) * amount))
                .offset(y: active ? cos(t * speed * 0.85 + phase) * 0.6 : 0)
        }
    }
}

/// The − at a tile's corner while arranging.
private struct RemoveBadge: View {
    var body: some View {
        Image(systemName: "minus")
            .font(.system(size: 13, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color(white: 0.3)))
            .overlay(Circle().strokeBorder(.white.opacity(0.28)))
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            .padding(6)
            .contentShape(Circle())
    }
}

/// The Mac's zoom from a TV's tile into its page (room tabs only).
private struct TVZoom: ViewModifier {
    var id: String
    var zoom: Namespace.ID?
    var zoomed: String?

    @ViewBuilder func body(content: Content) -> some View {
        if let zoom {
            content
                .matchedGeometryEffect(id: id, in: zoom, isSource: zoomed != id)
                .opacity(zoomed == id ? 0 : 1)
        } else {
            content
        }
    }
}
