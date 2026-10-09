import AVFoundation
import AppKit

/// Runs the camera -> tracker -> pipeline -> input loop. One instance for the app's life.
///
/// The per-frame decisions live in FramePipeline. Engine owns what that can't: the camera queue,
/// Vision, the clock, the stall watchdog, calibration, the gesture log, posting input, and
/// publishing to TrackingState. Marked `@unchecked Sendable` because the mutable state is only
/// ever touched on `camera.queue`, apart from main-actor lifecycle state and the locked input,
/// sampling and preview owners. Main-actor settings are handed over by `refreshFromMainActor`.
final class Engine: @unchecked Sendable {
    let camera = CameraCapture()
    let state: TrackingState
    let preferences: Preferences

    private let tracker = HandTracker()
    /// Nil unless this build carries an upload server; see LogUploader.
    let logUploader: LogUploader?
    private let faceTracker = FaceTracker()
    private let input: InputScheduler
    private let snapshots = LatestSnapshot<TrackingSnapshot>()
    private let samplingOwner = SamplingOwnership()
    @MainActor private var snapshotTimer: Timer?
    @MainActor private var startAttempt: UUID?
    private var calibrationToken: UUID?
    private var droppedFrames = 0
    private var droppedReasons: [String: Int] = [:]
    private var frameTimes: [CFTimeInterval] = []
    private var permissionTimer: Timer?

    // Touched only on the camera queue.
    private var pipeline: FramePipeline
    private var prefs: Settings
    private var gestureLog: GestureLog?
    /// The setup line the current log has, so a refresh only writes one when something changed.
    private var loggedSetup: GestureLog.Setup?
    /// The latest setup from the main actor, for the next log to open with.
    private var latestSetup: GestureLog.Setup?
    /// A session longer than this is split into more than one log, so no file outgrows the upload.
    private static let logRotateAfter: TimeInterval = 3600
    /// The face is detected on every Nth frame for the log alone; look mode runs it more often.
    private static let faceLogStride = 6
    private var quality = TrackingQuality()
    private var frameCount = 0
    private var lastHandTime: CFTimeInterval = 0
    private var calibrationEnd: CFTimeInterval?
    private var calibrationSamples: [CGPoint] = []
    private var onCalibrated: (@MainActor (CGRect?) -> Void)?
    /// Set while a calibration takes the frames instead of the recognizer; see startSampling.
    private var sampling: (token: UUID, handler: @MainActor ([HandPose], FacePose?) -> Void, wantsFace: Bool, label: String)?
    private var publishedBox: CGRect?
    /// The connected displays, for naming the one the control box targets.
    private var displayLayout: [DisplayInfo] = []
    private var publishedTargetName: String?
    /// The last face seen, kept across the frames look mode skips so the preview doesn't flicker.
    private var lastFace: FacePose?
    private var previewFace: FacePose?
    /// When the last camera frame arrived, for frame timing in the log.
    private var lastFrameTime: CFTimeInterval = 0

    /// Bundle ID of the frontmost app, for per-app gesture profiles. Main actor.
    @MainActor var frontmostBundleID: String?

    @MainActor
    convenience init(state: TrackingState, preferences: Preferences) {
        self.init(state: state, preferences: preferences, input: InputScheduler(),
                  pipeline: FramePipeline(preferences.settings),
                  logUploader: LogUploader.Config(info: Bundle.main.infoDictionary ?? [:]).map { LogUploader(config: $0) })
        GestureLog.recoverInterruptedLogs()
    }

    /// Explicit runtime dependencies let lifecycle tests use fake input without camera or log startup.
    @MainActor
    init(state: TrackingState, preferences: Preferences, input: InputScheduler,
         pipeline: FramePipeline, logUploader: LogUploader? = nil) {
        self.state = state
        self.preferences = preferences
        self.input = input
        self.pipeline = pipeline
        self.logUploader = logUploader
        prefs = preferences.settings
        logUploader?.setEnabled(prefs.uploadLogs)
        camera.onFrame = { [weak self] buffer in self?.process(buffer) }
        camera.onDroppedFrame = { [weak self] _, reason in
            guard let self else { return }
            droppedFrames += 1
            droppedReasons[reason ?? "unknown", default: 0] += 1
        }
    }

