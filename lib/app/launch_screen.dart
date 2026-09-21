import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'theme.dart';

/// What the launch screen has to say: a line of status, a fraction when
/// something measurable is happening (the first-run dictionary copy), or
/// an error when the app can't start at all.
class LaunchProgress {
  final String? status;
  final double? fraction;
  final String? error;

  const LaunchProgress({this.status, this.fraction, this.error});
}

/// The first frame — up within a few hundred milliseconds of the process
/// starting, while the databases open, the keystore is read and the
/// backend connects behind it. Shows the mark, and on a first run the
/// dictionary copy's progress. Hands over to [app] the moment it's ready.
///
/// On Android 12+ the system splash draws the same icon on the same green
/// first, so this reads as one continuous screen rather than two.
class LaunchScreen extends StatelessWidget {
  final ValueListenable<LaunchProgress> progress;
  final Future<Widget> app;

  const LaunchScreen({super.key, required this.progress, required this.app});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: app,
      builder: (context, snapshot) {
        final ready = snapshot.data;
        if (ready != null) return ready;
        return MaterialApp(
          title: 'Word Wizard',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          home: _Splash(progress: progress),
        );
      },
    );
  }
}

class _Splash extends StatelessWidget {
  final ValueListenable<LaunchProgress> progress;

  const _Splash({required this.progress});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E271A),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Image.asset('assets/icon/mark.png', fit: BoxFit.contain),
                ),
                const SizedBox(height: 18),
                Text(
                  'Word Wizard',
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 40),
                SizedBox(
                  height: 72,
                  child: ValueListenableBuilder<LaunchProgress>(
                    valueListenable: progress,
                    builder: (context, p, _) {
                      final error = p.error;
                      if (error != null) {
                        return Column(
                          children: [
                            Icon(Icons.error_outline, color: scheme.error),
                            const SizedBox(height: 8),
                            Text(
                              'Word Wizard couldn\'t start: $error',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        );
                      }
                      final status = p.status;
                      // Nothing to report: a plain quiet screen, which is
                      // what most launches are.
                      if (status == null) return const SizedBox.shrink();
                      return AnimatedOpacity(
                        opacity: 1,
                        duration: const Duration(milliseconds: 300),
                        child: Column(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(value: p.fraction, minHeight: 6),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              p.fraction == null
                                  ? status
                                  : '$status ${(p.fraction! * 100).round()}%',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
