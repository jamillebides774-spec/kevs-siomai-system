import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/product.dart';
import '../models/order.dart';
import '../models/payment_account.dart';
import '../models/queue_status.dart';
import '../services/api_service.dart';
import '../services/offline_service.dart';

class ShopProvider extends ChangeNotifier {
  List<Product> _products = [];
  List<PaymentAccount> _paymentAccounts = [];
  String _selectedCategory = 'All';
  bool _isLoading = false;
  bool _isOffline = false;
  bool _isDarkMode = true;
  String? _errorMessage;

  final Map<int, CartItem> _cart = {};
  QueueStatus? _queueStatus;
  List<CustomerOrder> _activeOrders = [];
  List<CustomerOrder> _pendingOfflineOrders = [];

  Timer? _queuePollTimer;

  static int _categoryPriority(String category) {
    final cat = category.toLowerCase().trim();
    if (cat.contains('siomai')) return 1;
    if (cat.contains('drink') || cat.contains('beverage')) return 2;
    if (cat.contains('add') || cat.contains('sauce') || cat.contains('condiment')) return 3;
    return 4;
  }

  // Getters
  List<Product> get products {
    final activeList = _products.where((p) => p.isActive).toList();
    activeList.sort((a, b) {
      final orderA = _categoryPriority(a.category);
      final orderB = _categoryPriority(b.category);
      if (orderA != orderB) return orderA.compareTo(orderB);
      return a.id.compareTo(b.id);
    });
    if (_selectedCategory == 'All') return activeList;
    return activeList.where((p) => p.category.toLowerCase() == _selectedCategory.toLowerCase()).toList();
  }

  List<String> get categories {
    final Set<String> rawCats = {};
    for (var p in _products.where((p) => p.isActive)) {
      if (p.category.isNotEmpty) rawCats.add(p.category);
    }
    final sorted = rawCats.toList()
      ..sort((a, b) => _categoryPriority(a).compareTo(_categoryPriority(b)));
    return ['All', ...sorted];
  }

  String get selectedCategory => _selectedCategory;
  bool get isLoading => _isLoading;
  bool get isOffline => _isOffline;
  bool get isDarkMode => _isDarkMode;
  String? get errorMessage => _errorMessage;

  Future<void> setDarkMode(bool isDark) async {
    if (_isDarkMode == isDark) return;
    _isDarkMode = isDark;
    notifyListeners();
    await OfflineService.setIsDarkMode(isDark);
  }

  Future<void> toggleTheme() async {
    await setDarkMode(!_isDarkMode);
  }

  Map<int, CartItem> get cart => _cart;
  int get cartCount => _cart.values.fold(0, (sum, it) => sum + it.quantity);
  double get cartTotal => _cart.values.fold(0.0, (sum, it) => sum + it.subtotal);

  /// Total count of HotSpot Siomai pieces in current cart
  int get totalSiomaiCount {
    int count = 0;
    for (final it in _cart.values) {
      final name = it.productName.toLowerCase();
      final product = _products.firstWhere(
        (p) => p.id == it.productId,
        orElse: () => Product(id: it.productId, name: it.productName, category: '', price: it.unitPrice, stock: 99, maxStock: 100, unit: '', description: '', imageUrl: ''),
      );
      final cat = product.category.toLowerCase();
      if (name.contains('siomai') || cat.contains('siomai')) {
        count += it.quantity;
      }
    }
    return count;
  }

  static bool isSiomaiProduct(dynamic productOrItem) {
    if (productOrItem == null) return false;
    final String name = (productOrItem is Product ? productOrItem.name : (productOrItem is CartItem ? productOrItem.productName : '')).toLowerCase();
    final String cat = (productOrItem is Product ? productOrItem.category : '').toLowerCase();
    return name.contains('siomai') || cat.contains('siomai');
  }

  static String? getAddonType(dynamic productOrItem) {
    if (productOrItem == null) return null;
    final String name = (productOrItem is Product ? productOrItem.name : (productOrItem is CartItem ? productOrItem.productName : '')).toLowerCase();
    if (name.contains('calamansi')) return 'calamansi';
    if (name.contains('soy')) return 'soy_sauce';
    if (name.contains('chili') || name.contains('chilli')) return 'chili_garlic';
    return null;
  }

  static String getAddonUnit(String addonType) {
    if (addonType == 'calamansi') return 'pcs';
    return 'packs';
  }

