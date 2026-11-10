import Foundation
import WoodruffKit

/// An Apple TV joining the family: its QR code (woodruff://join?u=…&t=…), scanned with this device's camera, opens
/// here, and the family's code goes to the Apple TV, whose settings sync then brings every TV, key and sign-in.
@MainActor
enum JoinTV {
    static func send(_ url: URL, fleet: Fleet) async {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let u = q.first(where: { $0.name == "u" })?.value.flatMap(URL.init(string:)),
              let t = q.first(where: { $0.name == "t" })?.value else {
            fleet.alert("Can’t Connect", "That code isn’t from Woodruff on an Apple TV.")
            return
        }
        guard let code = FamilyCode.load().record?.code else {
            fleet.alert("Can’t Connect", "This device doesn’t have the family’s settings yet.")
            return
        }
        var r = URLRequest(url: u.appendingPathComponent("join"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["t": t, "code": code])
        r.timeoutInterval = 10
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            if (resp as? HTTPURLResponse)?.statusCode == 200 {
                fleet.say("Apple TV Connected", "The family’s TVs and settings are coming over to it.")
            } else {
                let why = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["error"] as? String
                fleet.alert("Can’t Connect", why ?? "The Apple TV didn’t take the code. Show the code on it again and scan it.")
            }
        } catch {
            fleet.alert("Can’t Reach the Apple TV", "Make sure this device and the Apple TV are on the same Wi‑Fi.")
        }
    }
}
