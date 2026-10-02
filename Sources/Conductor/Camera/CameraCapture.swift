import AVFoundation

/// Thin AVCaptureSession wrapper. Frames arrive on `queue` through `onFrame`.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "com.talix.conductor.camera", qos: .userInteractive)
    var onFrame: ((CMSampleBuffer) -> Void)?

    private let output = AVCaptureVideoDataOutput()
    private var configured = false

    enum SetupError: Error { case noCamera, cannotAddInput, cannotAddOutput }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func configure() throws {
        guard !configured else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // 640x480 is plenty for hand pose and keeps Vision well under a frame budget at 30 fps.
        session.sessionPreset = .vga640x480

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified)
        guard let device = discovery.devices.first(where: { $0.position == .front }) ?? discovery.devices.first else {
            throw SetupError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw SetupError.cannotAddInput }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw SetupError.cannotAddOutput }
        session.addOutput(output)
        configured = true
    }

    func start() {
        guard configured, !session.isRunning else { return }
        queue.async { self.session.startRunning() }
    }

    func stop() {
        guard session.isRunning else { return }
        queue.async { self.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }
}
