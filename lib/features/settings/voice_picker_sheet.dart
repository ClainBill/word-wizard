import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/settings_repository.dart';

/// Lets the user pick which of the device's English text-to-speech voices
/// pronounces words, with a play button on each to try it. The choice is
/// saved as it's tapped; the sheet stays open so voices can be compared.
Future<void> showVoicePickerSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _VoicePickerSheet(),
  );
}

/// How a voice is named on screen — "Samantha" on iOS, where voices have
/// names; "Voice sfg, female 2" for Android's engine ids
/// (`en-us-x-sfg#female_2-local`) — with its region: "American English".
String describeVoice(TtsVoiceChoice voice) =>
    '${_VoicePickerSheetState._friendlyName(voice.name, voice.locale)} · '
    '${_VoicePickerSheetState._region(voice.locale)}';

class _VoiceOption {
  final TtsVoiceChoice choice;
  final String label;
  final String detail;

  const _VoiceOption({required this.choice, required this.label, required this.detail});
}

class _VoicePickerSheet extends ConsumerStatefulWidget {
  const _VoicePickerSheet();

  @override
  ConsumerState<_VoicePickerSheet> createState() => _VoicePickerSheetState();
}

class _VoicePickerSheetState extends ConsumerState<_VoicePickerSheet> {
  late final Future<List<_VoiceOption>> _voices = _loadVoices();

  Future<List<_VoiceOption>> _loadVoices() async {
    final raw = await ref.read(ttsProvider).getVoices;
    final options = <_VoiceOption>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final name = item['name']?.toString();
        final locale = item['locale']?.toString();
        if (name == null || locale == null) continue;
        // English voices only: this is an English dictionary, and a
        // Japanese voice reading English words is no use to anyone.
        if (!locale.toLowerCase().startsWith('en')) continue;
        // Voices that fetch audio from the network stall offline, which is
        // where this app is meant to work.
        if (item['network_required']?.toString() == '1') continue;
        options.add(
          _VoiceOption(
            choice: TtsVoiceChoice(name: name, locale: locale),
            label: _friendlyName(name, locale),
            detail: _detail(item, locale),
          ),
        );
      }
    }
    options.sort((a, b) {
      final byLocale = a.detail.compareTo(b.detail);
      return byLocale != 0 ? byLocale : a.label.compareTo(b.label);
    });
    return options;
  }

  /// iOS voices have real names ("Samantha"); Android's are engine ids like
  /// `en-us-x-sfg#female_2-local`, which this turns into "Voice sfg,
  /// female 2".
  static String _friendlyName(String name, String locale) {
    if (!name.contains('#') && !name.contains('-x-')) return name;
    var s = name;
    if (s.endsWith('-local')) s = s.substring(0, s.length - 6);
    if (s.endsWith('-network')) s = s.substring(0, s.length - 8);
    final hash = s.indexOf('#');
    final variant = hash >= 0 ? s.substring(hash + 1).replaceAll('_', ' ') : '';
    final base = hash >= 0 ? s.substring(0, hash) : s;
    final x = base.indexOf('-x-');
    final id = x >= 0 ? base.substring(x + 3) : base;
    return variant.isEmpty ? 'Voice $id' : 'Voice $id, $variant';
  }

  static String _region(String locale) => switch (locale.toLowerCase().replaceAll('_', '-')) {
      'en-us' => 'American English',
      'en-gb' => 'British English',
      'en-au' => 'Australian English',
      'en-in' => 'Indian English',
      'en-ie' => 'Irish English',
      'en-za' => 'South African English',
      'en-nz' => 'New Zealand English',
      'en-ca' => 'Canadian English',
      'en-sg' => 'Singaporean English',
      _ => 'English ($locale)',
    };

  static String _detail(Map item, String locale) {
    final parts = [_region(locale)];
    final gender = item['gender']?.toString();
    if (gender != null && gender.isNotEmpty && gender != 'unspecified') {
      parts.add(gender);
    }
    final quality = item['quality']?.toString();
    if (quality == 'enhanced' || quality == 'premium' || quality == 'very high') {
      parts.add('high quality');
    }
    return parts.join(' · ');
  }

  Future<void> _choose(TtsVoiceChoice? choice, String sample) async {
    await ref.read(settingsRepositoryProvider).setTtsVoice(choice);
    // The provider applies the setting to the engine as it changes; this
    // applies it first so the sample uses the voice just tapped rather
    // than racing the stream.
    final tts = ref.read(ttsProvider);
    await applyTtsVoice(tts, choice);
    await tts.stop();
    await tts.speak(sample);
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(ttsVoiceProvider).valueOrNull;
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) {
        return FutureBuilder<List<_VoiceOption>>(
          future: _voices,
          builder: (context, snapshot) {
            final voices = snapshot.data;
            // One RadioGroup over both the default row and the list, so a
            // tap anywhere selects and plays through the same path.
            return RadioGroup<TtsVoiceChoice?>(
              groupValue: current,
              onChanged: (choice) => _choose(choice, 'serendipity'),
              child: CustomScrollView(
                controller: controller,
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Pronunciation voice', style: theme.textTheme.titleLarge),
                          const SizedBox(height: 4),
                          Text(
                            'Tap a voice to hear it. Voices come from the device; more can be '
                            'installed in its text-to-speech settings.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: const RadioListTile<TtsVoiceChoice?>(
                      value: null,
                      // Re-tapping the selected voice still replays the sample.
                      toggleable: true,
                      title: Text('Device default'),
                      subtitle: Text('Whatever the system uses for English'),
                    ),
                  ),
                  if (voices == null)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    )
                  else if (voices.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          snapshot.hasError
                              ? 'Couldn\'t list the device\'s voices.'
                              : 'No English voices installed on this device.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    )
                  else
                    SliverList.builder(
                      itemCount: voices.length,
                      itemBuilder: (context, i) {
                        final v = voices[i];
                        return RadioListTile<TtsVoiceChoice?>(
                          value: v.choice,
                          title: Text(v.label),
                          subtitle: Text(v.detail),
                          secondary: const Icon(Icons.volume_up_outlined),
                        );
                      },
                    ),
                  const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
