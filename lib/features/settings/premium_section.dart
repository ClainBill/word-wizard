import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/environment.dart';
import '../../app/providers.dart';
import '../../domain/premium/premium.dart';
import '../../services/entitlement_sync.dart';
import '../../services/purchases_service.dart';
import '../premium/paywall_screen.dart';

/// Settings → Premium: what the person has, how to get it, how to restore
/// or manage it (spec §6.5 wants Restore in Settings too).
class PremiumSection extends ConsumerStatefulWidget {
  const PremiumSection({super.key});

  @override
  ConsumerState<PremiumSection> createState() => _PremiumSectionState();
}

class _PremiumSectionState extends ConsumerState<PremiumSection> {
  bool _restoring = false;

  @override
  Widget build(BuildContext context) {
    final purchases = ref.watch(purchasesServiceProvider);
    final status = ref.watch(premiumStatusProvider).valueOrNull ?? purchases.current;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Premium', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
        ListTile(
          leading: Icon(
            status.founder ? Icons.workspace_premium : Icons.workspace_premium_outlined,
            color: status.isPremium ? scheme.primary : null,
          ),
          title: Text(status.label),
          subtitle: Text(_describe(status, purchases)),
          trailing: status.isPremium ? null : const Icon(Icons.chevron_right),
          enabled: purchases.available,
          onTap: status.isPremium ? null : () => showPaywall(context, source: 'settings'),
        ),
        if (status.isPremium && status.product?.isSubscription == true)
          ListTile(
            leading: const Icon(Icons.manage_accounts_outlined),
            title: const Text('Manage subscription'),
            subtitle: const Text('Change or cancel it in your store account.'),
            onTap: () => _manage(purchases),
          ),
        if (purchases.available && !status.isPremium)
          ListTile(
            leading: const Icon(Icons.restore),
            title: const Text('Restore purchases'),
            subtitle: const Text(
              'Bought Premium before, or on another device with this store account?',
            ),
            trailing: _restoring
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _restoring ? null : () => _restore(purchases),
          ),
        if (AppEnvironment.devTools && purchases is FakePurchasesService) _DebugTools(purchases: purchases),
      ],
    );
  }

  static String _describe(PremiumStatus status, PurchasesService purchases) {
    if (!purchases.available) return 'Purchasing isn\'t available in this build.';
    switch (status.access) {
      case PremiumAccess.free:
        return 'Daily crosswords with the AI editor, Word Hunt, recall games in study, '
            'shared puzzles and no ads.';
      case PremiumAccess.lifetime:
        return status.founder
            ? 'One of the first 500. Premium for as long as Word Wizard runs.'
            : 'Premium for as long as Word Wizard runs.';
      case PremiumAccess.subscription:
        final until = status.expiresAt;
        final when = until == null ? '' : ' on ${until.day}/${until.month}/${until.year}';
        return status.willRenew ? 'Renews$when.' : 'Cancelled — Premium ends$when.';
      case PremiumAccess.gracePeriod:
        return 'Your last payment failed. Update your payment method in the store to keep Premium.';
      case PremiumAccess.billingRetry:
        return 'Premium is paused until the store can charge your payment method.';
      case PremiumAccess.expired:
        return 'Your games and progress are kept. Subscribe again to pick up where you left off.';
    }
  }

  Future<void> _restore(PurchasesService purchases) async {
    setState(() => _restoring = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final status = await purchases.restore();
      if (status.isPremium) {
        await EntitlementSync.instance.refresh();
        messenger.showSnackBar(SnackBar(content: Text('Restored: ${status.label}.')));
      } else {
        messenger.showSnackBar(
          const SnackBar(content: Text('No previous purchase found for this store account.')),
        );
      }
    } on StoreUnavailableException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  Future<void> _manage(PurchasesService purchases) async {
    final messenger = ScaffoldMessenger.of(context);
    final fallback = Theme.of(context).platform == TargetPlatform.iOS
        ? Uri.parse('https://apps.apple.com/account/subscriptions')
        : Uri.parse('https://play.google.com/store/account/subscriptions');
    final url = await purchases.managementUrl() ?? fallback;
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Open your store\'s subscription settings to manage it.')),
      );
    }
  }
}

/// Dev-tools builds with the in-memory store: flip premium on and off and see
/// the prompt again, so every state of the paywall and the gate can be
/// looked at without buying anything.
class _DebugTools extends ConsumerWidget {
  final FakePurchasesService purchases;

  const _DebugTools({required this.purchases});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final premium = purchases.current.isPremium;
    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.bug_report_outlined),
          title: const Text('Debug: fake Premium'),
          subtitle: const Text('In-memory store — no RevenueCat key in this build.'),
          value: premium,
          onChanged: (on) => purchases.status = on
              ? PremiumStatus(
                  access: PremiumAccess.subscription,
                  product: PremiumProduct.annual,
                  expiresAt: DateTime.now().add(const Duration(days: 365)),
                  willRenew: true,
                  verifiedAt: DateTime.now(),
                )
              : PremiumStatus.free,
        ),
        ListTile(
          leading: const Icon(Icons.bug_report_outlined),
          title: const Text('Debug: reset prompt cooldown'),
          onTap: () async {
            await ref.read(premiumPromptsProvider).reset();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Prompt state cleared (sessions kept).')),
              );
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.bug_report_outlined),
          title: const Text('Debug: open paywall'),
          onTap: () => context.push('/premium?source=debug'),
        ),
      ],
    );
  }
}
