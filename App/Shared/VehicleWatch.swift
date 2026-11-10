#if os(macOS)
import SwiftUI
import AppKit
import Vision
import CoreML
import ImageIO
import os
import WoodruffKit

/// Vehicle Alerts (Mac): Google's camera API sends no vehicle detections, so the Mac that sends the family's alerts
/// (the Mac Studio) watches a camera's live stream itself. About once a second Apple's object detector
/// (`VehicleDetector`) finds the vehicles in the picture, and `VehicleTracker` says when one has arrived: a vehicle
/// that wasn't there, on the camera's zone (its driveway) at two looks, where the picture changed as it turned up.
/// Cars parked in view, cars driving past and changes of light are not news. An arrival is an alert, at most one
/// every three minutes per camera unless the drive went quiet in between. In Test Mode (the default) it only notes
/// what it saw, with the frame, under the switch and in a log of its own beside the frames.
/// (It used to look for a change in the picture's brightness and ask Vision what the changed patch showed. In its
/// first days every vehicle that named was a neighbour's parked car as the light changed, and it missed the ones
/// that came.)
@Observable @MainActor
final class VehicleWatch {
    static let shared = VehicleWatch()
    nonisolated static let log = Logger(subsystem: "com.woodruff.family", category: "vehicles")

    /// The cameras watched.
    var watched: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "vehicle.cameras") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "vehicle.cameras"); sync() }
    }
    /// Only noted here, no alerts to the iPhones.
    var testMode: Bool {
        get { UserDefaults.standard.object(forKey: "vehicle.test") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "vehicle.test") }
    }
    private(set) var last: (at: Date, camera: String, file: URL)?
    private(set) var framesPerMinute = 0

    /// The Mac that sends the family's alerts does the watching (the Mac Studio, the updater's hub); the other Macs
    /// only show its switches. (A Mac with no updater watches for itself.)
    static var watchesHere: Bool { PushRelay.updaterRole() != "follower" }
    /// The cameras whose pictures it keeps playing on this Mac (none on a Mac that doesn't do the watching).
    var keeps: Set<String> { Self.watchesHere ? watched : [] }

    /// How sure the detector has to be (`defaults write com.woodruff.family.mac vehicle.minConfidence 0.5`).
    private var minConfidence: Double { UserDefaults.standard.object(forKey: "vehicle.minConfidence") as? Double ?? 0.5 }

    private static let gw = 64, gh = 36
    private struct Scene {
        var motion = VehicleMotion()
        var tracker = VehicleTracker()
        var lastMotion: Date = .distantPast
    }
    @ObservationIgnored private var scenes: [String: Scene] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    // For the heartbeat: looks, the most vehicles followed at once, arrivals, vehicles passed over, how much of the
    // picture changes from one look to the next.
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var inView = 0
    @ObservationIgnored private var detections = 0
    @ObservationIgnored private var passed = 0
    @ObservationIgnored private var changeSum: Double = 0
    @ObservationIgnored private var beatAt = Date()
    @ObservationIgnored private var lastFrame: (jpeg: Data, camera: String)?
    @ObservationIgnored private var lastPassedSaved = Date.distantPast

    static var folder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let f = base.appendingPathComponent("Woodruff Family/Vehicles", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    func start() { sync() }

    /// Starts or stops watching to match the switches.
    private func sync() {
        let on = keeps
        for id in CameraStreams.shared.pinned where !on.contains(id) && !CameraStreams.shared.warmed.contains(id) { CameraStreams.shared.stopKeeping(id) }
        if on.isEmpty || Demo.isOn {
            loop?.cancel(); loop = nil
            if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
            return
        }
        VehicleDetector.shared.prepare()
        guard loop == nil else { return }
        // Not slowed down while the app is in the background (App Nap would sample a frame now and then at best).
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Watching the driveway for vehicles")
        note("vehicle watch: on for \(on.count) camera(s), test mode \(testMode ? "on" : "off")")
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                // Every second while anything has moved in the last half minute; every two while the drive is still
                // (the first change seen brings it back to every second, before a vehicle's second look).
                let busy = self?.scenes.values.contains { Date().timeIntervalSince($0.lastMotion) < 30 } ?? true
                try? await Task.sleep(nanoseconds: busy ? 1_000_000_000 : 2_000_000_000)
            }
        }
    }

    private func tick() async {
        for id in keeps {
            guard let cam = NestCameras.shared.cameras.first(where: { $0.id == id }), cam.webRTC else { continue }
            let p = CameraStreams.shared.keepPlaying(cam)
            // 960 pixels across: a car at the street is a few dozen of them (at 480 the detector loses it at night).
            guard p.isLive, let jpeg = await p.frameJPEG(maxSide: 960), let image = Self.cgImage(jpeg) else { continue }
            frames += 1
            await look(at: image, jpeg: jpeg, camera: cam)
        }
        // (Asked for again, now and then, when the detector couldn't be had.)
        VehicleDetector.shared.prepare()
        beat()
    }

    private func look(at image: CGImage, jpeg: Data, camera cam: NestCameras.Camera) async {
        guard let grey = Self.grey(image) else { return }
        lastFrame = (jpeg, cam.name)
        let now = Date()
        var scene = scenes[cam.id] ?? Scene()
        scene.motion.look(at: grey, width: Self.gw, height: Self.gh, now: now)
        changeSum += scene.motion.share
        if scene.motion.share > 0.004 { scene.lastMotion = now }
        scenes[cam.id] = scene
        // (Nothing else touches this camera's scene while the detector works: one look follows another.)
        guard let found = await VehicleDetector.shared.vehicles(in: image) else { return }
        scene.tracker.rules.minConfidence = minConfidence
        let outcomes = scene.tracker.look(at: found, motion: scene.motion, zone: zone(for: cam), now: now)
        scenes[cam.id] = scene
        inView = max(inView, scene.tracker.following)
        for outcome in outcomes {
            switch outcome {
            case .arrived(let s):
                detections += 1
                let sure = Int((s.confidence * 100).rounded())
                // The frame kept has a box drawn where the vehicle is; the alert's picture is the frame as it is.
                let file = Self.keep(Self.marked(image, s.box) ?? jpeg, note: "\(cam.name)-\(s.label)-\(sure)")
                if let file { last = (now, cam.name, file) }
                note("vehicle seen on \(cam.name): \(s.label) \(sure)% at \(Self.place(s.box)) (test mode \(testMode ? "on: no alert" : "off: alert sent"))")
                if !testMode { NestAlerts.shared.postVehicle(camera: cam, jpeg: jpeg) }
            case .passedOver(let s, let why):
                passed += 1
                let sure = Int((s.confidence * 100).rounded())
                note("vehicle passed over on \(cam.name): \(s.label) \(sure)% at \(Self.place(s.box)), \(why)")
                // Test Mode: its frame too, to see whether passing it over was right (one every 15 s at most).
                if testMode, now.timeIntervalSince(lastPassedSaved) > 15, let frame = Self.marked(image, s.box) {
                    lastPassedSaved = now
                    _ = Self.keep(frame, note: "\(cam.name)-\(s.label)-\(sure)-\(why)", in: "Passed over")
                }
            }
        }
    }

    /// Where a vehicle counts on a camera's picture (its driveway), by the camera's id or name: this Mac's own
    /// (`defaults write com.woodruff.family.mac vehicle.zones -dict-add "<camera's name>" "<x,y x,y …>"`, in shares
    /// of the picture from its top left), else the one built in for it. None: anywhere in the picture.
    private func zone(for cam: NestCameras.Camera) -> VehicleZone? {
        let own = UserDefaults.standard.dictionary(forKey: "vehicle.zones") as? [String: String] ?? [:]
        let text = own[cam.id] ?? own[cam.name] ?? Self.zones[cam.name.lowercased()]
        return text.flatMap { VehicleZone($0) }
    }

    /// The family's Front Driveway camera: the driveway, its apron and the near lane right in front of it (not the
    /// street beyond, the kerb either side, or the neighbours' drives, where cars are always parked).
    private static let zones = [
        "front driveway camera": "0.28,0.20 0.80,0.22 0.86,0.34 0.72,0.41 0.71,1.00 0.08,1.00 0.02,0.62 0.10,0.60 0.32,0.30",
    ]

    private static func place(_ box: CGRect) -> String {
        String(format: "%.2f %.2f %.2f×%.2f", Double(box.minX), Double(box.minY), Double(box.width), Double(box.height))
    }

    /// What it saw: in the system's log, and in a file of its own beside the frames (`log.txt`, its newest lines).
    private func note(_ line: String) {
        Self.log.notice("\(line, privacy: .public)")
        guard let file = Self.folder?.appendingPathComponent("log.txt") else { return }
        var text = (try? Data(contentsOf: file)) ?? Data()
        if text.count > 400_000 { text = Data(text.suffix(200_000)) }
        text.append(Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8))
        try? text.write(to: file, options: .atomic)
    }

    /// Every ten minutes in the log: looks, the most vehicles followed at once, arrivals, vehicles passed over.
    private func beat() {
        let mins = Date().timeIntervalSince(beatAt) / 60
        guard mins >= 10 else { return }
        framesPerMinute = Int(Double(frames) / mins)
        let changing = frames > 0 ? changeSum / Double(frames) * 100 : 0
        note("vehicle watch: \(frames) looks, \(inView) vehicle(s) followed at most, \(detections) seen, \(passed) passed over in the last \(Int(mins)) minutes; \(String(format: "%.1f", changing))% of the picture changing; detector \(VehicleDetector.shared.state.words)")
        // Test Mode: one frame each time, to see what the camera sees (light, night vision).
        if testMode, let f = lastFrame { _ = Self.keep(f.jpeg, note: "\(f.camera)-sample", in: "Samples") }
        frames = 0; inView = 0; detections = 0; passed = 0; changeSum = 0; beatAt = Date()
    }

    // MARK: Pictures

    private nonisolated static func cgImage(_ jpeg: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// The picture as 64×36 brightness values (0–255).
    private nonisolated static func grey(_ image: CGImage) -> [Float]? {
        var px = [UInt8](repeating: 0, count: gw * gh)
        guard let ctx = CGContext(data: &px, width: gw, height: gh, bitsPerComponent: 8, bytesPerRow: gw,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: gw, height: gh))
        // CGContext's rows run bottom to top: flipped so row 0 is the picture's top, like the crop's coordinates.
        var out = [Float](repeating: 0, count: gw * gh)
        for y in 0..<gh { for x in 0..<gw { out[y * gw + x] = Float(px[(gh - 1 - y) * gw + x]) } }
        return out
    }

    /// The picture with a box drawn where a vehicle was found (for the frames kept to look at later).
    private nonisolated static func marked(_ image: CGImage, _ box: CGRect) -> Data? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Core Graphics measures up from the bottom; the box is measured down from the top.
        let rect = CGRect(x: box.minX * CGFloat(w), y: (1 - box.maxY) * CGFloat(h), width: box.width * CGFloat(w), height: box.height * CGFloat(h))
        ctx.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1))
        ctx.setLineWidth(max(2, CGFloat(w) / 320))
        ctx.stroke(rect)
        guard let drawn = ctx.makeImage() else { return nil }
        return jpeg(drawn)
    }

    private nonisolated static func jpeg(_ image: CGImage) -> Data? {
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? d as Data : nil
    }

    /// The frame saved for looking at later (the newest 200 are kept).
    private static func keep(_ jpeg: Data, note: String, in sub: String? = nil) -> URL? {
        guard var f = folder else { return nil }
        if let sub {
            f = f.appendingPathComponent(sub, isDirectory: true)
            try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let safe = note.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
        let file = f.appendingPathComponent("\(stamp)-\(safe).jpg")
        guard (try? jpeg.write(to: file, options: .atomic)) != nil else { return nil }
        if let all = try? FileManager.default.contentsOfDirectory(at: f, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }),
           all.count > 200 {
            for old in all.prefix(all.count - 200) { try? FileManager.default.removeItem(at: old) }
        }
        return file
    }
}


