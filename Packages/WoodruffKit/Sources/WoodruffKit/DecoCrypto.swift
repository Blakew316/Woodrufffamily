import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
import CryptoKit

// The encryption a TP-Link Deco's local sign-in uses (as in the open-source ha-tplink-deco integration):
// RSA (PKCS#1 v1.5) with keys the Deco hands out, in blocks, hex-joined; and AES-128-CBC with a key and IV
// that are each sixteen decimal digits. Done here in plain Swift so it works the same on iPhone and Mac,
// whatever size of RSA key the Deco uses.

/// A small unsigned big integer (little-endian 32-bit words), enough for RSA public-key encryption.
public struct BigUInt: Equatable, Sendable {
    public var words: [UInt32]

    public init(_ words: [UInt32]) { self.words = words; trim() }

    public init?(hex: String) {
        var w: [UInt32] = []
        var s = Substring(hex.lowercased().hasPrefix("0x") ? String(hex.dropFirst(2)) : hex)
        while !s.isEmpty {
            let chunk = s.suffix(8)
            guard let v = UInt32(chunk, radix: 16) else { return nil }
            w.append(v)
            s = s.dropLast(chunk.count)
        }
        self.init(w)
    }

    /// Big-endian bytes.
    public init(bytes: [UInt8]) {
        var w: [UInt32] = []
        var i = bytes.count
        while i > 0 {
            var v: UInt32 = 0
            let start = max(0, i - 4)
            for b in bytes[start..<i] { v = (v << 8) | UInt32(b) }
            w.append(v)
            i = start
        }
        self.init(w)
    }

    mutating func trim() { while words.count > 1 && words.last == 0 { words.removeLast() }; if words.isEmpty { words = [0] } }

    public var bitWidth: Int {
        guard let top = words.last, top != 0 else { return 0 }
        return (words.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    public func bit(_ i: Int) -> Bool { (words[i / 32] >> UInt32(i % 32)) & 1 == 1 }

    public static func compare(_ a: BigUInt, _ b: BigUInt) -> Int {
        if a.words.count != b.words.count { return a.words.count < b.words.count ? -1 : 1 }
        for i in stride(from: a.words.count - 1, through: 0, by: -1) where a.words[i] != b.words[i] {
            return a.words[i] < b.words[i] ? -1 : 1
        }
        return 0
    }

    public static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        var r = [UInt32](repeating: 0, count: a.words.count + b.words.count)
        for i in 0..<a.words.count {
            var carry: UInt64 = 0
            let ai = UInt64(a.words[i])
            if ai == 0 { continue }
            for j in 0..<b.words.count {
                let t = ai * UInt64(b.words[j]) + UInt64(r[i + j]) + carry
                r[i + j] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
            }
            var k = i + b.words.count
            while carry > 0 {
                let t = UInt64(r[k]) + carry
                r[k] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
                k += 1
            }
        }
        return BigUInt(r)
    }

    /// a mod m, by shift-and-subtract (plenty fast for a handful of RSA operations).
    public static func % (a: BigUInt, m: BigUInt) -> BigUInt {
        var r = BigUInt([0])
        for i in stride(from: a.bitWidth - 1, through: 0, by: -1) {
            r.shiftLeftOne(setting: a.bit(i))
            if compare(r, m) >= 0 { r.subtract(m) }
        }
        return r
    }

    mutating func shiftLeftOne(setting low: Bool) {
        var carry: UInt32 = low ? 1 : 0
        for i in 0..<words.count {
            let next = words[i] >> 31
            words[i] = (words[i] << 1) | carry
            carry = next
        }
        if carry != 0 { words.append(carry) }
    }

    mutating func subtract(_ b: BigUInt) {
        var borrow: Int64 = 0
        for i in 0..<words.count {
            var t = Int64(words[i]) - borrow - (i < b.words.count ? Int64(b.words[i]) : 0)
            if t < 0 { t += 1 << 32; borrow = 1 } else { borrow = 0 }
            words[i] = UInt32(t)
        }
        trim()
    }

    public func power(_ e: BigUInt, mod m: BigUInt) -> BigUInt {
        var result = BigUInt([1])
        var base = self % m
        for i in 0..<e.bitWidth {
            if e.bit(i) { result = (result * base) % m }
            base = (base * base) % m
        }
        return result
    }

    /// Big-endian bytes, left-padded to [length].
    public func bytes(length: Int) -> [UInt8] {
        var out: [UInt8] = []
        for w in words.reversed() { out += [UInt8(w >> 24), UInt8((w >> 16) & 255), UInt8((w >> 8) & 255), UInt8(w & 255)] }
        while out.count > length, out.first == 0 { out.removeFirst() }
        return [UInt8](repeating: 0, count: max(0, length - out.count)) + out
    }
}

public enum DecoCrypto {
    /// RSA PKCS#1 v1.5 encryption with the Deco's key (n, e in hex), split into blocks, each hex-encoded.
    public static func rsa(nHex: String, eHex: String, _ plain: Data) -> String? {
        guard let n = BigUInt(hex: nHex), let e = BigUInt(hex: eHex) else { return nil }
        let k = (n.bitWidth + 7) / 8
        let per = k - 11
        guard per > 0 else { return nil }
        let bytes = [UInt8](plain)
        var out = ""
        var i = 0
        while i < bytes.count {
            let block = Array(bytes[i..<min(bytes.count, i + per)])
            var padded: [UInt8] = [0x00, 0x02]
            for _ in 0..<(k - 3 - block.count) {
                var r: UInt8 = 0
                while r == 0 { r = UInt8.random(in: 1...255) }
                padded.append(r)
            }
            padded.append(0x00)
            padded += block
            let c = BigUInt(bytes: padded).power(e, mod: n)
            out += c.bytes(length: k).map { String(format: "%02x", $0) }.joined()
            i += block.count
        }
        return out
    }

    public static func aes(_ encrypt: Bool, key: String, iv: String, _ input: Data) -> Data? {
        let k = Data(key.utf8), v = Data(iv.utf8)
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { o in
            input.withUnsafeBytes { inp in
                k.withUnsafeBytes { kb in
                    v.withUnsafeBytes { vb in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                                kb.baseAddress, k.count, vb.baseAddress, inp.baseAddress, input.count, o.baseAddress, outCount, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    /// Sixteen decimal digits, no leading zero.
    public static func digits() -> String { String(UInt64.random(in: 1_000_000_000_000_000...9_999_999_999_999_999)) }

    public static func md5Hex(_ s: String) -> String { Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
}
#endif