  int getMaxAddonQuantity(dynamic productOrItem) {
    final type = getAddonType(productOrItem);
    if (type == null) return 999;

    final siomai = totalSiomaiCount;
    if (siomai <= 0) {
      return 0;
    } else if (siomai <= 10) {
      if (type == 'calamansi') return 3;
      return 2; // soy_sauce, chili_garlic
    } else {
      // 11+ siomai
      if (type == 'calamansi') return 5;
      return 3; // soy_sauce, chili_garlic
    }
  }

  int getProductMaxLimit(Product product) {
    final type = getAddonType(product);
    if (type == null) return product.stock;
    final addonCap = getMaxAddonQuantity(product);
    return addonCap < product.stock ? addonCap : product.stock;
  }

  List<String> getAddonViolations() {
    final List<String> violations = [];
    final siomai = totalSiomaiCount;

    for (final it in _cart.values) {
      final type = getAddonType(it);
      if (type == null) continue;

      final maxAllowed = getMaxAddonQuantity(it);
      final unit = getAddonUnit(type);

      if (it.quantity > maxAllowed) {
        if (siomai == 0) {
          violations.add('${it.productName}: ${it.quantity} $unit (Requires at least 1 Siomai, Max: 0 $unit)');
        } else {
          violations.add('${it.productName}: ${it.quantity} $unit (Max: $maxAllowed $unit for $siomai Siomai pcs)');
        }
      }
    }
    return violations;
  }

  QueueStatus? get queueStatus => _queueStatus;
  List<CustomerOrder> get activeOrders => _activeOrders.where((o) => !o.isCancelled).toList();
  List<CustomerOrder> get pendingOfflineOrders => _pendingOfflineOrders;
  List<PaymentAccount> get paymentAccounts => _paymentAccounts;
  List<PaymentAccount> get availablePaymentAccounts =>
      _paymentAccounts.where((a) => a.isAvailable).toList();
  bool get hasAvailablePaymentAccounts => availablePaymentAccounts.isNotEmpty;

  PaymentAccount? findAccountById(String? accountId) {
    if (accountId == null || accountId.isEmpty) return null;
    for (final a in _paymentAccounts) {
      if (a.accountId == accountId || a.id?.toString() == accountId) {
        return a;
      }
    }
    return null;
  }

  /// Returns true if an unpaid online order had a specific payment account selected,
  /// and that account has since become unavailable (deactivated or reached its limit).
  bool isOrderAccountUnavailable(CustomerOrder order) {
    if (!order.isOnlinePayment || order.isPaid || order.isCancelled) return false;
    final acctId = order.paymentAccountId;
    if (acctId == null || acctId.isEmpty) return false;
    if (_paymentAccounts.isEmpty) return false;
    final acct = findAccountById(acctId);
    if (acct == null) return true;
    return !acct.isAvailable;
  }

  ShopProvider() {
    init();
  }

