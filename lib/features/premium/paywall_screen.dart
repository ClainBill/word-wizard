import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/premium/premium.dart';
import '../../services/entitlement_sync.dart';
import '../../services/founder_service.dart';
import '../../services/premium_analytics.dart';
import '../../services/purchases_service.dart';
import '../account/sign_in_sheet.dart' show showSignInSheet;
import 'premium_preview.dart';

/// Opens the paywall over everything. [source] is where from, for the
/// funnel; [next] is where a successful purchase should land.
Future<void> showPaywall(BuildContext context, {required String source, String? next}) {
  final query = {'source': source, 'next': ?next};
  return context.push(Uri(path: '/premium', queryParameters: query).toString());
}

/// The Premium paywall (spec §3, §4, §7): outcome first, then the person's
/// own words in a preview, four benefits, the three options with live
/// store prices, one clear button, and the small print in readable type.
/// Founding Member is featured while places remain; Annual after.
class PaywallScreen extends ConsumerStatefulWidget {
  final String source;
  final String? next;

  const PaywallScreen({super.key, required this.source, this.next});

  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

enum _Phase { browsing, purchasing, pending, succeeded }

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  PremiumProduct? _selected;
  _Phase _phase = _Phase.browsing;
  String? _error;
  bool _restoring = false;

  /// Set when the backend said sold out during this visit, before the
  /// status provider has caught up.
  bool _founderGone = false;
  final _openedAt = DateTime.now();
  bool _viewLogged = false;

