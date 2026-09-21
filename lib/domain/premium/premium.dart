/// What Premium is, what it costs and who has it — the model behind the
/// paywall, the Games gate and Settings. Pure Dart; the store SDK and the
/// backend are behind [PurchasesService] and [FounderService].
///
/// Source: docs/Premium Offers Implementation Specification (19 Sept 2026).
library;

/// The RevenueCat entitlement every product unlocks (spec §6.1). The
/// backend's `_shared/revenuecat.ts` names the same one.
const String premiumEntitlementId = 'premium_active';

/// The three things for sale. Store identifiers are immutable once
/// released (spec §6.1); a changed price or term is a new `_v2` product.
enum PremiumProduct {
  monthly('premium_monthly_v1'),
  annual('premium_annual_v1'),
  founder('premium_founder_lifetime_v1');

  final String storeId;
  const PremiumProduct(this.storeId);

  bool get isSubscription => this != founder;

  static PremiumProduct? fromStoreId(String? id) {
    if (id == null) return null;
    for (final p in values) {
      // Store ids sometimes come back suffixed (`:base-plan` on Play).
      if (id == p.storeId || id.startsWith('${p.storeId}:')) return p;
    }
    return null;
  }
}

/// The entitlement states of spec §2.2, as the app needs to tell them
/// apart. Everything from [subscription] to [gracePeriod] is full access.
enum PremiumAccess {
  free,
  subscription,
  lifetime,

  /// Billing failed but the store is still granting access.
  gracePeriod,

  /// Billing failed and the store has stopped granting access; the app
  /// follows the store here — read-only, back to the paywall.
  billingRetry,

  /// Was premium, isn't now: expired, refunded or revoked. Data is kept.
  expired;

  bool get isPremium => this == subscription || this == lifetime || this == gracePeriod;
}

/// One user's premium standing right now.
class PremiumStatus {
  final PremiumAccess access;
  final PremiumProduct? product;
  final DateTime? expiresAt;
  final bool willRenew;
  final bool billingIssue;

  /// Set for a Founding Member — the permanent cohort marker (spec §6.1).
  final bool founder;

  /// When this was last confirmed with the store, null if never.
  final DateTime? verifiedAt;

  const PremiumStatus({
    required this.access,
    this.product,
    this.expiresAt,
    this.willRenew = false,
    this.billingIssue = false,
    this.founder = false,
    this.verifiedAt,
  });

  static const free = PremiumStatus(access: PremiumAccess.free);

  bool get isPremium => access.isPremium;

  /// A one-line description for Settings.
  String get label => switch (access) {
    PremiumAccess.free => 'Free',
    PremiumAccess.lifetime => founder ? 'Founding Member' : 'Premium, lifetime',
    PremiumAccess.subscription => switch (product) {
      PremiumProduct.annual => 'Premium, annual',
      PremiumProduct.monthly => 'Premium, monthly',
      _ => 'Premium',
    },
    PremiumAccess.gracePeriod => 'Premium — payment problem',
    PremiumAccess.billingRetry => 'Premium paused — payment problem',
    PremiumAccess.expired => 'Premium ended',
  };

  Map<String, Object?> toJson() => {
    'access': access.name,
    'product': product?.storeId,
    'expires_at': expiresAt?.toIso8601String(),
    'will_renew': willRenew,
    'billing_issue': billingIssue,
    'founder': founder,
    'verified_at': verifiedAt?.toIso8601String(),
  };

  static PremiumStatus fromJson(Map<String, Object?> json) => PremiumStatus(
    access: PremiumAccess.values.asNameMap()[json['access']] ?? PremiumAccess.free,
    product: PremiumProduct.fromStoreId(json['product'] as String?),
    expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? ''),
    willRenew: json['will_renew'] == true,
    billingIssue: json['billing_issue'] == true,
    founder: json['founder'] == true,
    verifiedAt: DateTime.tryParse(json['verified_at'] as String? ?? ''),
  );
}

/// One product as the store describes it. Every price string on screen
/// comes from here — never from a constant (spec §1.1).
class StoreOffer {
  final PremiumProduct product;

  /// Localised, formatted by the store: "$4.99", "£29.99", "CA$34.99".
  final String priceString;

  /// The numeric price in [currencyCode], for the annual-saving arithmetic.
  final double price;
  final String currencyCode;

  const StoreOffer({
    required this.product,
    required this.priceString,
    required this.price,
    required this.currencyCode,
  });
}

/// What the store returned for the three products. A missing product is
/// simply absent, and the paywall shows what it has.
class StoreOffers {
  final List<StoreOffer> offers;

  const StoreOffers(this.offers);

  static const empty = StoreOffers([]);

  StoreOffer? operator [](PremiumProduct product) {
    for (final o in offers) {
      if (o.product == product) return o;
    }
    return null;
  }

  bool get isEmpty => offers.isEmpty;

