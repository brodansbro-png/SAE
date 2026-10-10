import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';

/// Halaman masuk — email & kata sandi Firebase Auth.
///
/// Animasi: logo SAE fade-in + scale dari atas, lalu form slide-up.
/// Warna background gradient teal-ke-putih mengadaptasi palet SaeTheme.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _obscure = true;
  bool _busy = false;
  bool _resetting = false;
  String? _error;

  late AnimationController _animController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnim = CurvedAnimation(
      parent: _animController,
      curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: const Interval(0.2, 1.0, curve: Curves.easeOutCubic),
    ));
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await context.read<AppState>().signIn(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    if (error == null) _passwordController.clear();
  }

  Future<void> _resetPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Isi email terlebih dahulu untuk reset kata sandi.');
      return;
    }
    setState(() {
      _resetting = true;
      _error = null;
    });
    final error = await context.read<AppState>().requestPasswordReset(email);
    if (!mounted) return;
    setState(() => _resetting = false);
    showAppSnackBar(
      context,
      error ?? 'Tautan reset kata sandi dikirim ke $email.',
      isError: error != null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final padding = SaeTheme.pagePadding(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: Container(
        // Gradient teal-ke-surface — signature visual SAE
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? [const Color(0xFF00251A), theme.colorScheme.surface]
                : [const Color(0xFF00695C).withValues(alpha: 0.12), theme.colorScheme.surface],
            stops: const [0.0, 0.4],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: padding,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 24),

                      // ── Logo animasi ────────────────────────────────
                      FadeTransition(
                        opacity: _fadeAnim,
                        child: const _AnimatedLogo(),
                      ),
                      const SizedBox(height: 32),

                      // ── Form slide-up ───────────────────────────────
                      SlideTransition(
                        position: _slideAnim,
                        child: FadeTransition(
                          opacity: _fadeAnim,
                          child: _FormCard(
                            error: _error,
                            busy: _busy,
                            resetting: _resetting,
                            obscure: _obscure,
                            emailController: _emailController,
                            passwordController: _passwordController,
                            onToggleObscure: () =>
                                setState(() => _obscure = !_obscure),
                            onSubmit: _submit,
                            onReset: _resetPassword,
                          ),
                        ),
                      ),

                      const SizedBox(height: 16),
                      Center(
                        child: Text(
                          'SAE v1.0 — Sistem Absensi Elektronik',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Animated Logo ────────────────────────────────────────────────────────────
class _AnimatedLogo extends StatefulWidget {
  const _AnimatedLogo();

  @override
  State<_AnimatedLogo> createState() => _AnimatedLogoState();
}

class _AnimatedLogoState extends State<_AnimatedLogo>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);
    _scaleAnim = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // Pulsing glow di belakang logo
        AnimatedBuilder(
          animation: _scaleAnim,
          builder: (_, child) => Transform.scale(
            scale: _scaleAnim.value,
            child: child,
          ),
          child: Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  theme.colorScheme.primary.withValues(alpha: 0.25),
                  theme.colorScheme.primary.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ),
        // Logo utama
        Container(
          margin: const EdgeInsets.only(top: -64),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.2),
            ),
          ),
          child: Image.asset(
            'assets/image/sae_logo.png',
            width: 52,
            height: 52,
            errorBuilder: (_, _, _) => Icon(
              Icons.verified_user_outlined,
              size: 52,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'SAE',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w900,
            letterSpacing: 4,
            color: theme.colorScheme.primary,
          ),
        ),
        Text(
          'Sistem Absensi Elektronik',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

// ── Form Card ─────────────────────────────────────────────────────────────────
class _FormCard extends StatelessWidget {
  const _FormCard({
    required this.error,
    required this.busy,
    required this.resetting,
    required this.obscure,
    required this.emailController,
    required this.passwordController,
    required this.onToggleObscure,
    required this.onSubmit,
    required this.onReset,
  });

  final String? error;
  final bool busy;
  final bool resetting;
  final bool obscure;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final VoidCallback onToggleObscure;
  final VoidCallback onSubmit;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Masuk ke akun Anda',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Gunakan email yang terdaftar di sistem.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 20),

            if (error != null) ...[
              _ErrorBanner(message: error!),
              const SizedBox(height: 14),
            ],

            // Email
            TextFormField(
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.mail_outline_rounded),
              ),
              validator: (value) {
                final text = value?.trim() ?? '';
                if (text.isEmpty) return 'Email wajib diisi.';
                if (!text.contains('@') || !text.contains('.')) {
                  return 'Format email tidak valid.';
                }
                return null;
              },
            ),
            const SizedBox(height: 14),

            // Kata sandi
            TextFormField(
              controller: passwordController,
              obscureText: obscure,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              onFieldSubmitted: (_) => busy ? null : onSubmit(),
              decoration: InputDecoration(
                labelText: 'Kata sandi',
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  onPressed: onToggleObscure,
                  icon: Icon(
                    obscure
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  tooltip: obscure ? 'Tampilkan' : 'Sembunyikan',
                ),
              ),
              validator: (v) =>
                  (v == null || v.isEmpty) ? 'Kata sandi wajib diisi.' : null,
            ),

            // Lupa kata sandi
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: resetting ? null : onReset,
                child: Text(resetting ? 'Mengirim…' : 'Lupa kata sandi?'),
              ),
            ),
            const SizedBox(height: 8),

            // Tombol masuk
            FilledButton(
              onPressed: busy ? null : onSubmit,
              child: busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Masuk'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
