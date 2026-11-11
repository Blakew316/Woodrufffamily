import Foundation
import CoreGraphics
import Vision
#if os(macOS)
import WoodruffKit
#endif

/// Where a camera alert's subject is in its picture (the person for "Person seen", an animal, else whatever stands
/// out), framed with room around it, so the alert's small picture shows who or what was seen rather than the whole
/// wide scene. Used by the Mac for the small picture in its push and its own alerts, and by the iPhone's
/// notification extension for the snapshot it fetches. Give it a picture no bigger than about 1280 pixels across
/// (the extension has little memory).
enum SubjectCrop {
    /// [whole]: the whole picture, never cropped (a motion alert, as Google Home shows it).
    enum Kind: Sendable { case person, animal, other, whole }

    /// Where a camera's picture changed around its event: the cells of a small grid, row by row from the top. The Mac
    /// that sends the alerts knows it, from the last few seconds of the stream it keeps (`StreamMoment.moved`).
    struct Moved: Sendable {
        var cells: [Bool]
        var width: Int
        var height: Int
    }

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
    /// [moved]: where the picture changed around the event, when that's known: of several figures, the one there is
    /// who the alert is about; with nobody found, whatever changed there is.
    static func unitFocus(in image: CGImage, kind: Kind, moved: Moved? = nil) -> CGRect? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard kind != .whole, w > 0, h > 0, let f = framing(in: image, kind: kind, moved: moved) else { return nil }
        return CGRect(x: f.minX / w, y: f.minY / h, width: f.width / w, height: f.height / h)
    }

    /// The framing of a subject already found at [box] (shares of the picture, from its top left; the picture
    /// [width] by [height] pixels), as `unitFocus` gives it: the Mac that picked the alert's frame from its stream
    /// knows where the person is in it (`StreamMoment`), and doesn't look for them a second time.
    static func unitFocus(around box: CGRect, width: Int, height: Int) -> CGRect? {
        let w = CGFloat(width), h = CGFloat(height)
        guard w > 0, h > 0,
              let f = frame(CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h),
                            in: CGSize(width: w, height: h)) else { return nil }
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
    private static func framing(in image: CGImage, kind: Kind, moved: Moved?) -> CGRect? {
        guard let box = subjectBox(in: image, kind: kind, moved: moved) else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // Vision's box is in unit coordinates with the origin at the bottom left: flipped to the top left here.
        let pixels = CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
        return frame(pixels, in: CGSize(width: w, height: h))
    }

    /// [box] with room around it, between square and 4:3 (wider for a wide subject), at least a good quarter of the
    /// picture's height so a far-off figure isn't blown up into a blur, and never fewer than 260 pixels of it (a
    /// stream that comes in small, 640 by 360, gave close-ups of a hundred pixels, enlarged into a smear), kept
    /// inside the picture.
    static func frame(_ box: CGRect, in size: CGSize) -> CGRect? {
        let iw = size.width, ih = size.height
        guard iw > 0, ih > 0, box.width > 0, box.height > 0 else { return nil }
        var w = box.width * 1.5, h = box.height * 1.3
        let least = max(min(iw, ih) * 0.28, 260)
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
    private static func subjectBox(in image: CGImage, kind: Kind, moved: Moved?) -> CGRect? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var boxes: [CGRect] = []
        switch kind {
        case .person:
            #if os(macOS)
            // The Mac with Apple's object detector (Vehicle Alerts') asks it first: it makes out the small, far-off
            // figures Vision's own person finder misses (on the driveway that found the person in one alert of ten).
            var found = VehicleDetector.people(in: image) ?? []
            if found.isEmpty { found = people(handler) }
            // Of several, the ones where the picture changed (a walker, not a post taken for a figure), as one box.
            let listed = found.map { (box: turned($0.box), confidence: Double($0.confidence)) }
            if let who = EventFocus.subject(listed, changed: moved?.cells, width: moved?.width ?? 0, height: moved?.height ?? 0) {
                boxes = [turned(who)]
            }
            #else
            boxes = people(handler).map { $0.box }
            #endif
        case .animal:
            let animals = VNRecognizeAnimalsRequest()
            if (try? handler.perform([animals])) != nil {
                boxes = (animals.results ?? []).filter { $0.confidence >= 0.3 }.map { $0.boundingBox }
            }
            if boxes.isEmpty, let changed = patch(moved) { boxes = [changed] }
            if boxes.isEmpty { boxes = salient(handler) }
        case .other:
            if let changed = patch(moved) { boxes = [changed] } else { boxes = salient(handler) }
        case .whole:
            return nil
        }
        // Nobody found: whoever it was is where the picture changed, when that's known.
        if boxes.isEmpty, kind == .person, let changed = patch(moved) { boxes = [changed] }
        boxes = boxes.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    /// A box measured down from the picture's top as one measured up from its bottom (Vision's way), and back.
    private static func turned(_ r: CGRect) -> CGRect {
        let y: CGFloat = 1 - r.maxY
        return CGRect(x: r.minX, y: y, width: r.width, height: r.height)
    }

    /// The patch of the picture that changed around the event, in Vision's measure; nil when that isn't known (any
    /// device but the Mac that sends the alerts), nothing did, or the whole picture did (the light).
    private static func patch(_ moved: Moved?) -> CGRect? {
        #if os(macOS)
        guard let moved, let p = EventFocus.patch(moved.cells, width: moved.width, height: moved.height) else { return nil }
        return turned(p)
        #else
        return nil
        #endif
    }

    /// The people Vision finds in [handler]'s picture, each with how sure it is (unit coordinates, bottom-left origin):
    /// their figures; else their faces, with head and shoulders round them. The Mac also uses it to pick, of a
    /// stream's last few seconds, the frame that shows the person best (`StreamMoment`).
    static func people(_ handler: VNImageRequestHandler) -> [(box: CGRect, confidence: Float)] {
        let found = bodies(handler)
        // No figure found (half hidden, or very close to a doorbell): the face, with head and shoulders round it.
        return found.isEmpty ? faces(handler) : found
    }

    /// The figures Vision finds in [handler]'s picture (it wants them whole, head to foot).
    static func bodies(_ handler: VNImageRequestHandler) -> [(box: CGRect, confidence: Float)] {
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        guard (try? handler.perform([humans])) != nil else { return [] }
        return (humans.results ?? []).filter { $0.confidence >= 0.3 }.map { (box: $0.boundingBox, confidence: $0.confidence) }
    }

    /// The faces Vision finds in [handler]'s picture, each with head and shoulders round it.
    static func faces(_ handler: VNImageRequestHandler) -> [(box: CGRect, confidence: Float)] {
        let faces = VNDetectFaceRectanglesRequest()
        guard (try? handler.perform([faces])) != nil else { return [] }
        return (faces.results ?? []).map { f in
            let b = f.boundingBox
            return (box: CGRect(x: b.minX - b.width, y: b.minY - b.height * 2.5, width: b.width * 3, height: b.height * 3.8)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1)), confidence: f.confidence)
        }
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
