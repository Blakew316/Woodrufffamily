import Foundation
import UIKit
import WidgetKit
import WoodruffKit

/// Keeps the iPhone's Home Screen widgets in step with the app: what the remote's TV is playing, the weather and the
/// thermostat. Changes are gathered for a moment, and the widgets reload only when what they show has changed.
@MainActor
enum PhoneWidgetSync {
    private static var pending: Task<Void, Never>?

    static func update(_ fleet: Fleet) {
        guard PhoneWidgetShare.container != nil else { return }
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await write(fleet)
        }
    }

    /// Writes it now (a widget's or the Lock Screen's button has just changed what's playing).
    static func write(_ fleet: Fleet) async {
        guard PhoneWidgetShare.container != nil else { return }
        var s = PhoneWidgetShare.Snapshot()
        if let tv = fleet.selected {
            s.tvName = tv.name
            if let p = tv.nowPlaying {
                s.title = p.title
                s.detail = [p.subtitle, p.app].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
                s.isPlaying = p.isPlaying
                s.art = await art(fleet, p)
            }
        }
        s.selectedTV = fleet.selected?.id
        var lines: [PhoneWidgetShare.TVLine] = []
        var keep: Set<String> = []
        if let a = s.art { keep.insert(a) }
        for tv in fleet.tvs where !tv.isUnpaired {
            var line = PhoneWidgetShare.TVLine(id: tv.id, name: tv.name, online: tv.online, title: tv.nowPlaying?.title, isPlaying: tv.nowPlaying?.isPlaying ?? false)
            if let p = tv.nowPlaying {
                if let pr = p.progress { line.progress = (pr * 50).rounded() / 50 }
                line.left = timeLeft(position: p.position, duration: p.duration).map { $0.replacingOccurrences(of: " left", with: "") }
                line.art = await art(fleet, p)
                if let a = line.art { keep.insert(a) }
            }
            lines.append(line)
        }
        s.tvs = lines
        // Only the pictures something shows now are kept.
        if let dir = PhoneWidgetShare.container {
            for old in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where old.hasPrefix("art-") && !keep.contains(old) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(old))
            }
        }
        if let w = HomeWeather.shared.now {
            s.weatherTemp = w.tempText
            s.weatherSymbol = w.sky.symbol
            s.weatherWords = w.sky.words
            if let h = w.high, let l = w.low { s.highLow = "H \(Int(h.rounded()))°  L \(Int(l.rounded()))°" }
        }
        if let t = AccessoryStore.shared.thermostat {
            s.thermostatName = t.name
            s.thermostatTemp = t.temperature.map(temperatureText)
            let set = t.thermostatMode == "cool" ? (t.coolTo ?? t.target) : (t.heatTo ?? t.target)
            s.thermostatSet = t.thermostatMode == "off" ? "Off" : set.map(temperatureText)
            s.thermostatAction = t.thermostatMode == "off" ? "off" : t.action
        }
        if PhoneWidgetShare.save(s) { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Saves a small copy of the title's picture in the app group (once per title) and gives its name.
    private static func art(_ fleet: Fleet, _ p: NowPlaying) async -> String? {
        let a = fleet.artwork(for: p)
        guard let path = a?.poster ?? a?.backdrop, let url = fleet.hubClient()?.art(path) else { return nil }
        // A name that stays the same from launch to launch for the same picture.
        let hash = url.absoluteString.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        let name = "art-" + String(hash % 100_000_000) + ".jpg"
        if let file = PhoneWidgetShare.artURL(name), FileManager.default.fileExists(atPath: file.path) { return name }
        guard let image = await ImageStore.shared.image(url, maxPixel: 300),
              let data = image.jpegData(compressionQuality: 0.8),
              let file = PhoneWidgetShare.artURL(name) else { return nil }
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return name
    }
}
