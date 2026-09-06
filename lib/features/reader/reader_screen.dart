import 'package:flutter/material.dart';

/// Placeholder for the v1 Reader tab (paste text, tap any word to define —
/// see the "Roadmap" section of the design doc, Phase 3). The MVP ships the
/// tab in the nav shell so the five-tab layout matches the design doc, but
/// tokenization and tap-to-define land in a later pass.
class ReaderScreen extends StatelessWidget {
  const ReaderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reader')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.article_outlined, size: 48, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 12),
              Text(
                'Coming in a later pass: paste any text here and tap a word\nto look it up without leaving the page.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