  /// How much cheaper a year is than twelve months, as a whole percentage
  /// — only from the live prices, and only when both are in the same
  /// currency and the year really is cheaper (spec §1.2). Null otherwise.
  int? get annualSavingPercent {
    final monthly = this[PremiumProduct.monthly];
    final annual = this[PremiumProduct.annual];
    if (monthly == null || annual == null) return null;
    if (monthly.currencyCode != annual.currencyCode) return null;
    final year = monthly.price * 12;
    if (year <= 0 || annual.price >= year) return null;
    return ((1 - annual.price / year) * 100).round();
  }

  /// The annual price spread over twelve months, in the store's currency,
  /// formatted the way the store formats the annual price. Null when it
  /// can't be derived faithfully.
  String? get annualPerMonth {
    final annual = this[PremiumProduct.annual];
    if (annual == null || annual.price <= 0) return null;
    return reformatPrice(annual.priceString, annual.price, annual.price / 12);
  }
}

/// Writes [amount] in the same style as [sample], which the store formatted
/// for [sampleAmount]: same currency symbol, same separators, same number
/// of decimals. Null when the sample can't be parsed — the caller then
/// shows nothing rather than a guessed format.
String? reformatPrice(String sample, double sampleAmount, double amount) {
  final match = RegExp(r'(\d[\d.,\s ]*\d|\d)').firstMatch(sample);
  if (match == null) return null;
  final digits = match.group(0)!;
  // Decimal separator: the last '.' or ',' followed by exactly two digits.
  final decimal = RegExp(r'([.,])(\d{2})$').firstMatch(digits);
  final decimals = decimal == null ? 0 : 2;
  final decimalSeparator = decimal?.group(1) ?? '.';
  final groupSeparator = decimal == null
      ? (digits.contains(',')
            ? ','
            : digits.contains('.')
            ? '.'
            : null)
      : (decimalSeparator == '.'
            ? (digits.contains(',') ? ',' : null)
            : (digits.contains('.') ? '.' : null));
  final fixed = amount.toStringAsFixed(decimals);
  var whole = fixed.split('.').first;
  final fraction = decimals == 0 ? '' : fixed.split('.').last;
  if (groupSeparator != null) {
    final buffer = StringBuffer();
    for (var i = 0; i < whole.length; i++) {
      if (i > 0 && (whole.length - i) % 3 == 0) buffer.write(groupSeparator);
      buffer.write(whole[i]);
    }
    whole = buffer.toString();
  }
  final number = decimals == 0 ? whole : '$whole$decimalSeparator$fraction';
  return sample.replaceRange(match.start, match.end, number);
}

/// The Founding Member allocation as the backend last reported it (spec
/// §1.4, §6.3). The exact count is shown only while [isFresh].
class FounderStatus {
  final bool active;
  final int cap;
  final int sold;
  final int remaining;
  final int version;
  final DateTime lastUpdatedAt;
  final DateTime fetchedAt;

  const FounderStatus({
    required this.active,
    required this.cap,
    required this.sold,
    required this.remaining,
    required this.version,
    required this.lastUpdatedAt,
    required this.fetchedAt,
  });

  static const maxAge = Duration(minutes: 10);

  /// Recent enough to be shown as a live number.
  bool isFresh([DateTime? now]) => (now ?? DateTime.now()).difference(fetchedAt) < maxAge;

  bool get soldOut => !active || remaining <= 0;

  /// Below this, availability is re-checked right before the store sheet
  /// opens (spec §1.4).
  static const recheckBelow = 25;

  static FounderStatus fromJson(Map<String, Object?> json, {DateTime? fetchedAt}) {
    int n(String k) => (json[k] as num?)?.toInt() ?? 0;
    return FounderStatus(
      active: json['active'] == true,
      cap: n('cap'),
      sold: n('sold'),
      remaining: n('remaining'),
      version: n('version'),
      lastUpdatedAt: DateTime.tryParse(json['last_updated_at'] as String? ?? '') ?? DateTime.now(),
      fetchedAt: fetchedAt ?? DateTime.now(),
    );
  }

  /// The privacy-preserving band analytics gets instead of the number.
  String get remainingBucket => remaining <= 0
      ? '0'
      : remaining < 25
      ? '1-24'
      : remaining < 100
      ? '25-99'
      : remaining < 250
      ? '100-249'
      : '250+';
}

/// The benefits, in the order the paywall lists them (spec §4.1, plus the
/// recall games added after).
const List<String> premiumBenefits = [
  '3 personalized crosswords every day, with the AI editor',
  'A daily Word Hunt built from your words',
  'Recall games in every study session',
  'Shared puzzles with friends',
  'No ads',
];

/// What the free sample crossword lacks, in a sentence — shown wherever
/// the sample is offered so nobody judges Premium by it.
const String sampleWithoutEditorNote =
    'The sample skips the AI editor. Premium puzzles get an editorial pass that rewrites '
    'clunky clues in plain English and swaps out unfair answers; the sample\'s clues come '
    'straight from the dictionary, so a few will read stiffly.';
