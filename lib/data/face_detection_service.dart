import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// On-device face detection and liveness, for evidence capture.
///
/// Everything runs locally: no frame leaves the device during detection. ML Kit
/// ships as a bundled model, so this also works with no network.
///
/// **What this proves.** A real human face was in front of the front camera, and
/// it responded to a randomly ordered challenge sequence over several seconds.
/// That is meaningfully stronger than "a photo was attached".
///
/// **What it does not prove.** It does not prove *which* human. A printed photo
/// held up to a screen will pass a blink challenge if the attacker re-plays the
/// frames. Binding the capture to a registered face embedding, or running a
/// server-side liveness model, is what closes that gap — both need a server the
/// current Firebase-only architecture does not have. The gap is documented in
/// `README.md` rather than papered over.
class FaceDetectionService {
  FaceDetectionService({
    FaceDetectorOptions? options,
    LivenessPolicy? policy,
  })  : _options = options ??
            FaceDetectorOptions(
              // These three enable the eye-open probabilities the blink challenge
              // reads. Without `enableClassification` they are always null, and the
              // challenge would silently never complete.
              enableClassification: true,
              enableTracking: true,
              // `accurate` rather than `fast`: the cheaper detector does not
              // produce reliable eye probabilities at a distance.
              performanceMode: FaceDetectorMode.accurate,
              minFaceSize: 0.15,
            ),
        _policy = policy ?? const LivenessPolicy();

  final FaceDetectorOptions _options;
  final LivenessPolicy _policy;

  FaceDetector? _detector;
  CameraController? _camera;

  /// A randomised challenge the employee must complete before capture.
  late LivenessChallenge _challenge = LivenessChallenge.generate(_policy.challengeCount);

  /// Whether the current challenge sequence has been satisfied.
  bool _passed = false;

  /// Guards against overlapping image-stream callbacks.
  ///
  /// The camera delivers frames faster than ML Kit processes them; without this
  /// gate several detections queue up against the same state and the challenge
  /// index advances twice for one physical blink.
  bool _processing = false;

  /// Retained between frames so the UI can rebuild on any Flutter event without
  /// re-running detection.
  void Function(LivenessChallenge challenge, Face? face) _statusSink = (_, _) {};

  LivenessChallenge get challenge => _challenge;

  bool get isPassed => _passed;

  bool get isCameraReady => _camera != null && _camera!.value.isInitialized;

  /// The camera controller, for `CameraPreview`.
  ///
  /// Nullable because it only exists after [initialise]; the UI must check
  /// [isCameraReady] rather than assume one.
  CameraController? get cameraPreview => _camera;

  /// The stream's current status line, for the overlay.
  String get statusMessage => _challenge.statusMessage;

  /// Registers the callback that receives per-frame progress.
  void onStatusChanged(void Function(LivenessChallenge challenge, Face? face) callback) {
    _statusSink = callback;
  }

