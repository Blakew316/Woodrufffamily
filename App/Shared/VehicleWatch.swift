#if os(macOS)
import SwiftUI
import AppKit
import Vision
import ImageIO
import os
import WoodruffKit

/// Vehicle Alerts (Mac): Google's camera API sends no vehicle detections, so the Mac watches a camera's live stream
/// itself. About once a second it compares a small grey copy of the picture with what the scene usually looks like
/// (so a parked car soon counts as scenery), and when a solid patch of it changes, asks Vision what's in that patch.
/// A vehicle on two frames in a row is an alert, at most one every three minutes per camera unless the drive went
/// quiet in between. In Test Mode (the default) it only notes what it saw, with the frame, under the switch.
@Observable @MainActor
final class VehicleWatch {
    static let shared = VehicleWatch()
    nonisolated static let log = Logger(subsystem: "com.woodruff.family", category: "vehicles")

    /// The cameras watched (this Mac's own choice; not synced).
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

    // Tuning (each can be changed with `defaults write com.woodruff.family.mac <key> <value>` while testing).
    private var minConfidence: Float { UserDefaults.standard.object(forKey: "vehicle.minConfidence") as? Float ?? 0.3 }
    /// Of the small picture's cells: at least this share changed for a patch worth asking Vision about...
    private var minChanged: Double { UserDefaults.standard.object(forKey: "vehicle.minChanged") as? Double ?? 0.012 }
    /// ...and at most this share: more is the whole picture changing at once (night vision, headlights, the sun).
    private var maxChanged: Double { UserDefaults.standard.object(forKey: "vehicle.maxChanged") as? Double ?? 0.45 }

    private static let gw = 64, gh = 36
    private struct Scene {
        var background: [Float] = []
        var hits = 0
        var lastAlert: Date = .distantPast
        var lastMotion: Date = .distantPast
        var quietSinceAlert = true
    }
    @ObservationIgnored private var scenes: [String: Scene] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var candidates = 0
    @ObservationIgnored private var vehicleFrames = 0
    @ObservationIgnored private var detections = 0
    @ObservationIgnored private var beatAt = Date()
    /// For the heartbeat: how much the picture moves from one frame to the next, and the biggest change seen.
    @ObservationIgnored private var diffSum: Double = 0
    @ObservationIgnored private var maxShare: Double = 0
    @ObservationIgnored private var previous: [String: [Float]] = [:]
    @ObservationIgnored private var lastFrame: (jpeg: Data, camera: String)?
    @ObservationIgnored private var lastCandidateSaved = Date.distantPast