/// Apple's object detector for Vehicle Alerts: YOLOv3, from Apple's own Core ML models, which finds the cars, trucks,
/// buses and motorbikes in a picture and where they are. It isn't part of the app: the Mac that watches gets it from
/// Apple once (62 MB), keeps it beside its frames, and uses it from there after that.
@Observable @MainActor
final class VehicleDetector {
    static let shared = VehicleDetector()

    enum State: Equatable {
        case none, getting, ready, failed(String)
        var words: String {
            switch self {
            case .none: return "not asked for"
            case .getting: return "being got"
            case .ready: return "ready"
            case .failed(let why): return "not had (\(why))"
            }
        }
    }
    private(set) var state: State = .none

    /// The model, usable from any thread (Vision's own object; one look at a time uses it).
    private final class Model: @unchecked Sendable {
        let vision: VNCoreMLModel
        init(_ vision: VNCoreMLModel) { self.vision = vision }
    }
    @ObservationIgnored private var model: Model?
    @ObservationIgnored private var lastTry = Date.distantPast

    private nonisolated static let address = URL(string: "https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3/YOLOv3Int8LUT.mlmodel")!
    private nonisolated static let name = "YOLOv3Int8LUT"
    /// What it calls the vehicles it finds.
    private nonisolated static let vehicles: Set<String> = ["car", "truck", "bus", "motorbike", "motorcycle"]

