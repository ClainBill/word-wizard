import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:purchases_flutter/purchases_flutter.dart' as rc;

import '../domain/premium/premium.dart';
import 'purchases_service.dart';

/// [PurchasesService] over the RevenueCat SDK. Constructed once in `main`
/// after [rc.Purchases.configure]; see [RevenueCatPurchasesService.start].
class RevenueCatPurchasesService implements PurchasesService {
  final _controller = StreamController<PremiumStatus>.broadcast();
  PremiumStatus _status = PremiumStatus.free;

  RevenueCatPurchasesService._();

  /// Configures the SDK with the platform's public key and, when someone
  /// is already signed in, their user id — so purchases made now attach
  /// to the account rather than to an anonymous id that has to be
  /// aliased later.
  static Future<RevenueCatPurchasesService> start({required String apiKey, String? userId}) async {
    if (kDebugMode) await rc.Purchases.setLogLevel(rc.LogLevel.info);
    await rc.Purchases.configure(rc.PurchasesConfiguration(apiKey)..appUserID = userId);
    final service = RevenueCatPurchasesService._();
    rc.Purchases.addCustomerInfoUpdateListener(service._onCustomerInfo);
    try {
      service._onCustomerInfo(await rc.Purchases.getCustomerInfo());
    } catch (e) {
      // Offline at launch: the SDK serves its cache through the listener
      // once it has one; until then the standing is "free".
      debugPrint('revenuecat: initial customer info failed: $e');
    }
    return service;
  }

  void _onCustomerInfo(rc.CustomerInfo info) {
    _status = statusFrom(info);
    _controller.add(_status);
  }

  /// Pure: the SDK's customer info → the app's standing. The entitlement
  /// states of spec §2.2 come from the entitlement's flags.
  @visibleForTesting
  static PremiumStatus statusFrom(rc.CustomerInfo info, {DateTime? now}) {
    final entitlement = info.entitlements.all[premiumEntitlementId];
    final product = PremiumProduct.fromStoreId(entitlement?.productIdentifier);
    final verifiedAt = DateTime.tryParse(info.requestDate) ?? (now ?? DateTime.now());
    if (entitlement == null) {
      final everBought = info.allPurchasedProductIdentifiers.any(
        (id) => PremiumProduct.fromStoreId(id) != null,
      );
      return PremiumStatus(
        access: everBought ? PremiumAccess.expired : PremiumAccess.free,
        verifiedAt: verifiedAt,
      );
    }
    final billingIssue = entitlement.billingIssueDetectedAt != null;
    final PremiumAccess access;
    if (entitlement.isActive) {
      access = product == PremiumProduct.founder || entitlement.expirationDate == null
          ? PremiumAccess.lifetime
          : billingIssue
          ? PremiumAccess.gracePeriod
          : PremiumAccess.subscription;
    } else {
      access = billingIssue ? PremiumAccess.billingRetry : PremiumAccess.expired;
    }
    return PremiumStatus(
      access: access,
      product: product,
      expiresAt: DateTime.tryParse(entitlement.expirationDate ?? ''),
      willRenew: entitlement.willRenew,
      billingIssue: billingIssue,
      founder: product == PremiumProduct.founder && entitlement.isActive,
      verifiedAt: verifiedAt,
    );
  }

  @override
  bool get available => true;

  @override
  PremiumStatus get current => _status;

  @override
  Stream<PremiumStatus> get changes async* {
    yield _status;
    yield* _controller.stream;
  }

  Future<Map<PremiumProduct, rc.Package>> _packages() async {
    final rc.Offerings offerings;
    try {
      offerings = await rc.Purchases.getOfferings();
    } on PlatformException catch (e) {
      throw StoreUnavailableException(_describe(e));
    }
    final packages = <PremiumProduct, rc.Package>{};
    for (final package in offerings.current?.availablePackages ?? const <rc.Package>[]) {
      final product = PremiumProduct.fromStoreId(package.storeProduct.identifier);
      if (product != null) packages[product] = package;
    }
    if (packages.isEmpty) throw const StoreUnavailableException('No products are on sale yet.');
    return packages;
  }

  @override
  Future<StoreOffers> offers() async {
    final packages = await _packages();
    return StoreOffers([
      for (final entry in packages.entries)
        StoreOffer(
          product: entry.key,
          priceString: entry.value.storeProduct.priceString,
          price: entry.value.storeProduct.price,
          currencyCode: entry.value.storeProduct.currencyCode,
        ),
    ]);
  }

  @override
  Future<PurchaseOutcome> purchase(PremiumProduct product) async {
    final package = (await _packages())[product];
    if (package == null) {
      return const PurchaseFailed(
        'That option isn\'t on sale right now.',
        code: 'product_unavailable',
      );
    }
    try {
      final result = await rc.Purchases.purchase(rc.PurchaseParams.package(package));
      _onCustomerInfo(result.customerInfo);
      return PurchaseCompleted(_status);
    } on PlatformException catch (e) {
      final code = rc.PurchasesErrorHelper.getErrorCode(e);
      switch (code) {
        case rc.PurchasesErrorCode.purchaseCancelledError:
          return const PurchaseCancelled();
        case rc.PurchasesErrorCode.paymentPendingError:
          return const PurchasePending();
        case rc.PurchasesErrorCode.productAlreadyPurchasedError:
          // Already owned: sync and treat as done rather than sell twice.
          return PurchaseCompleted(await restore());
        case rc.PurchasesErrorCode.networkError:
        case rc.PurchasesErrorCode.offlineConnectionError:
          return PurchaseFailed(
            'No connection. Check your network and try again.',
            code: code.name,
          );
        case rc.PurchasesErrorCode.purchaseNotAllowedError:
          return PurchaseFailed(
            'Purchases aren\'t allowed on this device (parental controls or store settings).',
            code: code.name,
          );
        case rc.PurchasesErrorCode.storeProblemError:
          return PurchaseFailed(
            'The store had a problem completing the purchase. Try again in a moment.',
            code: code.name,
          );
        default:
          return PurchaseFailed(_describe(e), code: code.name, actionable: false);
      }
    }
  }

  @override
  Future<PremiumStatus> restore() async {
    try {
      _onCustomerInfo(await rc.Purchases.restorePurchases());
      return _status;
    } on PlatformException catch (e) {
      throw StoreUnavailableException(_describe(e));
    }
  }

  @override
  Future<PremiumStatus> refresh() async {
    try {
      _onCustomerInfo(await rc.Purchases.getCustomerInfo());
    } catch (e) {
      debugPrint('revenuecat: refresh failed: $e');
    }
    return _status;
  }

  @override
  Future<void> logIn(String userId) async {
    try {
      final result = await rc.Purchases.logIn(userId);
      _onCustomerInfo(result.customerInfo);
    } catch (e) {
      debugPrint('revenuecat: logIn failed: $e');
    }
  }

  @override
  Future<void> logOut() async {
    try {
      _onCustomerInfo(await rc.Purchases.logOut());
    } catch (e) {
      // logOutWithAnonymousUserError: nothing was linked. Fine.
      debugPrint('revenuecat: logOut: $e');
    }
  }

  @override
  Future<Uri?> managementUrl() async {
    try {
      final url = (await rc.Purchases.getCustomerInfo()).managementURL;
      return url == null ? null : Uri.tryParse(url);
    } catch (_) {
      return null;
    }
  }

  static String _describe(PlatformException e) =>
      e.message?.trim().isNotEmpty == true ? e.message!.trim() : 'The store returned an error.';
}
