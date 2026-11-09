import Foundation

/// Any JSON a TV sends, for answers whose shape varies between Android and webOS builds.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(_ key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? {
        switch self {
        case .string(let s): return s
        // A whole number reads without ".0"; one too large for Int (or not finite) used to crash here.
        case .number(let n): return Int(exactly: n).map(String.init) ?? String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    public var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    /// Rounded toward zero; nil for a value that isn't a finite number within Int's range (`Int(_:)` would crash).
    public var int: Int? {
        guard let d = double, d.isFinite else { return nil }
        return Int(exactly: d.rounded(.towardZero))
    }
    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        default: return nil
        }
    }
    public var array: [JSONValue] { if case .array(let a) = self { return a }; return [] }
    public var object: [String: JSONValue] { if case .object(let o) = self { return o }; return [:] }
    public var isNull: Bool { if case .null = self { return true }; return false }
}
