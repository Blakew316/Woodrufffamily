import Foundation

/// Where this package's own log lines go. The Apple TV app sets it to its playback log.
public enum FilmHeightsLog {
    public static var note: ((String) -> Void)?
}

/// AetherEngine's logger as its files here call it, handing every line to `FilmHeightsLog`.
enum EngineLog {
    enum Category {
        case session
        case swPlayback
    }

    static func emit(_ line: String, category: Category) {
        FilmHeightsLog.note?(line)
    }
}
