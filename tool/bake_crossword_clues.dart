// The clue bake: newspaper-style clues for the crossword word list, written
// offline by a model, checked by the app's own clue gate, and baked into
// assets/crossword/wordlist.tsv as type `e` (edited). The same pass gives
// each word a keep/reject verdict; rejected words leave the fill pool
// (flag 8) but stay usable, and clued, as study-word anchors.
//
// Why offline: the runtime needs no network and no per-puzzle model call
// to have good clues, and the editor pass becomes polish instead of repair.
// The harness (tool/crossword_harness.dart) measures the result.
//
//   dart run tool/bake_crossword_clues.dart <command> [options]
//
//   sync     --model M --cache FILE (--words-from run.json[,run.json] | --words A,B | --all)
//            [--limit N] [--chunk 25] [--concurrency 6]
//            Calls the model directly, a chunk of words per request. For
//            pilots; skips words already in the cache.
//   submit   --model M --cache FILE [--all | --words-from ...] [--limit N] [--chunk 25]
//            Submits the words not yet in the cache as an OpenAI Batch job
//            (half price, done within 24 h). Writes FILE.batch.json.
//   collect  --cache FILE
//            Checks the batch; when it's done, gates its answers into the cache.
//   export   --out DIR (--all | --words-from ... | --words ...) [--chunk 250] [--cache FILE]
//            For baking by hand in ChatGPT instead of the API: writes
//            DIR/PROMPT.md and DIR/words-0001.json… (skipping words already
//            in --cache). Paste the prompt, attach a file, save the .jsonl
//            it returns next to it.
//   import   --cache FILE DIR|FILE.jsonl...
//            Gates ChatGPT's .jsonl replies and adds them to the cache.
//   apply    --cache FILE --out FILE [--wordlist FILE] [--no-rejections]
//            Writes a word list with the baked clues (and, unless told not
//            to, the rejections) folded in.
//
// Cache lines are JSON, one word each, and the cache is append-only: a word
// is baked once per cache file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:word_wizard/domain/crossword/clues.dart' show ClueRejection, hasProfanity, validateClue;
import 'package:word_wizard/domain/crossword/crossword_models.dart';
import 'package:word_wizard/domain/crossword/word_list.dart';

import 'clue_bake/prompt.dart';
import 'crossword_harness/lint.dart';
import 'crossword_harness/llm.dart';

const _defaultWordlist = 'assets/crossword/wordlist.tsv';

/// Answers kept out of the fill pool whatever the model said: the app's
/// profanity list covers clue text, and these are crude as answers.
const _crudeAnswers = {
  'ASS', 'ASSES', 'ANAL', 'ANUS', 'BOOB', 'BOOBS', 'TIT', 'TITS', 'POO', 'POOP', 'PEE', 'PEED',
  'CRAP', 'CRAPS', 'DAMN', 'PISS', 'BUTT', 'BUTTS', 'SEXY', 'PORN', 'NUDE', 'NUDES', 'PENIS', 'VAGINA',
};

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: bake_crossword_clues.dart sync|submit|collect|apply [options]');
    exit(64);
  }
  final opts = _Opts(args.skip(1).toList());
  switch (args.first) {
    case 'sync':
      await _sync(opts);
    case 'submit':
      await _submit(opts);
    case 'collect':
      await _collect(opts);
    case 'apply':
      _apply(opts);
    case 'export':
      _export(opts);
    case 'import':
      _import(opts);
    default:
      stderr.writeln('unknown command ${args.first}');
      exit(64);
  }
}

// ---------------------------------------------------------------------
// Choosing words and building their context
// ---------------------------------------------------------------------

List<CrosswordEntry> _wordlist(_Opts o) =>
    parseWordList(File(o.value('--wordlist') ?? _defaultWordlist).readAsStringSync());