    /// Gets it ready: from where it's kept, or from Apple the first time. Again ten minutes after it couldn't be had.
    func prepare() {
        guard model == nil, state != .getting, Date().timeIntervalSince(lastTry) > 600,
              let folder = VehicleWatch.folder?.deletingLastPathComponent().appendingPathComponent("Models", isDirectory: true) else { return }
        lastTry = Date()
        state = .getting
        Task { [weak self] in
            let result = await VehicleDetector.load(in: folder)
            guard let self else { return }
            switch result {
            case .success(let m):
                self.model = m
                self.state = .ready
                VehicleWatch.log.notice("vehicle detector: ready")
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
                VehicleWatch.log.notice("vehicle detector: not had: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private nonisolated static func load(in folder: URL) async -> Result<Model, Error> {
        let fm = FileManager.default
        let compiled = folder.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: compiled.path) {
                let (downloaded, response) = try await URLSession.shared.download(from: address)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                // Core ML makes its own copy to use, from the file as Apple gives it (which has to have its name).
                let source = folder.appendingPathComponent("\(name).mlmodel")
                try? fm.removeItem(at: source)
                try fm.moveItem(at: downloaded, to: source)
                let made = try await MLModel.compileModel(at: source)
                try? fm.removeItem(at: compiled)
                try fm.moveItem(at: made, to: compiled)
                try? fm.removeItem(at: source)
            }
            let ml = try MLModel(contentsOf: compiled)
            let vision = try VNCoreMLModel(for: ml)
            return .success(Model(vision))
        } catch {
            // A copy that can't be used (cut short, or from another version of the system) isn't kept: it's got again.
            try? fm.removeItem(at: compiled)
            return .failure(error)
        }
    }

    /// The vehicles in [image], or nil while the detector isn't ready. Looked for in the whole picture and again in
    /// four overlapping parts of it (which finds the small ones at the street, and more at night).
    func vehicles(in image: CGImage) async -> [VehicleSighting]? {
        guard let model else { return nil }
        return await Task.detached(priority: .utility) { VehicleDetector.find(in: image, with: model) }.value
    }

    private nonisolated static func find(in image: CGImage, with model: Model) -> [VehicleSighting] {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var parts = [CGRect(x: 0, y: 0, width: 1, height: 1)]
        for (x, y) in [(0.0, 0.0), (0.4, 0.0), (0.0, 0.4), (0.4, 0.4)] { parts.append(CGRect(x: x, y: y, width: 0.6, height: 0.6)) }
        var found: [VehicleSighting] = []
        for part in parts {
            let whole = part.width >= 1
            let pixels = CGRect(x: part.minX * w, y: part.minY * h, width: part.width * w, height: part.height * h).integral
            guard let piece = whole ? image : image.cropping(to: pixels) else { continue }
            let request = VNCoreMLRequest(model: model.vision)
            request.imageCropAndScaleOption = .scaleFill
            try? VNImageRequestHandler(cgImage: piece, options: [:]).perform([request])
            for o in (request.results as? [VNRecognizedObjectObservation]) ?? [] {
                guard let best = o.labels.first, vehicles.contains(best.identifier) else { continue }
                // Vision measures a box up from the bottom of what it was shown: here it's down from the top of the
                // whole picture.
                let b = o.boundingBox
                let box = CGRect(x: part.minX + b.minX * part.width, y: part.minY + (1 - b.maxY) * part.height,
                                 width: b.width * part.width, height: b.height * part.height)
                found.append(VehicleSighting(label: best.identifier, confidence: Double(best.confidence), box: box))
            }
        }
        return found
    }
}

/// The Mac's own Settings window (⌘,) → Notifications: which cameras the Mac watches for vehicles.
struct VehicleAlertsSection: View {
    private let watch = VehicleWatch.shared
    private let detector = VehicleDetector.shared
    private let nest = NestCameras.shared
    @State private var watched = VehicleWatch.shared.watched
    @State private var testMode = VehicleWatch.shared.testMode