  /// Opens the front camera and starts the detection stream.
  ///
  /// Prefers the front lens because a selfie is the only angle from which the
  /// employee's own face can be verified; falls back to whatever camera exists so
  /// a tablet without a selfie lens still produces evidence, at the cost of the
  /// liveness challenge being meaningless.
  Future<void> initialise() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw const CameraFailure(CameraUnavailable.noCamera);
    }

    final front = cameras.where(
      (camera) => camera.lensDirection == CameraLensDirection.front,
    );
    final selected = front.isNotEmpty ? front.first : cameras.first;

    _detector = FaceDetector(options: _options);
    _camera = CameraController(
      selected,
      // `medium` is the sweet spot: enough pixels for reliable eye probabilities,
      // low enough that a frame is processed inside the stream interval on a
      // mid-range phone. `high` halves the frame rate and the challenges become
      // frustrating.
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _camera!.initialize();
    } on CameraException catch (error) {
      throw CameraFailure(_translateCameraError(error));
    }

    await _startStream();
  }

  /// Resets the challenge and resumes the stream after a failed attempt.
  Future<void> retry() async {
    _challenge = LivenessChallenge.generate(_policy.challengeCount);
    _passed = false;
    _processing = false;
    await _startStream();
  }

  /// Stops the stream without disposing the camera, so the preview can resume.
  Future<void> pause() async {
    if (_camera != null && _camera!.value.isStreamingImages) {
      await _camera!.stopImageStream();
    }
  }

  /// Processes one frame, reporting progress through the registered sink.
  Future<void> processFrame(CameraImage image) async {
    if (_processing || _passed || _detector == null || _camera == null) return;
    _processing = true;

    try {
      final input = _toInputImage(image, _camera!);
      if (input == null) {
        _processing = false;
        return;
      }

      final faces = await _detector!.processImage(input);

      if (faces.isEmpty) {
        // No face: reset the challenge's partial progress so a blink started
        // before the face left the frame cannot be completed afterwards.
        _challenge.onFaceLost();
        _statusSink(_challenge, null);
        return;
      }

      // The largest face is the subject. A second, smaller face is not treated
      // as an attack here — two employees sharing a phone is handled by the
      // device-id check, and refusing on face count alone would break legitimate
      // shared kiosks.
      faces.sort(
        (a, b) => (b.boundingBox.width * b.boundingBox.height)
            .compareTo(a.boundingBox.width * a.boundingBox.height),
      );
      final subject = faces.first;

      _challenge.observe(subject, _policy);
      _statusSink(_challenge, subject);

      if (_challenge.isSatisfied) {
        _passed = true;
        await pause();
      }
    } catch (_) {
      // A detection failure is neither a pass nor a fail: the frame is dropped
      // and the next is tried, so a transient plugin error does not lock the
      // employee out mid-capture.
    } finally {
      _processing = false;
    }
  }

  /// Captures the evidence photograph.
  ///
  /// Called only once the challenge is satisfied, which is what guarantees the
  /// frame came from a live camera rather than a gallery pick.
  Future<File> captureEvidence() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) {
      throw const CameraFailure(CameraUnavailable.notReady);
    }
    final XFile shot = await camera.takePicture();
    return File(shot.path);
  }

  /// Writes a `liveness:passed` marker alongside the evidence file.
  ///
  /// The dashboard reads this to distinguish a verified capture from one taken
  /// before liveness existed, without needing the frames themselves.
  Future<File> writeLivenessMarker(File evidence, {required bool passed}) async {
    final marker = File('${evidence.path}.liveness');
    await marker.writeAsString(
      'v1\nliveness=${passed ? 'passed' : 'unknown'}\n'
      'capturedAt=${DateTime.now().toIso8601String()}\n',
    );
    return marker;
  }

  Future<void> _startStream() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;
    if (camera.value.isStreamingImages) return;

    try {
      await camera.startImageStream((image) => processFrame(image));
    } on CameraException catch (error) {
      throw CameraFailure(_translateCameraError(error));
    }
  }

  /// Converts a camera frame into ML Kit's input format.
  ///
  /// Rotation and pixel format differ per platform and per sensor orientation.
  /// Getting them wrong yields a rotated or unreadable image, which ML Kit
  /// reports as "no face" rather than as an error — so the screen would sit on
  /// "Wajah tidak terdeteksi" forever with no clue why.
  static InputImage? _toInputImage(CameraImage image, CameraController controller) {
    final camera = controller.description;

    final rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (rotation == null || format == null || image.planes.isEmpty) return null;

    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  static CameraUnavailable _translateCameraError(CameraException error) {
    switch (error.code) {
      case 'CameraAccessDenied':
      case 'CameraAccessDeniedWithoutPrompt':
      case 'CameraAccessRestricted':
      case 'AudioAccessDenied':
        return CameraUnavailable.permissionDenied;
      default:
        return CameraUnavailable.failedToInitialise;
    }
  }

  Future<void> dispose() async {
    await _camera?.dispose();
    await _detector?.close();
    _camera = null;
    _detector = null;
  }
}

/// Why the camera could not be used.
enum CameraUnavailable {
  /// The device has no usable camera.
  noCamera,

  /// The user refused the camera permission.
  permissionDenied,

  /// The camera did not come up.
  failedToInitialise,

  /// A capture was requested before initialisation finished.
  notReady,
}

/// A camera failure carrying the reason.
class CameraFailure implements Exception {
  const CameraFailure(this.reason);

  final CameraUnavailable reason;

  String get message {
    switch (reason) {
      case CameraUnavailable.noCamera:
        return 'Tidak ada kamera yang dapat digunakan pada perangkat ini.';
      case CameraUnavailable.permissionDenied:
        return 'Izin kamera ditolak. Aktifkan melalui pengaturan aplikasi.';
      case CameraUnavailable.failedToInitialise:
        return 'Kamera tidak dapat dibuka. Tutup aplikasi lain yang memakai '
            'kamera lalu coba lagi.';
      case CameraUnavailable.notReady:
        return 'Kamera belum siap. Tunggu sebentar lalu coba lagi.';
    }
  }

  bool get isRetryable =>
      reason == CameraUnavailable.failedToInitialise ||
      reason == CameraUnavailable.notReady;

  @override
  String toString() => 'CameraFailure(${reason.name})';
}

/// A liveness action the employee must perform.
enum LivenessAction {
  /// Both eyes closed, then open.
  blink('Kedipkan kedua mata'),

  /// Turn the head to the subject's left, which reads as a right turn to them.
  turnLeft('Tolehkan wajah ke kiri'),

  /// Turn the head to the subject's right.
  turnRight('Tolehkan wajah ke kanan');

  const LivenessAction(this.instruction);

  /// Indonesian copy shown on the overlay.
  final String instruction;
}

/// The tuning of the liveness challenge.
class LivenessPolicy {
  const LivenessPolicy({
    this.challengeCount = 2,
    this.blinkClosedThreshold = 0.35,
    this.blinkOpenThreshold = 0.65,
    this.minBlinkDurationMs = 80,
    this.maxBlinkDurationMs = 600,
    this.headYawThresholdDegrees = 15,
  });

