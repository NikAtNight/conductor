import AVFoundation

/// Thin AVCaptureSession wrapper. Frames arrive on `queue` through `onFrame`.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "com.talix.conductor.camera", qos: .userInteractive)
    var onFrame: ((CMSampleBuffer) -> Void)?

    private let output = AVCaptureVideoDataOutput()
    private var configured = false
    private var input: AVCaptureDeviceInput?

    enum SetupError: Error { case noCamera, cannotAddInput, cannotAddOutput }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Every connected camera, built-in first.
    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
    }

    /// The camera to use: the chosen one if it's connected, otherwise a front-facing one, otherwise
    /// the first available.
    static func preferredDevice(id: String? = nil) -> AVCaptureDevice? {
        let devices = availableDevices()
        if let id, let chosen = devices.first(where: { $0.uniqueID == id }) { return chosen }
        return devices.first(where: { $0.position == .front }) ?? devices.first
    }

    static func isBuiltIn(id: String?) -> Bool {
        preferredDevice(id: id)?.deviceType == .builtInWideAngleCamera
    }

    func configure(deviceID: String?) throws {
        guard !configured else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // 640x480 is plenty for hand pose and keeps Vision well under a frame budget at 30 fps.
        session.sessionPreset = .vga640x480

        guard let device = Self.preferredDevice(id: deviceID) else { throw SetupError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw SetupError.cannotAddInput }
        session.addInput(input)
        self.input = input

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw SetupError.cannotAddOutput }
        session.addOutput(output)
        configured = true
    }

    /// Swaps the camera on a configured session without stopping it. Runs on the camera queue so it
    /// can't interleave with start and stop.
    func switchDevice(to deviceID: String?) {
        queue.async { [self] in
            guard configured, let device = Self.preferredDevice(id: deviceID),
                  device.uniqueID != input?.device.uniqueID,
                  let newInput = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            if let input { session.removeInput(input) }
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                input = newInput
            } else if let input {
                session.addInput(input) // put the old one back rather than end up with no camera
            }
            session.commitConfiguration()
        }
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