/// The words to bake, in a stable order, minus those already cached.
List<CrosswordEntry> _targets(_Opts o, List<CrosswordEntry> entries, Set<String> done) {
  final byText = <String, CrosswordEntry>{};
  for (final e in entries) {
    byText.putIfAbsent(e.text, () => e);
  }
  final wanted = <String>{};
  if (o.flag('--all')) {
    wanted.addAll([for (final e in entries) if (inFillPool(e)) e.text]);
  }
  for (final w in (o.value('--words') ?? '').split(',')) {
    if (w.trim().isNotEmpty) wanted.add(w.trim().toUpperCase());
  }
  for (final path in (o.value('--words-from') ?? '').split(',')) {
    if (path.trim().isEmpty) continue;
    final run = jsonDecode(File(path.trim()).readAsStringSync()) as Map<String, dynamic>;
    for (final p in run['puzzles'] as List) {
      for (final stage in ['before', 'after']) {
        for (final w in ((p as Map)[stage] as Map?)?['words'] as List? ?? const []) {
          wanted.add((w as Map)['answer'] as String);
        }
      }
      for (final a in p['anchors'] as List? ?? const []) {
        wanted.add('$a');
      }
    }
  }
  final out = [
    for (final t in wanted)
      if (!done.contains(t) && byText[t] != null) byText[t]!,
  ]..sort((a, b) => a.text.compareTo(b.text));
  final limit = int.tryParse(o.value('--limit') ?? '');
  return limit == null ? out : out.take(limit).toList();
}

/// Dictionary glosses for a word, most common entry and sense first.
class _Senses {
  final Database _db = sqlite3.open('assets/db/dictionary.db', mode: OpenMode.readOnly);
  late final PreparedStatement _q = _db.prepare(
    'SELECT e.pos, s.gloss FROM entries e JOIN senses s ON s.entry_id = e.id '
    'WHERE e.headword IN (?, ?, ?) '
    'ORDER BY (e.frequency_rank IS NULL), e.frequency_rank, s.sense_order LIMIT 6',
  );

  List<String> of(CrosswordEntry e) {
    final display = e.display;
    final lower = display.toLowerCase();
    final title = lower.isEmpty ? lower : lower[0].toUpperCase() + lower.substring(1);
    return [
      for (final row in _q.select([display, lower, title]))
        '${row['pos']}: ${(row['gloss'] as String).trim()}',
    ];
  }

  void close() => _db.dispose();
}

List<List<BakeItem>> _chunks(List<CrosswordEntry> targets, int size) {
  final senses = _Senses();
  try {
    final items = [
      for (var i = 0; i < targets.length; i++)
        BakeItem(
          i % size,
          targets[i].text,
          targets[i].display,
          senses.of(targets[i]),
          [for (final c in targets[i].clues.take(2)) c.text],
        ),
    ];
    return [for (var i = 0; i < items.length; i += size) items.sublist(i, (i + size).clamp(0, items.length))];
  } finally {
    senses.close();
  }
}

// ---------------------------------------------------------------------
// The gate, and the cache
// ---------------------------------------------------------------------

/// Checks each proposed clue with the app's own gate plus the harness's
/// lint (no glued senses, no dictionary residue, nothing unsuitable).
Map<String, dynamic> _gate(BakeResult r, String display, String model) {
  final clues = <Map<String, dynamic>>[];
  for (final c in r.clues) {
    // Crossword clues start with a capital; the model doesn't always.
    final raw = c.text.trim();
    final text = raw.isEmpty ? raw : raw[0].toUpperCase() + raw.substring(1);
    var gate = validateClue(text, r.answer, display: display);
    // The gate's two-word minimum exists for the editor's rewrites; a
    // one-word synonym ("Fuss" for ADO) is the most classic clue there is.
    if (gate.reason == ClueRejection.tooShort && gate.text.trim().isNotEmpty) {
      gate = (text: gate.text, ok: true, reason: ClueRejection.none);
    }
    final lint = lintClue(r.answer, gate.text)
        .where((f) => f == ClueFlag.multiSense || f == ClueFlag.residue || f == ClueFlag.unsuitable)
        .toList();
    clues.add({
      'text': gate.text,
      'style': c.style,
      'ok': gate.ok && lint.isEmpty,
      'rejection': !gate.ok ? gate.reason.name : (lint.isEmpty ? '' : lint.first.name),
    });
  }
  return {
    'answer': r.answer,
    'display': display,
    'model': model,
    'verdict': r.verdict,
    'reason': r.reason,
    'clues': clues,
  };
}

Set<String> _cached(String path) {
  final file = File(path);
  if (!file.existsSync()) return {};
  return {
    for (final line in file.readAsLinesSync())
      if (line.trim().isNotEmpty) (jsonDecode(line) as Map)['answer'] as String,
  };
}