  /// How many actions must be completed.
  ///
  /// Two is the sweet spot: one is a single frame of evidence, three starts to
  /// annoy a staff queue at a morning punch.
  final int challengeCount;

  /// Below this, an eye counts as closed. Relaxed from a strict 0.5 because a
  /// glasses-wearing employee frequently reads just under it.
  final double blinkClosedThreshold;

  /// Above this, an eye counts as open.
  final double blinkOpenThreshold;

  /// Shortest blink that counts.
  ///
  /// A human blink is 100–400 ms; anything shorter is ML Kit's noise rather than
  /// a deliberate one, so accepting 80 ms would let a held photograph pass.
  final int minBlinkDurationMs;

  /// Longest blink that counts, which excludes a prolonged eye closure.
  final int maxBlinkDurationMs;

  /// Head rotation required for a turn challenge, in degrees.
  final double headYawThresholdDegrees;
}

/// The randomised challenge the employee must satisfy.
class LivenessChallenge {
  LivenessChallenge(this.actions);

  /// Builds a shuffled challenge of [count] actions.
  ///
  /// Randomised per attempt so the sequence cannot be rehearsed: a fixed order
  /// is satisfiable by a script replaying three recorded clips.
  factory LivenessChallenge.generate(int count) {
    final pool = List<LivenessAction>.from(LivenessAction.values)..shuffle(Random());
    return LivenessChallenge(pool.take(min(count, pool.length)).toList());
  }

  final List<LivenessAction> actions;
  int _currentIndex = 0;

  DateTime? _blinkStartedAt;
  LivenessAction? _blinkClosedForAction;

  int get currentIndex => _currentIndex;

  int get total => actions.length;

  bool get isComplete => _currentIndex >= actions.length;

  /// Alias for [isComplete], reading better at the gate that enables capture.
  bool get isSatisfied => isComplete;

  /// The action currently being asked for, or `null` once all are done.
  LivenessAction? get currentAction =>
      _currentIndex < actions.length ? actions[_currentIndex] : null;

  /// The Indonesian status line for the overlay.
  String get statusMessage {
    if (isComplete) return 'Wajah terverifikasi. Silakan ambil foto.';

    final action = currentAction!;
    return 'Tantangan ${_currentIndex + 1} dari $total: ${action.instruction}';
  }

  /// Resets progress after the face leaves the frame.
  ///
  /// A blink half-completed before the face was lost would otherwise be finished
  /// by the first frame after it returns, letting an attacker holding a photo
  /// steady satisfy a blink across one dropout.
  void onFaceLost() {
    _blinkStartedAt = null;
    _blinkClosedForAction = null;
  }

  /// Folds one frame's face into the challenge.
  void observe(Face face, LivenessPolicy policy) {
    final action = currentAction;
    if (action == null) return;

    switch (action) {
      case LivenessAction.blink:
        _observeBlink(face, policy);
      case LivenessAction.turnLeft:
      case LivenessAction.turnRight:
        _observeTurn(face, policy, action);
    }
  }

  void _observeBlink(Face face, LivenessPolicy policy) {
    final left = face.leftEyeOpenProbability ?? 1.0;
    final right = face.rightEyeOpenProbability ?? 1.0;

    final bothClosed =
        left < policy.blinkClosedThreshold && right < policy.blinkClosedThreshold;
    final bothOpen =
        left > policy.blinkOpenThreshold && right > policy.blinkOpenThreshold;

    final now = DateTime.now();

    if (bothClosed) {
      // The clock starts on the first closed frame, and only for the action it
      // belongs to, so a closure during a different challenge does not count.
      if (_blinkStartedAt == null || _blinkClosedForAction != currentAction) {
        _blinkStartedAt = now;
        _blinkClosedForAction = currentAction;
      }
      return;
    }

    if (bothOpen && _blinkStartedAt != null) {
      final elapsedMs = now.difference(_blinkStartedAt!).inMilliseconds;
      _blinkStartedAt = null;
      _blinkClosedForAction = null;

      if (elapsedMs >= policy.minBlinkDurationMs &&
          elapsedMs <= policy.maxBlinkDurationMs) {
        advance();
      }
    }
  }

  void _observeTurn(Face face, LivenessPolicy policy, LivenessAction action) {
    // Yaw is positive when the subject turns to their left. The threshold is
    // generous: too tight and the instruction becomes a head-positioning test
    // rather than a liveness one.
    final yaw = face.headEulerAngleY ?? 0.0;
    final threshold = policy.headYawThresholdDegrees;

    // Inclusive at the boundary: a yaw estimate reported as exactly the
    // threshold is within sensor noise of a real turn, and refusing it would
    // reject a genuine attempt over a floating-point rounding difference.
    final satisfied = action == LivenessAction.turnLeft
        ? yaw >= threshold
        : yaw <= -threshold;

    if (satisfied) advance();
  }

  /// Marks the current action complete.
  void advance() {
    if (isComplete) return;
    _currentIndex++;
    _blinkStartedAt = null;
    _blinkClosedForAction = null;
  }
}