    static var folder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let f = base.appendingPathComponent("Woodruff Family/Vehicles", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    func start() { sync() }

    /// Starts or stops watching to match the switches.
    private func sync() {
        let on = watched
        for id in CameraStreams.shared.pinned where !on.contains(id) && !CameraStreams.shared.warmed.contains(id) { CameraStreams.shared.stopKeeping(id) }
        if on.isEmpty || Demo.isOn {
            loop?.cancel(); loop = nil
            if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
            return
        }
        guard loop == nil else { return }
        // Not slowed down while the app is in the background (App Nap would sample a frame now and then at best).
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Watching the driveway for vehicles")
        Self.log.notice("vehicle watch: on for \(on.count) camera(s), test mode \(self.testMode ? "on" : "off", privacy: .public)")
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                // Every second while anything has moved in the last half minute; every two while the drive is still
                // (the first change seen brings it back to every second, well before two frames confirm a vehicle).
                let busy = self?.scenes.values.contains { Date().timeIntervalSince($0.lastMotion) < 30 } ?? true
                try? await Task.sleep(nanoseconds: busy ? 1_000_000_000 : 2_000_000_000)
            }
        }
    }

    private func tick() async {
        for id in watched {
            guard let cam = NestCameras.shared.cameras.first(where: { $0.id == id }), cam.webRTC else { continue }
            let p = CameraStreams.shared.keepPlaying(cam)
            guard p.isLive, let jpeg = await p.frameJPEG(), let image = Self.cgImage(jpeg) else { continue }
            frames += 1
            await look(at: image, jpeg: jpeg, camera: cam)
        }
        beat()
    }

    private func look(at image: CGImage, jpeg: Data, camera cam: NestCameras.Camera) async {
        guard let grey = Self.grey(image) else { return }
        if let prev = previous[cam.id], prev.count == grey.count {
            diffSum += Double(zip(grey, prev).reduce(Float(0)) { $0 + abs($1.0 - $1.1) }) / Double(grey.count)
        }
        previous[cam.id] = grey
        lastFrame = (jpeg, cam.name)
        var scene = scenes[cam.id] ?? Scene()
        defer { scenes[cam.id] = scene }
        if scene.background.count != grey.count { scene.background = grey; return }
        // Cells clearly different from the scenery, keeping only those with a changed neighbour (not specks of noise).
        var changed = [Bool](repeating: false, count: grey.count)
        for i in grey.indices where abs(grey[i] - scene.background[i]) > 28 { changed[i] = true }
        var kept: [Int] = []
        for y in 0..<Self.gh { for x in 0..<Self.gw where changed[y * Self.gw + x] {
            var n = 0
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + dx, ny = y + dy
                if nx >= 0, ny >= 0, nx < Self.gw, ny < Self.gh, changed[ny * Self.gw + nx] { n += 1 }
            }
            if n >= 2 { kept.append(y * Self.gw + x) }
        } }
        let share = Double(kept.count) / Double(grey.count)
        maxShare = max(maxShare, share)
        // The scenery slowly takes in what stays (a car that parks); the whole picture changing resets it at once.
        if share > maxChanged {
            scene.background = grey
            scene.hits = 0
            return
        }
        for i in grey.indices { scene.background[i] += (grey[i] - scene.background[i]) * 0.04 }
        guard share >= minChanged else {
            scene.hits = 0
            if Date().timeIntervalSince(scene.lastMotion) > 45 { scene.quietSinceAlert = true }
            return
        }
        scene.lastMotion = Date()
        candidates += 1
        // The changed patch, with a margin, in the full picture.
        let xs = kept.map { $0 % Self.gw }, ys = kept.map { $0 / Self.gw }
        let sx = CGFloat(image.width) / CGFloat(Self.gw), sy = CGFloat(image.height) / CGFloat(Self.gh)
        var box = CGRect(x: CGFloat(xs.min()!) * sx, y: CGFloat(ys.min()!) * sy,
                         width: CGFloat(xs.max()! - xs.min()! + 1) * sx, height: CGFloat(ys.max()! - ys.min()! + 1) * sy)
        box = box.insetBy(dx: -max(24, box.width * 0.3), dy: -max(24, box.height * 0.3))
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let crop = image.cropping(to: box.integral) else { return }
        let (label, confidence, top) = await Self.vehicle(in: crop)
        // Test Mode: what changed and what Vision made of it, to count right and wrong calls (one every 15 s at most).
        if testMode, Date().timeIntervalSince(lastCandidateSaved) > 15, let jpegCrop = Self.jpeg(crop) {
            lastCandidateSaved = Date()
            _ = Self.keep(jpegCrop, note: "\(cam.name)-\(top)", in: "Candidates")
        }
        guard let label, confidence >= minConfidence else { scene.hits = 0; return }
        vehicleFrames += 1
        scene.hits += 1
        guard scene.hits >= 2 else { return }
        scene.hits = 0
        // One alert per camera every three minutes, unless the drive went quiet in between (another car).
        guard Date().timeIntervalSince(scene.lastAlert) > 180 || scene.quietSinceAlert else { return }
        scene.lastAlert = Date()
        scene.quietSinceAlert = false
        detections += 1
        let file = Self.keep(jpeg, note: "\(cam.name)-\(label)-\(Int(confidence * 100))")
        if let file { last = (Date(), cam.name, file) }
        Self.log.notice("vehicle seen on \(cam.name, privacy: .public): \(label, privacy: .public) \(Int(confidence * 100))% (test mode \(self.testMode ? "on: no alert" : "off: alert sent", privacy: .public))")
        if !testMode { NestAlerts.shared.postVehicle(camera: cam, jpeg: jpeg) }
    }

    /// Every ten minutes in the log: frames looked at, patches that changed, frames with a vehicle, alerts.
    private func beat() {
        let mins = Date().timeIntervalSince(beatAt) / 60
        guard mins >= 10 else { return }
        framesPerMinute = Int(Double(frames) / mins)
        let moved = frames > 1 ? diffSum / Double(frames - 1) : 0
        Self.log.notice("vehicle watch: \(self.frames) frames, \(self.candidates) changes, \(self.vehicleFrames) with a vehicle, \(self.detections) seen in the last \(Int(mins)) minutes; frame to frame \(String(format: "%.2f", moved), privacy: .public) of 255, biggest change \(String(format: "%.1f", self.maxShare * 100), privacy: .public)% of the picture")
        // Test Mode: one frame each time, to see what the camera sees (light, night vision).
        if testMode, let f = lastFrame { _ = Self.keep(f.jpeg, note: "\(f.camera)-sample") }
        frames = 0; candidates = 0; vehicleFrames = 0; detections = 0; beatAt = Date(); diffSum = 0; maxShare = 0
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

    /// Vision's own names for vehicles (exactly these: "car_seat" and "vehicle_toy" are not).
    private static let vehicleLabels: Set<String> = ["automobile", "bus", "car", "engine_vehicle", "jeep", "motorcycle",
                                                     "police_car", "semi_truck", "suv", "truck", "van", "vehicle"]

    /// Vision's best vehicle label for the patch, and how sure it is.
    /// Vision's best vehicle label for the patch and how sure it is, and its top three labels of any kind.
    private nonisolated static func vehicle(in crop: CGImage) async -> (String?, Float, String) {
        await Task.detached(priority: .utility) {
            let request = VNClassifyImageRequest()
            try? VNImageRequestHandler(cgImage: crop).perform([request])
            let results = (request.results ?? []).sorted { $0.confidence > $1.confidence }
            var best: (String?, Float) = (nil, 0)
            for o in results where o.confidence > best.1 && vehicleLabels.contains(o.identifier) { best = (o.identifier, o.confidence) }
            let top = results.prefix(3).map { "\($0.identifier)\(Int($0.confidence * 100))" }.joined(separator: "-")
            return (best.0, best.1, top)
        }.value
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

/// Settings → Notifications → Camera Alerts (Mac): which cameras the Mac watches for vehicles.
struct VehicleAlertsSection: View {
    private let watch = VehicleWatch.shared
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
            Text("Google doesn't pass on vehicles, so this Mac watches each camera chosen here itself and keeps its picture playing all the time. In Test Mode it only notes what it saw, here; turn Test Mode off to alert the iPhones.")
        }
    }
}
#endif
