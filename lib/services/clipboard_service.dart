import 'package:flutter/services.dart';

import '../domain/reader/tokenizer.dart';

/// What was on the clipboard, plus a [stamp] identifying that particular
/// copy so it's only ever pulled into the Reader once.
class ClipboardSnapshot {
  final String text;

  /// The HTML flavour of the same clip, when the source app put one there
  /// (browsers do) — carries headings, bold, lists. Null on plain copies.
  final String? html;
  final String stamp;

  const ClipboardSnapshot({required this.text, this.html, required this.stamp});

  bool get isEmpty => text.trim().isEmpty;
}

/// Reads the clipboard for the Reader tab.
///
/// Goes through the app's own `word_wizard/clipboard` channel on Android
/// (see MainActivity.kt) for two things Flutter's [Clipboard] can't do: tell
/// whether the clip has changed *without reading it* — Android 12+ toasts
/// "pasted from your clipboard" on every content read, which would fire on
/// every visit to the tab — and hand over the HTML flavour so formatting
/// survives. Falls back to plain [Clipboard.getData] anywhere the channel
/// isn't there.
class ClipboardService {
  static const _channel = MethodChannel('word_wizard/clipboard');

  /// The clipboard's text if it holds something other than the copy
  /// identified by [lastStamp]; null when it's empty, unchanged, or can't
  /// be read (Android only lets a focused app read it).
  Future<ClipboardSnapshot?> readIfNew(String? lastStamp) async {
    try {
      final description = await _channel.invokeMapMethod<String, Object?>('describe');
      if (description != null) {
        if (description['hasText'] != true) return null;
        final timestamp = description['timestamp'] as int?;
        if (timestamp != null && timestamp > 0) {
          final stamp = 'ts:$timestamp';
          if (stamp == lastStamp) return null;
          final snapshot = await _readViaChannel(stamp);
          if (snapshot != null) return snapshot;
        }
      }
    } on MissingPluginException {
      // Not Android — fall through to the plain-text path.
    } on PlatformException {
      // Same: the channel is best-effort.
    }
    final text = await _readPlain();
    if (text == null) return null;
    final stamp = 'fp:${fingerprint(text)}';
    if (stamp == lastStamp) return null;
    return ClipboardSnapshot(text: text, stamp: stamp);
  }

  /// An unconditional read, for an explicit "Paste" tap.
  Future<ClipboardSnapshot?> read() async {
    try {
      final snapshot = await _readViaChannel(null);
      if (snapshot != null) return snapshot;
    } on MissingPluginException {
      // fall through
    } on PlatformException {
      // fall through
    }
    final text = await _readPlain();
    if (text == null) return null;
    return ClipboardSnapshot(text: text, stamp: 'fp:${fingerprint(text)}');
  }

  Future<ClipboardSnapshot?> _readViaChannel(String? stamp) async {
    final clip = await _channel.invokeMapMethod<String, Object?>('read');
    final text = clip?['text'] as String?;
    if (text == null || text.trim().isEmpty) return null;
    final html = clip?['html'] as String?;
    return ClipboardSnapshot(
      text: text,
      html: html == null || html.trim().isEmpty ? null : html,
      stamp: stamp ?? 'fp:${fingerprint(text)}',
    );
  }

  Future<String?> _readPlain() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) return null;
    return text;
  }
}
