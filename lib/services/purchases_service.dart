import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/premium/premium.dart';

/// How a purchase attempt ended, as the paywall needs to know (spec §7).
sealed class PurchaseOutcome {
  const PurchaseOutcome();
}

/// The store confirmed it; [status] is the new standing.
class PurchaseCompleted extends PurchaseOutcome {
  final PremiumStatus status;
  const PurchaseCompleted(this.status);
}

/// The user backed out of the store sheet. Not an error.
class PurchaseCancelled extends PurchaseOutcome {
  const PurchaseCancelled();
}

/// The store accepted it but hasn't settled it yet (parental approval,
/// a delayed payment method). Acknowledge and keep checking.
class PurchasePending extends PurchaseOutcome {
  const PurchasePending();
}

/// Something went wrong; [message] is safe to show when [actionable].
class PurchaseFailed extends PurchaseOutcome {
  final String message;
  final String code;
  final bool actionable;
  const PurchaseFailed(this.message, {required this.code, this.actionable = true});
}

/// The store can't be reached or has no products for us: the paywall
/// shows its "temporarily unavailable" state and no guessed prices.
class StoreUnavailableException implements Exception {
  final String message;
  const StoreUnavailableException([this.message = 'The store is unavailable right now.']);
  @override
  String toString() => message;
}

/// The app's view of the store: what's for sale, what this person has,
/// and the actions the paywall and Settings take. The one real
/// implementation wraps RevenueCat ([RevenueCatPurchasesService]); the
/// others stand in when there is no store (tests, a build with no key).
///
/// The store is the source of truth for transactions (spec §6.2); the
/// backend derives the account's entitlement from it through the webhook
/// and `entitlement-refresh`. [changes] therefore reflects what the store
/// SDK reports, which is what lets a purchase unlock without a restart.
abstract class PurchasesService {
  /// Whether a store is wired at all. False means every action throws
  /// [StoreUnavailableException] and Settings says so.
  bool get available;

  /// The last known standing, synchronously — for gates that can't wait.
  PremiumStatus get current;

  /// Every change, starting with [current].
  Stream<PremiumStatus> get changes;

  /// The live products. Throws [StoreUnavailableException].
  Future<StoreOffers> offers();

  Future<PurchaseOutcome> purchase(PremiumProduct product);

  /// Re-syncs purchases from the store account. Returns the standing after.
  Future<PremiumStatus> restore();

  /// Re-reads the standing from the store (foreground, sign-in, after a
  /// server notification). Cheap; the SDK caches.
  Future<PremiumStatus> refresh();

  /// Ties purchases to the app account so the backend can find them, and
  /// so premium follows the account across platforms (spec §6.4).
  Future<void> logIn(String userId);
  Future<void> logOut();

  /// Where the store manages the subscription, when the store says.
  Future<Uri?> managementUrl();
}

/// No store in this build. The paywall renders its unavailable state.
class NoPurchasesService implements PurchasesService {
  const NoPurchasesService();

  @override
  bool get available => false;
  @override
  PremiumStatus get current => PremiumStatus.free;
  @override
  Stream<PremiumStatus> get changes => Stream.value(PremiumStatus.free);
  @override
  Future<StoreOffers> offers() async => throw const StoreUnavailableException();
  @override
  Future<PurchaseOutcome> purchase(PremiumProduct product) async =>
      throw const StoreUnavailableException();
  @override
  Future<PremiumStatus> restore() async => throw const StoreUnavailableException();
  @override
  Future<PremiumStatus> refresh() async => PremiumStatus.free;
  @override
  Future<void> logIn(String userId) async {}
  @override
  Future<void> logOut() async {}
  @override
  Future<Uri?> managementUrl() async => null;
}

/// A store that exists only in memory: debug builds before the RevenueCat
/// keys exist, and tests. Prices are sample strings, clearly not the
/// store's; it never ships (`main` picks it only in debug with no key).
class FakePurchasesService implements PurchasesService {
  final _controller = StreamController<PremiumStatus>.broadcast();
  PremiumStatus _status;
  StoreOffers _offers;
  Duration latency;

  /// What the next [purchase] does; the paywall's states can be walked
  /// through by changing it.
  PurchaseOutcome Function(PremiumProduct)? nextOutcome;

  /// Recorded for tests.
  final List<PremiumProduct> purchases = [];
  final List<String> logins = [];

  FakePurchasesService({
    PremiumStatus status = PremiumStatus.free,
    StoreOffers? offers,
    this.latency = Duration.zero,
  }) : _status = status,
       _offers = offers ?? sampleOffers;

  static const sampleOffers = StoreOffers([
    StoreOffer(
      product: PremiumProduct.monthly,
      priceString: r'$4.99',
      price: 4.99,
      currencyCode: 'USD',
    ),
    StoreOffer(
      product: PremiumProduct.annual,
      priceString: r'$29.99',
      price: 29.99,
      currencyCode: 'USD',
    ),
    StoreOffer(
      product: PremiumProduct.founder,
      priceString: r'$34.99',
      price: 34.99,
      currencyCode: 'USD',
    ),
  ]);

  @override
  bool get available => true;

  @override
  PremiumStatus get current => _status;

  set status(PremiumStatus value) {
    _status = value;
    _controller.add(value);
  }

  set offersForSale(StoreOffers value) => _offers = value;

  @override
  Stream<PremiumStatus> get changes async* {
    yield _status;
    yield* _controller.stream;
  }

  @override
  Future<StoreOffers> offers() async {
    await Future<void>.delayed(latency);
    if (_offers.isEmpty) throw const StoreUnavailableException();
    return _offers;
  }

  @override
  Future<PurchaseOutcome> purchase(PremiumProduct product) async {
    await Future<void>.delayed(latency);
    purchases.add(product);
    final outcome =
        nextOutcome?.call(product) ??
        PurchaseCompleted(
          PremiumStatus(
            access: product.isSubscription ? PremiumAccess.subscription : PremiumAccess.lifetime,
            product: product,
            expiresAt: product.isSubscription
                ? DateTime.now().add(Duration(days: product == PremiumProduct.annual ? 365 : 30))
                : null,
            willRenew: product.isSubscription,
            founder: product == PremiumProduct.founder,
            verifiedAt: DateTime.now(),
          ),
        );
    if (outcome is PurchaseCompleted) status = outcome.status;
    return outcome;
  }

  @override
  Future<PremiumStatus> restore() async {
    await Future<void>.delayed(latency);
    return _status;
  }

  @override
  Future<PremiumStatus> refresh() async => _status;

  @override
  Future<void> logIn(String userId) async => logins.add(userId);

  @override
  Future<void> logOut() async {}

  @override
  Future<Uri?> managementUrl() async => null;

  @mustCallSuper
  void dispose() => _controller.close();
}
