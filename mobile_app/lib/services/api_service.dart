import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/product.dart';
import '../models/order.dart';
import '../models/payment_account.dart';
import '../models/queue_status.dart';
import 'offline_service.dart';

class ApiResult<T> {
  final bool isSuccess;
  final T? data;
  final String? errorMessage;
  final bool isOffline;

  ApiResult.success(this.data)
      : isSuccess = true,
        errorMessage = null,
        isOffline = false;

  ApiResult.failure(this.errorMessage, {this.isOffline = false})
      : isSuccess = false,
        data = null;
}

class ApiService {
  static const Duration _timeout = Duration(seconds: 6);

  // ── Firestore Direct Fallback ──
  static Future<List<Product>> _fetchFromFirestoreDirect() async {
    try {
      final url = 'https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/products';
      final response = await http.get(Uri.parse(url)).timeout(_timeout);
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final List<dynamic> docs = data['documents'] ?? [];
        final List<Product> list = [];
        for (final doc in docs) {
          final f = doc['fields'] as Map<String, dynamic>?;
          if (f != null) {
            final priceVal = f['price']?['doubleValue'] ?? f['price']?['integerValue'] ?? 0.0;
            final rawStatus = (f['status']?['stringValue'] ?? '').toString().trim();
            final statusLower = rawStatus.toLowerCase();
            final bool boolActive = f['is_active']?['booleanValue'] ?? true;
            final bool effectiveActive = boolActive && statusLower != 'inactive' && statusLower != 'disabled';
            list.add(Product(
              id: int.tryParse(f['id']?['integerValue']?.toString() ?? '0') ?? 0,
              name: f['name']?['stringValue'] ?? '',
              category: f['category']?['stringValue'] ?? 'Siomai',
              price: (priceVal as num).toDouble(),
              stock: int.tryParse(f['stock']?['integerValue']?.toString() ?? '50') ?? 50,
              maxStock: int.tryParse(f['max_stock']?['integerValue']?.toString() ?? '100') ?? 100,
              unit: f['unit']?['stringValue'] ?? 'pcs',
              description: f['description']?['stringValue'] ?? '',
              imageUrl: f['image_url']?['stringValue'] ?? '',
              isActive: effectiveActive,
              status: effectiveActive ? 'Active' : 'Inactive',
            ));
          }
        }
        if (list.isNotEmpty) {
          await OfflineService.cacheProducts(list);
          return list;
        }
      }
    } catch (_) {}
    return [];
  }

  // ── Fetch Products ──
  static Future<ApiResult<List<Product>>> fetchProducts() async {
    final baseUrl = await OfflineService.getBaseUrl();
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/products?all=true'),
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final List<dynamic> list = data['products'] ?? [];
        final products = list.map((json) => Product.fromJson(json)).toList();
        await OfflineService.cacheProducts(products);
        return ApiResult.success(products);
      } else {
        final direct = await _fetchFromFirestoreDirect();
        if (direct.isNotEmpty) return ApiResult.success(direct);
        return ApiResult.failure('Server error: ${response.statusCode}');
      }
    } catch (e) {
      // 1. Try Google Cloud Firestore directly over HTTPS!
      final direct = await _fetchFromFirestoreDirect();
      if (direct.isNotEmpty) {
        return ApiResult.success(direct);
      }
      // 2. If network fails, attempt to read from offline cache!
      final cached = await OfflineService.getCachedProducts();
      if (cached.isNotEmpty) {
        return ApiResult.success(cached);
      }
      return ApiResult.failure(
        'Unable to connect to backend ($baseUrl). Please check server connection.',
        isOffline: true,
      );
    }
  }

  // ── Firestore Direct Order Submission ──
  static Future<bool> _postOrderToFirestoreDirect(
    Map<String, dynamic> payload,
    double total,
    List<CartItem> items,
  ) async {
    try {
      final docId = 'order_${DateTime.now().millisecondsSinceEpoch}';
      final url = 'https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/orders?documentId=$docId';

      final itemsArray = items.map((it) => {
        'mapValue': {
          'fields': {
            'product_id': {'integerValue': '${it.productId}'},
            'quantity': {'integerValue': '${it.quantity}'},
            'unit_price': {'doubleValue': it.unitPrice},
            'subtotal': {'doubleValue': it.subtotal},
            'name': {'stringValue': it.productName},
          }
        }
      }).toList();

      final body = {
        'fields': {
          'customer_name': {'stringValue': payload['customer_name'] ?? 'Online Customer'},
          'customer_phone': {'stringValue': payload['customer_phone'] ?? ''},
          'order_type': {'stringValue': payload['order_type'] ?? 'pickup'},
          'delivery_address': {'stringValue': payload['delivery_address'] ?? ''},
          'payment_method': {'stringValue': payload['payment_method'] ?? 'GCash'},
          'payment_account_id': {'stringValue': payload['payment_account_id'] ?? ''},
          'payment_account_name': {'stringValue': payload['payment_account_name'] ?? ''},
          'payment_provider': {'stringValue': payload['payment_provider'] ?? ''},
          'status': {'stringValue': 'pending'},
          'payment_status': {'stringValue': 'pending'},
          'total_amount': {'doubleValue': total},
          'notes': {'stringValue': payload['notes'] ?? ''},
          'synced_to_pos': {'booleanValue': false},
          'created_at': {'stringValue': DateTime.now().toUtc().toIso8601String()},
          'items': {'arrayValue': {'values': itemsArray}},
        }
      };

      final response = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ).timeout(_timeout);

      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── Place Order ──
  static Future<ApiResult<CustomerOrder>> placeOrder({
    required String customerName,
    required String customerPhone,
    required String orderType,
    required String deliveryAddress,
    required String paymentMethod,
    required List<CartItem> items,
    required String notes,
    String? paymentAccountId,
    String? paymentAccountName,
    String? paymentProvider,
  }) async {
    final baseUrl = await OfflineService.getBaseUrl();
    final total = items.fold<double>(0.0, (sum, it) => sum + it.subtotal);

    final payload = {
      'customer_name': customerName,
      'customer_phone': customerPhone,
      'order_type': orderType,
      'delivery_address': orderType == 'delivery' ? deliveryAddress : '',
      'payment_method': paymentMethod,
      'payment_account_id': paymentAccountId,
      'payment_account_name': paymentAccountName,
      'payment_provider': paymentProvider,
      'notes': notes,
      'items': items.map((i) => {
        'product_id': i.productId,
        'quantity': i.quantity,
      }).toList(),
    };

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/orders'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      ).timeout(_timeout);

      if (response.statusCode == 201 || response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final orderJson = data['order'] ?? {};
        final order = CustomerOrder.fromJson(orderJson);
        await OfflineService.saveActiveOrder(order);
        return ApiResult.success(order);
      } else {
        try {
          final Map<String, dynamic> data = jsonDecode(response.body);
          return ApiResult.failure(data['error'] ?? 'Failed to submit order');
        } catch (_) {
          return ApiResult.failure('Failed to submit order: ${response.body}');
        }
      }
    } catch (e) {
      // 1. If backend server is unreachable (cloud customer), submit directly to Cloud Firestore!
      final fsSent = await _postOrderToFirestoreDirect(payload, total, items);
      if (fsSent) {
        final cloudOrder = CustomerOrder(
          queueNo: 0,
          customerName: customerName,
          customerPhone: customerPhone,
          orderType: orderType,
          deliveryAddress: deliveryAddress,
          paymentMethod: paymentMethod,
          paymentAccountId: paymentAccountId,
          paymentAccountName: paymentAccountName,
          paymentProvider: paymentProvider,
          totalAmount: total,
          notes: notes,
          createdAt: DateTime.now().toUtc().toIso8601String(),
          items: items,
          isOfflinePending: false,
        );
        await OfflineService.saveActiveOrder(cloudOrder);
        return ApiResult.success(cloudOrder);
      }

      // 2. If completely offline, save locally in Offline Pending Queue
      final offlineOrder = CustomerOrder(
        queueNo: 0,
        customerName: customerName,
        customerPhone: customerPhone,
        orderType: orderType,
        deliveryAddress: deliveryAddress,
        paymentMethod: paymentMethod,
        paymentAccountId: paymentAccountId,
        paymentAccountName: paymentAccountName,
        paymentProvider: paymentProvider,
        totalAmount: total,
        notes: notes,
        createdAt: DateTime.now().toUtc().toIso8601String(),
        items: items,
        isOfflinePending: true,
      );
      await OfflineService.savePendingOrder(offlineOrder);
      return ApiResult.failure(
        'Offline: Order saved locally. It will auto-sync when connection is restored.',
        isOffline: true,
      );
    }
  }

  // ── Sync Pending Offline Orders ──
  static Future<int> syncPendingOrders() async {
    final pending = await OfflineService.getPendingOrders();
    if (pending.isEmpty) return 0;

    int syncedCount = 0;
    List<CustomerOrder> remaining = [];

    for (final order in pending) {
      final res = await placeOrder(
        customerName: order.customerName,
        customerPhone: order.customerPhone,
        orderType: order.orderType,
        deliveryAddress: order.deliveryAddress,
        paymentMethod: order.paymentMethod,
        items: order.items,
        notes: '${order.notes} [Synced from Offline Mobile]',
      );

      if (res.isSuccess) {
        syncedCount++;
      } else {
        remaining.add(order);
      }
    }

    await OfflineService.clearPendingOrders();
    for (final rem in remaining) {
      await OfflineService.savePendingOrder(rem);
    }

    return syncedCount;
  }

  // ── Firestore Queue Direct Fallback ──
  static Future<QueueStatus?> _fetchQueueFromFirestoreDirect() async {
    try {
      final url = 'https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/queue/status';
      final response = await http.get(Uri.parse(url)).timeout(_timeout);
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final f = data['fields'] as Map<String, dynamic>?;
        if (f != null) {
          final curr = int.tryParse(f['current_queue_no']?['integerValue']?.toString() ?? '0') ?? 0;
          final serv = int.tryParse(f['now_serving']?['integerValue']?.toString() ?? '0') ?? 0;
          return QueueStatus(
            currentQueueNo: curr,
            nowServing: serv,
            hasActive: true,
            timestamp: DateTime.now().toIso8601String(),
          );
        }
      }
    } catch (_) {}
    return null;
  }

  // ── Fetch Queue Status ──
  static Future<ApiResult<QueueStatus>> fetchQueueStatus() async {
    final baseUrl = await OfflineService.getBaseUrl();
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/queue'),
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final status = QueueStatus.fromJson(data);
        return ApiResult.success(status);
      } else {
        final direct = await _fetchQueueFromFirestoreDirect();
        if (direct != null) return ApiResult.success(direct);
        return ApiResult.failure('Failed to fetch queue info');
      }
    } catch (e) {
      final direct = await _fetchQueueFromFirestoreDirect();
      if (direct != null) return ApiResult.success(direct);
      return ApiResult.failure('Cannot reach queue server: $e', isOffline: true);
    }
  }

  // ── Helper to parse Firestore REST order document ──
  static CustomerOrder? _parseFirestoreOrder(Map<String, dynamic> f, {int? fallbackId}) {
    try {
      final int id = int.tryParse(f['id']?['integerValue']?.toString() ?? f['order_id']?['integerValue']?.toString() ?? '') ?? (fallbackId ?? 0);
      final int queueNo = int.tryParse(f['queue_no']?['integerValue']?.toString() ?? '0') ?? 0;
      final String name = f['customer_name']?['stringValue'] ?? 'Customer';
      final String phone = f['customer_phone']?['stringValue'] ?? '';
      final String orderType = f['order_type']?['stringValue'] ?? 'pickup';
      final String address = f['delivery_address']?['stringValue'] ?? '';
      final String method = f['payment_method']?['stringValue'] ?? 'GCash';
      final String rawPayStatus = (f['payment_status']?['stringValue'] ?? 'pending').toString().trim().toLowerCase();
      final String paymentStatus = (rawPayStatus == 'confirmed' || rawPayStatus == 'paid') ? 'confirmed' : 'pending';
      final String status = f['status']?['stringValue'] ?? 'pending';
      final num totalNum = f['total_amount']?['doubleValue'] ?? f['total_amount']?['integerValue'] ?? 0.0;
      final String notes = f['notes']?['stringValue'] ?? '';
      final String? createdAt = f['created_at']?['stringValue'] ?? f['timestamp']?['stringValue'];
      final String? paymentRef = f['payment_reference']?['stringValue'];
      final String? paymentAccountId = f['payment_account_id']?['stringValue'];
      final String? paymentAccountName = f['payment_account_name']?['stringValue'];
      final String? paymentProvider = f['payment_provider']?['stringValue'];

      final List<CartItem> items = [];
      final rawItems = f['items']?['arrayValue']?['values'] as List<dynamic>? ?? [];
      for (final raw in rawItems) {
        final m = raw['mapValue']?['fields'] as Map<String, dynamic>?;
        if (m != null) {
          final pid = int.tryParse(m['product_id']?['integerValue']?.toString() ?? '0') ?? 0;
          final pName = m['name']?['stringValue'] ?? m['product_name']?['stringValue'] ?? 'Siomai Item';
          final num pPrice = m['unit_price']?['doubleValue'] ?? m['unit_price']?['integerValue'] ?? 0.0;
          final qty = int.tryParse(m['quantity']?['integerValue']?.toString() ?? '1') ?? 1;
          items.add(CartItem(
            productId: pid,
            productName: pName,
            unitPrice: pPrice.toDouble(),
            quantity: qty,
          ));
        }
      }

      return CustomerOrder(
        id: id > 0 ? id : fallbackId,
        queueNo: queueNo,
        customerName: name,
        customerPhone: phone,
        orderType: orderType,
        deliveryAddress: address,
        paymentMethod: method,
        paymentStatus: paymentStatus,
        paymentAccountId: (paymentAccountId != null && paymentAccountId.isNotEmpty) ? paymentAccountId : null,
        paymentAccountName: (paymentAccountName != null && paymentAccountName.isNotEmpty) ? paymentAccountName : null,
        paymentProvider: (paymentProvider != null && paymentProvider.isNotEmpty) ? paymentProvider : null,
        status: status,
        totalAmount: totalNum.toDouble(),
        notes: notes,
        createdAt: createdAt,
        paymentReference: paymentRef,
        items: items,
      );
    } catch (_) {
      return null;
    }
  }

  // ── Fetch Specific Order Details ──
  static Future<ApiResult<CustomerOrder>> fetchOrderDetails(int orderId) async {
    final baseUrl = await OfflineService.getBaseUrl();
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/orders/$orderId'),
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final order = CustomerOrder.fromJson(data['order'] ?? {});
        await OfflineService.saveActiveOrder(order);
        return ApiResult.success(order);
      }
    } catch (_) {}

    // Direct Cloud Firestore Fallback for real-time status updates!
    try {
      final url = 'https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/orders/order_$orderId';
      final fsRes = await http.get(Uri.parse(url)).timeout(_timeout);
      if (fsRes.statusCode == 200) {
        final Map<String, dynamic> body = jsonDecode(fsRes.body);
        final f = body['fields'] as Map<String, dynamic>?;
        if (f != null) {
          final ord = _parseFirestoreOrder(f, fallbackId: orderId);
          if (ord != null) {
            await OfflineService.saveActiveOrder(ord);
            return ApiResult.success(ord);
          }
        }
      }
    } catch (_) {}

    return ApiResult.failure('Order not found or network offline', isOffline: true);
  }

  // ── Resolve Ticket Number & ID for Pending/Cloud Orders ──
  static Future<CustomerOrder?> resolveActiveOrder(CustomerOrder order) async {
    final baseUrl = await OfflineService.getBaseUrl();
    // 1. Try resolving from backend /queue
    try {
      final response = await http.get(Uri.parse('$baseUrl/queue')).timeout(_timeout);
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final rawOrders = data['orders'] as List<dynamic>? ?? [];
        for (final ro in rawOrders) {
          if (ro is Map<String, dynamic>) {
            final ph = (ro['customer_phone'] ?? '').toString();
            final name = (ro['customer_name'] ?? '').toString();
            if (ph == order.customerPhone && (name == order.customerName || order.customerName.isEmpty)) {
              final resolved = CustomerOrder.fromJson(ro);
              if (resolved.queueNo > 0) {
                return resolved;
              }
            }
          }
        }
      }
    } catch (_) {}

    // 2. Try resolving from Cloud Firestore direct REST
    try {
      final fsUrl = 'https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/orders?pageSize=30';
      final fsRes = await http.get(Uri.parse(fsUrl)).timeout(_timeout);
      if (fsRes.statusCode == 200) {
        final Map<String, dynamic> body = jsonDecode(fsRes.body);
        final rawDocs = body['documents'] as List<dynamic>? ?? [];
        for (final doc in rawDocs) {
          final f = doc['fields'] as Map<String, dynamic>?;
          if (f != null) {
            final ph = f['customer_phone']?['stringValue'] ?? '';
            final name = f['customer_name']?['stringValue'] ?? '';
            if (ph == order.customerPhone && (name == order.customerName || order.customerName.isEmpty)) {
              final resolved = _parseFirestoreOrder(f);
              if (resolved != null && resolved.queueNo > 0) {
                return resolved;
              }
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  // ── Cancel Order by Object (Handles null IDs & Firestore-Direct Orders) ──
  static Future<ApiResult<bool>> cancelOrderByOrder(CustomerOrder order) async {
    if (order.id != null && order.id! > 0) {
      return await cancelOrder(order.id!);
    }

    if (order.isOfflinePending) {
      return ApiResult.success(true);
    }

    // Direct Firestore search & cancel by phone and customer details
    try {
      final fsUrl = 'https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/orders?pageSize=30';
      final fsRes = await http.get(Uri.parse(fsUrl)).timeout(_timeout);
      if (fsRes.statusCode == 200) {
        final Map<String, dynamic> body = jsonDecode(fsRes.body);
        final rawDocs = body['documents'] as List<dynamic>? ?? [];
        for (final doc in rawDocs) {
          final f = doc['fields'] as Map<String, dynamic>?;
          final nameStr = doc['name']?.toString() ?? '';
          final docId = nameStr.split('/').last;
          if (f != null && docId.isNotEmpty) {
            final ph = f['customer_phone']?['stringValue'] ?? '';
            final name = f['customer_name']?['stringValue'] ?? '';
            if (ph == order.customerPhone && (name == order.customerName || order.customerName.isEmpty)) {
              final nowUtc = DateTime.now().toUtc().toIso8601String();
              final patchUrl = 'https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/orders/$docId?updateMask.fieldPaths=status&updateMask.fieldPaths=updated_at';
              final patchBody = {
                'fields': {
                  'status': {'stringValue': 'cancelled'},
                  'updated_at': {'stringValue': nowUtc},
                }
              };
              final patchRes = await http.patch(
                Uri.parse(patchUrl),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode(patchBody),
              ).timeout(_timeout);
              if (patchRes.statusCode == 200) {
                return ApiResult.success(true);
              }
            }
          }
        }
      }
    } catch (_) {}

    return ApiResult.failure('Could not locate order to cancel in database.');
  }

  // ── Cancel Order ──
  static Future<ApiResult<bool>> cancelOrder(dynamic orderIdentifier) async {
    final cleanId = orderIdentifier.toString().replaceAll(RegExp(r'[^0-9]'), '').trim();
    final targetId = cleanId.isNotEmpty ? cleanId : orderIdentifier.toString().trim();
    if (targetId.isEmpty) {
      return ApiResult.failure('Invalid order ID');
    }

    final baseUrl = await OfflineService.getBaseUrl();
    bool backendSuccess = false;

    try {
      final response = await http.put(
        Uri.parse('$baseUrl/orders/$targetId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'status': 'cancelled'}),
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        backendSuccess = true;
      }
    } catch (_) {}

    // Cloud Firestore direct update (guarantee Firestore is synchronously updated to cancelled)
    try {
      final nowUtc = DateTime.now().toUtc().toIso8601String();
      final url = 'https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/orders/order_$targetId?updateMask.fieldPaths=status&updateMask.fieldPaths=updated_at';
      final body = {
        'fields': {
          'status': {'stringValue': 'cancelled'},
          'updated_at': {'stringValue': nowUtc},
        }
      };
      final fsRes = await http.patch(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ).timeout(_timeout);
      if (fsRes.statusCode == 200) {
        return ApiResult.success(true);
      }
      if (fsRes.statusCode == 404) {
        final upsertUrl = 'https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/orders/order_$targetId';
        final upsertRes = await http.patch(
          Uri.parse(upsertUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        ).timeout(_timeout);
        if (upsertRes.statusCode == 200) {
          return ApiResult.success(true);
        }
      }
    } catch (_) {}

    if (backendSuccess) {
      return ApiResult.success(true);
    }
    return ApiResult.failure('Failed to cancel order in database');
  }

  // ── Fetch Payment Accounts (Backend + Firestore Fallback) ──
  static Future<List<PaymentAccount>> _fetchPaymentAccountsFromFirestoreDirect() async {
    try {
      final url = 'https://firestore.googleapis.com/v1/projects/boss-kevs/databases/(default)/documents/payment_accounts';
      final response = await http.get(Uri.parse(url)).timeout(_timeout);
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final List<dynamic> docs = data['documents'] ?? [];
        final List<PaymentAccount> accounts = [];
        for (final doc in docs) {
          final f = doc['fields'] as Map<String, dynamic>?;
          if (f != null) {
            final num limitVal = f['transaction_limit']?['doubleValue'] ?? f['transaction_limit']?['integerValue'] ?? 50.0;
            final String limitType = f['limit_type']?['stringValue'] ?? 'count';
            final int confCount = int.tryParse(f['confirmed_count']?['integerValue']?.toString() ?? '0') ?? 0;
            final num confAmt = f['confirmed_amount']?['doubleValue'] ?? f['confirmed_amount']?['integerValue'] ?? 0.0;
            final double usage = limitType == 'amount' ? confAmt.toDouble() : confCount.toDouble();
            final double limit = limitVal.toDouble();
            final double rem = (limit - usage) > 0 ? (limit - usage) : 0.0;
            final bool isActive = f['is_active']?['booleanValue'] ?? true;
            final bool limitReached = limit > 0 ? usage >= limit : false;
            accounts.add(PaymentAccount(
              id: int.tryParse(f['id']?['integerValue']?.toString() ?? '0'),
              accountId: f['account_id']?['stringValue'] ?? '',
              accountName: f['account_name']?['stringValue'] ?? 'GCash Account',
              provider: f['provider']?['stringValue'] ?? 'GCash',
              accountHolderName: f['account_holder_name']?['stringValue'] ?? '',
              mobileNumber: f['mobile_number']?['stringValue'] ?? '',
              qrImageUrl: f['qr_image_url']?['stringValue'] ?? '/images/gcash_instapay_qr_1.jpg',
              transactionLimit: limit,
              limitType: limitType,
              confirmedCount: confCount,
              confirmedAmount: confAmt.toDouble(),
              confirmedUsage: usage,
              remainingCapacity: rem,
              limitReached: limitReached,
              isActive: isActive,
              isAvailable: isActive && !limitReached,
              priorityOrder: int.tryParse(f['priority_order']?['integerValue']?.toString() ?? '1') ?? 1,
            ));
          }
        }
        accounts.sort((a, b) => a.priorityOrder.compareTo(b.priorityOrder));
        return accounts;
      }
    } catch (_) {}
    return [];
  }

  static Future<ApiResult<List<PaymentAccount>>> fetchPaymentAccounts() async {
    final baseUrl = await OfflineService.getBaseUrl();
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/payment-accounts'),
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final List<dynamic> list = data['accounts'] ?? [];
        final accounts = list.map((json) => PaymentAccount.fromJson(json)).toList();
        accounts.sort((a, b) => a.priorityOrder.compareTo(b.priorityOrder));
        return ApiResult.success(accounts);
      }
    } catch (_) {}

    final fsAccounts = await _fetchPaymentAccountsFromFirestoreDirect();
    if (fsAccounts.isNotEmpty) {
      return ApiResult.success(fsAccounts);
    }

    // Offline fallback seeded defaults
    return ApiResult.success([
      PaymentAccount(
        id: 1,
        accountId: 'acct_gcash_1',
        accountName: 'GCash / InstaPay Account 1 (Primary)',
        provider: 'GCash / InstaPay',
        accountHolderName: 'JA****E B.',
        mobileNumber: '+63 993 104 ••••',
        qrImageUrl: '/images/gcash_instapay_qr_1.jpg',
        transactionLimit: 25,
        limitType: 'count',
        confirmedCount: 0,
        confirmedAmount: 0,
        confirmedUsage: 0,
        remainingCapacity: 25,
        limitReached: false,
        isActive: true,
        isAvailable: true,
        priorityOrder: 1,
      ),
      PaymentAccount(
        id: 2,
        accountId: 'acct_gcash_2',
        accountName: 'GCash Account 2 (Backup)',
        provider: 'GCash',
        accountHolderName: 'JO*N LL**D C.',
        mobileNumber: '+63 921 296 ••••',
        qrImageUrl: '/images/gcash_qr.png',
        transactionLimit: 25,
        limitType: 'count',
        confirmedCount: 0,
        confirmedAmount: 0,
        confirmedUsage: 0,
        remainingCapacity: 25,
        limitReached: false,
        isActive: true,
        isAvailable: true,
        priorityOrder: 2,
      ),
    ]);
  }

  static Future<ApiResult<CustomerOrder>> selectOrderPaymentAccount(int orderId, String accountId) async {
    final baseUrl = await OfflineService.getBaseUrl();
    try {
      final response = await http.put(
        Uri.parse('$baseUrl/orders/$orderId/payment-account'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'payment_account_id': accountId}),
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final order = CustomerOrder.fromJson(data['order'] ?? {});
        await OfflineService.saveActiveOrder(order);
        return ApiResult.success(order);
      } else {
        final Map<String, dynamic> data = jsonDecode(response.body);
        return ApiResult.failure(data['error'] ?? 'Failed to select payment account');
      }
    } catch (e) {
      return ApiResult.failure('Failed to select payment account: $e');
    }
  }

  // ── Simulate GCash Payment ──
  static Future<ApiResult<Map<String, dynamic>>> initiateGCash(int orderId, {String? paymentAccountId}) async {
    final baseUrl = await OfflineService.getBaseUrl();
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/payments/gcash'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'order_id': orderId,
          if (paymentAccountId != null) 'payment_account_id': paymentAccountId,
        }),
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        return ApiResult.success(data);
      } else {
        try {
          final Map<String, dynamic> data = jsonDecode(response.body);
          return ApiResult.failure(data['error'] ?? 'GCash payment initialization failed');
        } catch (_) {
          return ApiResult.failure('GCash payment initialization failed');
        }
      }
    } catch (e) {
      return ApiResult.failure('Payment connection error: $e');
    }
  }

  static Future<ApiResult<bool>> confirmGCashCallback(int orderId, String reference, {String? paymentAccountId}) async {
    final baseUrl = await OfflineService.getBaseUrl();
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/payments/gcash/callback'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'order_id': orderId,
          'reference': reference,
          'status': 'paid',
          if (paymentAccountId != null) 'payment_account_id': paymentAccountId,
        }),
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        return ApiResult.success(true);
      }
      return ApiResult.failure('Payment verification failed');
    } catch (e) {
      return ApiResult.failure('Payment verification error: $e');
    }
  }
}
