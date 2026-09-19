import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'feedback_config.dart';

enum FeedbackKind {
  bug,
  feature;

  String get label => this == bug ? 'Bug report' : 'Feature suggestion';
}

/// An image the report carries: a captured screen or a photo from the
/// library.
class FeedbackAttachment {
  final String name;
  final String mime;
  final Uint8List bytes;

  const FeedbackAttachment({required this.name, required this.mime, required this.bytes});
}

/// One report as the user wrote it, plus what the app knows about itself.
class FeedbackReport {
  final String id;
  final FeedbackKind kind;
  final String message;

  /// Something that shows the problem — a page, a video — if they have one.
  final String? link;

  /// Only if they'd like a reply.
  final String? email;
  final String version;
  final String platform;
  final String screen;
  final DateTime createdAt;
  final List<FeedbackAttachment> attachments;

  FeedbackReport({
    String? id,
    required this.kind,
    required this.message,
    this.link,
    this.email,
    this.version = appVersion,
    String? platform,
    this.screen = '',
    DateTime? createdAt,
    this.attachments = const [],
  }) : id = id ?? _newId(),
       platform = platform ?? describePlatform(),
       createdAt = createdAt ?? DateTime.now();

  static String describePlatform() =>
      kIsWeb ? 'web' : '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';

  static String _newId() {
    final rand = Random();
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(36);
    final salt = rand.nextInt(1 << 20).toRadixString(36);
    return '$stamp-$salt';
  }

  /// The wire form the relay reads. Attachments go inline as base64 —
  /// there's no upload step, and a few screenshots are well within what
  /// one request carries.
  Map<String, dynamic> toJson({bool withAttachments = true}) => {
    'id': id,
    'kind': kind.name,
    'message': message,
    if (link != null && link!.isNotEmpty) 'link': link,
    if (email != null && email!.isNotEmpty) 'email': email,
    'app': {'version': version, 'platform': platform, 'screen': screen},
    'createdAt': createdAt.toUtc().toIso8601String(),
    'attachments': [
      for (final a in attachments)
        {'name': a.name, 'mime': a.mime, if (withAttachments) 'base64': base64Encode(a.bytes)},
    ],
  };

  factory FeedbackReport.fromJson(Map<String, dynamic> json, List<FeedbackAttachment> attachments) {
    final app = json['app'] as Map<String, dynamic>? ?? const {};
    return FeedbackReport(
      id: json['id'] as String?,
      kind: FeedbackKind.values.firstWhere(
        (k) => k.name == json['kind'],
        orElse: () => FeedbackKind.bug,
      ),
      message: json['message'] as String? ?? '',
      link: json['link'] as String?,
      email: json['email'] as String?,
      version: app['version'] as String? ?? appVersion,
      platform: app['platform'] as String?,
      screen: app['screen'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      attachments: attachments,
    );
  }
}

class FeedbackSendException implements Exception {
  final String message;
  const FeedbackSendException(this.message);
  @override
  String toString() => 'FeedbackSendException: $message';
}

/// Delivers one report, or throws.
abstract class FeedbackSender {
  Future<void> send(FeedbackReport report);
}

/// POSTs the report as JSON to [endpoint], the Apps Script relay in
/// `tool/feedback/`. Apps Script answers a POST with a redirect to a
/// one-shot result URL that has to be fetched with GET — dart:io doesn't
/// follow redirects for POST — so the redirect is followed by hand.
class HttpFeedbackSender implements FeedbackSender {
  final Uri endpoint;
  final Duration timeout;

  /// Extra request headers, resolved per send: the Supabase `feedback`
  /// function wants the anon key and a bearer token (the user's, or the
  /// anon key again when signed out). None for the Apps Script relay.
  final Future<Map<String, String>> Function()? headers;

  HttpFeedbackSender(this.endpoint, {this.timeout = const Duration(seconds: 40), this.headers});

  @override
  Future<void> send(FeedbackReport report) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.postUrl(endpoint);
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      for (final h in (await headers?.call() ?? const {}).entries) {
        request.headers.set(h.key, h.value);
      }
      request.write(jsonEncode(report.toJson()));
      var response = await request.close().timeout(timeout);
      // Not `isRedirect`: for a POST that's only true of a 303, and Apps
      // Script answers with a 302.
      if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null) {
          throw const FeedbackSendException('redirect without a location');
        }
        final follow = await client.getUrl(endpoint.resolve(location));
        response = await follow.close().timeout(timeout);
      }
      final body = await utf8.decodeStream(response);
      if (response.statusCode != 200) {
        throw FeedbackSendException('HTTP ${response.statusCode}');
      }
      final ok = _okFrom(body);
      if (!ok) {
        throw FeedbackSendException(
          'relay refused: ${body.length > 200 ? body.substring(0, 200) : body}',
        );
      }
    } finally {
      client.close();
    }
  }

  static bool _okFrom(String body) {
    try {
      final json = jsonDecode(body);
      return json is Map && json['ok'] == true;
    } catch (_) {
      return false;
    }
  }
}

