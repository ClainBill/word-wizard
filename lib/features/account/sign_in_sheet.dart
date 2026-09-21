import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../services/auth_service.dart';

/// Opens the sign-in sheet. Resolves when it closes, signed in or not.
Future<void> showSignInSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SignInSheet(auth: ref.read(authServiceProvider)),
    ),
  );
}

/// One sheet for every way in: Apple and Google, or an email address and
/// the six-digit code that comes back. Creating an account and signing in
/// are the same gesture — the first sign-in by any route makes the account.
class SignInSheet extends StatefulWidget {
  final AuthService auth;

  const SignInSheet({super.key, required this.auth});

  @override
  State<SignInSheet> createState() => _SignInSheetState();
}

enum _Step { choose, code, browser }

class _SignInSheetState extends State<SignInSheet> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _emailFocus = FocusNode();
  _Step _step = _Step.choose;

  /// Which button is working, so only that one shows the spinner.
  Object? _busy;
  String? _error;
  StreamSubscription<AuthUser?>? _signedIn;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    // A link tapped in the mail, or the browser flow landing, signs in
    // behind this sheet; close it when that happens rather than leave a
    // code field waiting.
    _signedIn = widget.auth.changes.listen((user) {
      if (user != null && mounted) _finish(user);
    });
  }

  @override
  void dispose() {
    _signedIn?.cancel();
    _email.dispose();
    _code.dispose();
    _emailFocus.dispose();
    super.dispose();
  }

  /// Once: a typed code also fires the change stream, and the sheet must
  /// close exactly one route.
  void _finish(AuthUser user) {
    if (_done) return;
    _done = true;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    final via = switch (user.provider) {
      'google' => ' with Google',
      'apple' => ' with Apple',
      _ => '',
    };
    messenger.showSnackBar(
      SnackBar(content: Text('Signed in$via as ${user.email ?? 'you'}. Welcome.')),
    );
  }

  Future<void> _social(SocialProvider provider) async {
    setState(() {
      _busy = provider;
      _error = null;
    });
    try {
      final user = await widget.auth.signInWith(provider);
      if (!mounted) return;
      if (user != null) {
        _finish(user);
      } else {
        setState(() => _step = _Step.browser);
      }
    } on AuthCancelled {
      // They changed their mind; nothing to say.
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  static final _emailShape = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (!_emailShape.hasMatch(email)) {
      setState(() => _error = 'That doesn\'t look like an email address.');
      _emailFocus.requestFocus();
      return;
    }
    setState(() {
      _busy = 'email';
      _error = null;
    });
    try {
      await widget.auth.sendEmailCode(email);
      if (mounted) {
        setState(() {
          _step = _Step.code;
          _code.clear();
        });
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.length < 6) {
      setState(() => _error = 'Enter all six digits from the email.');
      return;
    }
    setState(() {
      _busy = 'code';
      _error = null;
    });
    try {
      final user = await widget.auth.verifyEmailCode(email: _email.text, code: code);
      if (mounted) _finish(user);
    } on AuthException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _code.clear();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final providers = widget.auth.socialProviders;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween(begin: const Offset(0.06, 0), end: Offset.zero).animate(anim),
              child: child,
            ),
          ),
          child: switch (_step) {
            _Step.choose => _Choose(
              key: const ValueKey('choose'),
              email: _email,
              emailFocus: _emailFocus,
              providers: providers,
              busy: _busy,
              error: _error,
              onSocial: _social,
              onSendCode: _sendCode,
            ),
            _Step.code => _CodeStep(
              key: const ValueKey('code'),
              email: _email.text.trim(),
              code: _code,
              busy: _busy != null,
              error: _error,
              onVerify: _verify,
              onResend: _sendCode,
              onBack: () => setState(() {
                _step = _Step.choose;
                _error = null;
              }),
            ),
            _Step.browser => _BrowserStep(
              key: const ValueKey('browser'),
              onBack: () => setState(() => _step = _Step.choose),
            ),
          },
        ),
      ),
    );
  }
}

/// The first screen: the mark, the pitch, the buttons, the email field.
class _Choose extends StatelessWidget {
  final TextEditingController email;
  final FocusNode emailFocus;
  final List<SocialProvider> providers;
  final Object? busy;
  final String? error;
  final ValueChanged<SocialProvider> onSocial;
  final VoidCallback onSendCode;

