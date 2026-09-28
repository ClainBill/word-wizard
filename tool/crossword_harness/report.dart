// Turns a harness run into numbers (summarize) and a page you can read
// (renderReport). The page follows the app's own look — its paper, ink,
// ochre and moss, and the site's type — and works on a phone.

import 'dart:convert';

import 'lint.dart';

const _stages = ['before', 'after'];
const _scoreKeys = ['overall', 'clues', 'fill', 'variety', 'fun'];

double? _mean(Iterable<num> xs) => xs.isEmpty ? null : xs.reduce((a, b) => a + b) / xs.length;

/// Per size and overall: generation, lint and judge figures for each stage.
Map<String, dynamic> summarize(List<Map<String, dynamic>> puzzles) {
  Map<String, dynamic> group(List<Map<String, dynamic>> ps) {
    final ok = ps.where((p) => p['ok'] == true).toList();
    final out = <String, dynamic>{
      'puzzles': ps.length,
      'generated': ok.length,
      'meanGenMs': _mean(ok.map((p) => p['genMs'] as num)),
    };
    for (final stage in _stages) {
      final snaps = [for (final p in ok) if (p[stage] is Map) p[stage] as Map<String, dynamic>];
      if (snaps.isEmpty) continue;
      final lint = [for (final s in snaps) s['lint'] as Map<String, dynamic>];
      final words = lint.fold<int>(0, (a, l) => a + (l['words'] as int));
      final clueFlags = <String, int>{};
      final fillFlags = <String, int>{};
      for (final l in lint) {
        (l['clueFlags'] as Map).forEach((k, v) => clueFlags[k as String] = (clueFlags[k] ?? 0) + (v as int));
        (l['fillFlags'] as Map).forEach((k, v) => fillFlags[k as String] = (fillFlags[k] ?? 0) + (v as int));
      }
      final judged = [
        for (final s in snaps)
          if (s['judge'] is Map && (s['judge'] as Map)['scores'] is Map) s['judge'] as Map<String, dynamic>,
      ];
      final categories = <String, int>{};
      for (final j in judged) {
        for (final c in j['badClues'] as List) {
          final cat = '${(c as Map)['category'] ?? 'other'}';
          categories[cat] = (categories[cat] ?? 0) + 1;
        }
      }
      out[stage] = {
        'words': words,
        'flaggedCluePct': words == 0 ? 0 : 100 * lint.fold<int>(0, (a, l) => a + (l['flaggedClues'] as int)) / words,
        'flaggedFillPct': words == 0 ? 0 : 100 * lint.fold<int>(0, (a, l) => a + (l['flaggedFill'] as int)) / words,
        'meanClueWords': _mean(lint.map((l) => l['meanClueWords'] as num)),
        'clueFlags': clueFlags,
        'fillFlags': fillFlags,
        'judged': judged.length,
        'scores': {
          for (final k in _scoreKeys)
            k: _mean([for (final j in judged) if ((j['scores'] as Map)[k] is num) (j['scores'] as Map)[k] as num]),
        },
        'badCluesPerPuzzle': _mean([for (final j in judged) (j['badClues'] as List).length]),
        'badAnswersPerPuzzle': _mean([for (final j in judged) (j['badAnswers'] as List).length]),
        'badClueCategories': categories,
      };
    }
    final edited = [for (final p in ok) if (p['editor'] is Map) p['editor'] as Map<String, dynamic>];
    if (edited.isNotEmpty) {
      out['editor'] = {
        'runs': edited.length,
        'cluesProposed': edited.fold<int>(0, (a, e) => a + (e['cluesProposed'] as int)),
        'cluesApplied': edited.fold<int>(0, (a, e) => a + (e['cluesApplied'] as int)),
        'wordsProposed': edited.fold<int>(0, (a, e) => a + (e['wordsProposed'] as int)),
        'wordsApplied': edited.fold<int>(0, (a, e) => a + (e['wordsApplied'] as int)),
        'costUsd': edited.fold<double>(0, (a, e) => a + (e['costUsd'] as num)),
        'meanLatencyMs': _mean(edited.map((e) => e['latencyMs'] as num)),
      };
    }
    return out;
  }

  final sizes = <String>[];
  for (final p in puzzles) {
    if (!sizes.contains(p['size'])) sizes.add(p['size'] as String);
  }
  return {
    'all': group(puzzles),
    for (final s in sizes) s: group([for (final p in puzzles) if (p['size'] == s) p]),
  };
}

