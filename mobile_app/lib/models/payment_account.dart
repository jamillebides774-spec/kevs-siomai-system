class PaymentAccount {
  final int? id;
  final String accountId;
  final String accountName;
  final String provider;
  final String accountHolderName;
  final String mobileNumber;
  final String qrImageUrl;
  final String limitType; // 'count' or 'amount'
  final double transactionLimit;
  final int confirmedCount;
  final double confirmedAmount;
  final double confirmedUsage;
  final double remainingCapacity;
  final bool limitReached;
  final bool isActive;
  final bool isAvailable;
  final String statusLabel;
  final int priority;

  PaymentAccount({
    this.id,
    required this.accountId,
    required this.accountName,
    required this.provider,
    required this.accountHolderName,
    required this.mobileNumber,
    required this.qrImageUrl,
    this.limitType = 'count',
    this.transactionLimit = 5.0,
    this.confirmedCount = 0,
    this.confirmedAmount = 0.0,
    this.confirmedUsage = 0.0,
    this.remainingCapacity = 5.0,
    this.limitReached = false,
    this.isActive = true,
    this.isAvailable = true,
    this.statusLabel = 'Available',
    int? priority,
    int? priorityOrder,
  }) : priority = priorityOrder ?? priority ?? 1;

  int get priorityOrder => priority;

  String get displaySummary => '$accountName ($accountHolderName)';

  String get remainingCapacityLabel {
    if (limitType.toLowerCase() == 'amount') {
      return '₱${remainingCapacity.toStringAsFixed(2)} left';
    }
    return '${remainingCapacity.round()} txns left';
  }

  String get remainingLabel => remainingCapacityLabel;

  factory PaymentAccount.fromJson(Map<String, dynamic> json) {
    final lType = (json['limit_type'] ?? 'count').toString().toLowerCase();
    final tLimit = (json['transaction_limit'] as num?)?.toDouble() ?? 5.0;
    final cCount = int.tryParse(json['confirmed_count']?.toString() ?? '0') ?? 0;
    final cAmt = (json['confirmed_amount'] as num?)?.toDouble() ?? 0.0;
    final cUsage = (json['confirmed_usage'] as num?)?.toDouble() ??
        (lType == 'amount' ? cAmt : cCount.toDouble());
    final remCap = (json['remaining_capacity'] as num?)?.toDouble() ??
        ((tLimit - cUsage) > 0 ? (tLimit - cUsage) : 0.0);
    final limReached = json['limit_reached'] == true || (tLimit > 0 && cUsage >= tLimit);
    final active = json['is_active'] != false;
    final avail = json['is_available'] != null ? (json['is_available'] == true) : (active && !limReached);

    return PaymentAccount(
      id: int.tryParse(json['id']?.toString() ?? ''),
      accountId: (json['account_id'] ?? 'acct_gcash_1').toString(),
      accountName: (json['account_name'] ?? 'GCash Primary').toString(),
      provider: (json['provider'] ?? 'GCash / InstaPay').toString(),
      accountHolderName: (json['account_holder_name'] ?? 'JA****E B.').toString(),
      mobileNumber: (json['mobile_number'] ?? '+63 993 104 ••••').toString(),
      qrImageUrl: (json['qr_image_url'] ?? '/images/gcash_instapay_qr_1.jpg').toString(),
      limitType: lType,
      transactionLimit: tLimit,
      confirmedCount: cCount,
      confirmedAmount: cAmt,
      confirmedUsage: cUsage,
      remainingCapacity: remCap,
      limitReached: limReached,
      isActive: active,
      isAvailable: avail,
      statusLabel: (json['status_label'] ?? (!active ? 'Inactive' : (limReached ? 'Limit Reached' : 'Available'))).toString(),
      priority: int.tryParse((json['priority_order'] ?? json['priority'] ?? '1').toString()) ?? 1,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'account_id': accountId,
    'account_name': accountName,
    'provider': provider,
    'account_holder_name': accountHolderName,
    'mobile_number': mobileNumber,
    'qr_image_url': qrImageUrl,
    'limit_type': limitType,
    'transaction_limit': transactionLimit,
    'confirmed_count': confirmedCount,
    'confirmed_amount': confirmedAmount,
    'confirmed_usage': confirmedUsage,
    'remaining_capacity': remainingCapacity,
    'limit_reached': limitReached,
    'is_active': isActive,
    'is_available': isAvailable,
    'status_label': statusLabel,
    'priority': priority,
    'priority_order': priority,
  };
}

