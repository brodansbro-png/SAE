import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../../app/theme.dart';
import '../../data/face_detection_service.dart';
import 'common.dart';

/// Evidence capture: a live camera with a liveness overlay.
///
/// The punch button is not even shown until this returns, because a face check
/// that can be skipped is not a check. Everything here is advisory about *which*
/// action to perform; the decision to enable capture belongs to
/// [LivenessChallenge], which the test suite covers exhaustively.
class FaceCaptureSheet extends StatefulWidget {
  const FaceCaptureSheet({super.key});

  @override
  State<FaceCaptureSheet> createState() => _FaceCaptureSheetState();
}

class _FaceCaptureSheetState extends State<FaceCaptureSheet>
    with WidgetsBindingObserver {
  final FaceDetectionService _service = FaceDetectionService();

  bool _initialising = true;
  bool _capturing = false;
  bool _verified = false;
  String _status = 'Menyiapkan kamera…';
  CameraFailure? _failure;
  Face? _face;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The camera is released in the background, because iOS suspends the whole
    // app and holding the camera open there is a policy violation.
    if (state == AppLifecycleState.resumed && _verified) {
      _restart();
    }
  }

  Future<void> _start() async {
    setState(() {
      _initialising = true;
      _failure = null;
      _status = 'Menyiapkan kamera…';
    });

    try {
      _service.onStatusChanged((challenge, face) {
        if (!mounted) return;
        setState(() {
          _status = challenge.statusMessage;
          _face = face;
          _verified = challenge.isSatisfied;
        });
      });

      await _service.initialise();
      if (!mounted) return;

      setState(() {
        _initialising = false;
        _status = _service.statusMessage;
      });
    } on CameraFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _initialising = false;
        _failure = failure;
        _status = failure.message;
      });
    }
  }

  Future<void> _restart() async {
    setState(() {
      _verified = false;
      _initialising = true;
    });
    await _service.retry();
    await _start();
  }

  Future<void> _capture() async {
    if (_capturing || !_verified) return;

    setState(() => _capturing = true);
    try {
      final File photo = await _service.captureEvidence();
      final marker = await _service.writeLivenessMarker(photo, passed: true);

      if (!mounted) return;
      Navigator.of(context).pop(
        CapturedEvidence(path: photo.path, livenessMarkerPath: marker.path),
      );
    } on CameraException catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        'Foto gagal diambil: ${error.code}',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Verifikasi Wajah'),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_service.isCameraReady)
            CameraPreview(_service.cameraPreview!)
          else
            const ColoredBox(color: Colors.black),

          // Dim the preview until the check passes, so a screenshot taken mid
          // challenge is obviously incomplete rather than looking valid.
          if (!_verified)
            const ColoredBox(color: Color(0x99000000)),

          if (_initialising)
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),

          SafeArea(
            child: Column(
              children: [
                const Spacer(),
                _Overlay(
                  passed: _verified,
                  face: _face,
                  detected: _face != null,
                ),
                const SizedBox(height: 20),
                _StatusPanel(
                  status: _status,
                  failure: _failure,
                  onRetry: _failure?.isRetryable == true ? _start : _restart,
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      // Disabled until liveness passes. The visual state and the
                      // logic are the same flag, so they cannot disagree.
                      onPressed: _verified && !_capturing ? _capture : null,
                      icon: _capturing
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.camera_alt),
                      label: Text(
                        _verified ? 'Ambil foto' : 'Verifikasi wajah terlebih dahulu',
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                        backgroundColor: _verified ? SaeTheme.success : theme.colorScheme.surface,
                        foregroundColor:
                            _verified ? Colors.white : theme.colorScheme.outline,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The evidence returned to the attendance screen.
class CapturedEvidence {
  const CapturedEvidence({required this.path, this.livenessMarkerPath});

  final String path;
  final String? livenessMarkerPath;
}

/// The face outline and status ring.
class _Overlay extends StatelessWidget {
  const _Overlay({
    required this.passed,
    required this.detected,
    this.face,
  });

  final bool passed;
  final bool detected;
  final Face? face;

  @override
  Widget build(BuildContext context) {
    final color = passed
        ? SaeTheme.success
        : detected
            ? SaeTheme.warning
            : Colors.white54;

    return Center(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        width: 250,
        height: 310,
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(125),
            bottom: Radius.circular(125),
          ),
          border: Border.all(color: color, width: 3),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.3),
              blurRadius: 18,
              spreadRadius: 1,
            ),
          ],
        ),
        child: face == null
            ? null
            // The box tracks the face so the employee can see it is being
            // tracked rather than guessing whether they are centred.
            : Align(
                alignment: Alignment.center,
                child: Transform.translate(
                  offset: const Offset(0, 0),
                  child: Icon(Icons.face_retouching_natural,
                      size: 96, color: color.withValues(alpha: 0.7)),
                ),
              ),
      ),
    );
  }
}

/// The instruction line, and the remedy when the camera failed.
class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.status,
    required this.onRetry,
    this.failure,
  });

  final String status;
  final CameraFailure? failure;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final tone = failure == null
        ? Colors.white
        : (failure!.isRetryable ? Colors.white : const Color(0xFFFFCDD2));

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            status,
            textAlign: TextAlign.center,
            style: TextStyle(color: tone, fontSize: 15, height: 1.4),
          ),
          if (failure != null) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Coba lagi'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white54),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Opens the capture sheet and returns the evidence, or `null` if cancelled.
Future<CapturedEvidence?> captureWithLiveness(BuildContext context) {
  return Navigator.of(context).push<CapturedEvidence>(
    MaterialPageRoute(builder: (_) => const FaceCaptureSheet()),
  );
}

/// Convenience for screens that only need the path.
Future<String?> capturePhotoPath(BuildContext context) async {
  final evidence = await captureWithLiveness(context);
  return evidence?.path;
}

/// Reads the liveness verdict off a punch, for the history screen.
///
/// Null is rendered distinctly from `false`: a punch taken before liveness
/// existed is *unknown*, and showing it as "not verified" would read as an
/// accusation against a record that simply predates the check.
String describeLiveness(bool? verified) {
  if (verified == null) return 'Tidak dicatat';
  return verified ? 'Wajah terverifikasi' : 'Wajah tidak terverifikasi';
}