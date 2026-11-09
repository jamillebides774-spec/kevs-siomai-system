class Product {
  final int id;
  final String name;
  final String category;
  final double price;
  final int stock;
  final int maxStock;
  final String unit;
  final String description;
  final String imageUrl;
  final bool isActive;
  final String status;

  Product({
    required this.id,
    required this.name,
    required this.category,
    required this.price,
    required this.stock,
    required this.maxStock,
    required this.unit,
    required this.description,
    required this.imageUrl,
    this.isActive = true,
    String? status,
  }) : status = status ?? (isActive ? 'Active' : 'Inactive');

  bool get isAvailable => isActive && stock > 0;
  bool get isLowStock => stock > 0 && stock <= (maxStock * 0.2).round();

  /// Local bundled asset path matching product name
  String get assetPath {
    final n = name.toLowerCase();
    if (n.contains('siomai')) return 'assets/images/hotspot_siomai.jpg';
    if (n.contains('coke') || n.contains('coca')) return 'assets/images/coke.jpg';
    if (n.contains('royal')) return 'assets/images/royal.jpg';
    if (n.contains('sprite')) return 'assets/images/sprite.jpg';
    if (n.contains('chilli') || n.contains('chili')) return 'assets/images/chilli_garlic.jpg';
    if (n.contains('soy')) return 'assets/images/soy_sauce.jpg';
    if (n.contains('calamansi')) return 'assets/images/calamansi.jpg';
    return '';
  }

  /// High-resolution CDN fallback image
  String get onlineFallbackUrl {
    final n = name.toLowerCase();
    if (n.contains('siomai')) return 'https://images.unsplash.com/photo-1496116218417-1a781b1c416c?auto=format&fit=crop&w=600&q=80';
    if (n.contains('coke') || n.contains('coca')) return 'https://images.unsplash.com/photo-1622483767028-3f66f32aef97?auto=format&fit=crop&w=600&q=80';
    if (n.contains('royal')) return 'https://images.unsplash.com/photo-1625772299848-391b6a87d7b3?auto=format&fit=crop&w=600&q=80';
    if (n.contains('sprite')) return 'https://images.unsplash.com/photo-1513558161293-cdaf765ed2fd?auto=format&fit=crop&w=600&q=80';
    if (n.contains('chilli') || n.contains('chili')) return 'https://images.unsplash.com/photo-1589301760014-d929f3979dbc?auto=format&fit=crop&w=600&q=80';
    if (n.contains('soy')) return 'https://images.unsplash.com/photo-1588195538326-c5b1e9f80a1b?auto=format&fit=crop&w=600&q=80';
    if (n.contains('calamansi')) return 'https://images.unsplash.com/photo-1590502593747-42a996133562?auto=format&fit=crop&w=600&q=80';
    return '';
  }

  factory Product.fromJson(Map<String, dynamic> json) {
    final rawStatus = (json['status'] ?? '').toString().trim();
    final statusLower = rawStatus.toLowerCase();
    final bool parsedIsActive = json.containsKey('is_active') && json['is_active'] != null
        ? (json['is_active'] == true || json['is_active'].toString().toLowerCase() == 'true' || json['is_active'] == 1)
        : (statusLower != 'inactive' && statusLower != 'disabled');
    final bool effectiveActive = parsedIsActive && statusLower != 'inactive' && statusLower != 'disabled';

    return Product(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id'].toString()) ?? 0,
      name: json['name'] ?? '',
      category: json['category'] ?? 'General',
      price: (json['price'] is num) ? (json['price'] as num).toDouble() : double.tryParse(json['price'].toString()) ?? 0.0,
      stock: json['stock'] is int ? json['stock'] : int.tryParse(json['stock'].toString()) ?? 0,
      maxStock: json['max_stock'] is int ? json['max_stock'] : int.tryParse(json['max_stock'].toString()) ?? 100,
      unit: json['unit'] ?? 'pcs',
      description: json['description'] ?? '',
      imageUrl: json['image_url'] ?? '',
      isActive: effectiveActive,
      status: effectiveActive ? 'Active' : 'Inactive',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'category': category,
      'price': price,
      'stock': stock,
      'max_stock': maxStock,
      'unit': unit,
      'description': description,
      'image_url': imageUrl,
      'is_active': isActive,
      'status': status,
    };
  }
}
