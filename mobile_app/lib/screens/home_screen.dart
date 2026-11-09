import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/shop_provider.dart';
import '../widgets/product_card.dart';
import '../widgets/kevs_logo.dart';
import 'cart_screen.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback? onGoToQueue;

  const HomeScreen({super.key, this.onGoToQueue});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  IconData _getCategoryIcon(String category) {
    final cat = category.toLowerCase();
    if (cat == 'all') return Icons.restaurant_menu_rounded;
    if (cat.contains('siomai')) return Icons.lunch_dining_rounded;
    if (cat.contains('drink') || cat.contains('beverage')) return Icons.local_cafe_rounded;
    if (cat.contains('add') || cat.contains('sauce')) return Icons.local_fire_department_rounded;
    return Icons.category_rounded;
  }

  String _getCategoryLabel(String category) {
    final cat = category.toLowerCase();
    if (cat == 'all') return 'All Items';
    if (cat.contains('siomai')) return 'Siomai';
    if (cat.contains('drink') || cat.contains('beverage')) return 'Cold Drinks';
    if (cat.contains('add') || cat.contains('sauce')) return 'Add-ons';
    return category;
  }

  @override
  Widget build(BuildContext context) {
    final shop = context.watch<ShopProvider>();
    final size = MediaQuery.sizeOf(context);
    final screenWidth = size.width;

    // Responsive column count across all device form factors
    final int crossAxisCount = screenWidth >= 1200
        ? 5
        : screenWidth >= 900
            ? 4
            : screenWidth >= 600
                ? 3
                : 2;

    final double horizontalPadding = screenWidth > 900 ? (screenWidth - 900) / 2 + 16 : 16.0;

    // Filter products by category AND search query (only active items)
    final filteredProducts = shop.products.where((p) {
      if (!p.isActive) return false;
      if (_searchQuery.trim().isEmpty) return true;
      final q = _searchQuery.toLowerCase().trim();
      return p.name.toLowerCase().contains(q) ||
          p.category.toLowerCase().contains(q) ||
          p.description.toLowerCase().contains(q);
    }).toList();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final cardBorder = isDark ? Colors.white.withValues(alpha: 0.1) : const Color(0xFFE5E5E5);
    final textPrimary = isDark ? Colors.white : const Color(0xFF171717);
    final textSecondary = isDark ? Colors.white.withValues(alpha: 0.7) : const Color(0xFF525252);
    final textHint = isDark ? Colors.white.withValues(alpha: 0.38) : const Color(0xFF9CA3AF);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: CustomScrollView(
        slivers: [
          // ── Hero App Bar ──
          SliverAppBar(
            expandedHeight: 180,
            floating: false,
            pinned: true,
            backgroundColor: const Color(0xFF171717),
            elevation: 0,
            flexibleSpace: FlexibleSpaceBar(
              collapseMode: CollapseMode.parallax,
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF121212), Color(0xFF1E1E1E), Color(0xFF7F1D1D)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        const Row(
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: KevsBrandLockup(height: 48),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),

                        // Live Queue Tracker Pill
                        GestureDetector(
                          onTap: widget.onGoToQueue,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 7),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: const Color(0xFFDC2626).withValues(alpha: 0.4),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFF00E676),
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: Color(0xFF00E676),
                                        blurRadius: 6,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  shop.queueStatus != null &&
                                          shop.queueStatus!.hasActive &&
                                          shop.queueStatus!.nowServing > 0
                                      ? 'Now Serving: #${shop.queueStatus!.nowServing}  •  Tap to track'
                                      : 'Queue Open  •  Ready for orders',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                const Icon(
                                  Icons.arrow_forward_ios_rounded,
                                  size: 11,
                                  color: Colors.white70,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            actions: [
              IconButton(
                icon: Icon(
                  isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                  color: isDark ? Colors.amber.shade300 : Colors.white,
                ),
                tooltip: isDark ? 'Switch to Light Mode' : 'Switch to Dark Mode',
                onPressed: () => shop.toggleTheme(),
              ),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, color: Colors.white),
                tooltip: 'Refresh Menu',
                onPressed: () => shop.loadProducts(),
              ),
              if (shop.cartCount > 0)
                Stack(
                  alignment: Alignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.shopping_cart_outlined,
                          color: Colors.white),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const CartScreen()),
                      ),
                    ),
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Color(0xFFDC2626),
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '${shop.cartCount}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),

          // ── Offline Warning Banner ──
          if (shop.isOffline || shop.pendingOfflineOrders.isNotEmpty)
            SliverToBoxAdapter(
              child: Container(
                color: const Color(0xFFFFF3CD),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.wifi_off_rounded,
                        color: Color(0xFF856404), size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        shop.pendingOfflineOrders.isNotEmpty
                            ? '${shop.pendingOfflineOrders.length} order(s) saved offline — syncing when reconnected'
                            : 'Offline Mode: Showing cached menu',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF856404),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (shop.pendingOfflineOrders.isNotEmpty)
                      TextButton(
                        onPressed: () async {
                          final synced = await shop.syncOfflineOrders();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text('Synced $synced order(s)!'),
                            ));
                          }
                        },
                        child: const Text('Sync Now',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                  ],
                ),
              ),
            ),

          // ── Modern Search Bar ──
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
              child: Container(
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.06),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                  border: Border.all(color: cardBorder),
                ),
                child: TextField(
                  controller: _searchController,
                  style: TextStyle(color: textPrimary),
                  onChanged: (val) => setState(() => _searchQuery = val),
                  decoration: InputDecoration(
                    hintText: 'Search siomai, drinks, sauces...',
                    hintStyle: TextStyle(
                      color: textHint,
                      fontSize: 13.5,
                    ),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      color: Color(0xFFDC2626),
                      size: 20,
                    ),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 18),
                            color: textSecondary,
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                ),
              ),
            ),
          ),

          // ── Category Section Header & Count ──
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Our Menu',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      color: textPrimary,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: cardBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: cardBorder),
                    ),
                    child: Text(
                      '${filteredProducts.length} items',
                      style: TextStyle(
                        fontSize: 12,
                        color: textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Category Filter Chips ──
          SliverToBoxAdapter(
            child: SizedBox(
              height: 42,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: shop.categories.length,
                separatorBuilder: (context, index) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final cat = shop.categories[index];
                  final isSelected = shop.selectedCategory.toLowerCase() ==
                      cat.toLowerCase();
                  return GestureDetector(
                    onTap: () => shop.setCategory(cat),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFFDC2626)
                            : cardBg,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: isSelected
                              ? const Color(0xFFDC2626)
                              : cardBorder,
                        ),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: const Color(0xFFDC2626)
                                      .withValues(alpha: 0.35),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ]
                            : null,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _getCategoryIcon(cat),
                            size: 15,
                            color: isSelected ? Colors.white : const Color(0xFFDC2626),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _getCategoryLabel(cat),
                            style: TextStyle(
                              color: isSelected
                                  ? Colors.white
                                  : (isDark ? Colors.white.withValues(alpha: 0.85) : const Color(0xFF262626)),
                              fontWeight: isSelected
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 14)),

          // ── Products Grid or States ──
          if (shop.isLoading)
            const SliverFillRemaining(
              child: Center(
                child: CircularProgressIndicator(color: Color(0xFFDC2626)),
              ),
            )
          else if (filteredProducts.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _searchQuery.isNotEmpty
                          ? Icons.search_off_rounded
                          : Icons.no_meals_outlined,
                      size: 60,
                      color: isDark ? Colors.white24 : Colors.black26,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _searchQuery.isNotEmpty
                          ? 'No items match "$_searchQuery"'
                          : 'No menu items available',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _searchQuery.isNotEmpty
                          ? 'Try searching for something else'
                          : (shop.isOffline
                              ? 'Cannot connect to server'
                              : 'Tap refresh above to reload'),
                      style: TextStyle(
                        fontSize: 13,
                        color: textSecondary,
                      ),
                    ),
                    if (_searchQuery.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      TextButton.icon(
                        icon: const Icon(Icons.clear_rounded, size: 16, color: Color(0xFFDC2626)),
                        label: const Text('Clear search', style: TextStyle(color: Color(0xFFDC2626))),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      ),
                    ],
                  ],
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                  horizontalPadding, 0, horizontalPadding, shop.cartCount > 0 ? 94 : 20),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, rowIndex) {
                    final startIndex = rowIndex * crossAxisCount;
                    final rowChildren = <Widget>[];
                    for (int col = 0; col < crossAxisCount; col++) {
                      if (col > 0) {
                        rowChildren.add(const SizedBox(width: 12));
                      }
                      final itemIndex = startIndex + col;
                      if (itemIndex < filteredProducts.length) {
                        rowChildren.add(
                          Expanded(
                            child: ProductCard(product: filteredProducts[itemIndex]),
                          ),
                        );
                      } else {
                        rowChildren.add(const Expanded(child: SizedBox.shrink()));
                      }
                    }
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: rowChildren,
                        ),
                      ),
                    );
                  },
                  childCount: (filteredProducts.length / crossAxisCount).ceil(),
                ),
              ),
            ),
        ],
      ),

      // ── Modern Floating Bottom Cart Summary Bar ──
      bottomSheet: shop.cartCount > 0
          ? Container(
              decoration: BoxDecoration(
                color: cardBg,
                border: const Border(
                  top: BorderSide(color: Color(0xFFDC2626), width: 2),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.12),
                    blurRadius: 16,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: SafeArea(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Row(
                    children: [
                      // Cart badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFDC2626).withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFDC2626).withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.shopping_bag_outlined,
                                color: Color(0xFFDC2626), size: 17),
                            const SizedBox(width: 6),
                            Text(
                              '${shop.cartCount} item${shop.cartCount > 1 ? 's' : ''}',
                              style: TextStyle(
                                color: textPrimary,
                                fontWeight: FontWeight.w800,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),

                      // Total Price
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'ORDER TOTAL',
                            style: TextStyle(
                              color: textSecondary,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                          Text(
                            '₱${shop.cartTotal.toStringAsFixed(2)}',
                            style: TextStyle(
                              color: textPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 14),

                      // Checkout button
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFDC2626),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 2,
                        ),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const CartScreen()),
                        ),
                        child: const Row(
                          children: [
                            Text(
                              'Checkout',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 14,
                              ),
                            ),
                            SizedBox(width: 4),
                            Icon(Icons.arrow_forward_rounded, size: 16),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : null,
    );
  }
}
