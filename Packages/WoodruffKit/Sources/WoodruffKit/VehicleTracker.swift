import Foundation
// (On a Mac, Foundation alone has the box and point types without their arithmetic.)
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Vehicle Alerts: what counts as a vehicle arriving. The Mac that watches a camera finds the vehicles in each picture
// (Apple's object detector) and hands them here with how the picture changed; this says which of them is news. It is
// plain arithmetic on boxes and times, so it's tested without a camera.

/// Where a camera is, as far as its name and its room say. A camera inside the house is never watched for vehicles:
/// what the detector calls a car in a bedroom (a toy, a picture on a screen) isn't one, and it went out as an alert.
public enum VehiclePlace {
    /// Words for a room inside a house.
    private static let inside: Set<String> = [
        "room", "bedroom", "kitchen", "living", "dining", "nursery", "office", "den", "hall", "hallway", "basement",
        "bathroom", "bath", "playroom", "study", "loft", "attic", "closet", "laundry", "pantry", "stairs", "foyer",
        "lounge", "indoor", "indoors", "inside", "upstairs", "downstairs",
    ]
    /// Words for a place a vehicle can be, or that looks out on one. ("Front" and "back" aren't among them: a front
    /// room and a back bedroom are rooms.)
    private static let outside: Set<String> = [
        "driveway", "garage", "carport", "street", "road", "yard", "backyard", "porch", "door", "doorbell", "gate",
        "alley", "patio", "deck", "garden", "lot", "parking", "outside", "outdoor", "outdoors", "exterior", "shed",
        "barn", "pool", "fence", "curb", "kerb",
    ]

    /// Whether a camera called [name], in [room], is inside the house: its name or room has a word for a room
    /// ("Kyler Room camera", the kitchen) and none for a place a vehicle can be (the driveway, the front door, the
    /// garage, a yard). A camera whose name says neither counts as outside, and can be watched.
    public static func indoors(name: String, room: String?) -> Bool {
        let words = Set((name + " " + (room ?? "")).lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !words.isDisjoint(with: inside) && words.isDisjoint(with: outside)
    }
}

/// A vehicle found in one of a camera's pictures: what the detector called it, how sure it was, and where it is (a
/// box in shares of the picture, 0 to 1, across from its left and down from its top).
public struct VehicleSighting: Sendable, Equatable {
    public var label: String
    public var confidence: Double
    public var box: CGRect

    public init(label: String, confidence: Double, box: CGRect) {
        self.label = label
        self.confidence = confidence
        self.box = box
    }

    /// How much two boxes share of what they cover together, and how much of the smaller one the other covers.
    public static func overlap(_ a: CGRect, _ b: CGRect) -> (shared: Double, ofSmaller: Double) {
        let both = a.intersection(b)
        guard !both.isNull, both.width > 0, both.height > 0 else { return (0, 0) }
        let i = Double(both.width) * Double(both.height)
        let aa = Double(a.width) * Double(a.height), ab = Double(b.width) * Double(b.height)
        guard aa > 0, ab > 0 else { return (0, 0) }
        return (i / (aa + ab - i), i / min(aa, ab))
    }

    /// Two boxes that are the same vehicle: they mostly cover each other, or one is a part of the other (a vehicle
    /// cut off at the edge of the part of the picture it was found in).
    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        let o = overlap(a, b)
        return o.shared >= 0.3 || o.ofSmaller >= 0.7
    }

    /// A vehicle found more than once (in the whole picture and in a part of it) kept once: the surest finding, with
    /// the largest box among the findings about as sure (a part of the picture can cut a vehicle off).
    public static func merged(_ found: [VehicleSighting]) -> [VehicleSighting] {
        var kept: [VehicleSighting] = []
        for s in found.sorted(by: { $0.confidence > $1.confidence }) {
            if let i = kept.firstIndex(where: { same($0.box, s.box) }) {
                let area: CGFloat = s.box.width * s.box.height
                let had: CGFloat = kept[i].box.width * kept[i].box.height
                if area > had, s.confidence >= kept[i].confidence * 0.8 { kept[i].box = s.box }
            } else {
                kept.append(s)
            }
        }
        return kept
    }
}

