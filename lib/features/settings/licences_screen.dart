import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';

import '../../services/feedback_config.dart';

/// Where the words come from, and on what terms. Settings → About → Data
/// sources & licences. The same notices are registered with Flutter's
/// [LicenseRegistry] by [registerDataLicences], so the standard licence page
/// (open-source packages) carries them too.
class LicencesScreen extends StatelessWidget {
  const LicencesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Data sources & licences')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(
            'Word Wizard is built on open data. This is what it uses and what each '
            'source asks in return.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          for (final source in dataSources) ...[
            const SizedBox(height: 20),
            Text(source.name, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(source.role),
            const SizedBox(height: 4),
            Text(source.licence, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
          ],
          const SizedBox(height: 28),
          OutlinedButton.icon(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'Word Wizard',
              applicationVersion: appVersion,
              applicationLegalese: 'Dictionary content © Wiktionary contributors, CC BY-SA 3.0.',
            ),
            icon: const Icon(Icons.article_outlined),
            label: const Text('Open-source licences'),
          ),
        ],
      ),
    );
  }
}

/// One data source the app ships: what it is, what it's used for, and its
/// terms in a sentence — the full notice, where one is required, is in
/// [_notices].
class DataSource {
  final String name;
  final String role;
  final String licence;

  const DataSource({required this.name, required this.role, required this.licence});
}

const List<DataSource> dataSources = [
  DataSource(
    name: 'English Wiktionary, via Kaikki.org',
    role: 'The dictionary: headwords, senses, examples, pronunciations and etymologies.',
    licence:
        'Text © Wiktionary contributors, licensed under CC BY-SA 3.0 and the GFDL. '
        'Extract by Tatu Ylonen\'s Wiktextract project (kaikki.org).',
  ),
  DataSource(
    name: 'ENABLE word list',
    role: 'The spellings the Word Hunt accepts, and the base of the crossword word list.',
    licence: 'Public domain.',
  ),
  DataSource(
    name: 'Nediger crossword word list',
    role:
        'Curated crossword answers and their quality tiers, including the multi-word '
        'and colloquial entries.',
    licence: 'MIT License, © 2026 bewilderingly. Full notice under Open-source licences.',
  ),
  DataSource(
    name: 'WordNet',
    role: 'Sense counts and the glosses behind many crossword clues.',
    licence: 'Princeton University WordNet License. Full notice under Open-source licences.',
  ),
  DataSource(
    name: 'wordfreq',
    role: 'Word-frequency figures that decide which words count as familiar.',
    licence:
        'Code Apache 2.0; frequency data compiled from CC-licensed corpora, used '
        'with attribution (Robyn Speer, wordfreq).',
  ),
  DataSource(
    name: 'Material Symbols and Icons',
    role: 'The app\'s icons.',
    licence: 'Apache License 2.0, © Google.',
  ),
];

/// Full notices for the sources whose licences require one to travel with
/// the data.
const Map<String, String> _notices = {
  'Nediger crossword word list': '''
MIT License

Copyright (c) 2026 bewilderingly

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
''',
  'WordNet': '''
WordNet Release 3.0

This software and database is being provided to you, the LICENSEE, by Princeton University under the following license. By obtaining, using and/or copying this software and database, you agree that you have read, understood, and will comply with these terms and conditions.:

Permission to use, copy, modify and distribute this software and database and its documentation for any purpose and without fee or royalty is hereby granted, provided that you agree to comply with the following copyright notice and statements, including the disclaimer, and that the same appear on ALL copies of the software, database and documentation, including modifications that you make for internal use or for distribution.

WordNet 3.0 Copyright 2006 by Princeton University. All rights reserved.

THIS SOFTWARE AND DATABASE IS PROVIDED "AS IS" AND PRINCETON UNIVERSITY MAKES NO REPRESENTATIONS OR WARRANTIES, EXPRESS OR IMPLIED. BY WAY OF EXAMPLE, BUT NOT LIMITATION, PRINCETON UNIVERSITY MAKES NO REPRESENTATIONS OR WARRANTIES OF MERCHANT- ABILITY OR FITNESS FOR ANY PARTICULAR PURPOSE OR THAT THE USE OF THE LICENSED SOFTWARE, DATABASE OR DOCUMENTATION WILL NOT INFRINGE ANY THIRD PARTY PATENTS, COPYRIGHTS, TRADEMARKS OR OTHER RIGHTS.

The name of Princeton University or Princeton may not be used in advertising or publicity pertaining to distribution of the software and/or database. Title to copyright in this software, database and any associated documentation shall at all times remain with Princeton University and LICENSEE agrees to preserve same.
''',
  'English Wiktionary, via Kaikki.org': '''
Dictionary content is derived from the English Wiktionary (en.wiktionary.org), © Wiktionary contributors, and is available under the Creative Commons Attribution-ShareAlike 3.0 Unported License (CC BY-SA 3.0) and the GNU Free Documentation License (GFDL). The machine-readable extract is produced by Wiktextract (kaikki.org), by Tatu Ylonen.

Adaptations of that content in this app are offered under the same CC BY-SA 3.0 terms.
''',
  'wordfreq': '''
Word-frequency data from wordfreq (Robyn Speer), whose code is Apache License 2.0 and whose data is compiled from sources under Creative Commons licences. Attribution: "wordfreq" by Robyn Speer, https://github.com/rspeer/wordfreq.
''',
};

/// Adds the data-source notices to Flutter's licence registry, once, so
/// [showLicensePage] lists them next to the package licences. Called at
/// startup.
void registerDataLicences() {
  LicenseRegistry.addLicense(() async* {
    for (final entry in _notices.entries) {
      yield LicenseEntryWithLineBreaks([entry.key], entry.value.trim());
    }
  });
}
