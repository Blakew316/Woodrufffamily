import SwiftUI
import WoodruffKit

// The Woodruff look on Apple TV, the same as the iPhone and Mac apps: the app icon's blues drifting slowly behind
// everything, frosted cards, the pictures large, and tiles that lift toward you when the remote is on them.

/// The app icon's colours (the iPhone's `IconPalette`).
enum TVPalette {
    static let steel = Color(red: 0.220, green: 0.325, blue: 0.443)
    static let mid = Color(red: 0.114, green: 0.200, blue: 0.314)
    static let deep = Color(red: 0.031, green: 0.067, blue: 0.122)
    static let cyan = Color(red: 0.227, green: 0.678, blue: 0.875)
    static let ice = Color(red: 0.659, green: 0.831, blue: 0.961)
    /// A tile that's on: ice-white, a touch bluer at the bottom.
    static let onTile = LinearGradient(colors: [Color(red: 0.914, green: 0.965, blue: 1.0), Color(red: 0.749, green: 0.890, blue: 0.980)],
                                       startPoint: .top, endPoint: .bottom)
    /// Words on an "on" tile.
    static let onInk = Color(red: 0.05, green: 0.12, blue: 0.22)
}

/// Home's background on the iPhone: a slow, quiet gradient in the app's blues that drifts over half a minute.
struct TVBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            TVPalette.deep
            TimelineView(.animation(minimumInterval: 0.5, paused: reduceMotion)) { ctx in
                let t = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate / 30
                let w = Float(sin(t) * 0.12), v = Float(cos(t * 0.8) * 0.12)
                MeshGradient(width: 3, height: 3, points: [
                    [0, 0], [0.5 + w, 0], [1, 0],
                    [0, 0.5 + v], [0.5 - v, 0.5 + w], [1, 0.5 - w],
                    [0, 1], [0.5 + v, 1], [1, 1],
                ], colors: [
                    Color(red: 0.20, green: 0.30, blue: 0.42), TVPalette.steel, Color(red: 0.19, green: 0.29, blue: 0.41),
                    Color(red: 0.10, green: 0.19, blue: 0.30), Color(red: 0.13, green: 0.30, blue: 0.45), Color(red: 0.10, green: 0.18, blue: 0.29),
                    TVPalette.deep, Color(red: 0.05, green: 0.10, blue: 0.17), TVPalette.deep,
                ])
            }
            LinearGradient(colors: [.clear, .black.opacity(0.2)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// A picture from the network filling its space (cut to it), a soft placeholder until it comes.
struct TVArt: View {
    var url: URL?

    var body: some View {
        Color.clear.overlay {
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        TVPalette.mid.opacity(0.6)
                    }
                }
            } else {
                LinearGradient(colors: [TVPalette.steel, TVPalette.mid], startPoint: .top, endPoint: .bottom)
            }
        }
        .clipped()
    }
}

/// A tile on the remote: it lifts and glows when it has focus, and sinks a little when clicked.
struct TVTileStyle: ButtonStyle {
    var corner: CGFloat = 28
    /// A white ring around the focused tile (posters show only the lift, their name stays under them).
    var ring = true
    var lift: CGFloat = 1.06

    func makeBody(configuration: Configuration) -> some View {
        TVTileBody(configuration: configuration, corner: corner, ring: ring, lift: lift)
    }
}

private struct TVTileBody: View {
    let configuration: ButtonStyleConfiguration
    let corner: CGFloat
    let ring: Bool
    let lift: CGFloat
    @Environment(\.isFocused) private var focused

    var body: some View {
        configuration.label
            .overlay {
                if ring {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(.white.opacity(focused ? 0.85 : 0), lineWidth: 4)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : (focused ? lift : 1))
            .shadow(color: .black.opacity(focused ? 0.55 : 0.25), radius: focused ? 32 : 12, y: focused ? 20 : 6)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: focused)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A frosted rounded panel (the iPhone's glass cards).
struct TVGlass: ViewModifier {
    var corner: CGFloat = 28
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

extension View {
    func tvGlass(_ corner: CGFloat = 28) -> some View { modifier(TVGlass(corner: corner)) }
}

/// A page's heading over the backdrop.
struct TVSectionTitle: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.title3.weight(.bold))
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 80)
    }
}

/// "Good evening, Woodruff Family" and the day, as at the top of Home on the iPhone.
struct TVGreeting: View {
    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(alignment: .leading, spacing: 6) {
                Text("Good \(Self.part(ctx.date)), Woodruff Family")
                    .font(.system(size: 58, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
                Text(ctx.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    static func part(_ d: Date) -> String {
        switch Calendar.current.component(.hour, from: d) {
        case 5..<12: return "morning"
        case 12..<17: return "afternoon"
        default: return "evening"
        }
    }
}
