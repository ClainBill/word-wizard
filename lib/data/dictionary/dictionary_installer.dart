import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Gets the bundled dictionary onto a path sqlite can open, the way each
/// platform ships it:
///
/// - **iOS** carries `dictionary.db` as a bundle resource and opens it in
///   place, read-only. Nothing is copied.
/// - **Android** carries it as an install-time asset pack
///   (`android/dictionary_pack`), which sqlite can't read inside the APK,
///   so the first launch streams it out to app storage, reporting
///   progress as it goes; later launches find the copy and skip this.
/// - Anywhere else (desktop, tests) it falls back to Flutter's asset
///   bundle if the asset is there.
///
/// [version] marks the copy: bump it when the pipeline's output changes
/// and the next launch replaces what's on disk.
class DictionaryInstaller {
  static const _channel = MethodChannel('word_wizard/dictionary');

  /// The path to open, making it so if needed. [onProgress] gets 0..1
  /// while a copy is running, and nothing at all when there's no copy.
  static Future<String> ensure({
    required String version,
    void Function(double fraction)? onProgress,
  }) async {
    final located = await _locate();
    if (located != null) return located;

    final path = await installedPath();
    final marker = File(await _markerPath());
    final file = File(path);
    if (await file.exists() && await marker.exists() && await marker.readAsString() == version) {
      return path;
    }
    // Stale or half-copied: start clean, and leave no marker until done.
    if (await marker.exists()) await marker.delete();
    await _install(path, onProgress: onProgress);
    await marker.writeAsString(version);
    return path;
  }

  /// Where the copy lives on platforms that copy — also what the user
  /// database attaches (see `AppDatabases`).
  static Future<String> installedPath() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'dictionary.db');
  }

  static Future<String> _markerPath() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'dictionary.version');
  }

  static Future<String?> _locate() async {
    try {
      return await _channel.invokeMethod<String>('locate');
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> _install(String dest, {void Function(double)? onProgress}) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'progress' && onProgress != null) {
        onProgress((call.arguments as num).toDouble());
      }
    });
    try {
      await _channel.invokeMethod<Object?>('install', {'dest': dest});
    } on MissingPluginException {
      await _installFromFlutterAssets(dest, onProgress: onProgress);
    } finally {
      _channel.setMethodCallHandler(null);
    }
  }

  /// Desktop and tests: the asset, if it's in the bundle. Loads the whole
  /// file, which is what the native paths exist to avoid on phones.
  static Future<void> _installFromFlutterAssets(
    String dest, {
    void Function(double)? onProgress,
  }) async {
    final bytes = await rootBundle.load('assets/db/dictionary.db');
    await File(dest).create(recursive: true);
    await File(
      dest,
    ).writeAsBytes(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes), flush: true);
    onProgress?.call(1);
    debugPrint('dictionary: installed from the Flutter asset bundle');
  }
}
