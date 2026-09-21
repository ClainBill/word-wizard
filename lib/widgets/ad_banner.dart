import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../services/ads_service.dart';

/// The banner under a word card. Nothing at all — no reserved space —
/// for premium accounts, when there's no ad service, or when no ad
/// fills; and it disappears the moment premium activates, which is the
/// "next safe boundary" for a static banner (spec §7.3).
class AdBanner extends ConsumerStatefulWidget {
  /// Inline in scrolling content (a word card): the banner gets vertical
  /// breathing room and a soft edge, rather than sitting flush at the
  /// bottom of a screen.
  final bool inline;

  const AdBanner({super.key, this.inline = false});

  @override
  ConsumerState<AdBanner> createState() => _AdBannerState();
}

class _AdBannerState extends ConsumerState<AdBanner> {
  BannerHandle? _handle;
  int? _loadedWidth;

  @override
  void dispose() {
    _handle?.dispose();
    super.dispose();
  }

  Future<void> _load(AdsService ads, int width) async {
    if (_loadedWidth == width) return;
    _loadedWidth = width;
    final handle = await ads.loadBanner(width: width);
    if (!mounted) {
      handle?.dispose();
      return;
    }
    _handle?.dispose();
    setState(() => _handle = handle);
  }

  @override
  Widget build(BuildContext context) {
    final ads = ref.watch(adsServiceProvider);
    // The SDK finishes starting a few seconds after launch; a card opened
    // before that gets its banner when it does.
    return ListenableBuilder(
      listenable: ads.availability,
      builder: (context, _) => _build(context, ads),
    );
  }

  Widget _build(BuildContext context, AdsService ads) {
    final premium = ref.watch(isPremiumProvider);
    if (premium || !ads.available) {
      if (_handle != null) {
        _handle!.dispose();
        _handle = null;
        _loadedWidth = null;
      }
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.truncate();
        if (width > 0) _load(ads, width);
        final handle = _handle;
        if (handle == null) return const SizedBox.shrink();
        // Exactly the ad's height: in a Scaffold's bottom slot an
        // unconstrained Center would take the whole screen.
        final banner = SizedBox(
          height: handle.height,
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: Center(child: handle.widget),
          ),
        );
        if (widget.inline) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: ClipRRect(borderRadius: BorderRadius.circular(8), child: banner),
          );
        }
        return SafeArea(top: false, child: banner);
      },
    );
  }
}