    /// Sends every finished log and report the server hasn't got yet; see LogUploader. Nothing
    /// happens in a build without a server, or with uploads turned off in Settings > Data.
    @MainActor
    func uploadLogs() {
        guard let logUploader, preferences.settings.uploadLogs else { return }
        logUploader.sweep()
    }

    // MARK: Gesture log

    /// Camera queue. Every tracking session is logged (see GestureLog), opening with the setup line.
    private func openLog() {
        do {
            let log = try GestureLog()
            if let latestSetup {
                log.setup(latestSetup)
                loggedSetup = latestSetup
            }
            if let format = camera.pixelFormat {
                log.note(String(format: "camera capture: pixel format 0x%08x", format))
            }
            gestureLog = log
        } catch {
            NSLog("Conductor: can't start the gesture log: \(error)")
        }
    }

    /// Camera queue. Closes the file, sends what's finished (unless uploads are off), and keeps
    /// the folder bounded.
    private func closeLog() {
        logTiming()
        let log = gestureLog
        gestureLog = nil
        loggedSetup = nil
        let uploader = prefs.uploadLogs ? logUploader : nil
        let finish: @Sendable () -> Void = {
            if let log { Self.reportLogFailure(log) }
            if let uploader { uploader.sweep() }
            else { GestureLog.prune() }
        }
        if let log { log.finish(completion: finish) }
        else { DispatchQueue.global(qos: .utility).async(execute: finish) }
    }

    private static func reportLogFailure(_ log: GestureLog) {
        let diagnostics = log.diagnostics
        guard diagnostics.failedLines > 0 || diagnostics.droppedLines > 0 || diagnostics.finalizationError != nil else { return }
        NSLog("Conductor: gesture log finished with %d dropped lines, %d failed lines; finalization: %@",
              diagnostics.droppedLines, diagnostics.failedLines, diagnostics.finalizationError ?? "complete")
    }

