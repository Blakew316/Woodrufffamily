import SwiftUI
import AVFoundation

/// The camera, reading the pairing QR code a TV shows (Settings → Phone connection on the TV).
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }
    func updateUIViewController(_ c: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        /// Starting and stopping go one after the other, off the main thread (a stop that overtook a start left the
        /// camera running).
        private let sessionQueue = DispatchQueue(label: "com.woodruff.family.qrscanner")
        private var preview: AVCaptureVideoPreviewLayer?
        /// Says which way up the picture goes as the iPhone or iPad is turned (left alone it stayed as for a phone held
        /// upright: sideways in landscape, as an iPad mostly is).
        private var rotation: AVCaptureDevice.RotationCoordinator?
        private var rotationWatch: NSKeyValueObservation?
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                let l = UILabel()
                l.text = "The camera isn't available. Paste the TV's link instead."
                l.textColor = .white; l.numberOfLines = 0; l.textAlignment = .center
                l.frame = view.bounds.insetBy(dx: 24, dy: 24); l.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.addSubview(l)
                return
            }
            session.addInput(input)
            let out = AVCaptureMetadataOutput()
            if session.canAddOutput(out) {
                session.addOutput(out)
                out.setMetadataObjectsDelegate(self, queue: .main)
                out.metadataObjectTypes = [.qr]
            }
            let p = AVCaptureVideoPreviewLayer(session: session)
            p.videoGravity = .resizeAspectFill
            view.layer.addSublayer(p)
            preview = p
            // The picture turns with the device: now, and each time it's turned.
            let r = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: p)
            rotation = r
            turnPreview(to: r.videoRotationAngleForHorizonLevelPreview)
            rotationWatch = r.observe(\.videoRotationAngleForHorizonLevelPreview, options: .new) { [weak self] _, change in
                guard let angle = change.newValue else { return }
                Task { @MainActor in self?.turnPreview(to: angle) }
            }
            sessionQueue.async { [session] in session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
            // Again here: the preview's connection may not have been there yet when the scanner was made.
            if let r = rotation { turnPreview(to: r.videoRotationAngleForHorizonLevelPreview) }
        }

        /// Turns the preview to [angle] (degrees), when the camera can show it that way up.
        private func turnPreview(to angle: CGFloat) {
            guard let c = preview?.connection, c.isVideoRotationAngleSupported(angle), c.videoRotationAngle != angle else { return }
            c.videoRotationAngle = angle
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            sessionQueue.async { [session] in session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode?(code)
        }
    }
}