  const _Choose({
    super.key,
    required this.email,
    required this.emailFocus,
    required this.providers,
    required this.busy,
    required this.error,
    required this.onSocial,
    required this.onSendCode,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final anyBusy = busy != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Header(
          title: 'Welcome to Word Wizard',
          subtitle:
              'One account for Premium, the AI editor, shared puzzles and the leaderboard. '
              'Your words and progress stay on this device either way.',
        ),
        const SizedBox(height: 22),
        for (final p in providers) ...[
          _SocialButton(
            provider: p,
            busy: busy == p,
            enabled: !anyBusy,
            onPressed: () => onSocial(p),
          ),
          const SizedBox(height: 10),
        ],
        if (providers.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(child: Divider(color: scheme.outlineVariant)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text('or', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
              ),
              Expanded(child: Divider(color: scheme.outlineVariant)),
            ],
          ),
          const SizedBox(height: 14),
        ],
        TextField(
          controller: email,
          focusNode: emailFocus,
          enabled: !anyBusy,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          autofillHints: const [AutofillHints.email],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => onSendCode(),
          decoration: InputDecoration(
            labelText: 'Email',
            hintText: 'you@example.com',
            prefixIcon: const Icon(Icons.alternate_email),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        const SizedBox(height: 10),
        _BigButton(
          label: 'Continue with email',
          busy: busy == 'email',
          enabled: !anyBusy,
          onPressed: onSendCode,
          filled: true,
        ),
        if (error != null) _ErrorLine(error!),
        const SizedBox(height: 14),
        const _Legal(),
      ],
    );
  }
}

/// "We sent a code to…": six boxes and the way back.
class _CodeStep extends StatefulWidget {
  final String email;
  final TextEditingController code;
  final bool busy;
  final String? error;
  final VoidCallback onVerify;
  final VoidCallback onResend;
  final VoidCallback onBack;

  const _CodeStep({
    super.key,
    required this.email,
    required this.code,
    required this.busy,
    required this.error,
    required this.onVerify,
    required this.onResend,
    required this.onBack,
  });

  @override
  State<_CodeStep> createState() => _CodeStepState();
}

class _CodeStepState extends State<_CodeStep> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.code.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    widget.code.removeListener(_onChanged);
    _focus.dispose();
    super.dispose();
  }

  void _onChanged() {
    setState(() {});
    // All six typed: go, without a second tap.
    if (widget.code.text.length == 6 && !widget.busy) widget.onVerify();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: 'Check your email',
          subtitle:
              'We sent a sign-in link and a six-digit code to ${widget.email}. Tap the link, '
              'or type the code here. Good for an hour.',
          onBack: widget.onBack,
        ),
        const SizedBox(height: 22),
        // The real field is invisible; the boxes mirror it.
        GestureDetector(
          onTap: () => _focus.requestFocus(),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: 0,
                child: SizedBox(
                  height: 1,
                  child: TextField(
                    controller: widget.code,
                    focusNode: _focus,
                    enabled: !widget.busy,
                    keyboardType: TextInputType.number,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    showCursor: false,
                    enableInteractiveSelection: false,
                    decoration: const InputDecoration.collapsed(hintText: ''),
                  ),
                ),
              ),
              _CodeBoxes(
                code: widget.code.text,
                focused: _focus.hasFocus,
                error: widget.error != null,
              ),
            ],
          ),
        ),
        if (widget.error != null) _ErrorLine(widget.error!),
        const SizedBox(height: 18),
        _BigButton(
          label: 'Sign in',
          busy: widget.busy,
          enabled: !widget.busy,
          onPressed: widget.onVerify,
          filled: true,
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: widget.busy ? null : widget.onResend,
              child: const Text('Send it again'),
            ),
            Text('·', style: TextStyle(color: scheme.outline)),
            TextButton(
              onPressed: widget.busy ? null : widget.onBack,
              child: const Text('Use a different email'),
            ),
          ],
        ),
      ],
    );
  }
}

class _CodeBoxes extends StatelessWidget {
  final String code;
  final bool focused;
  final bool error;

  const _CodeBoxes({required this.code, required this.focused, required this.error});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < 6; i++) ...[
          if (i == 3) const SizedBox(width: 10),
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 44,
            height: 54,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                width: focused && i == min(code.length, 5) ? 2 : 1,
                color: error
                    ? scheme.error
                    : focused && i == min(code.length, 5)
                    ? scheme.primary
                    : scheme.outlineVariant,
              ),
            ),
            child: Text(
              i < code.length ? code[i] : '',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// While the system browser has the sign-in. The sheet closes on its own
/// when the session lands.
class _BrowserStep extends StatelessWidget {
  final VoidCallback onBack;

  const _BrowserStep({super.key, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: 'Finish in your browser',
          subtitle:
              'Sign in on the page that opened; you\'ll come straight back here when it\'s done.',
          onBack: onBack,
        ),
        const SizedBox(height: 28),
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 28),
        TextButton(onPressed: onBack, child: const Text('Try another way')),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback? onBack;

  const _Header({required this.title, required this.subtitle, this.onBack});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (onBack != null)
              IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Back',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              )
            else
              Container(
                width: 52,
                height: 52,
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E271A),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Image.asset('assets/icon/mark.png', fit: BoxFit.contain),
              ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(subtitle, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
      ],
    );
  }
}