void _append(String path, Iterable<Map<String, dynamic>> rows) {
  final file = File(path)..parent.createSync(recursive: true);
  final sink = file.openSync(mode: FileMode.append);
  for (final r in rows) {
    sink.writeStringSync('${jsonEncode(r)}\n');
  }
  sink.closeSync();
}

Map<String, dynamic> _requestBody(String model, List<BakeItem> chunk) => {
  'model': model,
  'messages': [
    {'role': 'system', 'content': bakeSystemPrompt},
    {'role': 'user', 'content': bakeUserMessage(chunk)},
  ],
  'response_format': {'type': 'json_object'},
  'reasoning_effort': 'low',
  'max_completion_tokens': 16000,
};

// ---------------------------------------------------------------------
// sync
// ---------------------------------------------------------------------

Future<void> _sync(_Opts o) async {
  final model = o.value('--model') ?? 'gpt-5-mini';
  final cache = o.required('--cache');
  final ai = OpenAi.fromEnvironment() ?? (throw StateError('No OPENAI_API_KEY'));
  final entries = _wordlist(o);
  final targets = _targets(o, entries, _cached(cache));
  final displays = {for (final t in targets) t.text: t.display};
  final chunks = _chunks(targets, int.tryParse(o.value('--chunk') ?? '') ?? 25);
  final concurrency = int.tryParse(o.value('--concurrency') ?? '') ?? 6;
  stdout.writeln('${targets.length} words in ${chunks.length} requests to $model');

  var next = 0;
  var cost = 0.0;
  var baked = 0;
  var kept = 0;
  Future<void> worker() async {
    while (next < chunks.length) {
      final chunk = chunks[next++];
      try {
        final r = await ai.chat(
          model: model,
          system: bakeSystemPrompt,
          user: bakeUserMessage(chunk),
          reasoningEffort: 'low',
        );
        cost += r.costUsd;
        final rows = [for (final b in parseBakeReply(r.content, chunk)) _gate(b, displays[b.answer]!, model)];
        _append(cache, rows);
        baked += rows.length;
        kept += rows.where((row) => (row['clues'] as List).any((c) => (c as Map)['ok'] == true)).length;
        stdout.writeln('  $baked/${targets.length} baked, \$${cost.toStringAsFixed(3)}');
      } catch (e) {
        stderr.writeln('  chunk failed: $e');
      }
    }
  }

  await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  stdout.writeln('done: $baked words, $kept with at least one clue past the gate, \$${cost.toStringAsFixed(3)}');
}

// ---------------------------------------------------------------------
// Batch
// ---------------------------------------------------------------------

Future<void> _submit(_Opts o) async {
  final model = o.value('--model') ?? 'gpt-5-mini';
  final cache = o.required('--cache');
  final ai = OpenAi.fromEnvironment() ?? (throw StateError('No OPENAI_API_KEY'));
  final entries = _wordlist(o);
  final targets = _targets(o, entries, _cached(cache));
  final chunks = _chunks(targets, int.tryParse(o.value('--chunk') ?? '') ?? 25);
  if (chunks.isEmpty) {
    stdout.writeln('nothing to bake');
    return;
  }
  final lines = StringBuffer();
  final plan = <String, List<Map<String, dynamic>>>{};
  for (var i = 0; i < chunks.length; i++) {
    final id = 'chunk-$i';
    lines.writeln(jsonEncode({'custom_id': id, 'method': 'POST', 'url': '/v1/chat/completions', 'body': _requestBody(model, chunks[i])}));
    plan[id] = [for (final item in chunks[i]) {'id': item.id, 'answer': item.answer, 'display': item.display}];
  }
  final requests = File('$cache.requests.jsonl')..writeAsStringSync(lines.toString());
  stdout.writeln('${targets.length} words in ${chunks.length} requests → uploading ${requests.lengthSync() ~/ 1024} KB');

  final fileId = await _upload(ai.key, requests);
  final batch = await _api(ai.key, 'POST', '/v1/batches', {
    'input_file_id': fileId,
    'endpoint': '/v1/chat/completions',
    'completion_window': '24h',
    'metadata': {'purpose': 'word wizard clue bake'},
  });
  File('$cache.batch.json').writeAsStringSync(
    const JsonEncoder.withIndent(' ').convert({'batch': batch['id'], 'model': model, 'plan': plan}),
  );
  stdout.writeln('batch ${batch['id']} submitted (${batch['status']}). Run `collect` to check on it.');
}

