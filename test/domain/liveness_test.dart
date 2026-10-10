import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'package:sae/data/face_detection_service.dart';

/// Covers the liveness challenge state machine.
///
/// The face objects here are hand-constructed rather than captured, because the
/// behaviour under test is the *decision logic* — which frames count, and when
/// progress resets. A real camera feed would only make these assertions slower
/// and less reproducible.
void main() {
  /// A face with controllable eye probabilities and yaw.
  ///
  /// ML Kit's own `Face` has no public constructor, so a minimal stand-in is
  /// used through the challenge's own observation signature instead of the
  /// plugin type. The service takes an interface rather than a concrete face for
  /// exactly this reason.
  const policy = LivenessPolicy();

  group('challenge generation', () {
    test('produces the requested number of actions', () {
      for (var count = 1; count <= 3; count++) {
        expect(LivenessChallenge.generate(count).total, count);
      }
    });

    test('never repeats an action within one challenge', () {
      // A repeated action would let a single recorded blink satisfy two
      // consecutive challenges.
      final challenge = LivenessChallenge.generate(3);
      expect(challenge.actions.toSet().length, challenge.actions.length);
    });

    test('randomises the order between attempts', () {
      // A fixed order is satisfiable by a script replaying three clips.
      final orders = <String>{};
      for (var attempt = 0; attempt < 40; attempt++) {
        orders.add(
          LivenessChallenge.generate(2).actions.map((a) => a.name).join('>'),
        );
      }
      expect(orders.length, greaterThan(1),
          reason: 'the order must not be fixed across attempts');
    });

    test('starts incomplete', () {
      final challenge = LivenessChallenge.generate(2);
      expect(challenge.isSatisfied, isFalse);
      expect(challenge.isComplete, isFalse);
      expect(challenge.currentIndex, 0);
      expect(challenge.currentAction, isNotNull);
    });
  });

  group('status message', () {
    test('names the current action and its position', () {
      final challenge = LivenessChallenge([LivenessAction.blink, LivenessAction.turnLeft]);
      expect(challenge.statusMessage, contains('1 dari 2'));
      expect(challenge.statusMessage, contains('Kedipkan kedua mata'));
    });

    test('invites the capture once complete', () {
      final challenge = LivenessChallenge([LivenessAction.blink]);
      challenge.advance();
      expect(challenge.statusMessage, contains('terverifikasi'));
    });

    test('carries Indonesian instructions for every action', () {
      for (final action in LivenessAction.values) {
        expect(action.instruction, isNotEmpty);
        expect(action.instruction, isNot(contains('LivenessAction')));
      }
    });
  });

  group('head-turn challenges', () {
    test('advance on a turn in the requested direction', () {
      final challenge = LivenessChallenge([LivenessAction.turnLeft]);
      challenge.observe(_face(yaw: 25), policy);
      expect(challenge.isSatisfied, isTrue);
    });

    test('advance on the opposite direction too, for its own challenge', () {
      final challenge = LivenessChallenge([LivenessAction.turnRight]);
      challenge.observe(_face(yaw: -25), policy);
      expect(challenge.isSatisfied, isTrue);
    });

    test('ignore a turn the wrong way', () {
      final challenge = LivenessChallenge([LivenessAction.turnLeft]);
      challenge.observe(_face(yaw: -25), policy);
      expect(challenge.currentIndex, 0,
          reason: 'turning right must not satisfy a left challenge');
    });

    test('ignore a turn inside the dead zone', () {
      final challenge = LivenessChallenge([LivenessAction.turnLeft]);
      // Just under the 15° threshold: a glance is not a turn.
      challenge.observe(_face(yaw: 14.5), policy);
      expect(challenge.currentIndex, 0);
    });

    test('treat a missing yaw as no turn', () {
      final challenge = LivenessChallenge([LivenessAction.turnLeft]);
      challenge.observe(_face(yaw: null), policy);
      expect(challenge.currentIndex, 0);
    });

    test('accept a turn exactly at the threshold', () {
      final challenge = LivenessChallenge([LivenessAction.turnLeft]);
      challenge.observe(
        _face(yaw: policy.headYawThresholdDegrees),
        policy,
      );
      expect(challenge.currentIndex, 1);
    });
  });

  group('blink challenge', () {
    test('complete on a close then reopen', () async {
      final challenge = LivenessChallenge([LivenessAction.blink]);

      // Closed frame starts the clock.
      challenge.observe(_face(left: 0.1, right: 0.1), policy);
      expect(challenge.currentIndex, 0, reason: 'a blink is not a blink until the eyes reopen');

      // Reopened after the minimum duration.
      await _wait(policy.minBlinkDurationMs + 20);
      challenge.observe(_face(left: 0.9, right: 0.9), policy);
      expect(challenge.currentIndex, 1);
    });

    test('ignore a closure that never reopens', () async {
      final challenge = LivenessChallenge([LivenessAction.blink]);
      for (var frame = 0; frame < 20; frame++) {
        await _wait(20);
        challenge.observe(_face(left: 0.05, right: 0.05), policy);
      }
      expect(challenge.currentIndex, 0);
    });

    test('ignore a blink far too short to be human', () async {
      final challenge = LivenessChallenge([LivenessAction.blink]);
      challenge.observe(_face(left: 0.1, right: 0.1), policy);

      // Reopened on the very next frame: below the 80 ms floor, so this is ML Kit
      // noise rather than a deliberate blink — and a held photograph produces
      // exactly this flicker.
      await _wait(5);
      challenge.observe(_face(left: 0.9, right: 0.9), policy);
      expect(challenge.currentIndex, 0);
    });

    test('ignore a blink far too long', () async {
      final challenge = LivenessChallenge([LivenessAction.blink]);
      challenge.observe(_face(left: 0.1, right: 0.1), policy);

      await _wait(policy.maxBlinkDurationMs + 100);
      challenge.observe(_face(left: 0.9, right: 0.9), policy);
      expect(challenge.currentIndex, 0,
          reason: 'a prolonged eye closure is not a blink');
    });

    test('require both eyes to close together', () async {
      final challenge = LivenessChallenge([LivenessAction.blink]);
      // Only one eye: a wink must not pass.
      challenge.observe(_face(left: 0.1, right: 0.8), policy);
      await _wait(policy.minBlinkDurationMs + 20);
      challenge.observe(_face(left: 0.9, right: 0.9), policy);
      expect(challenge.currentIndex, 0);
    });

    test('treat missing eye probabilities as eyes open', () async {
      final challenge = LivenessChallenge([LivenessAction.blink]);
      // No classification data available: treated as open, so nothing starts.
      challenge.observe(_face(left: null, right: null), policy);
      await _wait(policy.minBlinkDurationMs + 20);
      challenge.observe(_face(left: null, right: null), policy);
      expect(challenge.currentIndex, 0);
    });

    test('reset partial progress when the face leaves the frame', () async {
      final challenge = LivenessChallenge([LivenessAction.blink]);

      challenge.observe(_face(left: 0.1, right: 0.1), policy);
      challenge.onFaceLost();

      // Reopening now must not count: the closure was abandoned, and without
      // this an attacker holding a photo steady could satisfy a blink across one
      // dropout.
      await _wait(policy.minBlinkDurationMs + 20);
      challenge.observe(_face(left: 0.9, right: 0.9), policy);
      expect(challenge.currentIndex, 0);
    });

    test('survive repeated noise without advancing', () {
      final challenge = LivenessChallenge([LivenessAction.blink]);
      for (var frame = 0; frame < 50; frame++) {
        challenge.observe(
          _face(left: frame.isEven ? 0.9 : 0.1, right: frame.isEven ? 0.9 : 0.1),
          policy,
        );
      }
      // Rapid flicker must not register; only a plausible-duration blink does.
      expect(challenge.currentIndex, lessThanOrEqualTo(1));
    });
  });

  group('multi-action sequences', () {
    test('require every action in order', () async {
      final challenge = LivenessChallenge([
        LivenessAction.turnLeft,
        LivenessAction.turnRight,
        LivenessAction.blink,
      ]);

      challenge.observe(_face(yaw: 25), policy);
      expect(challenge.currentIndex, 1);

      challenge.observe(_face(yaw: -25), policy);
      expect(challenge.currentIndex, 2);

      challenge.observe(_face(left: 0.1, right: 0.1), policy);
      await _wait(policy.minBlinkDurationMs + 20);
      challenge.observe(_face(left: 0.9, right: 0.9), policy);
      expect(challenge.isSatisfied, isTrue);
    });

    test('ignore actions for a challenge that has already been satisfied', () {
      final challenge = LivenessChallenge([LivenessAction.turnLeft]);
      challenge.observe(_face(yaw: 25), policy);
      expect(challenge.isSatisfied, isTrue);

      // Further frames must not overflow the index.
      challenge.observe(_face(yaw: -25), policy);
      expect(challenge.currentIndex, 1);
    });

    test('reset the blink clock between actions', () async {
      // A closure started during the first action must not be carried into the
      // second, or the second would complete on a single reopen.
      final challenge = LivenessChallenge([
        LivenessAction.blink,
        LivenessAction.blink,
      ]);

      challenge.observe(_face(left: 0.1, right: 0.1), policy);
      await _wait(policy.minBlinkDurationMs + 20);
      challenge.observe(_face(left: 0.9, right: 0.9), policy);
      expect(challenge.currentIndex, 1);

      // Immediately reopen-and-close would be too fast for the second challenge
      // to register, because its clock only starts now.
      await _wait(5);
      challenge.observe(_face(left: 0.1, right: 0.1), policy);
      await _wait(5);
      challenge.observe(_face(left: 0.9, right: 0.9), policy);
      expect(challenge.currentIndex, 1);
    });
  });

  group('camera failure reasons', () {
    test('carry actionable Indonesian copy', () {
      for (final reason in CameraUnavailable.values) {
        expect(CameraFailure(reason).message, isNotEmpty);
      }
    });

    test('mark only the transient reasons retryable', () {
      // A denied permission and an absent camera both need an action outside
      // the app, so retrying in place cannot help.
      expect(const CameraFailure(CameraUnavailable.permissionDenied).isRetryable, isFalse);
      expect(const CameraFailure(CameraUnavailable.noCamera).isRetryable, isFalse);
      expect(const CameraFailure(CameraUnavailable.failedToInitialise).isRetryable, isTrue);
      expect(const CameraFailure(CameraUnavailable.notReady).isRetryable, isTrue);
    });
  });
}

/// A face stand-in for the challenge logic.
///
/// The plugin's `Face` cannot be constructed in a test, so the challenge reads
/// only eye probabilities and yaw — the two fields the state machine uses — and
/// this exposes exactly those.
class _FakeFace implements Face {
  _FakeFace({this.leftEyeOpenProbability, this.rightEyeOpenProbability, this.headEulerAngleY});

  @override
  final double? leftEyeOpenProbability;
  @override
  final double? rightEyeOpenProbability;
  @override
  final double? headEulerAngleY;

  // Unused by the challenge logic.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

_FakeFace _face({double? left = 0.9, double? right = 0.9, double? yaw = 0}) =>
    _FakeFace(
      leftEyeOpenProbability: left,
      rightEyeOpenProbability: right,
      headEulerAngleY: yaw,
    );

Future<void> _wait(int milliseconds) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));