  Future<void> init() async {
    _isDarkMode = await OfflineService.getIsDarkMode();
    notifyListeners();
    await loadProducts();
    await refreshPaymentAccounts(silent: true);
    await loadLocalOrders();
    await refreshQueue();

    // Start background queue polling every 2 seconds for real-time synchronization
    _queuePollTimer?.cancel();
    _queuePollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      loadProducts(showLoader: false);
      refreshQueue(silent: true);
      refreshActiveOrders(silent: true);
      refreshPaymentAccounts(silent: true);
    });
  }

  @override
  void dispose() {
    _queuePollTimer?.cancel();
    super.dispose();
  }

  void setCategory(String cat) {
    _selectedCategory = cat;
    notifyListeners();
  }

  // ── Products ──
  Future<void> loadProducts({bool showLoader = true}) async {
    if (showLoader) {
      _isLoading = true;
      _errorMessage = null;
      notifyListeners();
    }

    final res = await ApiService.fetchProducts();
    _isLoading = false;

    if (res.isSuccess && res.data != null) {
      _products = res.data!;
      _isOffline = false;
      _errorMessage = null;
    } else {
      _isOffline = res.isOffline;
      _errorMessage = res.errorMessage;
      // Load offline cached products if available
      final cached = await OfflineService.getCachedProducts();
      if (cached.isNotEmpty) {
        _products = cached;
      }
    }
    // Clean up any items that became inactive or unavailable from active cart
    if (_products.isNotEmpty) {
      _cart.removeWhere((id, _) => !_products.any((p) => p.id == id && p.isActive));
    }
    notifyListeners();
  }

  Product? findProductById(int productId) {
    for (final p in _products) {
      if (p.id == productId) return p;
    }
    return null;
  }

  // ── Cart Operations ──
  void addToCart(Product product) {
    final live = findProductById(product.id) ?? product;
    if (!live.isActive || live.stock <= 0) return;

    final type = getAddonType(product);
    if (type != null) {
      final maxAllowed = getMaxAddonQuantity(product);
      final existingQty = _cart[product.id]?.quantity ?? 0;
      if (existingQty >= maxAllowed || existingQty >= product.stock) {
        return; // Block adding above applicable limit (Requirement 2 & 4)
      }
    }

    if (_cart.containsKey(product.id)) {
      final existing = _cart[product.id]!;
      if (existing.quantity < product.stock) {
        existing.quantity++;
      }
    } else {
      _cart[product.id] = CartItem(
        productId: product.id,
        productName: product.name,
        unitPrice: product.price,
        quantity: 1,
      );
    }
    notifyListeners();
  }

  void removeFromCart(int productId) {
    _cart.remove(productId);
    notifyListeners();
  }

  void updateQuantity(int productId, int delta) {
    if (!_cart.containsKey(productId)) return;
    final item = _cart[productId]!;
    final product = _products.firstWhere((p) => p.id == productId, orElse: () => Product(id: productId, name: item.productName, category: '', price: item.unitPrice, stock: 99, maxStock: 100, unit: '', description: '', imageUrl: ''));
    if (!product.isActive) {
      _cart.remove(productId);
      notifyListeners();
      return;
    }

    final newQty = item.quantity + delta;
    if (newQty <= 0) {
      _cart.remove(productId);
    } else {
      final type = getAddonType(product);
      if (type != null && delta > 0) {
        final maxAllowed = getMaxAddonQuantity(product);
        if (newQty > maxAllowed) {
          return; // Block exceeding limit
        }
      }
      if (newQty <= product.stock) {
        item.quantity = newQty;
      }
    }
    notifyListeners();
  }

  /// Sets item quantity directly (e.g. from typing in unit-based quantity input).
  /// Returns false if the requested quantity exceeded available stock or add-on limit (and was clamped).
  bool setItemQuantity(int productId, int quantity) {
    if (quantity <= 0) {
      _cart.remove(productId);
      notifyListeners();
      return true;
    }

    final product = _products.firstWhere(
      (p) => p.id == productId,
      orElse: () => Product(id: productId, name: 'Item', category: '', price: 0, stock: 99, maxStock: 100, unit: '', description: '', imageUrl: ''),
    );
    if (!product.isActive) {
      _cart.remove(productId);
      notifyListeners();
      return false;
    }

    final type = getAddonType(product);
    int effectiveCap = product.stock;
    if (type != null) {
      final maxAddon = getMaxAddonQuantity(product);
      if (maxAddon < effectiveCap) effectiveCap = maxAddon;
    }

    if (quantity > effectiveCap) {
      final clamped = effectiveCap > 0 ? effectiveCap : 0;
      if (clamped <= 0) {
        _cart.remove(productId);
      } else {
        if (_cart.containsKey(productId)) {
          _cart[productId]!.quantity = clamped;
        } else {
          _cart[productId] = CartItem(
            productId: productId,
            productName: product.name,
            unitPrice: product.price,
            quantity: clamped,
          );
        }
      }
      notifyListeners();
      return false; // exceeded limit
    }

    if (_cart.containsKey(productId)) {
      _cart[productId]!.quantity = quantity;
    } else {
      _cart[productId] = CartItem(
        productId: productId,
        productName: product.name,
        unitPrice: product.price,
        quantity: quantity,
      );
    }
    notifyListeners();
    return true;
  }

  Future<bool> cancelOrder(int? orderId, {CustomerOrder? order}) async {
    final targetId = orderId ?? order?.id;
    _isLoading = true;
    notifyListeners();

    bool success = false;

    if (order != null && order.isOfflinePending) {
      // Offline pending order cancellation
      final pending = await OfflineService.getPendingOrders();
      pending.removeWhere((o) => o.customerPhone == order.customerPhone && o.createdAt == order.createdAt);
      await OfflineService.clearPendingOrders();
      for (final p in pending) {
        await OfflineService.savePendingOrder(p);
      }
      await OfflineService.removeActiveOrder(order: order);
      _activeOrders.removeWhere((o) => o == order);
      _isLoading = false;
      await refreshQueue();
      notifyListeners();
      return true;
    }

    if (order != null) {
      final res = await ApiService.cancelOrderByOrder(order);
      success = res.isSuccess;
    } else if (targetId != null && targetId > 0) {
      final res = await ApiService.cancelOrder(targetId);
      success = res.isSuccess;
    }

    _isLoading = false;

    if (success) {
      // Mark as cancelled and immediately purge from persistent storage & active list
      if (order != null) {
        order.status = 'cancelled';
        await OfflineService.removeActiveOrder(order: order);
        _activeOrders.removeWhere((o) => o == order || (order.id != null && o.id == order.id));
      } else if (targetId != null) {
        await OfflineService.removeActiveOrder(targetId: targetId);
        _activeOrders.removeWhere((o) => o.id == targetId);
      }
      await refreshActiveOrders();
      await refreshQueue();
      notifyListeners();
      return true;
    }
    notifyListeners();
    return false;
  }

  void clearCart() {
    _cart.clear();
    notifyListeners();
  }

  // ── Payment Accounts Management ──
  Future<void> refreshPaymentAccounts({bool silent = false}) async {
    final res = await ApiService.fetchPaymentAccounts();
    if (res.isSuccess && res.data != null) {
      final newAccounts = res.data!;
      bool changed = _paymentAccounts.length != newAccounts.length;
      if (!changed) {
        for (int i = 0; i < _paymentAccounts.length; i++) {
          final a = _paymentAccounts[i];
          final b = newAccounts[i];
          if (a.accountId != b.accountId ||
              a.isAvailable != b.isAvailable ||
              a.isActive != b.isActive ||
              a.limitReached != b.limitReached ||
              a.confirmedUsage != b.confirmedUsage ||
              a.remainingCapacity != b.remainingCapacity ||
              a.accountName != b.accountName ||
              a.qrImageUrl != b.qrImageUrl) {
            changed = true;
            break;
          }
        }
      }
      _paymentAccounts = newAccounts;
      if (changed || !silent) notifyListeners();
    }
  }

  Future<CustomerOrder?> selectOrderPaymentAccount(CustomerOrder order, String accountId) async {
    final acct = findAccountById(accountId);
    if (order.id != null && order.id! > 0) {
      final res = await ApiService.selectOrderPaymentAccount(order.id!, accountId);
      if (res.isSuccess && res.data != null) {
        final updated = res.data!;
        final idx = _activeOrders.indexWhere((o) => o.id == order.id);
        if (idx >= 0) {
          _activeOrders[idx] = updated;
        }
        order.paymentAccountId = updated.paymentAccountId;
        order.paymentAccountName = updated.paymentAccountName;
        order.paymentProvider = updated.paymentProvider;
        await OfflineService.saveActiveOrder(updated);
        await refreshPaymentAccounts(silent: true);
        notifyListeners();
        return updated;
      } else {
        _errorMessage = res.errorMessage;
        notifyListeners();
        return null;
      }
    } else if (acct != null) {
      order.paymentAccountId = acct.accountId;
      order.paymentAccountName = acct.accountName;
      order.paymentProvider = acct.provider;
      await OfflineService.saveActiveOrder(order);
      notifyListeners();
      return order;
    }
    return null;
  }

  // ── Place Order ──
  Future<CustomerOrder?> submitOrder({
    required String customerName,
    required String customerPhone,
    required String orderType,
    required String deliveryAddress,
    required String paymentMethod,
    required String notes,
    String? paymentAccountId,
    String? paymentAccountName,
    String? paymentProvider,
  }) async {
    // Purge any products that became inactive before submitting order
    if (_products.isNotEmpty) {
      final hadInactive = _cart.keys.any((id) => !_products.any((p) => p.id == id && p.isActive));
      if (hadInactive) {
        _cart.removeWhere((id, _) => !_products.any((p) => p.id == id && p.isActive));
        _errorMessage = 'One or more items in your cart are no longer available and were removed.';
        notifyListeners();
        return null;
      }
    }
    if (_cart.isEmpty) return null;

    final items = _cart.values.toList();
    _isLoading = true;
    notifyListeners();

    // Remember customer profile
    await OfflineService.saveCustomerProfile(customerName, customerPhone);

    final res = await ApiService.placeOrder(
      customerName: customerName,
      customerPhone: customerPhone,
      orderType: orderType,
      deliveryAddress: deliveryAddress,
      paymentMethod: paymentMethod,
      items: items,
      notes: notes,
      paymentAccountId: paymentAccountId,
      paymentAccountName: paymentAccountName,
      paymentProvider: paymentProvider,
    );

    _isLoading = false;

    if (res.isSuccess && res.data != null) {
      final order = res.data!;
      _cart.clear();
      _activeOrders.insert(0, order);
      await refreshQueue();
      await refreshPaymentAccounts(silent: true);
      await loadProducts(showLoader: false);
      notifyListeners();
      return order;
    } else if (res.isOffline) {
      // Saved to pending offline list
      _cart.clear();
      await loadLocalOrders();
      notifyListeners();
      return null;
    } else {
      _errorMessage = res.errorMessage;
      notifyListeners();
      return null;
    }
  }

  // ── Queue Management ──
  Future<void> refreshQueue({bool silent = false}) async {
    final res = await ApiService.fetchQueueStatus();
    if (res.isSuccess && res.data != null) {
      final newStatus = res.data!;
      final bool changed = _queueStatus == null ||
          _queueStatus!.nowServing != newStatus.nowServing ||
          _queueStatus!.currentQueueNo != newStatus.currentQueueNo ||
          _queueStatus!.activeOrders != newStatus.activeOrders;
      _queueStatus = newStatus;
      if (changed || !silent) notifyListeners();
    }
  }

  Future<void> loadLocalOrders() async {
    _activeOrders = await OfflineService.getActiveOrders();
    _pendingOfflineOrders = await OfflineService.getPendingOrders();
    notifyListeners();
  }

  Future<void> refreshActiveOrders({bool silent = false}) async {
    if (_activeOrders.isEmpty) return;
    bool changed = false;

    // Purge any cancelled orders from active list
    _activeOrders.removeWhere((o) => o.isCancelled);

    for (int i = 0; i < _activeOrders.length; i++) {
      final ord = _activeOrders[i];
      if (ord.isCancelled) continue;

      if (ord.id != null) {
        final res = await ApiService.fetchOrderDetails(ord.id!);
        if (res.isSuccess && res.data != null) {
          final updated = res.data!;
          if (updated.isCancelled) {
            await OfflineService.removeActiveOrder(order: ord, targetId: ord.id);
            _activeOrders.removeAt(i);
            i--;
            changed = true;
            continue;
          } else {
            if (ord.status != updated.status ||
                ord.paymentStatus != updated.paymentStatus ||
                ord.paymentAccountId != updated.paymentAccountId ||
                ord.paymentAccountName != updated.paymentAccountName ||
                ord.queueNo != updated.queueNo) {
              changed = true;
            }
            _activeOrders[i] = updated;
            await OfflineService.saveActiveOrder(updated);
          }
        }
      } else if ((ord.id == null || ord.queueNo <= 0) && !ord.isOfflinePending) {
        // Resolve ticket number and canonical ID from POS / Cloud Firestore
        final resolved = await ApiService.resolveActiveOrder(ord);
        if (resolved != null) {
          if (resolved.isCancelled) {
            await OfflineService.removeActiveOrder(order: ord, targetId: resolved.id);
            _activeOrders.removeAt(i);
            i--;
            changed = true;
            continue;
          }
          _activeOrders[i] = resolved;
          await OfflineService.saveActiveOrder(resolved);
          changed = true;
        }
      }
    }

    if (changed) {
      notifyListeners();
    }
  }

  // ── Sync Offline Pending Orders ──
  Future<int> syncOfflineOrders() async {
    _isLoading = true;
    notifyListeners();

    final count = await ApiService.syncPendingOrders();
    await loadLocalOrders();
    await loadProducts(showLoader: false);
    await refreshQueue();

    _isLoading = false;
    notifyListeners();
    return count;
  }

  // ── GCash Payment Submission (Customer Notification Only; Admin Must Confirm) ──
  Future<bool> processGCashPayment(CustomerOrder order, {String? paymentAccountId}) async {
    if (order.id == null) return false;

    final targetAcctId = paymentAccountId ?? order.paymentAccountId;

    // 1. Initiate GCash / bind selected payment account
    final initRes = await ApiService.initiateGCash(
      order.id!,
      paymentAccountId: targetAcctId,
    );
    if (!initRes.isSuccess) {
      _errorMessage = initRes.errorMessage;
      notifyListeners();
      return false;
    }

    final ref = initRes.data?['reference'] ?? 'GC-MANUAL';
    final acctJson = initRes.data?['payment_account'];
    if (acctJson is Map<String, dynamic>) {
      order.paymentAccountId = acctJson['account_id']?.toString() ?? order.paymentAccountId;
      order.paymentAccountName = acctJson['account_name']?.toString() ?? order.paymentAccountName;
      order.paymentProvider = acctJson['provider']?.toString() ?? order.paymentProvider;
    }

    // 2. Record customer QR scan notification (payment_status stays 'pending' until Admin confirms!)
    final confirmRes = await ApiService.confirmGCashCallback(
      order.id!,
      ref,
      paymentAccountId: order.paymentAccountId,
    );
    if (confirmRes.isSuccess) {
      order.paymentReference = ref;
      await OfflineService.saveActiveOrder(order);
      await refreshActiveOrders();
      await refreshPaymentAccounts(silent: true);
      notifyListeners();
      return true;
    }
    return false;
  }

}