Future<void> _collect(_Opts o) async {
  final cache = o.required('--cache');
  final ai = OpenAi.fromEnvironment() ?? (throw StateError('No OPENAI_API_KEY'));
  final stateFile = File('$cache.batch.json');
  final state = jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic>;
  final batch = await _api(ai.key, 'GET', '/v1/batches/${state['batch']}');
  final counts = batch['request_counts'] as Map? ?? const {};
  stdout.writeln('batch ${batch['id']}: ${batch['status']} — ${counts['completed']}/${counts['total']} done, ${counts['failed']} failed');
  if (batch['status'] != 'completed') return;

  final output = await _download(ai.key, batch['output_file_id'] as String);
  final plan = (state['plan'] as Map).map((k, v) => MapEntry(k as String, (v as List).cast<Map>()));
  final model = state['model'] as String;
  final done = _cached(cache);
  var baked = 0;
  var failed = 0;
  for (final line in const LineSplitter().convert(output)) {
    if (line.trim().isEmpty) continue;
    final row = jsonDecode(line) as Map<String, dynamic>;
    final items = [
      for (final p in plan[row['custom_id']] ?? const <Map>[])
        BakeItem((p['id'] as num).toInt(), p['answer'] as String, p['display'] as String, const [], const []),
    ];
    final displays = {for (final i in items) i.answer: i.display};
    try {
      final body = (row['response'] as Map)['body'] as Map;
      final content = (body['choices'] as List).first['message']['content'] as String;
      final results = [
        for (final b in parseBakeReply(content, items))
          if (!done.contains(b.answer)) _gate(b, displays[b.answer]!, model),
      ];
      _append(cache, results);
      baked += results.length;
    } catch (e) {
      failed++;
    }
  }
  stateFile.renameSync('$cache.batch.done.json');
  stdout.writeln('collected $baked words ($failed requests unreadable) into $cache');
}

Future<Map<String, dynamic>> _api(String key, String method, String path, [Map<String, dynamic>? body]) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, Uri.parse('https://api.openai.com$path'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 300) throw HttpException('$method $path ${response.statusCode}: $text');
    return jsonDecode(text) as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

Future<String> _upload(String key, File file) async {
  const boundary = '----wordwizardbake';
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse('https://api.openai.com/v1/files'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
    request.headers.contentType = ContentType('multipart', 'form-data', parameters: {'boundary': boundary});
    request.write('--$boundary\r\nContent-Disposition: form-data; name="purpose"\r\n\r\nbatch\r\n');
    request.write('--$boundary\r\nContent-Disposition: form-data; name="file"; filename="requests.jsonl"\r\n'
        'Content-Type: application/jsonl\r\n\r\n');
    request.add(file.readAsBytesSync());
    request.write('\r\n--$boundary--\r\n');
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 300) throw HttpException('upload ${response.statusCode}: $text');
    return (jsonDecode(text) as Map)['id'] as String;
  } finally {
    client.close();
  }
}

Future<String> _download(String key, String fileId) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse('https://api.openai.com/v1/files/$fileId/content'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
    final response = await request.close();
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close();
  }
}

// ---------------------------------------------------------------------
// ChatGPT hand-off
// ---------------------------------------------------------------------

void _export(_Opts o) {
  final dir = Directory(o.required('--out'))..createSync(recursive: true);
  final cache = o.value('--cache');
  final entries = _wordlist(o);
  final targets = _targets(o, entries, cache == null ? {} : _cached(cache));
  final size = int.tryParse(o.value('--chunk') ?? '') ?? 250;
  final chunks = _chunks(targets, size);
  File('${dir.path}/PROMPT.md').writeAsStringSync('$chatGptPrompt\n');
  for (var i = 0; i < chunks.length; i++) {
    final name = 'words-${(i + 1).toString().padLeft(4, '0')}';
    File('${dir.path}/$name.json').writeAsStringSync(
      const JsonEncoder.withIndent(' ').convert([
        for (final item in chunks[i])
          {
            'answer': item.answer,
            if (item.toJson().containsKey('as_written')) 'as_written': item.display,
            'senses': item.senses,
            if (item.existing.isNotEmpty) 'old_clues_may_be_poor': item.existing,
          },
      ]),
    );
  }
  stdout.writeln('${targets.length} words in ${chunks.length} files of up to $size → ${dir.path}');
}