/// The part of a camera's picture where a vehicle counts (the driveway): an outline, in the picture's shares (0 to 1,
/// across from its left and down from its top).
public struct VehicleZone: Sendable, Equatable {
    public var points: [CGPoint]

    public init(points: [CGPoint]) { self.points = points }

    /// As a Mac's settings keep it: "0.28,0.20 0.80,0.22 0.86,0.34". Nil unless it's three points or more.
    public init?(_ text: String) {
        var read: [CGPoint] = []
        for pair in text.split(whereSeparator: { $0 == " " || $0 == ";" || $0 == "\n" }) {
            let xy = pair.split(separator: ",")
            guard xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]) else { return nil }
            read.append(CGPoint(x: x, y: y))
        }
        guard read.count >= 3 else { return nil }
        points = read
    }

    public func contains(_ p: CGPoint) -> Bool {
        var inside = false
        var j = points.count - 1
        for i in points.indices {
            let a = points[i], b = points[j]
            if (a.y > p.y) != (b.y > p.y) {
                let crossing: CGFloat = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                if p.x < crossing { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// The share of [box] inside the outline (looked at on a grid of points across it).
    public func share(of box: CGRect) -> Double {
        let n = 8
        var hits = 0
        for iy in 0..<n {
            for ix in 0..<n {
                let across: CGFloat = (CGFloat(ix) + 0.5) / CGFloat(n)
                let down: CGFloat = (CGFloat(iy) + 0.5) / CGFloat(n)
                let x: CGFloat = box.minX + box.width * across
                let y: CGFloat = box.minY + box.height * down
                if contains(CGPoint(x: x, y: y)) { hits += 1 }
            }
        }
        return Double(hits) / Double(n * n)
    }

    /// A vehicle in [box] is on it: where its wheels are (the foot of its box) is inside the outline, or a good part
    /// of the whole box is.
    public func holds(_ box: CGRect) -> Bool {
        let foot: CGFloat = box.maxY - box.height * 0.1
        return contains(CGPoint(x: box.midX, y: foot)) || share(of: box) >= 0.35
    }
}

/// How a camera's picture changes from one look to the next, on a small grid of brightness values (0 to 255): which
/// parts changed and when, and whether it was the whole picture at once (the light, night vision coming on), which
/// says nothing about what's in it.
public struct VehicleMotion: Sendable {
    public private(set) var width = 0
    public private(set) var height = 0
    private var previous: [Float] = []
    /// When each cell last changed, in seconds (0: never).
    private var changedAt: [TimeInterval] = []
    /// The share of the picture that changed at the last look.
    public private(set) var share = 0.0
    /// The last look's change was the light: most of the picture at once, or all of it brighter or darker.
    public private(set) var lightChanged = false

    public init() {}

    public mutating func look(at grid: [Float], width: Int, height: Int, now: Date) {
        defer { previous = grid }
        guard width > 0, height > 0, grid.count == width * height else { return }
        if previous.count != grid.count || self.width != width {
            self.width = width
            self.height = height
            changedAt = [TimeInterval](repeating: 0, count: grid.count)
            share = 0
            lightChanged = false
            return
        }
        var delta = [Float](repeating: 0, count: grid.count)
        for i in grid.indices { delta[i] = grid[i] - previous[i] }
        // Against the change of the picture as a whole (the camera's exposure drifting), not against none at all.
        let middle = delta.sorted()[delta.count / 2]
        var changed: [Int] = []
        for i in delta.indices where abs(delta[i] - middle) > 16 { changed.append(i) }
        share = Double(changed.count) / Double(grid.count)
        lightChanged = share > 0.4 || abs(middle) > 22
        guard !lightChanged else { return }
        let t = now.timeIntervalSinceReferenceDate
        for i in changed { changedAt[i] = t }
    }

    /// The share of [box]'s part of the picture that changed in the [seconds] up to [now].
    public func share(in box: CGRect, within seconds: TimeInterval, of now: Date) -> Double {
        guard width > 0, height > 0, changedAt.count == width * height else { return 0 }
        let x0 = max(0, Int((box.minX * CGFloat(width)).rounded(.down)))
        let x1 = min(width - 1, Int((box.maxX * CGFloat(width)).rounded(.up)) - 1)
        let y0 = max(0, Int((box.minY * CGFloat(height)).rounded(.down)))
        let y1 = min(height - 1, Int((box.maxY * CGFloat(height)).rounded(.up)) - 1)
        guard x1 >= x0, y1 >= y0 else { return 0 }
        let since = now.timeIntervalSinceReferenceDate - seconds
        var n = 0
        for y in y0...y1 {
            for x in x0...x1 {
                let at = changedAt[y * width + x]
                if at > 0, at >= since { n += 1 }
            }
        }
        return Double(n) / Double((x1 - x0 + 1) * (y1 - y0 + 1))
    }
}

/// Follows the vehicles in a camera's picture from one look to the next and says when one has arrived: a vehicle
/// that wasn't there, on the zone (the driveway) at two looks, where the picture changed as it turned up. Vehicles
/// that stand where they are (parked across the street, or on the drive since before) are scenery; one driving past
/// is gone before its second look; one the detector only now makes out, with nothing having moved, is passed over.
public struct VehicleTracker: Sendable {
    public struct Rules: Sendable {
        /// How sure the detector has to be.
        public var minConfidence = 0.5
        /// Looks a new vehicle has to be on the zone at before it's news.
        public var confirmLooks = 2
        /// Of its box's part of the picture, how much has to have changed lately for it to have arrived.
        public var movedShare = 0.2
        public var movedWithin: TimeInterval = 8
        /// Seen this long away from the zone: scenery.
        public var settleAfter: TimeInterval = 20
        /// A vehicle not found for this long is no longer followed...
        public var forgetAfter: TimeInterval = 30
        /// ...but where it stood is remembered this long (the detector loses a parked car now and then, and at night).
        public var rememberFor: TimeInterval = 20 * 60
        /// One arrival at most in this long, unless the zone went quiet in between (another vehicle).
        public var cooldown: TimeInterval = 180
        public var quietAfter: TimeInterval = 45
        /// After the light changes, what turns up for this long is scenery made out anew.
        public var lightGrace: TimeInterval = 10

        public init() {}
    }

    public enum Outcome: Sendable, Equatable {
        /// A vehicle arrived on the zone.
        case arrived(VehicleSighting)
        /// A vehicle turned up on the zone and wasn't news, and why.
        case passedOver(VehicleSighting, why: String)
    }

    struct Track: Sendable {
        var sighting: VehicleSighting
        var firstSeen: Date
        var lastSeen: Date
        /// Looks in a row it wasn't found at.
        var missed = 0
        /// Looks it was found on the zone at, since it turned up there.
        var zoneLooks = 0
        /// The picture changed where it is, around when it turned up.
        var moved = false
        /// Nothing more to say about it: scenery, or already told about. Where it stood then.
        var settled = false
        var home: CGRect?
        /// It has been passed over once already (said once, not at every look).
        var said = false
    }

    struct Place: Sendable {
        var box: CGRect
        var until: Date
    }

    public var rules: Rules
    private(set) var tracks: [Track] = []
    private(set) var places: [Place] = []
    private var lightUntil = Date.distantPast
    private var lastArrival = Date.distantPast
    private var lastBusy = Date.distantPast
    private var quiet = true

    public init(rules: Rules = Rules()) { self.rules = rules }

    /// The vehicles followed now (found at the last look or lately).
    public var following: Int { tracks.count }

    /// One look: the vehicles [found] in the picture, how the picture has been changing ([motion], already told of
    /// this picture), and the [zone] where a vehicle counts (none: anywhere).
    public mutating func look(at found: [VehicleSighting], motion: VehicleMotion, zone: VehicleZone?, now: Date) -> [Outcome] {
        var out: [Outcome] = []
        places.removeAll { $0.until < now }
        if motion.lightChanged { lightUntil = now.addingTimeInterval(rules.lightGrace) }
        let light = now < lightUntil
        var unmatched = VehicleSighting.merged(found.filter { $0.confidence >= rules.minConfidence })

        // Each vehicle followed: found again (the finding that covers it best), or missed at this look.
        for i in tracks.indices {
            var best: (index: Int, shared: Double)?
            for (j, s) in unmatched.enumerated() where VehicleSighting.same(tracks[i].sighting.box, s.box) {
                let shared = VehicleSighting.overlap(tracks[i].sighting.box, s.box).shared
                if best == nil || shared > best!.shared { best = (j, shared) }
            }
            if let best {
                tracks[i].sighting = unmatched.remove(at: best.index)
                tracks[i].lastSeen = now
                tracks[i].missed = 0
            } else {
                tracks[i].missed += 1
            }
        }

        // The rest are new. Scenery from the start when the light has just changed (the detector making out what was
        // there all along), or where a vehicle stood lately with nothing having moved there since.
        for s in unmatched {
            var t = Track(sighting: s, firstSeen: now, lastSeen: now)
            t.moved = hasMoved(s.box, motion, now)
            if light || (!t.moved && places.contains(where: { VehicleSighting.same($0.box, s.box) })) {
                t.settled = true
                t.home = s.box
            }
            tracks.append(t)
        }

        for i in tracks.indices where tracks[i].missed == 0 {
            let s = tracks[i].sighting
            // A settled one that's no longer where it stood is on the move: looked at afresh.
            if tracks[i].settled, let home = tracks[i].home, !VehicleSighting.same(home, s.box) {
                tracks[i].settled = false
                tracks[i].home = nil
                tracks[i].zoneLooks = 0
                tracks[i].moved = false
                tracks[i].firstSeen = now
            }
            guard !tracks[i].settled, !light else { continue }
            if !tracks[i].moved { tracks[i].moved = hasMoved(s.box, motion, now) }
            let onZone = zone?.holds(s.box) ?? true
            if onZone {
                tracks[i].zoneLooks += 1
                lastBusy = now
            } else {
                tracks[i].zoneLooks = 0
            }
            if onZone, tracks[i].zoneLooks >= rules.confirmLooks {
                tracks[i].settled = true
                tracks[i].home = s.box
                if !tracks[i].moved {
                    if !tracks[i].said { out.append(.passedOver(s, why: "nothing moved there")) }
                    tracks[i].said = true
                } else if now.timeIntervalSince(lastArrival) < rules.cooldown, !quiet {
                    out.append(.passedOver(s, why: "too soon after the last one"))
                } else {
                    out.append(.arrived(s))
                    lastArrival = now
                    quiet = false
                }
            } else if !onZone, now.timeIntervalSince(tracks[i].firstSeen) >= rules.settleAfter {
                tracks[i].settled = true
                tracks[i].home = s.box
            }
        }
        if now.timeIntervalSince(lastBusy) > rules.quietAfter { quiet = true }

        // No longer followed: one that never came to anything, after two looks without it; a settled one after a
        // while, its place remembered.
        var kept: [Track] = []
        for t in tracks {
            if t.missed == 0 { kept.append(t); continue }
            let gone = t.settled ? now.timeIntervalSince(t.lastSeen) >= rules.forgetAfter : t.missed >= 2
            if !gone { kept.append(t); continue }
            if t.settled { places.append(Place(box: t.home ?? t.sighting.box, until: now.addingTimeInterval(rules.rememberFor))) }
        }
        tracks = kept
        if places.count > 40 { places.removeFirst(places.count - 40) }
        return out
    }

    private func hasMoved(_ box: CGRect, _ motion: VehicleMotion, _ now: Date) -> Bool {
        motion.share(in: box, within: rules.movedWithin, of: now) >= rules.movedShare
    }
}