/// Apple's and Google's buttons, to their guidelines: Apple's black (white
/// in the dark), Google's white with the coloured G.
class _SocialButton extends StatelessWidget {
  final SocialProvider provider;
  final bool busy;
  final bool enabled;
  final VoidCallback onPressed;

  const _SocialButton({
    required this.provider,
    required this.busy,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (bg, fg, border) = switch (provider) {
      SocialProvider.apple =>
        dark ? (Colors.white, Colors.black, null) : (Colors.black, Colors.white, null),
      SocialProvider.google => (
        dark ? const Color(0xFF131314) : Colors.white,
        dark ? const Color(0xFFE3E3E3) : const Color(0xFF1F1F1F),
        dark ? const Color(0xFF8E918F) : const Color(0xFF747775),
      ),
    };
    final icon = switch (provider) {
      SocialProvider.apple => Icon(Icons.apple, color: fg, size: 22),
      SocialProvider.google => const _GoogleG(),
    };
    return SizedBox(
      height: 48,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          disabledBackgroundColor: bg.withValues(alpha: 0.6),
          disabledForegroundColor: fg.withValues(alpha: 0.6),
          side: BorderSide(color: border ?? bg),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        onPressed: enabled ? onPressed : null,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: busy ? _Spinner(color: fg) : icon,
            ),
            Text(
              'Continue with ${provider.label}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// The four-colour G, drawn rather than shipped as an asset.
class _GoogleG extends StatelessWidget {
  const _GoogleG();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(width: 20, height: 20, child: CustomPaint(painter: _GoogleGPainter()));
  }
}

class _GoogleGPainter extends CustomPainter {
  const _GoogleGPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final c = Offset(r, r);
    final stroke = size.width * 0.22;
    final rect = Rect.fromCircle(center: c, radius: r - stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    // Red top-left, yellow bottom-left, green bottom-right, blue right —
    // angles in radians, clockwise from 3 o'clock.
    void arc(Color color, double start, double sweep) =>
        canvas.drawArc(rect, start, sweep, false, paint..color = color);
    arc(const Color(0xFFEA4335), pi * 1.15, pi * 0.6); // red: upper-left
    arc(const Color(0xFFFBBC05), pi * 0.6, pi * 0.55); // yellow: lower-left
    arc(const Color(0xFF34A853), pi * 0.12, pi * 0.48); // green: lower-right
    arc(const Color(0xFF4285F4), -pi * 0.04, pi * 0.16); // blue: the tail
    canvas.drawRect(
      Rect.fromLTWH(r, r - stroke / 2, r - stroke * 0.1, stroke),
      Paint()..color = const Color(0xFF4285F4),
    );
  }

  @override
  bool shouldRepaint(_GoogleGPainter old) => false;
}

class _BigButton extends StatelessWidget {
  final String label;
  final bool busy;
  final bool enabled;
  final bool filled;
  final VoidCallback onPressed;

  const _BigButton({
    required this.label,
    required this.busy,
    required this.enabled,
    required this.onPressed,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final child = busy
        ? _Spinner(color: Theme.of(context).colorScheme.onPrimary)
        : Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600));
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    return SizedBox(
      height: 48,
      child: filled
          ? FilledButton(
              style: FilledButton.styleFrom(shape: shape),
              onPressed: enabled ? onPressed : null,
              child: child,
            )
          : OutlinedButton(
              style: OutlinedButton.styleFrom(shape: shape),
              onPressed: enabled ? onPressed : null,
              child: child,
            ),
    );
  }
}

class _Spinner extends StatelessWidget {
  final Color color;
  const _Spinner({required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2, color: color),
    );
  }
}

class _ErrorLine extends StatelessWidget {
  final String text;
  const _ErrorLine(this.text);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: scheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text, style: TextStyle(color: scheme.onErrorContainer)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Legal extends StatelessWidget {
  const _Legal();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final link = TextStyle(color: scheme.primary, decoration: TextDecoration.underline);
    return Text.rich(
      TextSpan(
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        children: [
          const TextSpan(text: 'By continuing you agree to the '),
          WidgetSpan(
            child: GestureDetector(
              onTap: () => context.push('/legal/terms'),
              child: Text('Terms', style: link.copyWith(fontSize: 12)),
            ),
          ),
          const TextSpan(text: ' and '),
          WidgetSpan(
            child: GestureDetector(
              onTap: () => context.push('/legal/privacy'),
              child: Text('Privacy Policy', style: link.copyWith(fontSize: 12)),
            ),
          ),
          const TextSpan(text: '.'),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}