void _import(_Opts o) {
  final cache = o.required('--cache');
  final entries = _wordlist(o);
  final displays = <String, String>{};
  for (final e in entries) {
    displays.putIfAbsent(e.text, () => e.display);
  }
  final files = <File>[];
  // Positional arguments: anything that isn't an option or an option's value.
  final positional = [
    for (var i = 0; i < o.args.length; i++)
      if (!o.args[i].startsWith('--') && (i == 0 || !o.args[i - 1].startsWith('--'))) o.args[i],
  ];
  for (final arg in positional) {
    final type = FileSystemEntity.typeSync(arg);
    if (type == FileSystemEntityType.directory) {
      files.addAll(Directory(arg).listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl')));
    } else if (type == FileSystemEntityType.file) {
      files.add(File(arg));
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  final done = _cached(cache);
  var added = 0;
  var skipped = 0;
  var unreadable = 0;
  for (final file in files) {
    for (final line in file.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || !trimmed.startsWith('{')) continue;
      try {
        final row = jsonDecode(trimmed) as Map<String, dynamic>;
        final answer = '${row['answer']}'.toUpperCase().replaceAll(RegExp('[^A-Z]'), '');
        final display = displays[answer];
        if (display == null || done.contains(answer)) {
          skipped++;
          continue;
        }
        final result = BakeResult(
          answer,
          row['verdict'] == 'reject' ? 'reject' : 'keep',
          row['reason'] as String? ?? '',
          [
            for (final c in row['clues'] as List? ?? const [])
              if (c is String) (text: c, style: '') else if (c is Map) (text: '${c['text']}', style: '${c['style'] ?? ''}'),
          ],
        );
        _append(cache, [_gate(result, display, 'chatgpt')]);
        done.add(answer);
        added++;
      } catch (_) {
        unreadable++;
      }
    }
  }
  stdout.writeln('imported $added words from ${files.length} files '
      '($skipped already done or not in the word list, $unreadable unreadable lines) into $cache');
}

// ---------------------------------------------------------------------
// apply
// ---------------------------------------------------------------------

void _apply(_Opts o) {
  final cache = o.required('--cache');
  final out = o.required('--out');
  final rejections = !o.flag('--no-rejections');
  final baked = <String, Map<String, dynamic>>{};
  for (final line in File(cache).readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    final row = jsonDecode(line) as Map<String, dynamic>;
    baked[row['answer'] as String] = row;
  }

  final lines = File(o.value('--wordlist') ?? _defaultWordlist).readAsLinesSync();
  final output = StringBuffer();
  var recluded = 0;
  var rejected = 0;
  for (final line in lines) {
    if (line.startsWith('#')) {
      output.writeln(line
          .replaceFirst('# flags: 1=proper 2=phrase 4=crosswordese', '# flags: 1=proper 2=phrase 4=crosswordese 8=rejected by the clue bake')
          .replaceFirst('l=llm', 'l=llm e=edited (clue bake, tool/bake_crossword_clues.dart)'));
      continue;
    }
    final f = line.split('\t');
    final row = f.length >= 9 ? baked[f[0]] : null;
    if (row == null) {
      output.writeln(line);
      continue;
    }
    final good = [
      for (final c in row['clues'] as List)
        if ((c as Map)['ok'] == true) (c['text'] as String).replaceAll('\t', ' '),
    ];
    var fields = f;
    if (good.isNotEmpty) {
      fields = [...f.take(9), for (final c in good.take(3)) 'e:$c'];
      recluded++;
    }
    final crude = _crudeAnswers.contains(f[0]) || hasProfanity(f[1]);
    if (rejections && (row['verdict'] == 'reject' || crude)) {
      fields = [...fields];
      final flags = int.parse(fields[4]);
      if (flags & 8 == 0) {
        fields[4] = '${flags | 8}';
        rejected++;
      }
    }
    output.writeln(fields.join('\t'));
  }
  File(out)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(output.toString());
  stdout.writeln('wrote $out: $recluded words re-clued${rejections ? ', $rejected rejected from the fill pool' : ''}');
}

class _Opts {
  final List<String> args;
  _Opts(this.args);

  String? value(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  String required(String name) => value(name) ?? (throw ArgumentError('$name is required'));
  bool flag(String name) => args.contains(name);
}
