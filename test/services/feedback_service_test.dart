import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:word_wizard/services/feedback_service.dart';

/// A sender that can be told to fail, and remembers what it was given.
class _FakeSender implements FeedbackSender {
  bool fail;
  final List<FeedbackReport> sent = [];
  _FakeSender({this.fail = false});

  @override
  Future<void> send(FeedbackReport report) async {
    if (fail) throw const FeedbackSendException('down');
    sent.add(report);
  }
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('feedback_outbox_');
  });

  tearDown(() => temp.delete(recursive: true));

  FeedbackReport report({List<FeedbackAttachment> attachments = const []}) => FeedbackReport(
    kind: FeedbackKind.bug,
    message: 'The hint arrow pointed at the wrong tile',
    link: 'https://example.com/clip',
    email: 'someone@example.com',
    screen: '390×844 @3.0x',
    attachments: attachments,
  );

  test('a report serialises with its attachments inline', () {
    final r = report(
      attachments: [
        FeedbackAttachment(
          name: 'screen-1.png',
          mime: 'image/png',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
      ],
    );
    final json = r.toJson();
    expect(json['kind'], 'bug');
    expect(json['message'], r.message);
    expect(json['link'], 'https://example.com/clip');
    expect((json['app'] as Map)['screen'], '390×844 @3.0x');
    expect((json['attachments'] as List).single['base64'], base64Encode([1, 2, 3]));
    // The outbox form leaves the bytes to files.
    expect(
      (r.toJson(withAttachments: false)['attachments'] as List).single.containsKey('base64'),
      isFalse,
    );
  });

  test('with no relay configured a report is queued, and survives a reload', () async {
    final service = FeedbackService(sender: null, outboxDirectory: () async => temp);
    expect(service.configured, isFalse);
    final r = report(
      attachments: [
        FeedbackAttachment(
          name: 'screen-1.png',
          mime: 'image/png',
          bytes: Uint8List.fromList([9, 8, 7]),
        ),
      ],
    );
    expect(await service.submit(r), FeedbackOutcome.queued);
    expect(await service.pendingCount(), 1);
    expect(File(p.join(temp.path, r.id, 'report.json')).existsSync(), isTrue);
    expect(File(p.join(temp.path, r.id, 'screen-1.png')).readAsBytesSync(), [9, 8, 7]);
    // Nothing to send it with: flush is a no-op.
    expect(await service.flush(), 0);
    expect(await service.pendingCount(), 1);

    // A later build with a relay sends it, bytes and all, and clears it.
    final sender = _FakeSender();
    final later = FeedbackService(sender: sender, outboxDirectory: () async => temp);
    expect(await later.flush(), 1);
    expect(await later.pendingCount(), 0);
    final sent = sender.sent.single;
    expect(sent.id, r.id);
    expect(sent.message, r.message);
    expect(sent.email, r.email);
    expect(sent.attachments.single.bytes, [9, 8, 7]);
    expect(sent.attachments.single.mime, 'image/png');
  });

  test('a relay that is down queues; the next flush that reaches it sends', () async {
    final sender = _FakeSender(fail: true);
    final service = FeedbackService(sender: sender, outboxDirectory: () async => temp);
    expect(await service.submit(report()), FeedbackOutcome.queued);
    expect(await service.flush(), 0, reason: 'still down');
    sender.fail = false;
    expect(await service.submit(report()), FeedbackOutcome.sent);
    expect(await service.flush(), 1, reason: 'the earlier one goes out too');
    expect(sender.sent, hasLength(2));
    expect(await service.pendingCount(), 0);
  });

  test('a half-written outbox entry is dropped, not sent', () async {
    await Directory(p.join(temp.path, 'broken')).create();
    final sender = _FakeSender();
    final service = FeedbackService(sender: sender, outboxDirectory: () async => temp);
    expect(await service.flush(), 0);
    expect(sender.sent, isEmpty);
    expect(await service.pendingCount(), 0);
  });

  group('HttpFeedbackSender', () {
    late HttpServer server;
    final requests = <({String method, String path, String body})>[];
    var refuse = false;

    setUp(() async {
      requests.clear();
      refuse = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // Behaves like Apps Script: a POST is answered with a redirect to a
      // result URL, which a GET then reads.
      server.listen((req) async {
        final body = await utf8.decodeStream(req);
        requests.add((method: req.method, path: req.uri.path, body: body));
        if (req.method == 'POST') {
          req.response
            ..statusCode = HttpStatus.found
            ..headers.set(HttpHeaders.locationHeader, '/result');
        } else {
          req.response
            ..statusCode = 200
            ..write(jsonEncode({'ok': !refuse, if (refuse) 'error': 'quota'}));
        }
        await req.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('follows the redirect and reads the result', () async {
      final sender = HttpFeedbackSender(Uri.parse('http://127.0.0.1:${server.port}/exec'));
      await sender.send(report());
      expect(requests.map((r) => r.method), ['POST', 'GET']);
      expect(requests.first.path, '/exec');
      expect(jsonDecode(requests.first.body)['message'], report().message);
      expect(requests.last.path, '/result');
    });

    test('a refusal from the relay is an error, so the report queues', () async {
      refuse = true;
      final sender = HttpFeedbackSender(Uri.parse('http://127.0.0.1:${server.port}/exec'));
      await expectLater(sender.send(report()), throwsA(isA<FeedbackSendException>()));
      final service = FeedbackService(sender: sender, outboxDirectory: () async => temp);
      expect(await service.submit(report()), FeedbackOutcome.queued);
    });
  });
}
