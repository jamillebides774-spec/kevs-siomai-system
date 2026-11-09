import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/product.dart';
import '../providers/shop_provider.dart';
import 'unit_quantity_selector.dart';

class ProductCard extends StatelessWidget {
  final Product product;

  const ProductCard({super.key, required this.product});

  IconData _getCategoryIcon(String category) {
    final cat = category.toLowerCase();
    if (cat.contains('drink') || cat.contains('beverage')) {
      return Icons.local_drink_rounded;
    } else if (cat.contains('add') || cat.contains('sauce')) {
      return Icons.soup_kitchen_outlined;
    }
    return Icons.lunch_dining_rounded;
  }

  Color _getCategoryColor(String category) {
    final cat = category.toLowerCase();
    if (cat.contains('drink') || cat.contains('beverage')) return const Color(0xFF0288D1);
    if (cat.contains('add') || cat.contains('sauce') || cat.contains('condiment')) return const Color(0xFFE65100);
    return const Color(0xFFDC2626);
  }

  Widget _buildProductImage(Color catColor, bool isOut) {
    Widget fallbackIcon() => Container(
          color: catColor.withValues(alpha: 0.08),
          child: Center(
            child: Icon(
              _getCategoryIcon(product.category),
              size: 46,
              color: catColor.withValues(alpha: isOut ? 0.3 : 0.8),
            ),
          ),
        );

    // 1. Try local bundled asset first
    if (product.assetPath.isNotEmpty) {
      return Image.asset(
        product.assetPath,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (context, error, stackTrace) {
          // Fallback to online image if asset fails
          if (product.onlineFallbackUrl.isNotEmpty) {
            return Image.network(
              product.onlineFallbackUrl,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              errorBuilder: (context, error, stackTrace) => fallbackIcon(),
            );
          }
          return fallbackIcon();
        },
      );
    }

    // 2. Try network URL
    final netUrl = product.imageUrl.startsWith('http')
        ? product.imageUrl
        : (product.onlineFallbackUrl.isNotEmpty
            ? product.onlineFallbackUrl
            : '');

    if (netUrl.isNotEmpty) {
      return Image.network(
        netUrl,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return Container(
            color: const Color(0xFF1E1E1E),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: catColor,
                ),
              ),
            ),
          );
        },
        errorBuilder: (context, error, stackTrace) => fallbackIcon(),
      );
    }

    return fallbackIcon();
  }

  void _showProductDetails(BuildContext context) {
    final catColor = _getCategoryColor(product.category);
    final isOut = product.stock <= 0;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Consumer<ShopProvider>(
          builder: (ctx, shop, _) {
            final liveProduct = shop.findProductById(product.id) ?? product;
            final isProductInactive = !liveProduct.isActive;
            final isLiveOut = liveProduct.stock <= 0 || isProductInactive;
            final cartItem = shop.cart[product.id];
            final inCart = !isProductInactive && cartItem != null && cartItem.quantity > 0;
            final qty = inCart ? cartItem.quantity : 0;
            final addonType = ShopProvider.getAddonType(liveProduct);
            final maxAddonQty = addonType != null ? shop.getMaxAddonQuantity(liveProduct) : null;
            final addonUnit = addonType != null ? ShopProvider.getAddonUnit(addonType) : liveProduct.unit;
            final effectiveMax = shop.getProductMaxLimit(liveProduct);
            final isAddonCapped = addonType != null && qty >= (maxAddonQty ?? 0);

            final isDark = Theme.of(ctx).brightness == Brightness.dark;
            final sheetBg = isDark ? const Color(0xFF1E1E1E) : Colors.white;
            final sheetBorder = isDark ? const Color(0xFF333333) : const Color(0xFFE5E5E5);
            final textPrimary = isDark ? Colors.white : const Color(0xFF171717);
            final textSecondary = isDark ? Colors.white70 : const Color(0xFF525252);

            return Container(
              decoration: BoxDecoration(
                color: sheetBg,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                border: Border(
                  top: BorderSide(color: sheetBorder, width: 1),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white24 : Colors.black26,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      height: 180,
                      width: double.infinity,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _buildProductImage(catColor, isOut),
                          Positioned(
                            top: 10,
                            left: 10,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.75),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: Colors.white24, width: 0.5),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(_getCategoryIcon(product.category), size: 13, color: Colors.white),
                                  const SizedBox(width: 4),
                                  Text(
                                    product.category,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          product.name,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            color: textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '₱${product.price % 1 == 0 ? product.price.toInt() : product.price.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFFDC2626),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (product.description.isNotEmpty)
                    Text(
                      product.description,
                      style: TextStyle(
                        fontSize: 14,
                        color: textSecondary,
                        height: 1.4,
                      ),
                    ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isOut ? Icons.cancel_outlined : Icons.check_circle_outline,
                            size: 16,
                            color: isOut
                                ? const Color(0xFFEF4444)
                                : (product.isLowStock ? Colors.orange : const Color(0xFF10B981)),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isOut
                                ? 'Currently Out of Stock'
                                : '${product.stock} ${product.unit} available',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isOut
                                  ? const Color(0xFFEF4444)
                                  : (product.isLowStock
                                      ? Colors.orange.shade400
                                      : const Color(0xFF34D399)),
                            ),
                          ),
                        ],
                      ),
                      if (addonType != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: maxAddonQty == 0 ? const Color(0x33EF4444) : const Color(0x333B82F6),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: maxAddonQty == 0 ? const Color(0x80EF4444) : const Color(0x803B82F6),
                            ),
                          ),
                          child: Text(
                            'Max: $maxAddonQty $addonUnit',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: maxAddonQty == 0 ? const Color(0xFFF87171) : const Color(0xFF60A5FA),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (!isLiveOut)
                    Row(
                      children: [
                        if (inCart) ...[
                          UnitQuantitySelector(
                            quantity: qty,
                            maxStock: effectiveMax,
                            unit: addonType != null ? addonUnit : product.unit,
                            isCompact: false,
                            onChanged: (newQ) {
                              shop.setItemQuantity(product.id, newQ);
                            },
                          ),
                          const SizedBox(width: 12),
                        ],
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: (isAddonCapped && !inCart)
                                  ? const Color(0xFF333333)
                                  : const Color(0xFFDC2626),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              elevation: 2,
                            ),
                            icon: Icon(inCart
                                ? Icons.shopping_bag_outlined
                                : Icons.add_shopping_cart_rounded),
                            label: Text(
                              inCart
                                  ? 'In Order ($qty $addonUnit • ₱${(qty * product.price).toStringAsFixed(2)})'
                                  : (addonType != null && maxAddonQty == 0
                                      ? 'Requires Siomai First'
                                      : (isAddonCapped
                                          ? 'Max Limit Reached'
                                          : 'Add to Order • ₱${product.price % 1 == 0 ? product.price.toInt() : product.price.toStringAsFixed(2)}')),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            onPressed: () {
                              if (!inCart) {
                                if (addonType != null && (maxAddonQty == 0 || isAddonCapped)) {
                                  return;
                                }
                                shop.addToCart(product);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final shop = context.watch<ShopProvider>();
    final cartItem = shop.cart[product.id];
    final inCart = cartItem != null && cartItem.quantity > 0;
    final isOut = product.stock <= 0;
    final isLow = product.isLowStock;
    final catColor = _getCategoryColor(product.category);
    final addonType = ShopProvider.getAddonType(product);
    final maxAddonQty = addonType != null ? shop.getMaxAddonQuantity(product) : null;
    final addonUnit = addonType != null ? ShopProvider.getAddonUnit(addonType) : product.unit;
    final effectiveMax = shop.getProductMaxLimit(product);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final cardBorder = isDark ? const Color(0xFF2E2E2E) : const Color(0xFFE5E5E5);
    final titleColor = isOut
        ? (isDark ? Colors.white38 : Colors.black38)
        : (isDark ? Colors.white : const Color(0xFF171717));
    final stockTextColor = isOut
        ? (isDark ? Colors.white38 : Colors.black38)
        : (isLow
            ? (isDark ? Colors.orange.shade300 : Colors.orange.shade800)
            : (isDark ? Colors.white70 : const Color(0xFF525252)));

    return InkWell(
      onTap: () => _showProductDetails(context),
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(18),
          border: inCart
              ? Border.all(color: const Color(0xFFDC2626), width: 2)
              : Border.all(color: cardBorder, width: 1),
          boxShadow: [
            BoxShadow(
              color: inCart
                  ? const Color(0xFFDC2626).withValues(alpha: 0.18)
                  : Colors.black.withValues(alpha: isDark ? 0.35 : 0.06),
              blurRadius: inCart ? 12 : 6,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(17),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Product Image Header ──
              SizedBox(
                height: 110,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildProductImage(catColor, isOut),

                    // Subtle bottom gradient shadow over image
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      height: 40,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.5),
                            ],
                          ),
                        ),
                      ),
                    ),

                    // Category Pill top-left
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.25),
                            width: 0.5,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_getCategoryIcon(product.category), size: 11, color: Colors.white),
                            const SizedBox(width: 3),
                            Text(
                              product.category,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Sold out overlay
                    if (isOut)
                      Container(
                        color: Colors.black.withValues(alpha: 0.7),
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFFDC2626),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              'SOLD OUT',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ),
                        ),
                      )
                    else if (isLow)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.orange.shade800,
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.25),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                          child: const Text(
                            'LOW STOCK',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),

                    // In-Cart Badge bottom-right of image
                    if (inCart)
                      Positioned(
                        bottom: 6,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFFDC2626),
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.3),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                          child: Text(
                            '${cartItem.quantity} ${product.unit} in cart',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // ── Product Details Body (auto-adjusting height, no clipped text) ──
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.max,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Product Title (up to 2 lines so full name is visible)
                          Text(
                            product.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              height: 1.25,
                              fontWeight: FontWeight.w800,
                              color: titleColor,
                            ),
                          ),
                          const SizedBox(height: 4),

                          // Stock Pill & Unit
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isOut
                                      ? (isDark ? Colors.white24 : Colors.black26)
                                      : (isLow
                                          ? Colors.orange.shade400
                                          : const Color(0xFF10B981)),
                                ),
                              ),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  isOut
                                      ? 'Not available'
                                      : '${product.stock} ${product.unit} left',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: stockTextColor,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (addonType != null) ...[
                            const SizedBox(height: 5),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: maxAddonQty == 0 ? const Color(0x33EF4444) : const Color(0x333B82F6),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: maxAddonQty == 0 ? const Color(0x80EF4444) : const Color(0x803B82F6),
                                  width: 0.8,
                                ),
                              ),
                              child: Text(
                                'Max: $maxAddonQty $addonUnit',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: maxAddonQty == 0
                                      ? (isDark ? const Color(0xFFF87171) : const Color(0xFFDC2626))
                                      : (isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8)),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 10),

                      // Price & Action Button (responsive wrap so stepper never clips price)
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            '₱${product.price % 1 == 0 ? product.price.toInt() : product.price.toStringAsFixed(2)}',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                              color: isOut
                                  ? (isDark ? Colors.white38 : Colors.black38)
                                  : const Color(0xFFDC2626),
                            ),
                          ),

                          // Action: Unit-based Stepper or Add button
                          if (inCart)
                            UnitQuantitySelector(
                              quantity: cartItem.quantity,
                              maxStock: effectiveMax,
                              unit: addonType != null ? addonUnit : product.unit,
                              isCompact: true,
                              onChanged: (newQ) => shop.setItemQuantity(product.id, newQ),
                            )
                          else
                            Builder(builder: (ctx) {
                              final bool isAddonBlocked = addonType != null && (maxAddonQty == 0 || (cartItem?.quantity ?? 0) >= (maxAddonQty ?? 0));
                              final bool isButtonDisabled = isOut || isAddonBlocked;
                              return GestureDetector(
                                onTap: isButtonDisabled ? null : () => shop.addToCart(product),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: isButtonDisabled
                                        ? (isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE5E5E5))
                                        : const Color(0xFFDC2626),
                                    shape: BoxShape.circle,
                                    boxShadow: isButtonDisabled
                                        ? null
                                        : [
                                            BoxShadow(
                                              color: const Color(0xFFDC2626)
                                                  .withValues(alpha: 0.35),
                                              blurRadius: 6,
                                              offset: const Offset(0, 2),
                                            ),
                                          ],
                                  ),
                                  child: Icon(
                                    Icons.add,
                                    size: 16,
                                    color: isButtonDisabled
                                        ? (isDark ? Colors.white24 : Colors.black38)
                                        : Colors.white,
                                  ),
                                ),
                              );
                            }),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