  @override
  Widget build(BuildContext context) {
    final status =
        ref.watch(premiumStatusProvider).valueOrNull ?? ref.watch(purchasesServiceProvider).current;
    final offersAsync = ref.watch(storeOffersProvider);
    final founderAsync = ref.watch(founderStatusProvider);
    final wordCount = ref.watch(studyStatsProvider).valueOrNull?.total ?? 0;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final founder = founderAsync.valueOrNull;
    final founderKnown = founderAsync.hasValue;
    // Unknown availability still shows the option — without a number and
    // without a working button — until the backend answers (spec §4.2).
    final founderAvailable = !_founderGone && (founder == null || !founder.soldOut);
    final offers = offersAsync.valueOrNull;
    final founderOffer = founderAvailable && offers != null ? offers[PremiumProduct.founder] : null;

    if (!_viewLogged && offersAsync.hasValue && founderKnown) {
      _viewLogged = true;
      PremiumAnalytics.instance.log('paywall_viewed', {
        'source': widget.source,
        'variant': founderAvailable ? 'founder_featured' : 'annual_featured',
        'entitlement_state': status.access.name,
        'word_count': wordCount,
        'founder_remaining_bucket': founder?.remainingBucket,
      });
      if (founder != null) {
        PremiumAnalytics.instance.log('founder_status_seen', {
          'remaining_bucket': founder.remainingBucket,
          'status_age_seconds': DateTime.now().difference(founder.lastUpdatedAt).inSeconds,
        });
      }
    }

    // Default selection: the featured option, once we know which it is.
    if (_selected == null && offers != null && founderKnown) {
      _selected = founderOffer != null
          ? PremiumProduct.founder
          : offers[PremiumProduct.annual] != null
          ? PremiumProduct.annual
          : offers.offers.firstOrNull?.product;
    }
    // The founder card disappearing from under a selection.
    if (_selected == PremiumProduct.founder && founderKnown && founderOffer == null) {
      _selected = PremiumProduct.annual;
    }

    final alreadyEntitled = status.isPremium && _phase != _Phase.succeeded;

    return PopScope(
      canPop: _phase != _Phase.purchasing,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _logDismissed();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Not now',
            onPressed: _phase == _Phase.purchasing ? null : () => context.pop(),
          ),
          title: const Text('Premium'),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            if (alreadyEntitled) ...[
              _Headline(
                title: 'You already have Premium',
                body: status.founder
                    ? 'You\'re a Founding Member. Thank you for backing Word Wizard early.'
                    : 'Everything is unlocked. Nothing more to buy here.',
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: _startPlaying, child: const Text('Start playing')),
            ] else if (_phase == _Phase.succeeded) ...[
              _Headline(
                title: _selected == PremiumProduct.founder
                    ? 'Welcome, Founding Member'
                    : 'Welcome to Premium',
                body: 'Premium is ready. Your games are being prepared.',
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: _startPlaying, child: const Text('Start playing')),
            ] else ...[
              _Headline(
                title: 'Make your words playable',
                body:
                    'Turn the vocabulary you save into daily games designed around what you '
                    'are learning.',
              ),
              if (wordCount > 0) ...[
                const SizedBox(height: 8),
                Text(
                  'You have $wordCount ${wordCount == 1 ? 'word' : 'words'} ready to play.',
                  style: text.titleSmall?.copyWith(color: scheme.primary),
                ),
              ],
              const SizedBox(height: 20),
              const PremiumPreview(),
              const SizedBox(height: 20),
              for (final benefit in premiumBenefits)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(Icons.check_rounded, size: 20, color: scheme.secondary),
                      const SizedBox(width: 10),
                      Expanded(child: Text(benefit, style: text.bodyLarge)),
                    ],
                  ),
                ),
              const SizedBox(height: 24),
              if (founderOffer != null) ...[
                _FounderBanner(status: founder, offer: founderOffer),
                const SizedBox(height: 12),
              ] else if ((founder?.soldOut ?? false) || _founderGone) ...[
                const _FounderEnded(),
                const SizedBox(height: 12),
              ],
              ..._options(offersAsync, offers, founder, founderOffer, scheme),
              const SizedBox(height: 16),
              _primaryButton(offers, founder, founderOffer),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(color: scheme.error)),
              ],
              const SizedBox(height: 20),
              _Disclosure(selected: _selected, offers: offers),
            ],
            const SizedBox(height: 20),
            _Links(restoring: _restoring, onRestore: _restore),
          ],
        ),
      ),
    );
  }

  List<Widget> _options(
    AsyncValue<StoreOffers> offersAsync,
    StoreOffers? offers,
    FounderStatus? founder,
    StoreOffer? founderOffer,
    ColorScheme scheme,
  ) {
    if (offersAsync.isLoading) {
      return [for (var i = 0; i < 3; i++) const _SkeletonOption()];
    }
    if (offers == null) {
      final message = offersAsync.error is StoreUnavailableException
          ? (offersAsync.error as StoreUnavailableException).message
          : 'Purchasing is temporarily unavailable.';
      return [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Purchasing is temporarily unavailable',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  '$message The previews still work, and nothing here is lost.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => ref.invalidate(storeOffersProvider),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      ];
    }
    final annual = offers[PremiumProduct.annual];
    final monthly = offers[PremiumProduct.monthly];
    final saving = offers.annualSavingPercent;
    final perMonth = offers.annualPerMonth;
    return [
      if (founderOffer != null)
        _OptionCard(
          product: PremiumProduct.founder,
          title: 'Founding Member',
          price: founderOffer.priceString,
          priceNote: 'one time',
          tag: 'Founding offer',
          detail: founder != null && founder.isFresh()
              ? 'Pay once. Premium access with no recurring charge. '
                    '${founder.remaining} of ${founder.cap} places remain.'
              : 'Pay once. Premium access with no recurring charge. '
                    'Limited to ${founder?.cap ?? 500} completed purchases.',
          selected: _selected == PremiumProduct.founder,
          onSelect: _select,
        ),
      if (annual != null)
        _OptionCard(
          product: PremiumProduct.annual,
          title: 'Annual',
          price: annual.priceString,
          priceNote: 'per year',
          tag: saving != null && saving >= 5 ? 'Best subscription value' : null,
          detail: [
            if (saving != null && saving >= 5) 'Save about $saving% against monthly.',
            if (perMonth != null)
              'Equivalent to $perMonth a month; billed yearly.'
            else
              'Billed yearly.',
          ].join(' '),
          selected: _selected == PremiumProduct.annual,
          onSelect: _select,
        ),
      if (monthly != null)
        _OptionCard(
          product: PremiumProduct.monthly,
          title: 'Monthly',
          price: monthly.priceString,
          priceNote: 'per month',
          detail: 'Flexible access. Renews monthly until cancelled.',
          selected: _selected == PremiumProduct.monthly,
          onSelect: _select,
        ),
    ];
  }

  Widget _primaryButton(StoreOffers? offers, FounderStatus? founder, StoreOffer? founderOffer) {
    final selected = _selected;
    final offer = selected == null || offers == null ? null : offers[selected];
    final (label, subtext) = switch (_phase) {
      _Phase.purchasing => (
        'Confirming purchase',
        'Keep the app open while the store confirms your purchase.',
      ),
      _Phase.pending => (
        'Confirming purchase',
        'The store is still confirming this purchase. You can keep using the app; Premium unlocks when it does.',
      ),
      _ => switch (selected) {
        PremiumProduct.founder => (
          'Become a Founding Member',
          'One-time purchase of ${offer?.priceString ?? '…'}. No subscription.',
        ),
        PremiumProduct.annual => (
          'Start Annual Premium',
          '${offer?.priceString ?? '…'} per year. Renews yearly until cancelled.',
        ),
        PremiumProduct.monthly => (
          'Start Monthly Premium',
          '${offer?.priceString ?? '…'} per month. Renews monthly until cancelled.',
        ),
        null => ('Choose an option', ''),
      },
    };
    // A founder place is reserved against an account; ask for that first.
    final needsSignIn =
        selected == PremiumProduct.founder &&
        ref.watch(founderServiceProvider).needsAccount &&
        ref.watch(authUserProvider).valueOrNull == null;
    if (needsSignIn && _phase == _Phase.browsing && offer != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton(
            onPressed: () => showSignInSheet(context, ref),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
            child: const Text('Sign in to continue', style: TextStyle(fontSize: 16)),
          ),
          const SizedBox(height: 6),
          Text(
            'A Founding Member place is tied to your account, so this one needs a sign-in '
            'first — a subscription doesn\'t. Then: one-time purchase of ${offer.priceString}, '
            'no subscription.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      );
    }
    // Founding Member can't be sold on an unknown count (spec §4.2).
    final founderBlocked =
        selected == PremiumProduct.founder &&
        (founderOffer == null || founder == null || !founder.isFresh());
    final enabled = _phase == _Phase.browsing && offer != null && !founderBlocked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          onPressed: enabled ? _buy : null,
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
          child: _phase == _Phase.purchasing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(label, style: const TextStyle(fontSize: 16)),
        ),
        if (subtext.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            subtext,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
        if (founderBlocked && _phase == _Phase.browsing) ...[
          const SizedBox(height: 4),
          Text(
            'Availability couldn\'t be confirmed just now, so this can\'t be sold yet. '
            'Check again, or choose Annual or Monthly.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          TextButton(
            onPressed: () => ref.invalidate(founderStatusProvider),
            child: const Text('Check again'),
          ),
        ],
        if (_phase == _Phase.pending) ...[
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _refreshStatus, child: const Text('Refresh status')),
        ],
      ],
    );
  }

  void _select(PremiumProduct product) {
    if (_phase != _Phase.browsing) return;
    setState(() {
      _selected = product;
      _error = null;
    });
    final offer = ref
        .read(storeOffersProvider)
        .valueOrNull
        ?.offers
        .where((o) => o.product == product)
        .firstOrNull;
    PremiumAnalytics.instance.log('product_selected', {
      'product_id': product.storeId,
      'localized_price': offer?.priceString,
      'source': widget.source,
    });
  }

  Future<void> _buy() async {
    final product = _selected;
    if (product == null) return;
    final purchases = ref.read(purchasesServiceProvider);
    setState(() {
      _phase = _Phase.purchasing;
      _error = null;
    });
    String? reservation;
    if (product == PremiumProduct.founder) {
      // Near the end, re-check right before the store sheet (spec §1.4),
      // then hold a place for the minutes the sheet takes (spec §6.3).
      final founders = ref.read(founderServiceProvider);
      var founder = ref.read(founderStatusProvider).valueOrNull;
      if (founder == null || founder.remaining < FounderStatus.recheckBelow) {
        founder = await founders.status();
      }
      if (founder == null || founder.soldOut) {
        _soldOut();
        return;
      }
      try {
        reservation = await founders.reserve();
      } on FounderSoldOut {
        _soldOut();
        return;
      } on FounderReserveFailed catch (e) {
        if (!mounted) return;
        setState(() {
          _phase = _Phase.browsing;
          _error = e.message;
        });
        return;
      }
    }
    PremiumAnalytics.instance.log('purchase_started', {
      'product_id': product.storeId,
      'source': widget.source,
      'founder_reservation_id': ?reservation,
    });
    final PurchaseOutcome outcome;
    try {
      outcome = await purchases.purchase(product);
    } on StoreUnavailableException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.browsing;
        _error = e.message;
      });
      return;
    }
    if (!mounted) return;
    switch (outcome) {
      case PurchaseCompleted():
        PremiumAnalytics.instance.log('purchase_completed', {
          'product_id': product.storeId,
          'verified': true,
          'source': widget.source,
        });
        // The backend learns of it from the webhook; this closes the gap
        // for the AI quota so the first game after buying is a premium one.
        unawaited(EntitlementSync.instance.refresh());
        setState(() => _phase = _Phase.succeeded);
      case PurchaseCancelled():
        PremiumAnalytics.instance.log('purchase_cancelled', {
          'product_id': product.storeId,
          'source': widget.source,
        });
        unawaited(ref.read(premiumPromptsProvider).markPurchaseCancelled());
        // Back to browsing, quietly (spec §7).
        setState(() => _phase = _Phase.browsing);
      case PurchasePending():
        setState(() => _phase = _Phase.pending);
      case PurchaseFailed(:final message, :final code, :final actionable):
        PremiumAnalytics.instance.log('purchase_failed', {
          'product_id': product.storeId,
          'normalized_error_code': code,
          'source': widget.source,
        });
        setState(() {
          _phase = _Phase.browsing;
          _error = actionable ? message : 'The purchase didn\'t go through. Try again in a moment.';
        });
    }
  }

  void _soldOut() {
    if (!mounted) return;
    ref.invalidate(founderStatusProvider);
    setState(() {
      _founderGone = true;
      _phase = _Phase.browsing;
      _selected = PremiumProduct.annual;
      _error = null;
    });
  }

  Future<void> _refreshStatus() async {
    final status = await ref.read(purchasesServiceProvider).refresh();
    if (!mounted) return;
    if (status.isPremium) setState(() => _phase = _Phase.succeeded);
  }

  Future<void> _restore() async {
    setState(() {
      _restoring = true;
      _error = null;
    });
    PremiumAnalytics.instance.log('restore_started', {'source': widget.source});
    try {
      final status = await ref.read(purchasesServiceProvider).restore();
      PremiumAnalytics.instance.log('restore_completed', {
        'resulting_entitlement': status.access.name,
      });
      if (!mounted) return;
      if (status.isPremium) {
        unawaited(EntitlementSync.instance.refresh());
        setState(() => _phase = _Phase.succeeded);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No previous purchase found for this store account.')),
        );
      }
    } on StoreUnavailableException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  void _startPlaying() {
    final next = widget.next;
    context.pop();
    if (next != null) {
      context.push(next);
    } else if (!widget.source.startsWith('games')) {
      context.go('/games');
    }
  }

  void _logDismissed() {
    if (_phase == _Phase.succeeded) return;
    PremiumAnalytics.instance.log('paywall_dismissed', {
      'source': widget.source,
      'dwell_ms': DateTime.now().difference(_openedAt).inMilliseconds,
      'selected_product': _selected?.storeId,
    });
  }
}