String _f(Object? x, [int digits = 1]) => x is num ? x.toStringAsFixed(digits) : '—';

String formatSummary(Map<String, dynamic> summary) {
  final b = StringBuffer();
  summary.forEach((name, g) {
    g as Map<String, dynamic>;
    b.write('${name.padRight(5)} ${g['generated']}/${g['puzzles']} built');
    for (final stage in _stages) {
      final s = g[stage] as Map<String, dynamic>?;
      if (s == null) continue;
      final scores = s['scores'] as Map;
      b.write(' | $stage: clues flagged ${_f(s['flaggedCluePct'])}%, fill flagged ${_f(s['flaggedFillPct'])}%'
          '${s['judged'] == 0 ? '' : ', judge overall ${_f(scores['overall'])} clues ${_f(scores['clues'])} fill ${_f(scores['fill'])}'}');
    }
    b.writeln();
  });
  return b.toString();
}

String _esc(Object? s) => const HtmlEscape().convert('${s ?? ''}');

final _clueLabels = {for (final f in ClueFlag.values) f.name: f.label};
final _fillLabels = {for (final f in FillFlag.values) f.name: f.label};

String renderReport(Map<String, dynamic> run) {
  final summary = run['summary'] as Map<String, dynamic>;
  final config = run['config'] as Map<String, dynamic>;
  final puzzles = (run['puzzles'] as List).cast<Map<String, dynamic>>();
  final b = StringBuffer();
  b.write('''
<title>Crossword Harness</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,400..600&family=Newsreader:ital,opsz,wght@0,6..72,400..600;1,6..72,400&family=Instrument+Sans:wght@400;500;600&display=swap">
<style>
:root{--paper:#E9EAE0;--surface:#F5F5EF;--ink:#1E2A22;--ink-2:#5B665F;--ink-3:#8A948C;--rule:#C9CCBE;--rule-2:#DDDFD3;
--ochre:#8A5A22;--ochre-soft:rgba(138,90,34,.14);--moss:#35604F;--moss-soft:rgba(53,96,79,.14);--bad:#9A3B2E;--bad-soft:rgba(154,59,46,.12);
--cell:#FBFBF7;--block:#1E2A22;
--display:"Fraunces",Georgia,serif;--body:"Newsreader",Georgia,serif;--ui:"Instrument Sans","Helvetica Neue",Arial,sans-serif}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){color-scheme:dark;--paper:#14170F;--surface:#1B1F17;--ink:#EDEBDF;--ink-2:#A6AA9A;--ink-3:#737A6C;--rule:#33382C;--rule-2:#2A2F24;
--ochre:#D3A45C;--ochre-soft:rgba(211,164,92,.16);--moss:#7FBBA0;--moss-soft:rgba(127,187,160,.16);--bad:#E08A7B;--bad-soft:rgba(224,138,123,.14);--cell:#22271D;--block:#0B0D08}}
:root[data-theme="dark"]{color-scheme:dark;--paper:#14170F;--surface:#1B1F17;--ink:#EDEBDF;--ink-2:#A6AA9A;--ink-3:#737A6C;--rule:#33382C;--rule-2:#2A2F24;
--ochre:#D3A45C;--ochre-soft:rgba(211,164,92,.16);--moss:#7FBBA0;--moss-soft:rgba(127,187,160,.16);--bad:#E08A7B;--bad-soft:rgba(224,138,123,.14);--cell:#22271D;--block:#0B0D08}
*{box-sizing:border-box}
body{background:var(--paper);color:var(--ink);font-family:var(--body);font-size:16px;line-height:1.5;padding-inline:clamp(16px,4vw,40px);padding-block:24px 64px}
main{max-width:1080px;margin:0 auto;display:grid;gap:40px}
h1,h2,h3{font-family:var(--display);font-weight:500;letter-spacing:-.01em;text-wrap:balance;margin:0}
h1{font-size:clamp(28px,5vw,40px)} h2{font-size:24px} h3{font-size:19px}
.meta{font-family:var(--ui);font-size:13px;color:var(--ink-2)}
.eyebrow{font-family:var(--ui);font-size:11px;font-weight:600;letter-spacing:.1em;text-transform:uppercase;color:var(--ink-3)}
.scroll{overflow-x:auto}
table{border-collapse:collapse;font-family:var(--ui);font-size:13px;font-variant-numeric:tabular-nums;width:100%}
th,td{padding:7px 10px;border-bottom:1px solid var(--rule-2);text-align:right;white-space:nowrap}
th:first-child,td:first-child{text-align:left}
th{font-weight:500;color:var(--ink-3)}
td.good{color:var(--moss);font-weight:600} td.bad{color:var(--bad);font-weight:600}
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chip{font-family:var(--ui);font-size:11.5px;padding:2px 8px;border-radius:999px;background:var(--bad-soft);color:var(--bad)}
.chip.fill{background:var(--ochre-soft);color:var(--ochre)}
.chip.ok{background:var(--moss-soft);color:var(--moss)}
section.puzzle{border-top:1px solid var(--rule);padding-top:20px;display:grid;gap:16px}
.pz-head{display:flex;flex-wrap:wrap;gap:8px 16px;align-items:baseline}
.pz-body{display:grid;grid-template-columns:minmax(0,auto) minmax(0,1fr);gap:24px;align-items:start}
@media (max-width:760px){.pz-body{grid-template-columns:1fr}}
.grid{display:grid;gap:1px;background:var(--block);padding:1px;border-radius:4px;width:max-content;max-width:100%}
.grid span{width:22px;height:22px;display:grid;place-items:center;background:var(--cell);font-family:var(--ui);font-size:11px;font-weight:600}
.grid span.b{background:var(--block)}
.clues{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:4px 24px}
.clue{display:grid;grid-template-columns:2.2em 1fr;gap:2px 6px;padding:5px 0;border-bottom:1px solid var(--rule-2);font-size:14.5px}
.clue .n{font-family:var(--ui);font-size:12px;color:var(--ink-3);padding-top:2px}
.clue .a{font-family:var(--ui);font-weight:600;font-size:12.5px;letter-spacing:.04em}
.clue .a small{font-weight:400;color:var(--ink-3);letter-spacing:0}
.clue .chips{grid-column:2}
.clue.study .a{color:var(--moss)}
.judge{background:var(--surface);border:1px solid var(--rule);border-radius:12px;padding:14px 16px;display:grid;gap:8px;font-size:14.5px}
.judge ul{margin:0;padding-left:18px;display:grid;gap:4px}
.edits{font-family:var(--ui);font-size:13px;display:grid;gap:4px}
.edits .x{color:var(--ink-3);text-decoration:line-through}
details{border:1px solid var(--rule-2);border-radius:10px;padding:10px 14px;background:var(--surface)}
summary{cursor:pointer;font-family:var(--ui);font-size:13.5px;font-weight:600}
summary:focus-visible{outline:2px solid var(--ochre);outline-offset:3px}
</style>
<main>
<header style="display:grid;gap:6px">
  <span class="eyebrow">Word Wizard · crossword quality</span>
  <h1>Crossword harness: ${_esc(run['label'])}</h1>
  <p class="meta">${_esc(run['createdAt'])} · seed ${config['seed']} · ${config['count']} per size ·
  editor ${config['editor'] == true ? _esc(config['editorModel']) : 'off'} ·
  judge ${config['judge'] == true ? _esc(config['judgeModel']) : 'off'} ·
  ${_esc(config['wordlist'] ?? 'assets/crossword/wordlist.tsv')}</p>
</header>
''');

  // ---- Summary ----
  b.write('<section style="display:grid;gap:12px"><h2>Summary</h2><div class="scroll"><table><tr>'
      '<th>Size</th><th>Built</th><th>Stage</th><th>Judge overall</th><th>Clues</th><th>Fill</th><th>Variety</th>'
      '<th>Bad clues / puzzle</th><th>Bad answers / puzzle</th><th>Clues flagged</th><th>Fill flagged</th><th>Words / clue</th></tr>');
  summary.forEach((name, g) {
    g as Map<String, dynamic>;
    for (final stage in _stages) {
      final s = g[stage] as Map<String, dynamic>?;
      if (s == null) continue;
      final scores = s['scores'] as Map;
      String cls(Object? v, {bool higherIsBetter = true, double good = 7, double bad = 5}) {
        if (v is! num) return '';
        return higherIsBetter ? (v >= good ? 'good' : v < bad ? 'bad' : '') : (v <= good ? 'good' : v > bad ? 'bad' : '');
      }

      b.write('<tr><td>${stage == 'before' ? _esc(name == 'all' ? 'All' : name[0].toUpperCase() + name.substring(1)) : ''}</td>'
          '<td>${stage == 'before' ? '${g['generated']}/${g['puzzles']}' : ''}</td><td>$stage</td>'
          '<td class="${cls(scores['overall'])}">${_f(scores['overall'])}</td>'
          '<td class="${cls(scores['clues'])}">${_f(scores['clues'])}</td>'
          '<td class="${cls(scores['fill'])}">${_f(scores['fill'])}</td>'
          '<td>${_f(scores['variety'])}</td>'
          '<td>${_f(s['badCluesPerPuzzle'])}</td><td>${_f(s['badAnswersPerPuzzle'])}</td>'
          '<td class="${cls(s['flaggedCluePct'], higherIsBetter: false, good: 5, bad: 15)}">${_f(s['flaggedCluePct'])}%</td>'
          '<td class="${cls(s['flaggedFillPct'], higherIsBetter: false, good: 3, bad: 10)}">${_f(s['flaggedFillPct'])}%</td>'
          '<td>${_f(s['meanClueWords'])}</td></tr>');
    }
  });
  b.write('</table></div>');

  final all = summary['all'] as Map<String, dynamic>;
  final allBefore = all['before'] as Map<String, dynamic>?;
  if (allBefore != null) {
    String counts(Map m, Map<String, String> labels, String cls) {
      final entries = m.entries.toList()..sort((x, y) => (y.value as int).compareTo(x.value as int));
      return entries.isEmpty
          ? '<span class="chip ok">none</span>'
          : entries.map((e) => '<span class="chip $cls">${_esc(labels[e.key] ?? e.key)} · ${e.value}</span>').join();
    }

    b.write('<div style="display:grid;gap:10px">'
        '<div><span class="eyebrow">Clue faults, before the editor</span><div class="chips" style="margin-top:6px">'
        '${counts(allBefore['clueFlags'] as Map, _clueLabels, '')}</div></div>'
        '<div><span class="eyebrow">Answer faults, before the editor</span><div class="chips" style="margin-top:6px">'
        '${counts(allBefore['fillFlags'] as Map, _fillLabels, 'fill')}</div></div>'
        '<div><span class="eyebrow">What the judge objected to, before</span><div class="chips" style="margin-top:6px">'
        '${counts(allBefore['badClueCategories'] as Map, const {}, '')}</div></div>');
    final allAfter = all['after'] as Map<String, dynamic>?;
    if (allAfter != null) {
      b.write('<div><span class="eyebrow">What the judge objected to, after</span><div class="chips" style="margin-top:6px">'
          '${counts(allAfter['badClueCategories'] as Map, const {}, '')}</div></div>');
    }
    b.write('</div>');
  }
  final editor = all['editor'] as Map<String, dynamic>?;
  if (editor != null) {
    b.write('<p class="meta">AI editor: ${editor['cluesApplied']} of ${editor['cluesProposed']} clue rewrites applied, '
        '${editor['wordsApplied']} of ${editor['wordsProposed']} answer bans applied across ${editor['runs']} puzzles; '
        '\$${_f(editor['costUsd'], 3)} total, ${_f((editor['meanLatencyMs'] as num?)?.toDouble() == null ? null : (editor['meanLatencyMs'] as num) / 1000)} s average.</p>');
  }
  b.write('</section>');

  // ---- Puzzles ----
  b.write('<section style="display:grid;gap:8px"><h2>Puzzles</h2><p class="meta">Each puzzle as generated, what the judge said, '
      'and what the editor changed. Green answers are the study words it was anchored on.</p></section>');
  for (final p in puzzles) {
    final size = '${p['size']}';
    final title = '${size[0].toUpperCase()}${size.substring(1)} · seed ${p['seed']}';
    if (p['ok'] != true) {
      b.write('<section class="puzzle"><h3>${_esc(title)}</h3><p class="meta">Generation failed after ${p['genMs']} ms.</p></section>');
      continue;
    }
    b.write('<section class="puzzle" id="p${p['seed']}"><div class="pz-head"><h3>${_esc(title)}</h3>'
        '<span class="meta">${_esc(p['theme'] ?? 'no theme')} · built in ${p['genMs']} ms</span></div>');
    b.write(_stage(p['before'] as Map<String, dynamic>, 'As generated', open: true));
    if (p['editor'] is Map) {
      final e = p['editor'] as Map<String, dynamic>;
      final edits = (e['edits'] as List).cast<Map<String, dynamic>>();
      b.write('<details><summary>AI editor: ${e['cluesApplied']}/${e['cluesProposed']} clue rewrites, '
          '${e['wordsApplied']}/${e['wordsProposed']} bans applied</summary><div class="edits" style="margin-top:8px">'
          '<p class="meta" style="margin:0">${_esc(e['notes'])}</p>');
      for (final edit in edits) {
        b.write('<div>${edit['kind'] == 'ban' ? 'Ban' : 'Clue'}: <span class="${edit['applied'] == true ? '' : 'x'}">'
            '${_esc(edit['before'])} → ${_esc(edit['after'])}</span>'
            '${edit['applied'] == true ? '' : ' <span class="chip">${_esc(edit['rejection'])}</span>'}</div>');
      }
      if ('${e['banFailure']}'.isNotEmpty) b.write('<div class="chip">bans not applied: ${_esc(e['banFailure'])}</div>');
      b.write('</div></details>');
    } else if (p['editorError'] != null) {
      b.write('<p class="meta">Editor failed: ${_esc(p['editorError'])}</p>');
    }
    if (p['after'] is Map) b.write(_stage(p['after'] as Map<String, dynamic>, 'After the editor', open: false));
    b.write('</section>');
  }
  b.write('</main>');
  return b.toString();
}

