import Foundation
import CoreGraphics
import Vision

/// Where a camera alert's subject is in its picture (the person for "Person seen", an animal, else whatever stands
/// out), framed with room around it, so the alert's small picture shows who or what was seen rather than the whole
/// wide scene. Used by the Mac for the small picture in its push and its own alerts, and by the iPhone's
/// notification extension for the snapshot it fetches. Give it a picture no bigger than about 1280 pixels across
/// (the extension has little memory).
enum SubjectCrop {
    /// [whole]: the whole picture, never cropped (a motion alert, as Google Home shows it).
    enum Kind: Sendable { case person, animal, other, whole }

    /// The kind an alert's title names: "Person seen" and "Someone’s at the door" are a person; "Vehicle seen" and a
    /// package are whatever stands out; "Motion seen" is the whole picture.
    static func kind(_ title: String) -> Kind {
        let words = Set(title.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        if words.contains("motion") { return .whole }
        if !words.isDisjoint(with: ["person", "people", "someone", "door", "doorbell", "face", "visitor"]) { return .person }
        if !words.isDisjoint(with: ["animal", "animals", "pet", "pets", "dog", "cat"]) { return .animal }
        return .other
    }

    /// The subject's framing as a unit rectangle with its origin at the top left (what a notification attachment's
    /// thumbnail is clipped to); nil when nothing is found, or the framing would be most of the picture anyway.
    static func unitFocus(in image: CGImage, kind: Kind) -> CGRect? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard kind != .whole, w > 0, h > 0, let f = framing(in: image, kind: kind) else { return nil }
        return CGRect(x: f.minX / w, y: f.minY / h, width: f.width / w, height: f.height / h)
    }

    /// [image] cropped to [unit] (a `unitFocus`).
    static func crop(_ image: CGImage, unit: CGRect) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let r = CGRect(x: unit.minX * w, y: unit.minY * h, width: unit.width * w, height: unit.height * h).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        return image.cropping(to: r)
    }

    /// The framing in the image's pixels (top-left origin, as CGImage cropping counts them).
    private static func framing(in image: CGImage, kind: Kind) -> CGRect? {
        guard let box = subjectBox(in: image, kind: kind) else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // Vision's box is in unit coordinates with the origin at the bottom left: flipped to the top left here.
        let pixels = CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
        return frame(pixels, in: CGSize(width: w, height: h))
    }

    /// [box] with room around it, between square and 4:3 (wider for a wide subject), at least a third of the
    /// picture's height so a far-off figure isn't blown up into a blur, kept inside the picture.
    static func frame(_ box: CGRect, in size: CGSize) -> CGRect? {
        let iw = size.width, ih = size.height
        guard iw > 0, ih > 0, box.width > 0, box.height > 0 else { return nil }
        var w = box.width * 1.5, h = box.height * 1.3
        let least = max(min(iw, ih) * 0.34, 96)
        if w < least { w = least }
        if h < least { h = least }
        if w < h { w = h }
        if w > h * 4 / 3 { h = w * 3 / 4 }
        w = min(w, iw)
        h = min(h, ih)
        // Centred on the subject, a little high for a figure (heads at the top, not the middle), inside the picture.
        let cx = box.midX, cy = box.midY - box.height * 0.05
        let x = min(max(0, cx - w / 2), iw - w), y = min(max(0, cy - h / 2), ih - h)
        let r = CGRect(x: x, y: y, width: w, height: h)
        // Nearly the whole picture: no crop at all.
        return r.width * r.height > iw * ih * 0.8 ? nil : r
    }

    /// Vision's box round what the alert is about (several of them together), in unit coordinates, bottom-left origin.
    private static func subjectBox(in image: CGImage, kind: Kind) -> CGRect? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var boxes: [CGRect] = []
        switch kind {
        case .person:
            let humans = VNDetectHumanRectanglesRequest()
            humans.upperBodyOnly = false
            if (try? handler.perform([humans])) != nil {
                boxes = (humans.results ?? []).filter { $0.confidence >= 0.3 }.map { $0.boundingBox }
            }
            if boxes.isEmpty {
                // No figure found (half hidden, or very close to a doorbell): the face, with head and shoulders round it.
                let faces = VNDetectFaceRectanglesRequest()
                if (try? handler.perform([faces])) != nil {
                    boxes = (faces.results ?? []).map { f in
                        let b = f.boundingBox
                        return CGRect(x: b.minX - b.width, y: b.minY - b.height * 2.5, width: b.width * 3, height: b.height * 3.8)
                            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                    }
                }
            }
        case .animal:
            let animals = VNRecognizeAnimalsRequest()
            if (try? handler.perform([animals])) != nil {
                boxes = (animals.results ?? []).filter { $0.confidence >= 0.3 }.map { $0.boundingBox }
            }
            if boxes.isEmpty { boxes = salient(handler) }
        case .other:
            boxes = salient(handler)
        case .whole:
            return nil
        }
        boxes = boxes.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    /// What stands out (a vehicle, a parcel, whatever moved): the objects Vision picks out, else where the eye goes.
    private static func salient(_ handler: VNImageRequestHandler) -> [CGRect] {
        let objects = VNGenerateObjectnessBasedSaliencyImageRequest()
        if (try? handler.perform([objects])) != nil {
            let found = (objects.results?.first?.salientObjects ?? []).sorted { $0.confidence > $1.confidence }.prefix(2)
            if !found.isEmpty { return found.map { $0.boundingBox } }
        }
        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        if (try? handler.perform([attention])) != nil {
            return (attention.results?.first?.salientObjects ?? []).map { $0.boundingBox }
        }
        return []
    }
}
