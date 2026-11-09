class CartItem {
  final int productId;
  final String productName;
  final double unitPrice;
  int quantity;

  CartItem({
    required this.productId,
    required this.productName,
    required this.unitPrice,
    this.quantity = 1,
  });

  double get subtotal => unitPrice * quantity;

  Map<String, dynamic> toJson() => {
    'product_id': productId,
    'product_name': productName,
    'quantity': quantity,
    'unit_price': unitPrice,
  };

  factory CartItem.fromJson(Map<String, dynamic> json) => CartItem(
    productId: json['product_id'] ?? 0,
    productName: json['product_name'] ?? '',
    unitPrice: (json['unit_price'] as num?)?.toDouble() ?? 0.0,
    quantity: json['quantity'] ?? 1,
  );
}

class CustomerOrder {
  final int? id;
  final int queueNo;
  final String customerName;
  final String customerPhone;
  final String orderType; // 'pickup' or 'delivery'
  final String deliveryAddress;
  final String paymentMethod; // 'GCash' or 'Cash'
  String paymentStatus; // 'pending', 'confirmed', 'failed'
  String? paymentAccountId;
  String? paymentAccountName;
  String? paymentProvider;
  String status; // 'pending', 'accepted', 'preparing', 'ready_pickup', 'ready_delivery', 'out_for_delivery', 'completed', 'delivered', 'cancelled'
  final double totalAmount;
  final String notes;
  final String? createdAt;
  String? paymentReference;
  final List<CartItem> items;
  final bool isOfflinePending;

  CustomerOrder({
    this.id,
    required this.queueNo,
    required this.customerName,
    required this.customerPhone,
    required this.orderType,
    this.deliveryAddress = '',
    required this.paymentMethod,
    this.paymentStatus = 'pending',
    this.paymentAccountId,
    this.paymentAccountName,
    this.paymentProvider,
    this.status = 'pending',
    required this.totalAmount,
    this.notes = '',
    this.createdAt,
    this.paymentReference,
    required this.items,
    this.isOfflinePending = false,
  });

  bool get isCancelled => status.toLowerCase() == 'cancelled';
  bool get isCompleted => status == 'completed' || status == 'delivered' || isCancelled;
  bool get isReady => status == 'ready_pickup' || status == 'ready_delivery';
  bool get isOutForDelivery => status == 'out_for_delivery';
  bool get isPreparing => status == 'preparing';
  bool get isPaid => paymentStatus.trim().toLowerCase() == 'confirmed' || paymentStatus.trim().toLowerCase() == 'paid';
  bool get isOnlinePayment => paymentMethod.trim().toLowerCase() != 'cash' && paymentMethod.trim().isNotEmpty;
  bool get hasValidTicket => queueNo > 0;
  String get ticketDisplay => hasValidTicket ? 'Ticket #$queueNo' : 'Ticket: Pending';

  /// Formats [createdAt] in Philippine Time (Asia/Manila, UTC+8).
  String get formattedDate {
    final raw = (createdAt ?? '').trim();
    if (raw.isEmpty) return '';
    try {
      String s = raw.replaceAll(' ', 'T');
      final hasZone = s.endsWith('Z') ||
          s.endsWith('z') ||
          RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(s);
      if (!hasZone && RegExp(r'^\d{4}-\d{2}-\d{2}T').hasMatch(s)) {
        s = '${s}Z';
      }
      final dtUtc = DateTime.parse(s).toUtc();
      final ph = dtUtc.add(const Duration(hours: 8));
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      final m = months[ph.month - 1];
      final d = ph.day.toString().padLeft(2, '0');
      final y = ph.year;
      final h12 = ph.hour % 12 == 0 ? 12 : ph.hour % 12;
      final hStr = h12.toString().padLeft(2, '0');
      final minStr = ph.minute.toString().padLeft(2, '0');
      final ampm = ph.hour >= 12 ? 'PM' : 'AM';
      return '$m $d, $y • $hStr:$minStr $ampm';
    } catch (_) {
      return raw;
    }
  }

  factory CustomerOrder.fromJson(Map<String, dynamic> json) {
    var rawItems = json['items'] as List<dynamic>? ?? [];
    List<CartItem> parsedItems = [];
    for (var it in rawItems) {
      if (it is Map<String, dynamic>) {
        parsedItems.add(CartItem(
          productId: int.tryParse(it['product_id']?.toString() ?? '0') ?? 0,
          productName: it['product_name'] ?? it['name'] ?? 'Siomai Item',
          unitPrice: (it['unit_price'] as num?)?.toDouble() ?? 0.0,
          quantity: int.tryParse(it['quantity']?.toString() ?? '1') ?? 1,
        ));
      }
    }

    final int? parsedId = int.tryParse(json['id']?.toString() ?? json['order_id']?.toString() ?? '');
    final int parsedQueue = int.tryParse(json['queue_no']?.toString() ?? json['queue_number']?.toString() ?? '') ?? 0;

    final rawPayStatus = (json['payment_status'] ?? 'pending').toString().trim().toLowerCase();
    final normalizedPayStatus = (rawPayStatus == 'confirmed' || rawPayStatus == 'paid') ? 'confirmed' : 'pending';

    return CustomerOrder(
      id: parsedId,
      queueNo: parsedQueue,
      customerName: json['customer_name'] ?? 'Customer',
      customerPhone: json['customer_phone'] ?? '',
      orderType: json['order_type'] ?? 'pickup',
      deliveryAddress: json['delivery_address'] ?? '',
      paymentMethod: json['payment_method'] ?? 'GCash',
      paymentStatus: normalizedPayStatus,
      paymentAccountId: json['payment_account_id']?.toString(),
      paymentAccountName: json['payment_account_name']?.toString(),
      paymentProvider: json['payment_provider']?.toString(),
      status: json['status'] ?? 'pending',
      totalAmount: (json['total_amount'] as num?)?.toDouble() ?? 0.0,
      notes: json['notes'] ?? '',
      createdAt: json['created_at'],
      paymentReference: json['payment_reference'],
      items: parsedItems,
      isOfflinePending: json['is_offline_pending'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'queue_no': queueNo,
      'customer_name': customerName,
      'customer_phone': customerPhone,
      'order_type': orderType,
      'delivery_address': deliveryAddress,
      'payment_method': paymentMethod,
      'payment_status': paymentStatus,
      'payment_account_id': paymentAccountId,
      'payment_account_name': paymentAccountName,
      'payment_provider': paymentProvider,
      'status': status,
      'total_amount': totalAmount,
      'notes': notes,
      'created_at': createdAt,
      'payment_reference': paymentReference,
      'items': items.map((i) => i.toJson()).toList(),
      'is_offline_pending': isOfflinePending,
    };
  }
}