    var body: some View {
        Section {
            ForEach(nest.cameras.filter(\.webRTC)) { cam in
                Toggle(cam.name, isOn: Binding(
                    get: { watched.contains(cam.id) },
                    set: { on in
                        if on { watched.insert(cam.id) } else { watched.remove(cam.id) }
                        watch.watched = watched
                    }))
            }
            Toggle("Test Mode", isOn: $testMode).onChange(of: testMode) { _, v in watch.testMode = v }
            if VehicleWatch.watchesHere, !watched.isEmpty {
                switch detector.state {
                case .getting: Text("Getting Apple's vehicle detector (62 MB, once).").foregroundStyle(.secondary)
                case .failed(let why): Text("Couldn't get Apple's vehicle detector: \(why)").foregroundStyle(.secondary)
                default: EmptyView()
                }
            }
            if let last = watch.last {
                HStack(spacing: 12) {
                    if let image = NSImage(contentsOf: last.file) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    Text("Last vehicle: \(last.at.formatted(date: .omitted, time: .shortened)), \(last.camera)")
                }
            }
        } header: { Text("Vehicle Alerts") } footer: {
            Text(VehicleWatch.watchesHere
                 ? "Google doesn't pass on vehicles, so this Mac watches each camera chosen here itself and keeps its picture playing all the time. A vehicle that comes onto the driveway is one; cars parked in view or driving past aren't. In Test Mode it only notes what it saw, here; turn Test Mode off to alert the iPhones."
                 : "Google doesn't pass on vehicles, so the Mac Studio watches each camera chosen here itself. In Test Mode it only notes what it saw; turn Test Mode off to alert the iPhones.")
        }
    }
}
#endif
