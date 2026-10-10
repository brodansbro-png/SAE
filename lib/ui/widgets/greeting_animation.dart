import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

/// Animasi salam berdasarkan waktu hari.
///
/// Ported dari absensi/lib/app/modules/home — memakai file Lottie yang sama:
/// pagi.json, siang.json, sore.json, malam.json.
///
/// Batas jam disesuaikan dengan jadwal shift nyata (08:00, 15:00, 22:00)
/// bukan fajar puitik.
class GreetingAnimation extends StatelessWidget {
  const GreetingAnimation({super.key, this.size = 64, this.showText = true});

  final double size;
  final bool showText;

  static ({String asset, String greeting, String emoji}) forHour(int hour) {
    if (hour >= 4 && hour < 11) {
      return (
        asset: 'assets/animation/pagi.json',
        greeting: 'Selamat pagi',
        emoji: '🌅',
      );
    }
    if (hour >= 11 && hour < 15) {
      return (
        asset: 'assets/animation/siang.json',
        greeting: 'Selamat siang',
        emoji: '☀️',
      );
    }
    if (hour >= 15 && hour < 18) {
      return (
        asset: 'assets/animation/sore.json',
        greeting: 'Selamat sore',
        emoji: '🌇',
      );
    }
    return (
      asset: 'assets/animation/malam.json',
      greeting: 'Selamat malam',
      emoji: '🌙',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final greeting = forHour(DateTime.now().hour);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Lottie.asset(
          greeting.asset,
          width: size,
          height: size,
          repeat: true,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => Text(
            greeting.emoji,
            style: TextStyle(fontSize: size * 0.5),
          ),
        ),
        if (showText) ...[
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                greeting.greeting,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                _subtitleFor(greeting.greeting),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  static String _subtitleFor(String greeting) {
    switch (greeting) {
      case 'Selamat pagi':
        return 'Siap untuk absensi hari ini';
      case 'Selamat siang':
        return 'Jangan lupa istirahat sejenak';
      case 'Selamat sore':
        return 'Waktunya absen pulang';
      default:
        return 'Absensi tetap tersedia 24 jam';
    }
  }
}

// ── Animasi sukses punch ─────────────────────────────────────────────────────

/// Animasi konfirmasi setelah punch berhasil dicatat.
/// ScaleTransition dengan elasticOut — terasa "mendarat" bukan muncul begitu saja.
class PunchSuccessAnimation extends StatefulWidget {
  const PunchSuccessAnimation({super.key, this.size = 120});

  final double size;

  @override
  State<PunchSuccessAnimation> createState() => _PunchSuccessAnimationState();
}

class _PunchSuccessAnimationState extends State<PunchSuccessAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..forward();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ScaleTransition(
      scale: CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.check_circle,
          size: widget.size * 0.6,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

// ── Logo SAE ─────────────────────────────────────────────────────────────────

/// Logo utama dari sae.png.
/// Satu sumber, tidak bisa berbeda dari favicon dashboard atau ikon launcher.
class SaeLogo extends StatelessWidget {
  const SaeLogo({super.key, this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: EdgeInsets.all(size * 0.15),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Image.asset(
        'assets/image/sae_logo.png',
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => Icon(
          Icons.verified_user_outlined,
          size: size,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

// ── Theme switcher animasi ────────────────────────────────────────────────────
/// Ported dari absensi/lib/app/data/theme_switcher.dart
/// Toggle gelap/terang dengan animasi bintang bergerak (mode malam) dan
/// glow matahari (mode siang).
class AnimatedThemeSwitcher extends StatefulWidget {
  const AnimatedThemeSwitcher({
    super.key,
    required this.isDark,
    required this.onToggle,
  });

  final bool isDark;
  final VoidCallback onToggle;

  @override
  State<AnimatedThemeSwitcher> createState() => _AnimatedThemeSwitcherState();
}

class _AnimatedThemeSwitcherState extends State<AnimatedThemeSwitcher>
    with TickerProviderStateMixin {
  late AnimationController _glowController;
  late AnimationController _starController;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _starController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _glowController.dispose();
    _starController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;

    return GestureDetector(
      onTap: widget.onToggle,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        width: 72,
        height: 36,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(50),
          gradient: LinearGradient(
            colors: isDark
                ? [const Color(0xFF000428), const Color(0xFF004e92)]
                : [const Color(0xFFfceabb), const Color(0xFFf8b500)],
          ),
        ),
        child: Stack(
          children: [
            // Bintang bergerak (mode malam)
            if (isDark)
              AnimatedBuilder(
                animation: _starController,
                builder: (_, _) => Stack(
                  children: List.generate(4, (i) {
                    final dx = (i * 12.0) + (_starController.value * 8);
                    final dy = (i.isEven ? 2.0 : 10.0);
                    return Positioned(
                      left: dx.clamp(0, 50),
                      top: dy,
                      child: Opacity(
                        opacity: 0.5 +
                            (_starController.value * 0.5).clamp(0.0, 0.5),
                        child: const Icon(Icons.star,
                            color: Colors.white, size: 5),
                      ),
                    );
                  }),
                ),
              ),
            // Glow matahari (mode terang)
            if (!isDark)
              Center(
                child: AnimatedBuilder(
                  animation: _glowController,
                  builder: (_, _) => Container(
                    width: 26 + (_glowController.value * 8),
                    height: 26 + (_glowController.value * 8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.orange.withValues(alpha: 0.3),
                    ),
                  ),
                ),
              ),
            // Thumb
            AnimatedAlign(
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOut,
              alignment:
                  isDark ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: isDark
                          ? Colors.blueAccent.withValues(alpha: 0.6)
                          : Colors.orangeAccent.withValues(alpha: 0.6),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Icon(
                  isDark ? Icons.nightlight_round : Icons.wb_sunny,
                  size: 15,
                  color: isDark ? Colors.indigo : Colors.orange,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Lottie loader sederhana ───────────────────────────────────────────────────
/// Spinner animasi Lottie dari loader.json (ported dari absensi)
class LottieLoader extends StatelessWidget {
  const LottieLoader({super.key, this.size = 80, this.message});

  final double size;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Coba load loader.json, fallback ke CircularProgressIndicator
        SizedBox(
          width: size,
          height: size,
          child: Lottie.asset(
            'assets/image/loader.json',
            repeat: true,
            errorBuilder: (_, _, _) => CircularProgressIndicator(
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        if (message != null) ...[
          const SizedBox(height: 12),
          Text(
            message!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}
