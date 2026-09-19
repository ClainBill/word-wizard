import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/providers.dart';
import '../../services/feedback_config.dart';
import '../../services/feedback_service.dart';
import '../../services/screen_capture.dart';

/// Report a bug or suggest a feature without leaving the app: a message,
/// an optional link and reply address, and screenshots — the screens the
/// user was just on, captured automatically, or a photo from the library.
class FeedbackScreen extends ConsumerStatefulWidget {
  /// Which kind the form opens on; the user can switch.
  final FeedbackKind initialKind;

  const FeedbackScreen({super.key, this.initialKind = FeedbackKind.bug});

  @override
  ConsumerState<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends ConsumerState<FeedbackScreen> {
  late FeedbackKind _kind = widget.initialKind;
  final _message = TextEditingController();
  final _link = TextEditingController();
  final _email = TextEditingController();

  /// Captured screens ticked for attachment, and photos picked from the
  /// library. Together they're capped at [maxAttachments].
  final Set<CapturedScreen> _screens = {};
  final List<FeedbackAttachment> _photos = [];
  static const int maxAttachments = 4;

  bool _sending = false;

  int get _attachmentCount => _screens.length + _photos.length;

  @override
  void initState() {
    super.initState();
    _message.addListener(() => setState(() {}));
    // Anything still queued from an earlier visit gets another try now,
    // while the user is here and likely online.
    ref.read(feedbackServiceProvider).flush().then((_) {
      if (mounted) ref.invalidate(feedbackPendingProvider);
    });
  }

  @override
  void dispose() {
    _message.dispose();
    _link.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Couldn\'t open the photo library.')));
      }
      return;
    }
    if (picked == null || !mounted) return;
    final file = picked;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    setState(() {
      _photos.add(
        FeedbackAttachment(
          name: 'photo-${_photos.length + 1}${_extensionOf(file.name)}',
          mime: file.mimeType ?? _mimeFor(file.name),
          bytes: bytes,
        ),
      );
    });
  }

  static String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '.jpg' : name.substring(dot).toLowerCase();
  }

  static String _mimeFor(String name) => switch (_extensionOf(name)) {
    '.png' => 'image/png',
    '.gif' => 'image/gif',
    '.webp' => 'image/webp',
    '.heic' => 'image/heic',
    _ => 'image/jpeg',
  };

  Future<void> _send() async {
    final message = _message.text.trim();
    if (message.isEmpty || _sending) return;
    setState(() => _sending = true);
    final size = MediaQuery.sizeOf(context);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final attachments = <FeedbackAttachment>[];
    var n = 0;
    for (final screen in _screens) {
      n++;
      attachments.add(
        FeedbackAttachment(
          name: 'screen-$n-${_slug(screen.label)}.png',
          mime: 'image/png',
          bytes: await screen.png(),
        ),
      );
    }
    attachments.addAll(_photos);
    final report = FeedbackReport(
      kind: _kind,
      message: message,
      link: _link.text.trim(),
      email: _email.text.trim(),
      screen: '${size.width.round()}×${size.height.round()} @${ratio}x',
      attachments: attachments,
    );
    final service = ref.read(feedbackServiceProvider);
    final outcome = await service.submit(report);
    if (!mounted) return;
    ref.invalidate(feedbackPendingProvider);
    // The app-level messenger, so the confirmation outlives this screen.
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(switch (outcome) {
          FeedbackOutcome.sent =>
            'Thanks — your ${_kind == FeedbackKind.bug ? 'report' : 'suggestion'} '
                'has been sent.',
          FeedbackOutcome.queued =>
            service.configured
                ? 'Saved. It\'ll be sent next time the app is online.'
                : 'Saved. It\'ll be sent once this build has somewhere to send it.',
        }),
      ),
    );
  }

  static String _slug(String label) =>
      label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isBug = _kind == FeedbackKind.bug;
    final capture = ref.watch(screenCaptureProvider);
    // The screen this form was opened from is the newest capture, which
    // is Settings — of little use for a report, so it comes last.
    final recent = [
      for (final s in capture.recent)
        if (s.label != 'Settings' && s.label != 'Feedback') s,
      for (final s in capture.recent)
        if (s.label == 'Settings') s,
    ];
    final canSend = _message.text.trim().isNotEmpty && !_sending;

    return Scaffold(
      appBar: AppBar(title: Text(isBug ? 'Report a bug' : 'Suggest a feature')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          SegmentedButton<FeedbackKind>(
            segments: const [
              ButtonSegment(
                value: FeedbackKind.bug,
                icon: Icon(Icons.bug_report_outlined),
                label: Text('Bug'),
              ),
              ButtonSegment(
                value: FeedbackKind.feature,
                icon: Icon(Icons.lightbulb_outline),
                label: Text('Feature'),
              ),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _message,
            minLines: 4,
            maxLines: 10,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: isBug ? 'What happened?' : 'What would you like?',
              hintText: isBug
                  ? 'What you did, what you expected, and what happened instead.'
                  : 'What it would do, and where in the app it belongs.',
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _link,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Link (optional)',
              helperText: 'A page, video or anything else that shows it',
              prefixIcon: Icon(Icons.link),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Your email (optional)',
              helperText: 'Only if you\'d like a reply',
              prefixIcon: Icon(Icons.alternate_email),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          Text('Screenshots', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            recent.isEmpty
                ? 'The screens you visit are kept for a moment so a report can '
                      'show one. None yet — go to the screen and come back.'
                : 'Tap a screen you were just on to attach it'
                      '${_attachmentCount >= maxAttachments ? ' (up to $maxAttachments)' : ''}.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          if (recent.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 168,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: recent.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, i) {
                  final screen = recent[i];
                  final selected = _screens.contains(screen);
                  return _ScreenThumb(
                    screen: screen,
                    selected: selected,
                    enabled: selected || _attachmentCount < maxAttachments,
                    onTap: () => setState(() {
                      if (!_screens.remove(screen)) _screens.add(screen);
                    }),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (_photos.isNotEmpty) ...[
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final photo in _photos)
                  _PhotoThumb(photo: photo, onRemove: () => setState(() => _photos.remove(photo))),
              ],
            ),
            const SizedBox(height: 12),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _attachmentCount < maxAttachments ? _pickPhoto : null,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Add a photo'),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: canSend ? _send : null,
            icon: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_outlined),
            label: Text(_sending ? 'Sending…' : 'Send'),
          ),
          const SizedBox(height: 12),
          Text(
            'Goes to $feedbackEmail, with the app version '
            '($appVersion) and your device\'s OS so it can be reproduced. '
            'Nothing else is included unless you add it.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ScreenThumb extends StatelessWidget {
  final CapturedScreen screen;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _ScreenThumb({
    required this.screen,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final image = screen.image;
    final aspect = image.width / image.height;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 140,
              width: 140 * aspect,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? scheme.primary : scheme.outlineVariant,
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RawImage(image: image, fit: BoxFit.cover),
                  if (selected)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Icon(Icons.check_circle, color: scheme.primary, size: 22),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              screen.label,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoThumb extends StatelessWidget {
  final FeedbackAttachment photo;
  final VoidCallback onRemove;

  const _PhotoThumb({required this.photo, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Container(
          width: 96,
          height: 96,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Image.memory(photo.bytes, fit: BoxFit.cover),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: IconButton.filledTonal(
            onPressed: onRemove,
            icon: const Icon(Icons.close, size: 16),
            tooltip: 'Remove',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            padding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}
