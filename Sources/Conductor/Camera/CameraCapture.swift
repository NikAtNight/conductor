import AVFoundation

/// Thin AVCaptureSession wrapper. Frames arrive on `queue` through `onFrame`.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "com.talix.conductor.camera", qos: .userInteractive)
    var onFrame: ((CMSampleBuffer) -> Void)?
    /// Runs on the capture queue with the dropped frame's timing and AVFoundation's reason.
    var onDroppedFrame: ((CMSampleBuffer, String?) -> Void)?
    private(set) var pixelFormat: OSType?

    private let output = AVCaptureVideoDataOutput()
    private let useBGRAForBenchmark: Bool
    private var configured = false
    private var input: AVCaptureDeviceInput?

    enum SetupError: Error { case noCamera, cannotAddInput, cannotAddOutput, unsupportedPixelFormat }

    /// CONDUCTOR_CAMERA_BGRA=1 keeps the old format for a local camera comparison.
    init(useBGRAForBenchmark: Bool = ProcessInfo.processInfo.environment["CONDUCTOR_CAMERA_BGRA"] == "1") {
        self.useBGRAForBenchmark = useBGRAForBenchmark
        super.init()
    }

    static func preferredPixelFormat(from available: [OSType], useBGRAForBenchmark: Bool = false) -> OSType? {
        let preferences = useBGRAForBenchmark ? [kCVPixelFormatType_32BGRA] : [
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA,
        ]
        return preferences.first(where: available.contains)
    }

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
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw SetupError.cannotAddOutput }
        session.addOutput(output)
        guard let format = Self.preferredPixelFormat(from: output.availableVideoPixelFormatTypes,
                                                    useBGRAForBenchmark: useBGRAForBenchmark) else {
            session.removeOutput(output)
            session.removeInput(input)
            self.input = nil
            throw SetupError.unsupportedPixelFormat
        }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
        pixelFormat = format
        configured = true
    }

    /// Swaps the camera on a configured session without stopping it. Runs on the camera queue so it
    /// can't interleave with start and stop.
    /// Resolve the device on the caller's thread (`preferredDevice`): discovery can be slow, and
    /// this queue also carries frames.
    func switchDevice(to device: AVCaptureDevice?) {
        queue.async { [self] in
            guard configured, let device, device.uniqueID != input?.device.uniqueID,
                  let newInput = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            if let input { session.removeInput(input) }
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                if let format = Self.preferredPixelFormat(from: output.availableVideoPixelFormatTypes,
                                                         useBGRAForBenchmark: useBGRAForBenchmark) {
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
                    pixelFormat = format
                    input = newInput
                } else {
                    session.removeInput(newInput)
                    if let input { session.addInput(input) }
                }
            } else if let input {
                session.addInput(input) // put the old one back rather than end up with no camera
            }
            session.commitConfiguration()
        }
    }

    /// Both checks run on the queue, in order. Checking `isRunning` before queueing raced: a stop
    /// right after a start saw "not running yet" and did nothing, leaving the camera on.
    func start() {
        queue.async { [self] in
            if configured, !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                     attachmentModeOut: nil) as? String
        onDroppedFrame?(sampleBuffer, reason)
    }
}
