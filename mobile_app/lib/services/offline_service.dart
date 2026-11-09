import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/product.dart';
import '../models/order.dart';

class OfflineService {
  static const String _keyProducts = 'cached_products';
  static const String _keyPendingOrders = 'pending_offline_orders';
  static const String _keyActiveOrders = 'active_customer_orders';
  static const String _keyCustomerName = 'saved_customer_name';
  static const String _keyCustomerPhone = 'saved_customer_phone';
  static const String _keyCustomerAddress = 'saved_customer_address';
  static const String _keyBackendUrl = 'backend_base_url';
  static const String _keyThemeMode = 'kevs_mobile_dark_mode';

  // ── Theme Preference (Light Mode / Dark Mode) ──
  static Future<bool> getIsDarkMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyThemeMode) ?? true;
  }

  static Future<void> setIsDarkMode(bool isDark) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyThemeMode, isDark);
  }

  // Default backend URL: origin on Web, saved URL on mobile, fallback to Render production
  static Future<String> getBaseUrl() async {
    // 1. Web PWA / Browser: Always use current origin directly
    if (kIsWeb) {
      try {
        if (Uri.base.origin.isNotEmpty && Uri.base.origin.startsWith('http')) {
          return '${Uri.base.origin}/api';
        }
      } catch (_) {}
    }

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_keyBackendUrl);
    if (saved != null && saved.isNotEmpty) return saved;

    final host = Uri.base.host;
    if (host.isNotEmpty && host != '0.0.0.0' && host != 'localhost') {
      return 'http://$host:5000/api';
    }
    if (host == 'localhost') {
      return 'http://localhost:5000/api';
    }
    return 'https://kevs-siomai.onrender.com/api';
  }

  static Future<void> setBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyBackendUrl, url.trim());
  }

  // ── Products Cache ──
  static Future<void> cacheProducts(List<Product> products) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = products.map((p) => p.toJson()).toList();
    await prefs.setString(_keyProducts, jsonEncode(jsonList));
  }

  static Future<List<Product>> getCachedProducts() async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString(_keyProducts);
    if (str == null || str.isEmpty) return [];
    try {
      final List<dynamic> decoded = jsonDecode(str);
      return decoded.map((item) => Product.fromJson(item as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  // ── Pending Offline Orders ──
  static Future<void> savePendingOrder(CustomerOrder order) async {
    final prefs = await SharedPreferences.getInstance();
    final orders = await getPendingOrders();
    orders.add(order);
    final jsonList = orders.map((o) => o.toJson()).toList();
    await prefs.setString(_keyPendingOrders, jsonEncode(jsonList));
  }

  static Future<List<CustomerOrder>> getPendingOrders() async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString(_keyPendingOrders);
    if (str == null || str.isEmpty) return [];
    try {
      final List<dynamic> decoded = jsonDecode(str);
      return decoded.map((item) => CustomerOrder.fromJson(item as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> clearPendingOrders() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyPendingOrders);
  }

  // ── Active Orders Placed by This Device ──
  static Future<void> saveActiveOrder(CustomerOrder order) async {
    final prefs = await SharedPreferences.getInstance();
    final orders = await getActiveOrders();
    // If order is cancelled, purge it from active queue storage immediately
    if (order.isCancelled) {
      orders.removeWhere((o) =>
          (o.id != null && o.id == order.id) ||
          (o.queueNo == order.queueNo && o.queueNo > 0) ||
          (o.customerPhone == order.customerPhone && o.createdAt == order.createdAt));
      final jsonList = orders.map((o) => o.toJson()).toList();
      await prefs.setString(_keyActiveOrders, jsonEncode(jsonList));
      return;
    }
    // Replace if exists, or append
    final index = orders.indexWhere((o) =>
        (o.id != null && o.id == order.id) ||
        (o.queueNo == order.queueNo && o.queueNo > 0) ||
        (o.customerPhone == order.customerPhone && o.createdAt == order.createdAt));
    if (index >= 0) {
      if (orders[index].isPaid && !order.isPaid) {
        order.paymentStatus = 'confirmed';
      }
      orders[index] = order;
    } else {
      orders.insert(0, order);
    }
    final jsonList = orders.map((o) => o.toJson()).toList();
    await prefs.setString(_keyActiveOrders, jsonEncode(jsonList));
  }

  static Future<void> removeActiveOrder({int? targetId, CustomerOrder? order}) async {
    final prefs = await SharedPreferences.getInstance();
    final orders = await getActiveOrders();
    orders.removeWhere((o) =>
        (targetId != null && o.id == targetId) ||
        (order != null && ((order.id != null && o.id == order.id) || (o.customerPhone == order.customerPhone && o.createdAt == order.createdAt)))
    );
    final jsonList = orders.map((o) => o.toJson()).toList();
    await prefs.setString(_keyActiveOrders, jsonEncode(jsonList));
  }

  static Future<List<CustomerOrder>> getActiveOrders() async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString(_keyActiveOrders);
    if (str == null || str.isEmpty) return [];
    try {
      final List<dynamic> decoded = jsonDecode(str);
      return decoded
          .map((item) => CustomerOrder.fromJson(item as Map<String, dynamic>))
          .where((o) => !o.isCancelled)
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ── Customer Profile ──
  static Future<void> saveCustomerProfile(String name, String phone, [String address = '']) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCustomerName, name);
    await prefs.setString(_keyCustomerPhone, phone);
    await prefs.setString(_keyCustomerAddress, address);
  }

  static Future<Map<String, String>> getCustomerProfile() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'name': prefs.getString(_keyCustomerName) ?? '',
      'phone': prefs.getString(_keyCustomerPhone) ?? '',
      'address': prefs.getString(_keyCustomerAddress) ?? '',
    };
  }
}