String _stage(Map<String, dynamic> snap, String label, {required bool open}) {
  final b = StringBuffer();
  final grid = (snap['grid'] as List).cast<String>();
  final judge = snap['judge'] as Map<String, dynamic>?;
  final scores = judge?['scores'] as Map?;
  b.write('<details${open ? ' open' : ''}><summary>$label'
      '${scores == null ? '' : ' · judge ${scores['overall']}/10 (clues ${scores['clues']}, fill ${scores['fill']})'}'
      '</summary><div style="display:grid;gap:14px;margin-top:12px">');
  if (judge != null && judge['error'] == null) {
    final badAnswers = (judge['badAnswers'] as List).cast<Map>();
    final badClues = (judge['badClues'] as List).cast<Map>();
    b.write('<div class="judge"><span class="eyebrow">Judge</span><div>${_esc(judge['summary'])}</div>');
    if (badAnswers.isNotEmpty) {
      b.write('<ul>${badAnswers.map((a) => '<li><b>${_esc(a['answer'])}</b>: ${_esc(a['why'])}</li>').join()}</ul>');
    }
    if (badClues.isNotEmpty) {
      b.write('<ul>${badClues.map((c) => '<li><b>${_esc(c['answer'])}</b> <span class="chip">${_esc(c['category'])}</span> '
          '“${_esc(c['clue'])}”: ${_esc(c['why'])}${c['better'] == null ? '' : ' <i>Better: ${_esc(c['better'])}</i>'}</li>').join()}</ul>');
    }
    b.write('</div>');
  } else if (judge?['error'] != null) {
    b.write('<p class="meta">Judge failed: ${_esc(judge!['error'])}</p>');
  }
  b.write('<div class="pz-body"><div class="scroll"><div class="grid" style="grid-template-columns:repeat(${grid.first.length},22px)">');
  for (final row in grid) {
    for (final ch in row.split('')) {
      b.write(ch == '#' ? '<span class="b"></span>' : '<span>$ch</span>');
    }
  }
  b.write('</div></div><div class="clues">');
  final words = (snap['words'] as List).cast<Map<String, dynamic>>();
  for (final dir in ['across', 'down']) {
    b.write('<div><span class="eyebrow">$dir</span>');
    for (final w in words.where((w) => w['dir'] == dir)) {
      final fill = (w['fillFlags'] as List).cast<String>();
      final clue = (w['clueFlags'] as List).cast<String>();
      b.write('<div class="clue${w['study'] == true ? ' study' : ''}"><span class="n">${w['number']}</span>'
          '<div><div>${_esc(w['clue'])}</div><div class="a">${_esc(w['answer'])} '
          '<small>${_esc(w['clueType'])} · zipf ${_f(w['zipf'])}${w['familiarity'] == null ? '' : ' · fam ${w['familiarity']}'}</small></div></div>');
      if (fill.isNotEmpty || clue.isNotEmpty) {
        b.write('<div class="chips">'
            '${clue.map((f) => '<span class="chip">${_esc(_clueLabels[f] ?? f)}</span>').join()}'
            '${fill.map((f) => '<span class="chip fill">${_esc(_fillLabels[f] ?? f)}</span>').join()}</div>');
      }
      b.write('</div>');
    }
    b.write('</div>');
  }
  b.write('</div></div></div></details>');
  return b.toString();
}
