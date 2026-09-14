import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/settings_repository.dart';
import 'reader_page.dart';

/// Reading options: body text size and whether uncommon words get their
/// faint underline. Both persist across documents.
Future<void> showReaderOptionsSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    builder: (context) => const _ReaderOptionsSheet(),
  );
}

class _ReaderOptionsSheet extends ConsumerWidget {
  const _ReaderOptionsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(readerPrefsProvider).valueOrNull ?? const ReaderPrefs();
    final settings = ref.read(settingsRepositoryProvider);
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Reading options', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            Row(
              children: [
                Text('A', style: TextStyle(fontSize: 13, fontFamily: readerFontFamily)),
                Expanded(
                  child: Slider(
                    value: prefs.fontSize.clamp(14, 24),
                    min: 14,
                    max: 24,
                    divisions: 10,
                    label: '${prefs.fontSize.round()}',
                    onChanged: (v) => settings.setReaderFontSize(v.roundToDouble()),
                  ),
                ),
                Text('A', style: TextStyle(fontSize: 24, fontFamily: readerFontFamily)),
              ],
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'The '),
                    TextSpan(
                      text: 'ineffable',
                      style: TextStyle(
                        decoration: TextDecoration.underline,
                        decorationStyle: TextDecorationStyle.dotted,
                        decorationColor: scheme.onSurfaceVariant.withValues(alpha: 0.55),
                      ),
                    ),
                    const TextSpan(text: ' quality of a '),
                    TextSpan(
                      text: 'well-set',
                      style: TextStyle(background: Paint()..color = ReaderPalette.highlight(0, Theme.of(context).brightness)),
                    ),
                    const TextSpan(text: ' page.'),
                  ],
                ),
                style: TextStyle(
                  fontFamily: readerFontFamily,
                  fontFamilyFallback: readerFontFallback,
                  fontSize: prefs.fontSize,
                  height: 1.6,
                  color: scheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mark uncommon words'),
              subtitle: const Text(
                'A faint dotted underline under words rarer than everyday vocabulary — '
                'the ones worth a second look.',
              ),
              value: prefs.markUncommon,
              onChanged: settings.setReaderMarkUncommon,
            ),
          ],
        ),
      ),
    );
  }
}
