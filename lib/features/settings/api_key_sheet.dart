import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/api_key_store.dart';

/// Enter, check, or remove the user's own OpenAI key — see [ApiKeyStore].
Future<void> showApiKeySheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => const _ApiKeySheet(),
  );
}

class _ApiKeySheet extends StatefulWidget {
  const _ApiKeySheet();

  @override
  State<_ApiKeySheet> createState() => _ApiKeySheetState();
}

class _ApiKeySheetState extends State<_ApiKeySheet> {
  final _controller = TextEditingController();
  bool _obscure = true;
  bool _busy = false;

  /// The last check's outcome: null = not checked, '' = passed, else the
  /// reason it failed.
  String? _checkResult;

  @override
  void initState() {
    super.initState();
    _controller.text = ApiKeyStore.instance.key ?? '';
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    setState(() {
      _controller.text = text;
      _checkResult = null;
    });
  }

  Future<void> _check() async {
    setState(() => _busy = true);
    final result = await ApiKeyStore.validate(_controller.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _checkResult = result ?? '';
    });
  }

  Future<void> _save() async {
    final text = _controller.text.trim();
    if (text.isNotEmpty && !ApiKeyStore.looksLikeKey(text)) {
      setState(() => _checkResult = 'That doesn\'t look like an API key.');
      return;
    }
    setState(() => _busy = true);
    await ApiKeyStore.instance.save(text);
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_controller.text.trim().isEmpty ? 'API key removed.' : 'API key saved.')),
    );
  }

  Future<void> _remove() async {
    setState(() => _busy = true);
    await ApiKeyStore.instance.clear();
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('API key removed.')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasStored = ApiKeyStore.instance.hasKey;
    final checkPassed = _checkResult == '';

    return Padding(
      // Keep the sheet above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('OpenAI API key', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                'Powers the crossword AI editor and the "guess from the clues" recall '
                'game. Calls go straight from this device to OpenAI on your account, '
                'so you pay for what you use. The key is kept in the device\'s secure '
                'keystore and never leaves it otherwise.',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant, height: 1.4),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                autofocus: !hasStored,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                onChanged: (_) => setState(() => _checkResult = null),
                decoration: InputDecoration(
                  hintText: 'sk-…',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.content_paste_outlined),
                        tooltip: 'Paste',
                        onPressed: _busy ? null : _paste,
                      ),
                      IconButton(
                        icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        tooltip: _obscure ? 'Show' : 'Hide',
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ],
                  ),
                ),
              ),
              if (_checkResult != null) ...[
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      checkPassed ? Icons.check_circle_outline : Icons.error_outline,
                      size: 18,
                      color: checkPassed ? scheme.secondary : scheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        checkPassed ? 'The key works.' : _checkResult!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: checkPassed ? scheme.secondary : scheme.error),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  if (hasStored)
                    TextButton(
                      onPressed: _busy ? null : _remove,
                      style: TextButton.styleFrom(foregroundColor: scheme.error),
                      child: const Text('Remove'),
                    ),
                  const Spacer(),
                  OutlinedButton(
                    onPressed: _busy || _controller.text.trim().isEmpty ? null : _check,
                    child: _busy
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Check'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy ? null : _save,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