class _Headline extends StatelessWidget {
  final String title;
  final String body;

  const _Headline({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(
          body,
          style: text.bodyLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// The Founding Member invitation (spec §4.2), above the options while
/// places remain.
class _FounderBanner extends StatelessWidget {
  final FounderStatus? status;
  final StoreOffer offer;

  const _FounderBanner({required this.status, required this.offer});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final s = status;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Become a Founding Member',
            style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            'Join the first ${s?.cap ?? 500} people supporting the app and unlock Premium with '
            'one purchase — no recurring subscription.',
          ),
          const SizedBox(height: 10),
          Text(
            '${offer.priceString} one time',
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            s != null && s.isFresh()
                ? '${s.remaining} of ${s.cap} Founding Member places remain'
                : 'Limited to ${s?.cap ?? 500} completed purchases',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _FounderEnded extends StatelessWidget {
  const _FounderEnded();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.workspace_premium_outlined, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Founding offer has ended',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  'All 500 places are taken — thank you, founders. Choose Annual or Monthly '
                  'Premium to continue.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  final PremiumProduct product;
  final String title;
  final String price;
  final String priceNote;
  final String? tag;
  final String detail;
  final bool selected;
  final ValueChanged<PremiumProduct> onSelect;

  const _OptionCard({
    required this.product,
    required this.title,
    required this.price,
    required this.priceNote,
    this.tag,
    required this.detail,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '$title, $price $priceNote. ${tag ?? ''} $detail',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: selected ? scheme.primary.withValues(alpha: 0.08) : scheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => onSelect(product),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      selected ? Icons.radio_button_checked : Icons.radio_button_off,
                      color: selected ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            Text(
                              title,
                              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            if (tag != null)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: scheme.secondaryContainer,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  tag!,
                                  style: text.labelSmall?.copyWith(
                                    color: scheme.onSecondaryContainer,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(detail, style: TextStyle(color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(price, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      Text(
                        priceNote,
                        style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The shape of an option while the store answers — no placeholder price.
class _SkeletonOption extends StatelessWidget {
  const _SkeletonOption();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget bar(double width) => Container(
      width: width,
      height: 12,
      decoration: BoxDecoration(
        color: scheme.outlineVariant.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
    );
    return Semantics(
      label: 'Loading prices',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(Icons.radio_button_off, color: scheme.outlineVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [bar(90), const SizedBox(height: 8), bar(200)],
                ),
              ),
              const SizedBox(width: 12),
              bar(48),
            ],
          ),
        ),
      ),
    );
  }
}

/// The renewal and lifetime terms, in the same size as everything else
/// (spec §7.1).
class _Disclosure extends StatelessWidget {
  final PremiumProduct? selected;
  final StoreOffers? offers;

  const _Disclosure({required this.selected, required this.offers});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final store = Theme.of(context).platform == TargetPlatform.iOS ? 'App Store' : 'Google Play';
    return Text(
      'Subscriptions are charged to your $store account and renew automatically until '
      'you cancel, at least 24 hours before the current period ends, in your $store '
      'subscription settings. Founding Member is a one-time purchase: "lifetime" means '
      'Premium access for as long as Word Wizard and its online service operate, tied to your '
      'store account and non-transferable. Premium covers the features listed above and '
      'their ordinary improvements.',
      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13, height: 1.4),
    );
  }
}

class _Links extends StatelessWidget {
  final bool restoring;
  final VoidCallback onRestore;

  const _Links({required this.restoring, required this.onRestore});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      children: [
        TextButton(
          onPressed: restoring ? null : onRestore,
          child: restoring
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Restore Purchases'),
        ),
        const Text('·'),
        TextButton(onPressed: () => context.push('/legal/terms'), child: const Text('Terms')),
        const Text('·'),
        TextButton(onPressed: () => context.push('/legal/privacy'), child: const Text('Privacy')),
      ],
    );
  }
}
