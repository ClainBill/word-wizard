import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/backup_repository.dart';
import '../../services/feedback_config.dart';

/// Settings → Your data: save lists and study progress to a file, and
/// bring such a file back — onto this phone or a new one.
class BackupSection extends ConsumerStatefulWidget {
  const BackupSection({super.key});

  @override
  ConsumerState<BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends ConsumerState<BackupSection> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Your data', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
        ListTile(
          leading: const Icon(Icons.save_alt_outlined),
          title: const Text('Back up to a file'),
          subtitle: const Text(
            'Your lists, study progress and history, pinned meanings, notes and Slang Stack, '
            'in one file you keep — on the phone, or in Drive or iCloud.',
          ),
          enabled: !_busy,
          onTap: _backUp,
        ),
        ListTile(
          leading: const Icon(Icons.settings_backup_restore_outlined),
          title: const Text('Restore from a backup'),
          subtitle: const Text('Bring a backup file onto this phone — added to what\'s here, or replacing it.'),
          enabled: !_busy,
          onTap: _restore,
        ),
      ],
    );
  }

  static String _fileName(DateTime now) =>
      'word-wizard-backup-${now.year}-${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}.json';

  Future<void> _backUp() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final data = await ref.read(backupRepositoryProvider).export(appVersion: appVersion);
      final bytes = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent(' ').convert(data)));
      final saved = await FilePicker.saveFile(
        fileName: _fileName(DateTime.now()),
        bytes: bytes,
        mimeType: 'application/json',
        dialogTitle: 'Save your Word Wizard backup',
      );
      if (saved == null) return; // cancelled
      final cards = (data['studyCards'] as List).length;
      final lists = (data['lists'] as List).length;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Backed up $lists ${lists == 1 ? 'list' : 'lists'} and $cards study '
            '${cards == 1 ? 'card' : 'cards'}.',
          ),
        ),
      );
    } catch (e) {
      debugPrint('backup: $e');
      messenger.showSnackBar(const SnackBar(content: Text('Couldn\'t save the backup. Try again.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final messenger = ScaffoldMessenger.of(context);
    final PlatformFile? file;
    try {
      file = await FilePicker.pickFile(dialogTitle: 'Choose a Word Wizard backup');
    } catch (e) {
      debugPrint('restore pick: $e');
      messenger.showSnackBar(const SnackBar(content: Text('Couldn\'t open the file picker.')));
      return;
    }
    if (file == null || !mounted) return;

    final Object? json;
    final BackupSummary summary;
    try {
      json = jsonDecode(utf8.decode(await file.xFile.readAsBytes()));
      summary = BackupRepository.summarize(json);
    } on BackupFormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('That file isn\'t a Word Wizard backup.')));
      return;
    }
    if (!mounted) return;

    final mode = await showDialog<bool>(
      context: context,
      builder: (context) => _RestoreDialog(summary: summary),
    );
    if (mode == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final result = await ref.read(backupRepositoryProvider).restore(json, replace: mode);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Restored ${result.cards} study ${result.cards == 1 ? 'card' : 'cards'}, '
            '${result.listWords} list ${result.listWords == 1 ? 'word' : 'words'} and '
            '${result.slangWords} slang ${result.slangWords == 1 ? 'word' : 'words'}'
            '${result.skippedWords > 0 ? '. ${result.skippedWords} ${result.skippedWords == 1 ? 'word isn\'t' : 'words aren\'t'} in this dictionary and ${result.skippedWords == 1 ? 'was' : 'were'} skipped' : ''}.',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e) {
      debugPrint('restore: $e');
      messenger.showSnackBar(
        const SnackBar(content: Text('Couldn\'t restore that backup. Nothing on this phone was changed.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// What's in the file, and how to bring it in. Pops true for replace,
/// false for merge, null to cancel.
class _RestoreDialog extends StatelessWidget {
  final BackupSummary summary;

  const _RestoreDialog({required this.summary});

  @override
  Widget build(BuildContext context) {
    final when = summary.exportedAt;
    final scheme = Theme.of(context).colorScheme;
    String plural(int n, String one, String many) => '$n ${n == 1 ? one : many}';
    return AlertDialog(
      title: const Text('Restore this backup?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (when != null)
            Text(
              'Made ${when.day}/${when.month}/${when.year} at '
              '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}.',
            ),
          const SizedBox(height: 8),
          Text(
            '${plural(summary.lists, 'list', 'lists')} with ${plural(summary.listWords, 'word', 'words')}\n'
            '${plural(summary.studyWords, 'word', 'words')} studied, ${plural(summary.reviews, 'review', 'reviews')}\n'
            '${plural(summary.notes, 'note', 'notes')}'
            '${summary.slangWords > 0 ? '\n${plural(summary.slangWords, 'slang word', 'slang words')}' : ''}',
          ),
          const SizedBox(height: 12),
          Text(
            'Add to this phone keeps what\'s here and brings in the rest; where a word is '
            'studied in both, the more recently reviewed card wins.\n\n'
            'Replace clears this phone\'s lists, study progress, pinned meanings, notes and '
            'Slang Stack first.',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: scheme.error),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Replace'),
        ),
        FilledButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Add to this phone')),
      ],
    );
  }
}
