import AVFoundation
import SwiftUI
import UIKit

struct PairingScanner: UIViewControllerRepresentable {
    let scanned: (String) -> Void
    let failed: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        ScannerController(scanned: scanned, failed: failed)
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) {
        controller.stop()
    }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let cameraQueue = DispatchQueue(label: "vpcomm.qr.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var finished = false
    private let scanned: (String) -> Void
    private let failed: (String) -> Void

    init(scanned: @escaping (String) -> Void, failed: @escaping (String) -> Void) {
        self.scanned = scanned
        self.failed = failed
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(scanned:failed:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.preview = preview
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                guard granted else {
                    self.finish(error: "Allow camera access in iPhone Settings to scan pairing QR codes.")
                    return
                }
                self.configure()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    private func configure() {
        cameraQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                           for: .video, position: .back) else {
                    throw VoiceError.packet
                }
                let input = try AVCaptureDeviceInput(device: camera)
                let output = AVCaptureMetadataOutput()
                self.session.beginConfiguration()
                guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                    self.session.commitConfiguration()
                    throw VoiceError.packet
                }
                self.session.addInput(input)
                self.session.addOutput(output)
                guard output.availableMetadataObjectTypes.contains(.qr) else {
                    self.session.commitConfiguration()
                    throw VoiceError.packet
                }
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                self.session.commitConfiguration()
                self.session.startRunning()
            } catch {
                DispatchQueue.main.async {
                    self.finish(error: "Camera unavailable. Use a physical iPhone to scan the QR.")
                }
            }
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !finished, let value = metadataObjects.compactMap({
            ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue
        }).first else { return }
        stop()
        scanned(value)
    }

    private func finish(error: String) {
        guard !finished else { return }
        stop()
        failed(error)
    }

    func stop() {
        finished = true
        cameraQueue.async { [session] in session.stopRunning() }
    }
}