    @MainActor
    func start() async {
        guard !state.isRunning, startAttempt == nil else { return }
        let attempt = UUID()
        startAttempt = attempt
        defer { if startAttempt == attempt { startAttempt = nil } }
        let allowed = await CameraCapture.requestAccess()
        guard startAttempt == attempt, !Task.isCancelled else { return }
        guard allowed else {
            state.error = "Camera access denied. Enable it in System Settings > Privacy & Security > Camera."
            return
        }
        do {
            try camera.configure(deviceID: preferences.settings.cameraDeviceID)
        } catch {
            state.error = "Camera setup failed: \(error)"
            return
        }
        refreshFromMainActor(promptForAccessibility: true)
        // Ask again here rather than read the pipeline's flag: that's set on the camera queue and
        // isn't updated yet, which flashed a false "not granted" for the first two seconds.
        state.error = Permissions.accessibilityGranted(prompt: false) ? nil
            : "Accessibility not granted. Cursor won't move until you allow Conductor in System Settings."
        beginProcessing()
        camera.queue.async { [self] in openLog() }
        camera.start()
        state.isRunning = true
        // The grant can be flipped in System Settings while we run, and AXIsProcessTrusted picks it
        // up live. Poll so the user doesn't have to pause and restart to make the cursor move.
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.recheckAccessibility() }
        }
    }

    /// Starts processing separately from capture and logging. Frames remain inadmissible until
    /// the queued reset finishes, including callbacks left behind by the previous camera session.
    @MainActor
    func beginProcessing() {
        snapshots.start()
        snapshotTimer?.invalidate()
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let snapshot = self.snapshots.take() else { return }
                snapshot.publish(to: self.state)
            }
        }
        let session = input.start(acceptingFrames: false) { [weak self] token in self?.cameraStalled(token) }
        camera.queue.async { [self] in
            guard input.ownsSession(session) else { return }
            pipeline.reset()
            lastFace = nil
            previewFace = nil
            frameTimes = []
            frameCount = 0
            lastHandTime = 0
            lastFrameTime = CACurrentMediaTime()
            input.arm(session)
        }
    }

    @MainActor
    private func recheckAccessibility() {
        let trusted = Permissions.accessibilityGranted(prompt: false)
        camera.queue.async { [self] in post(pipeline.setInputAllowed(trusted)) }
        state.error = trusted ? nil
            : "Accessibility not granted. Cursor won't move until you allow Conductor in System Settings."
    }

    @MainActor
    func stop() {
        endProcessing()
        camera.stop()
        camera.queue.async { [self] in closeLog() }
    }

    @MainActor
    func endProcessing() {
        startAttempt = nil
        snapshots.stop()
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        input.stop()
        samplingOwner.cancel()
        permissionTimer?.invalidate()
        permissionTimer = nil
        camera.queue.async { [self] in
            _ = pipeline.releaseHeld()
            sampling = nil
            cancelCalibration()
        }
        if case .running = state.calibration { state.calibration = .none }
        state.isRunning = false
        state.hands = []
        state.gestureLabel = "Paused"
    }

    /// Quitting: let go of every button and key before the process exits. Synchronous on purpose;
    /// an async release would be queued behind the session teardown and never run.
    @MainActor
    func shutdown() {
        snapshots.stop()
        snapshotTimer?.invalidate()
        input.stop()
        samplingOwner.cancel()
        camera.queue.sync {
            if let gestureLog {
                gestureLog.finishAndWait()
                Self.reportLogFailure(gestureLog)
            }
            gestureLog = nil
        }
        camera.stop()
    }

    /// Input queue. Releases already happened here, even if Vision has blocked the camera queue.
    private func cameraStalled(_ token: UInt64) {
        snapshots.stop()
        samplingOwner.cancel()
        DispatchQueue.main.async {
            guard self.state.isRunning, self.input.ownsGeneration(token), self.snapshots.currentToken == nil else { return }
            self.state.gestureLabel = "Camera stopped sending frames"
            if case .running = self.state.calibration { self.state.calibration = .failed }
        }
        camera.queue.async { [self] in
            guard input.ownsGeneration(token) else { return }
            _ = pipeline.releaseHeld()
            sampling = nil
            cancelCalibration()
            gestureLog?.note("watchdog: camera processing stalled, released held input")
            input.resumeAfterStall(token)
            DispatchQueue.main.async {
                guard self.state.isRunning, self.input.isCurrent(token) else { return }
                self.snapshots.start()
            }
        }
    }

    /// Camera queue. Clears sample storage after the ownership gate has notified cancellation.
    private func cancelCalibration() {
        guard calibrationEnd != nil else { return }
        calibrationEnd = nil
        calibrationSamples = []
        publishedBox = nil // undo the live preview
        publishBox()
        calibrationToken = nil
        onCalibrated = nil
    }

    /// Snapshots main-actor-owned values for the camera queue. Called on start and whenever
    /// preferences change.
    @MainActor
    func refreshFromMainActor(promptForAccessibility: Bool = false) {
        let started = CACurrentMediaTime()
        let snapshot = preferences.settings
        logUploader?.setEnabled(snapshot.uploadLogs)
        let map = Preferences.effectiveMap(base: snapshot.gestureMap, profiles: snapshot.appProfiles,
                                           frontmost: frontmostBundleID)
        let layout = DisplayLayout.current()
        let bounds = layout.map(\.bounds)
        // Device discovery can take a while, so it happens here and not on the queue frames use.
        let device = CameraCapture.preferredDevice(id: snapshot.cameraDeviceID)
        let resolved = CameraPlacement.resolve(snapshot.cameraPlacement, displays: layout,
                                               builtInCamera: device?.deviceType == .builtInWideAngleCamera)
        // No-op unless the camera is running and the choice actually changed (checked on its queue).
        camera.switchDevice(to: device)
        let trusted = Permissions.accessibilityGranted(prompt: promptForAccessibility)
        let setup = GestureLog.Setup(install: logUploader?.installID ?? LogUploader.installID(in: .standard),
                                     displays: layout, camera: device, placement: resolved,
                                     accessibility: trusted, settings: snapshot)
        let mainMs = (CACurrentMediaTime() - started) * 1000
        camera.queue.async { [self] in
            prefs = snapshot
            displayLayout = layout
            post(pipeline.apply(snapshot, map: map, displays: bounds,
                                cameraMount: resolved.map { ($0.x, $0.display.bounds) },
                                lookDisplays: Dictionary(uniqueKeysWithValues: layout.map { ($0.uuid, $0.bounds) })))
            post(pipeline.setInputAllowed(trusted))
            publishBox()
            publishTargetDisplay()
            latestSetup = setup
            if let gestureLog, loggedSetup != setup {
                gestureLog.setup(setup)
                loggedSetup = setup
            }
            gestureLog?.note("refresh: \(Int(mainMs)) ms on the main thread")
        }
    }

    /// Starts the camera if needed, then records the hand for `Calibration.duration` seconds.
    /// No input is sent meanwhile. `completion` gets the measured box (Vision space) or nil.
    @MainActor
    func calibrate(completion: @escaping @MainActor (CGRect?) -> Void) async {
        guard let token = samplingOwner.claim(.reach, cancelled: {
            DispatchQueue.main.async { completion(nil) }
        }) else { completion(nil); return }
        if !state.isRunning { await start() }
        guard state.isRunning, !Task.isCancelled, samplingOwner.contains(token) else {
            if samplingOwner.release(token) { completion(nil) }
            return
        }
        guard input.setSampling(true) else {
            samplingOwner.release(token)
            completion(nil)
            return
        }
        snapshots.start()
        state.calibration = .running(secondsLeft: Int(Calibration.duration))
        camera.queue.async { [self] in
            guard samplingOwner.contains(token) else { return }
            post(pipeline.releaseHeld())
            calibrationToken = token
            calibrationSamples = []
            lastHandTime = CACurrentMediaTime()
            calibrationEnd = CACurrentMediaTime() + Calibration.duration
            onCalibrated = completion
        }
    }

    @MainActor
    func startLookSampling(onCancelled: @escaping @MainActor () -> Void,
                           _ handler: @escaping @MainActor (FacePose?) -> Void) async -> UUID? {
        await startSampling(kind: .look, label: "Calibrating look", face: true, onCancelled: onCancelled) {
            _, face in handler(face)
        }
    }

    @MainActor
    func startHandSampling(onCancelled: @escaping @MainActor () -> Void,
                           _ handler: @escaping @MainActor ([HandPose]) -> Void) async -> UUID? {
        await startSampling(kind: .gestureCheck, label: "Checking gestures", face: false, onCancelled: onCancelled) {
            hands, _ in handler(hands)
        }
    }

    @MainActor
    private func startSampling(kind: SamplingOwnership.Kind, label: String, face: Bool,
                               onCancelled: @escaping @MainActor () -> Void,
                               _ handler: @escaping @MainActor ([HandPose], FacePose?) -> Void) async -> UUID? {
        guard let token = samplingOwner.claim(kind, cancelled: {
            DispatchQueue.main.async { onCancelled() }
        }) else { return nil }
        if !state.isRunning { await start() }
        guard state.isRunning, !Task.isCancelled, samplingOwner.contains(token) else {
            samplingOwner.release(token)
            return nil
        }
        guard input.setSampling(true) else {
            samplingOwner.release(token)
            return nil
        }
        snapshots.start()
        camera.queue.async { [self] in
            guard samplingOwner.contains(token) else { return }
            post(pipeline.releaseHeld())
            lastHandTime = CACurrentMediaTime()
            sampling = (token, handler, face, label)
        }
        return token
    }

    @MainActor
    func stopSampling(_ token: UUID) {
        guard samplingOwner.release(token) else { return }
        input.setSampling(false)
        if state.isRunning { snapshots.start() }
        camera.queue.async { [self] in
            guard sampling == nil || sampling?.token == token else { return }
            sampling = nil
            pipeline.reset()
        }
    }

    /// Writes a note to the gesture log, if it's recording. Look calibration marks each dot with
    /// one, so a log can be split into the samples for each display afterwards.
    @MainActor
    func logNote(_ text: String) {
        camera.queue.async { [self] in gestureLog?.note(text) }
    }

    /// One sampling frame. Returns true while sampling, so the caller skips gesture handling.
    /// Logged like any other frame, so a calibration that goes wrong can be read back.
    private func samplingStep(_ buffer: CMSampleBuffer, hands: [HandPose], primary: HandPose?, fps: Double,
                              now: CFTimeInterval, sinceLastMs: Double?, detectMs: Double, uiToken: UUID, inputToken: UInt64) -> Bool {
        guard let sampling, samplingOwner.contains(sampling.token) else { return false }
        var face: FacePose?
        var faceMs: Double?
        if sampling.wantsFace {
            let faceStart = CACurrentMediaTime()
            face = faceTracker.detect(in: buffer, includeEyeDetails: false)
            faceMs = (CACurrentMediaTime() - faceStart) * 1000
        }
        gestureLog?.write(time: Date(), fps: fps, hands: hands, primary: primary, face: face,
                          output: GestureRecognizer.Output(mode: .idle, pointer: nil, actions: [], label: sampling.label),
                          cursor: nil, sinceLastMs: sinceLastMs, detectMs: detectMs, faceMs: faceMs,
                          processMs: (CACurrentMediaTime() - now) * 1000)
        guard input.isCurrent(inputToken), samplingOwner.contains(sampling.token) else { return true }
        snapshots.offer(TrackingSnapshot(hands: hands, face: face, fps: fps, label: sampling.label,
                                        warning: nil, box: pipeline.box, targetName: targetDisplayName), token: uiToken)
        DispatchQueue.main.async {
            guard self.samplingOwner.contains(sampling.token) else { return }
            sampling.handler(hands, face)
        }
        return true
    }

    /// One calibration frame. Returns true while calibrating, so the caller skips gesture handling.
    private func calibrationStep(hands: [HandPose], now: CFTimeInterval, fps: Double, uiToken: UUID) -> Bool {
        guard let end = calibrationEnd, let token = calibrationToken, samplingOwner.contains(token) else { return false }
        if let pointer = GestureRecognizer.primaryHand(hands, prefer: prefs.mainHand)?.pointer {
            calibrationSamples.append(pointer)
        }
        let left = end - now
        if left > 0 {
            let seconds = Int(left.rounded(.up))
            // Stretch the green box over what's been traced so far, so you see what's measured.
            let traced = calibrationSamples.count >= Calibration.minimumSamples
                ? Calibration.extent(of: calibrationSamples).map { ScreenMapper.visionRect(forViewBox: $0, mirrored: prefs.mirrored) }
                : nil
            snapshots.offer(TrackingSnapshot(hands: hands, face: nil, fps: fps,
                label: "Calibrating: move your whole hand around the edge of your comfortable reach, \(seconds)s",
                warning: nil, calibration: .running(secondsLeft: seconds), box: traced ?? pipeline.box,
                targetName: targetDisplayName), token: uiToken)
            return true
        }
        calibrationEnd = nil
        calibrationToken = nil
        let result = Calibration.box(from: calibrationSamples)
        let traced = Calibration.extent(of: calibrationSamples) ?? .zero
        gestureLog?.note(String(format: "calibration: %d samples, traced %.3f x %.3f, %@", calibrationSamples.count,
                                traced.width, traced.height, result == nil ? "rejected" : "saved"))
        calibrationSamples = []
        pipeline.reset()
        // The live preview overwrote the published box. A saved box is published by the refresh the
        // preference change triggers; a rejected one puts the old box back now.
        publishedBox = nil
        if result == nil { publishBox() }
        let done = onCalibrated
        onCalibrated = nil
        snapshots.offer(TrackingSnapshot(hands: hands, face: nil, fps: fps,
            label: result == nil ? "Calibration saw too small an area. Move your whole hand, not just your fingers." : "Calibrated",
            warning: nil, calibration: result == nil ? .failed : .finished,
            box: pipeline.box, targetName: targetDisplayName), token: uiToken)
        DispatchQueue.main.async {
            guard self.samplingOwner.release(token) else { return }
            self.input.setSampling(false)
            self.state.calibration = result == nil ? .failed : .finished
            done?(result)
        }
        return true
    }

    /// Camera queue. Publishes the control box when it changes.
    private func publishBox() {
        let box = pipeline.box
        guard box != publishedBox else { return }
        publishedBox = box
        let token = snapshots.currentToken
        DispatchQueue.main.async {
            guard token == self.snapshots.currentToken else { return }
            if self.state.controlBox != box { self.state.controlBox = box }
        }
    }

    /// Camera queue. Publishes the name of the display the control box maps onto when it changes,
    /// in the modes where it can change. Nil elsewhere so the UI shows nothing.
    private func publishTargetDisplay() {
        let name = targetDisplayName
        guard name != publishedTargetName else { return }
        publishedTargetName = name
        let token = snapshots.currentToken
        DispatchQueue.main.async {
            guard token == self.snapshots.currentToken else { return }
            if self.state.targetDisplayName != name { self.state.targetDisplayName = name }
        }
    }

    private var targetDisplayName: String? {
        guard prefs.displayMode == .lookedAt || prefs.displayMode == .followCursor else { return nil }
        return displayLayout.first { $0.bounds == pipeline.screen }?.name
    }

    private func post(_ commands: [InputCommand]) { input.submit(commands) }

    private func logTiming() {
        if let note = input.timingNote() { gestureLog?.note(note) }
        if let log = gestureLog {
            let stats = log.diagnostics
            log.note(String(format: "log writer: pending %d peak %d written %d dropped %d failed %d; enqueue %.3f ms max %.3f ms; encode %.3f ms max %.3f ms; write %.3f ms max %.3f ms",
                            stats.pendingLines, stats.highWaterMark, stats.writtenLines, stats.droppedLines, stats.failedLines,
                            stats.enqueueMs, stats.maxEnqueueMs, stats.encodeMs, stats.maxEncodeMs,
                            stats.writeMs, stats.maxWriteMs))
        }
        if droppedFrames > 0 {
            gestureLog?.note("camera dropped: \(droppedFrames) frames, reasons \(droppedReasons)")
            droppedFrames = 0
            droppedReasons = [:]
        }
    }

    /// Power saving: after this long with no hand, analyze only every `idleStride`th frame.
    private static let idleAfter: CFTimeInterval = 60
    private static let idleStride = 6

    /// Runs on the camera queue.
    private func process(_ buffer: CMSampleBuffer) {
        guard let inputToken = input.beginFrame(), let uiToken = snapshots.currentToken else { return }
        let now = CACurrentMediaTime()
        let sinceLast = lastFrameTime > 0 ? now - lastFrameTime : nil
        lastFrameTime = now
        frameCount += 1
        if frameCount % 30 == 0 { logTiming() }
        let idle = prefs.powerSaving && lastHandTime > 0 && now - lastHandTime > Self.idleAfter
        if idle, frameCount % Self.idleStride != 0 { return }
        if let gestureLog, Date().timeIntervalSince(gestureLog.started) > Self.logRotateAfter {
            closeLog()
            openLog()
        }

        if frameCount % 15 == 0, let pixels = CMSampleBufferGetImageBuffer(buffer),
           let luma = TrackingQuality.meanLuma(of: pixels) {
            quality.addBrightness(luma)
        }
        let detectStart = CACurrentMediaTime()
        let hands = tracker.detect(in: buffer)
        let detectMs = (CACurrentMediaTime() - detectStart) * 1000
        guard input.isCurrent(inputToken) else { return }
        if lastHandTime == 0 || !hands.isEmpty { lastHandTime = now }
        let primary = GestureRecognizer.primaryHand(hands, prefer: prefs.mainHand)
        if let primary {
            let values = primary.confidence.values
            if !values.isEmpty { quality.addConfidence(Double(values.reduce(0, +)) / Double(values.count)) }
        } else {
            quality.handLost()
        }
        let warning = quality.warning
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        if calibrationStep(hands: hands, now: now, fps: Double(frameTimes.count), uiToken: uiToken) { return }
        if samplingStep(buffer, hands: hands, primary: primary, fps: Double(frameTimes.count), now: now,
                        sinceLastMs: sinceLast.map { $0 * 1000 }, detectMs: detectMs, uiToken: uiToken, inputToken: inputToken) { return }
        // Ownership may be claimed while this frame is in detection, before its setup is queued.
        guard !samplingOwner.isOccupied else { return }
        let fps = Double(frameTimes.count)

        // The face feeds the log and, in look mode, the display pick. Look mode detects it on every
        // other frame (the picker's dwell hides a frame's delay); the log alone every sixth, since
        // head angles and distance change slowly and the face request costs more than the hands.
        // Frames in between reuse the last face for the picker and the preview, and log none, so
        // the log holds only fresh readings.
        let looking = prefs.displayMode == .lookedAt
        let detectsFace = frameCount % (looking ? 2 : Self.faceLogStride) == 0
        var freshFace: FacePose?
        var faceMs: Double = 0
        if detectsFace {
            let faceStart = CACurrentMediaTime()
            freshFace = faceTracker.detect(in: buffer, includeEyeDetails: frameCount % Self.faceLogStride == 0)
            faceMs = (CACurrentMediaTime() - faceStart) * 1000
            lastFace = freshFace
            if frameCount % Self.faceLogStride == 0 || freshFace == nil {
                previewFace = freshFace
            } else if var preview = freshFace {
                preview.leftEye = previewFace?.leftEye
                preview.rightEye = previewFace?.rightEye
                preview.landmarkConfidence = previewFace?.landmarkConfidence
                previewFace = preview
            }
        }
        let face = freshFace ?? lastFace

        guard let frame = processTrackedFrame(hands: hands, face: face, at: now, generation: inputToken) else { return }
        if let gestureLog {
            gestureLog.write(time: Date(), fps: fps, hands: hands, primary: primary, face: freshFace,
                             output: frame.recognized, cursor: frame.cursor, sinceLastMs: sinceLast.map { $0 * 1000 },
                             detectMs: detectMs, faceMs: detectsFace ? faceMs : nil,
                             processMs: (CACurrentMediaTime() - now) * 1000, warning: warning, idle: idle)
        }
        let recognized = frame.recognized
        snapshots.offer(TrackingSnapshot(hands: hands, face: previewFace, fps: fps,
            label: idle ? "Idle: checking for your hand a few times a second" : recognized.label,
            warning: warning, idle: idle, mode: recognized.mode, feedback: recognized.feedback,
            trigger: recognized.trigger, box: pipeline.box, targetName: targetDisplayName), token: uiToken)
    }

    /// Camera queue, after detection. Kept separate from Vision so lifecycle tests exercise the
    /// same recognizer, generation checks and posting path with synthetic poses and a fake sink.
    @discardableResult
    func processTrackedFrame(hands: [HandPose], face: FacePose? = nil, at now: TimeInterval,
                             generation inputToken: UInt64) -> FramePipeline.Output? {
        guard input.isCurrent(inputToken), !samplingOwner.isOccupied else { return nil }
        let frame = pipeline.step(hands: hands, face: face, at: now) { input.location() }
        let clicked = frame.commands.contains(where: \.isClick)
        let events = frame.recognized.events
        input.submit(frame.commands, generation: inputToken, frameTime: now) { [weak self] in
            guard clicked || !events.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                if clicked { self.state.clicks.send() }
                for event in events { self.state.events.send(event) }
            }
        }
        return frame
    }
}
