#if canImport(AVFoundation)
import CoreMedia
import Foundation
import VideoToolbox

/// A film's picture that Apple's decoder won't take under the name the file gives it, though it decodes what's in it.
///
/// - HEVC marked "hev1" (and Dolby Vision marked "dvhe"), as ffmpeg marks it unless told otherwise: the same picture as
///   "hvc1", with its parameter sets repeated inside the frames. Apple's reader calls such a track undecodable, and the
///   app's own player played the film's sound over a black screen.
/// - Dolby Vision of a profile Apple doesn't play (7, the Blu-ray kind, with its second layer): the HDR10 picture under
///   it is shown, without the Dolby Vision. Profile 5 goes as "dvh1" and profile 8 as "hvc1" with its Dolby Vision kept,
///   as Apple's own files are.
/// - H.264 marked "avc3": as "avc1".
///
/// The app's own player hands every frame to Apple's decoder itself (`FilmPlayer`), so it hands them over under the
/// name the decoder takes. A kind this device has no decoder for (AV1 on most Apple TVs) stays as it is.
public enum FilmPictureFormat {
    static let hvc1: FourCharCode = 0x6876_6331
    static let hev1: FourCharCode = 0x6865_7631
    static let dvh1: FourCharCode = 0x6476_6831
    static let dvhe: FourCharCode = 0x6476_6865
    static let avc1: FourCharCode = 0x6176_6331
    static let avc3: FourCharCode = 0x6176_6333

    /// The boxes that hold a picture's Dolby Vision settings.
    static let visionBoxes = ["dvcC", "dvvC", "dvwC"]

    /// [format] made again under a name Apple's decoder takes, or nil when there's nothing it could be made as.
    public static func takeable(_ format: CMFormatDescription) -> CMFormatDescription? {
        let kind = CMFormatDescriptionGetMediaSubType(format)
        let hevc = [hvc1, hev1, dvh1, dvhe].contains(kind)
        guard hevc || kind == avc3 else { return nil }
        var extensions = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) as? [String: Any] ?? [:]
        let boxesKey = kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String
        var boxes = extensions[boxesKey] as? [String: Any] ?? [:]
        // The parameter sets the decoder starts from.
        guard boxes[hevc ? "hvcC" : "avcC"] != nil else { return nil }
        var to = hevc ? hvc1 : avc1
        var dropVision = false
        if hevc, let profile = visionProfile(boxes) {
            if profile == 5 {
                // Nothing but Dolby Vision under it: it can only be shown as Dolby Vision.
                to = dvh1
            } else if profile != 8 {
                dropVision = true
            }
        }
        if to == kind, !dropVision {
            // Already under that name: all that's left to try is the picture under its Dolby Vision.
            guard hevc, to == hvc1, visionBoxes.contains(where: { boxes[$0] != nil }) else { return nil }
            dropVision = true
        }
        if dropVision {
            for box in visionBoxes { boxes.removeValue(forKey: box) }
        }
        extensions[boxesKey] = boxes
        // The file's own description of the sample entry still says "hev1": left out.
        extensions.removeValue(forKey: kCMFormatDescriptionExtension_VerbatimSampleDescription as String)
        extensions.removeValue(forKey: kCMFormatDescriptionExtension_VerbatimISOSampleEntry as String)
        guard VTIsHardwareDecodeSupported(hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264) else { return nil }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        var made: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: to, width: size.width, height: size.height,
                                             extensions: extensions as CFDictionary, formatDescriptionOut: &made) == noErr else { return nil }
        return made
    }

    /// For a picture the file marks "hev1" or "dvhe" (its frames may carry its parameter sets too): the parameter sets
    /// its sample description gives, which the frames' own copies are taken out against (`FilmNALUnits`). Nil for
    /// any other picture.
    public static func knownSets(_ format: CMFormatDescription) -> (lengthSize: Int, sets: Set<Data>)? {
        let kind = CMFormatDescriptionGetMediaSubType(format)
        guard kind == hev1 || kind == dvhe else { return nil }
        let extensions = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) as? [String: Any] ?? [:]
        let boxes = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] ?? [:]
        guard let value = boxes["hvcC"], let hvcC = (value as? Data) ?? (value as? [Data])?.first,
              let known = FilmNALUnits.parameterSets(hvcC: hvcC), !known.sets.isEmpty else { return nil }
        return known
    }

    /// The Dolby Vision profile in a picture's Dolby Vision box, when it has one.
    static func visionProfile(_ boxes: [String: Any]) -> Int? {
        for box in visionBoxes {
            guard let value = boxes[box], let data = (value as? Data) ?? (value as? [Data])?.first, data.count >= 4 else { continue }
            return Int(data[data.startIndex + 2] >> 1) & 0x7F
        }
        return nil
    }

    /// What a picture's kind is called, for saying it can't be shown ("AV1"), from its four letters.
    public static func name(_ letters: String) -> String {
        switch letters {
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case "vp08": return "VP8"
        case "vvc1", "vvi1": return "H.266"
        case "hvc1", "hev1": return "HEVC"
        case "dvh1", "dvhe": return "Dolby Vision"
        case "avc1", "avc3": return "H.264"
        case "mp4v": return "MPEG-4"
        case "mp2v", "mp1v": return "MPEG-2"
        default: return letters
        }
    }

    /// Each format the file gives the picture's samples, made under the name the decoder takes once and kept: the
    /// track's own first ([from], already made as [to]). Used on the player's queue only.
    final class Remade {
        private var made: [(from: CMFormatDescription, to: CMFormatDescription)]

        init(from: CMFormatDescription, to: CMFormatDescription) {
            made = [(from, to), (to, to)]
        }

        func callAsFunction(_ format: CMFormatDescription) -> CMFormatDescription {
            if let kept = made.first(where: { CMFormatDescriptionEqual($0.from, otherFormatDescription: format) }) { return kept.to }
            let to = FilmPictureFormat.takeable(format) ?? format
            made.append((format, to))
            return to
        }
    }
}
#endif