enum FeedbackOutcome {
  /// Delivered to the relay.
  sent,

  /// Saved to the outbox — offline, the relay was down, or no relay is
  /// configured yet — to be sent on a later launch.
  queued,
}

/// Takes reports from the form and gets them to [feedbackEmail], now or
/// later. A report that can't be sent is written to an outbox on disk and
/// retried on every launch and every visit to the form, so nothing a user
/// took the trouble to write is lost to a dead spot.
class FeedbackService {
  /// Replaced in `main` with one that has a sender once the backend is
  /// known; until then, everything queues.
  static FeedbackService instance = FeedbackService.standard(sender: null);

  /// The app's service: the real outbox directory, and [sender] — the
  /// Supabase `feedback` function, the Apps Script relay, or nothing.
  factory FeedbackService.standard({required FeedbackSender? sender}) => FeedbackService(
        sender: sender,
        outboxDirectory: () async =>
            Directory(p.join((await getApplicationSupportDirectory()).path, 'feedback_outbox')),
      );

  /// Null when no relay is configured: everything queues.
  final FeedbackSender? sender;
  final Future<Directory> Function() outboxDirectory;

  FeedbackService({required this.sender, required this.outboxDirectory});

  bool get configured => sender != null;

  Future<FeedbackOutcome> submit(FeedbackReport report) async {
    final sender = this.sender;
    if (sender != null) {
      try {
        await sender.send(report);
        return FeedbackOutcome.sent;
      } catch (_) {
        // Falls through to the outbox.
      }
    }
    await _enqueue(report);
    return FeedbackOutcome.queued;
  }

  /// Tries every queued report once; returns how many went out.
  Future<int> flush() async {
    final sender = this.sender;
    if (sender == null) return 0;
    var sent = 0;
    for (final dir in await _queued()) {
      final report = await _read(dir);
      if (report == null) {
        // Unreadable — half-written when the app died. Nothing to send.
        await dir.delete(recursive: true);
        continue;
      }
      try {
        await sender.send(report);
      } catch (_) {
        continue;
      }
      await dir.delete(recursive: true);
      sent++;
    }
    return sent;
  }

  Future<int> pendingCount() async => (await _queued()).length;

  // -------------------------------------------------------------------
  // Outbox: one directory per report — report.json plus the attachments
  // as files, so a queued report with screenshots costs no re-encoding.
  // -------------------------------------------------------------------

  static const _reportFile = 'report.json';

  Future<List<Directory>> _queued() async {
    final root = await outboxDirectory();
    if (!await root.exists()) return const [];
    final dirs = [
      await for (final e in root.list())
        if (e is Directory) e,
    ]..sort((a, b) => a.path.compareTo(b.path));
    return dirs;
  }

  Future<void> _enqueue(FeedbackReport report) async {
    final root = await outboxDirectory();
    final dir = Directory(p.join(root.path, report.id));
    // Written under a temporary name and renamed, so a crash mid-write
    // leaves nothing that looks like a whole report.
    final staging = Directory('${dir.path}.tmp');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    for (final a in report.attachments) {
      await File(p.join(staging.path, a.name)).writeAsBytes(a.bytes, flush: true);
    }
    await File(
      p.join(staging.path, _reportFile),
    ).writeAsString(jsonEncode(report.toJson(withAttachments: false)), flush: true);
    if (await dir.exists()) await dir.delete(recursive: true);
    await staging.rename(dir.path);
  }

  Future<FeedbackReport?> _read(Directory dir) async {
    try {
      final json =
          jsonDecode(await File(p.join(dir.path, _reportFile)).readAsString())
              as Map<String, dynamic>;
      final attachments = <FeedbackAttachment>[];
      for (final a in json['attachments'] as List? ?? const []) {
        final name = a['name'] as String;
        final file = File(p.join(dir.path, name));
        if (!await file.exists()) continue;
        attachments.add(
          FeedbackAttachment(
            name: name,
            mime: a['mime'] as String? ?? 'application/octet-stream',
            bytes: await file.readAsBytes(),
          ),
        );
      }
      return FeedbackReport.fromJson(json, attachments);
    } catch (_) {
      return null;
    }
  }
}
