import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/product.dart';
import '../models/payment_account.dart';
import '../providers/shop_provider.dart';
import '../services/offline_service.dart';
import '../widgets/gcash_qr_dialog.dart';
import '../widgets/unit_quantity_selector.dart';
import '../widgets/kevs_logo.dart';

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _addressController = TextEditingController();
  final _notesController = TextEditingController();

  String _orderType = 'pickup'; // 'pickup' or 'delivery'
  String _paymentMethod = 'GCash'; // 'GCash' or 'Cash'
  String? _selectedPaymentAccountId;
  bool _isSubmitting = false;

  String _selectedGatidSitio = 'Batisan (Near Boss KEVS)';
  final List<String> _gatidSitios = [
    'Batisan (Near Boss KEVS)',
    'National Highway, Gatid',
    'Sitio Ilaya, Gatid',
    'Sitio Ibaba, Gatid',
    'Sitio Maligaya, Gatid',
    'Gatid Elementary School Vicinity',
    'Other Area in Brgy. Gatid',
  ];

  String _buildFullDeliveryAddress() {
    final street = _addressController.text.trim();
    if (street.isEmpty) return '';
    return '$street, $_selectedGatidSitio, Brgy. Gatid, Santa Cruz, Laguna';
  }

  bool _isAddressInGatid(String addr) {
    if (_orderType != 'delivery') return true;
    final lower = addr.toLowerCase();
    return lower.contains('gatid') || lower.contains('batisan');
  }

  void _showOutsideDeliveryDialog() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dialogBg = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final textPrimary = isDark ? Colors.white : const Color(0xFF171717);
    final textSecondary = isDark ? Colors.white70 : const Color(0xFF525252);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: dialogBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.location_off_rounded, color: Color(0xFFDC2626)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Outside Delivery Area',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: textPrimary),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Paumanhin, ang Boss KEVS delivery ay para lamang sa Barangay Gatid, Santa Cruz, Laguna.',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: textPrimary),
            ),
            const SizedBox(height: 8),
            Text(
              'Kapag wala sa Gatid ang iyong address, hindi po makakapag-deliver ang aming rider. Mangyaring lumipat sa "Store Pickup" upang maihanda ang iyong order sa tindahan (070 Batisan, Gatid, Santa Cruz, Laguna).',
              style: TextStyle(fontSize: 12.5, color: textSecondary, height: 1.3),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('I-edit ang Address', style: TextStyle(color: textSecondary)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.storefront_rounded, size: 16),
            label: const Text('Lumipat sa Store Pickup'),
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _orderType = 'pickup');
            },
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadProfile();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<ShopProvider>().refreshPaymentAccounts(silent: true);
      }
    });
  }

  Future<void> _loadProfile() async {
    final profile = await OfflineService.getCustomerProfile();
    if (mounted) {
      setState(() {
        if (profile['name']?.isNotEmpty ?? false) {
          _nameController.text = profile['name']!;
        }
        if (profile['phone']?.isNotEmpty ?? false) {
          _phoneController.text = profile['phone']!;
        }
        if (profile['address']?.isNotEmpty ?? false) {
          _addressController.text = profile['address']!;
        }
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _addressController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _handleCheckout(ShopProvider shop) async {
    if (shop.cart.isEmpty) return;
    if (!_formKey.currentState!.validate()) return;

    // Requirement 3 & 6: Validate add-on restrictions before checkout
    final addonViolations = shop.getAddonViolations();
    if (addonViolations.isNotEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: const [
              Icon(Icons.warning_amber_rounded, color: Color(0xFFF97316)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Adjust Add-on Quantities',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Ang iyong add-on selections ay lumagpas sa limitasyon para sa ${shop.totalSiomaiCount} pcs HotSpot Siomai:',
                style: const TextStyle(fontSize: 13.5, color: Colors.white),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF2B1212),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF7F1D1D)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: addonViolations.map((v) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text('• $v', style: const TextStyle(fontSize: 12.5, color: Color(0xFFFCA5A5), fontWeight: FontWeight.w600)),
                  )).toList(),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Mangyaring i-adjust ang dami ng iyong add-ons bago mag-checkout.',
                style: TextStyle(fontSize: 12.5, color: Colors.white70),
              ),
            ],
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF97316),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('I-adjust ang Quantities', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
      return;
    }

    final fullDeliveryAddress = _orderType == 'delivery' ? _buildFullDeliveryAddress() : '';

    if (_orderType == 'delivery' && !_isAddressInGatid(fullDeliveryAddress)) {
      _showOutsideDeliveryDialog();
      return;
    }

    PaymentAccount? selectedAcct;
    if (_paymentMethod == 'GCash') {
      final avail = shop.availablePaymentAccounts;
      if (avail.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Online payment is temporarily unavailable. Please select Cash (Counter / COD).'),
            backgroundColor: Color(0xFFDC2626),
          ),
        );
        return;
      }
      if (_selectedPaymentAccountId != null && _selectedPaymentAccountId!.isNotEmpty) {
        final candidate = shop.findAccountById(_selectedPaymentAccountId);
        if (candidate == null || !candidate.isAvailable) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Your previously selected payment account is no longer available. Please select another available receiving account.'),
              backgroundColor: Color(0xFFDC2626),
            ),
          );
          setState(() => _selectedPaymentAccountId = null);
          return;
        }
        selectedAcct = candidate;
      } else {
        selectedAcct = avail.first;
      }
    }

    setState(() => _isSubmitting = true);

    final order = await shop.submitOrder(
      customerName: _nameController.text.trim(),
      customerPhone: _phoneController.text.trim(),
      orderType: _orderType,
      deliveryAddress: fullDeliveryAddress,
      paymentMethod: _paymentMethod,
      notes: _notesController.text.trim(),
      paymentAccountId: selectedAcct?.accountId,
      paymentAccountName: selectedAcct?.accountName,
      paymentProvider: selectedAcct?.provider,
    );

    setState(() => _isSubmitting = false);

    if (!mounted) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dialogBg = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final textPrimary = isDark ? Colors.white : const Color(0xFF171717);
    final textSecondary = isDark ? Colors.white70 : const Color(0xFF525252);

    if (order != null) {
      if (order.paymentMethod == 'GCash') {
        // Automatically display GCash QR code for the selected account
        await GCashQRDialog.show(
          context,
          order: order,
          totalAmount: order.totalAmount,
          initialAccountId: order.paymentAccountId ?? selectedAcct?.accountId,
        );
        if (!mounted) return;
        Navigator.pop(context); // Back to catalog
      } else {
        // Order placed successfully on backend (Cash)
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            backgroundColor: dialogBg,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                const Icon(Icons.check_circle, color: Color(0xFF10B981)),
                const SizedBox(width: 8),
                Text('Order Placed!', style: TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  order.hasValidTicket
                      ? 'Your Queue Ticket: #${order.queueNo}'
                      : 'Queue Ticket: Pending Assignment',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFDC2626)),
                ),
                if (order.formattedDate.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Placed: ${order.formattedDate}',
                    style: TextStyle(fontSize: 12, color: textSecondary),
                  ),
                ],
                const SizedBox(height: 8),
                Text('Order Type: ${order.orderType.toUpperCase()}', style: TextStyle(color: textSecondary)),
                if (order.orderType == 'delivery' && order.deliveryAddress.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: Text(
                      'Delivery to: ${order.deliveryAddress}',
                      style: TextStyle(fontSize: 12, color: textSecondary),
                    ),
                  ),
                Text('Payment: ${order.paymentMethod} (${order.paymentStatus})', style: TextStyle(color: textSecondary)),
                Text('Total: ₱${order.totalAmount.toStringAsFixed(2)}', style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary)),
                const SizedBox(height: 12),
                Text(
                  'Your order has been sent to Boss KEVS and added to the live unified queue.',
                  style: TextStyle(fontSize: 13, color: textSecondary),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.pop(context); // Back to catalog
                },
                child: const Text('View Status in Queue', style: TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      }
    } else if (shop.errorMessage != null && shop.errorMessage!.isNotEmpty) {
      // Backend returned specific validation error (e.g. delivery restriction)
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: dialogBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Color(0xFFDC2626)),
              const SizedBox(width: 8),
              Text('Paunawa sa Order', style: TextStyle(color: textPrimary)),
            ],
          ),
          content: Text(shop.errorMessage!, style: TextStyle(color: textSecondary)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('OK', style: TextStyle(color: textPrimary)),
            ),
            if (_orderType == 'delivery')
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFDC2626),
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.storefront_rounded, size: 16),
                label: const Text('Lumipat sa Store Pickup'),
                onPressed: () {
                  Navigator.pop(ctx);
                  setState(() => _orderType = 'pickup');
                },
              ),
          ],
        ),
      );
    } else {
      // Check if saved offline
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: dialogBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.cloud_off, color: Colors.amber.shade800),
              const SizedBox(width: 8),
              Text('Saved Offline', style: TextStyle(color: textPrimary)),
            ],
          ),
          content: Text(
            'Cannot reach server. Your order has been saved offline on your device and will automatically sync once connectivity is restored.',
            style: TextStyle(color: textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.pop(context);
              },
              child: const Text('OK', style: TextStyle(color: Color(0xFFDC2626))),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final shop = context.watch<ShopProvider>();
    final items = shop.cart.values.toList();
    final deliveryFee = _orderType == 'delivery' ? 30.0 : 0.0;
    final grandTotal = shop.cartTotal + deliveryFee;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark ? Colors.white : const Color(0xFF171717);
    final textSecondary = isDark ? Colors.white60 : const Color(0xFF525252);
    final dividerCol = isDark ? const Color(0xFF2E2E2E) : const Color(0xFFE5E5E5);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Row(
          children: const [
            KevsLogo(size: 26),
            SizedBox(width: 8),
            Text('Checkout & Cart'),
          ],
        ),
        actions: [
          if (items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear Cart',
              onPressed: () => shop.clearCart(),
            ),
        ],
      ),
      body: items.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.shopping_cart_outlined, size: 70, color: isDark ? Colors.white30 : Colors.black26),
                  const SizedBox(height: 12),
                  Text('Your cart is empty', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textPrimary)),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Explore Menu'),
                  ),
                ],
              ),
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                  // ── Items List Card ──
                  Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Order Items',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: textPrimary),
                          ),
                          Divider(color: dividerCol),
                          ...items.map((it) {
                            final product = shop.products.firstWhere(
                              (p) => p.id == it.productId,
                              orElse: () => Product(
                                id: it.productId,
                                name: it.productName,
                                category: '',
                                price: it.unitPrice,
                                stock: 99,
                                maxStock: 100,
                                unit: 'pcs',
                                description: '',
                                imageUrl: '',
                              ),
                            );
                            final addonType = ShopProvider.getAddonType(product);
                            final effectiveMax = shop.getProductMaxLimit(product);
                            final maxAddonQty = addonType != null ? shop.getMaxAddonQuantity(product) : null;
                            final isOverLimit = addonType != null && it.quantity > maxAddonQty!;
                            final addonUnit = addonType != null ? ShopProvider.getAddonUnit(addonType) : product.unit;

                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Wrap(
                                              spacing: 6,
                                              runSpacing: 4,
                                              crossAxisAlignment: WrapCrossAlignment.center,
                                              children: [
                                                Text(
                                                  it.productName,
                                                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, color: textPrimary),
                                                ),
                                                if (addonType != null)
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
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
                                                        fontSize: 10.5,
                                                        fontWeight: FontWeight.bold,
                                                        color: maxAddonQty == 0
                                                            ? (isDark ? const Color(0xFFF87171) : const Color(0xFFDC2626))
                                                            : (isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8)),
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              addonType != null
                                                  ? '₱${it.unitPrice.toStringAsFixed(2)} / $addonUnit'
                                                  : '₱${it.unitPrice.toStringAsFixed(2)} / ${product.unit} • Max: ${product.stock} ${product.unit}',
                                              style: TextStyle(fontSize: 12, color: textSecondary),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      UnitQuantitySelector(
                                        quantity: it.quantity,
                                        maxStock: effectiveMax,
                                        unit: addonType != null ? addonUnit : product.unit,
                                        isCompact: true,
                                        onChanged: (newQ) {
                                          shop.setItemQuantity(it.productId, newQ);
                                        },
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        '₱${it.subtotal.toStringAsFixed(2)}',
                                        style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFFDC2626), fontSize: 15),
                                      ),
                                    ],
                                  ),
                                  if (isOverLimit) ...[
                                    const SizedBox(height: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: const Color(0x22EF4444),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: const Color(0x66EF4444)),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.warning_rounded, size: 14, color: Color(0xFFEF4444)),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              shop.totalSiomaiCount == 0
                                                  ? 'Requires at least 1 Siomai (Max: 0 $addonUnit). Please reduce to 0.'
                                                  : 'Exceeds limit of $maxAddonQty $addonUnit for ${shop.totalSiomaiCount} Siomai pcs! Please reduce.',
                                              style: const TextStyle(fontSize: 11, color: Color(0xFFFCA5A5), fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Fulfillment Type ──
                  Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Fulfillment Option', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: textPrimary)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: ChoiceChip(
                                  avatar: Icon(Icons.storefront, size: 18, color: _orderType == 'pickup' ? Colors.white : textSecondary),
                                  label: const Center(child: Text('Store Pickup')),
                                  selected: _orderType == 'pickup',
                                  selectedColor: const Color(0xFFDC2626),
                                  labelStyle: TextStyle(
                                    color: _orderType == 'pickup' ? Colors.white : textPrimary,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  onSelected: (val) {
                                    if (val) setState(() => _orderType = 'pickup');
                                  },
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: ChoiceChip(
                                  avatar: Icon(Icons.delivery_dining, size: 18, color: _orderType == 'delivery' ? Colors.white : textSecondary),
                                  label: const Center(child: Text('Delivery (+₱30)')),
                                  selected: _orderType == 'delivery',
                                  selectedColor: const Color(0xFFDC2626),
                                  labelStyle: TextStyle(
                                    color: _orderType == 'delivery' ? Colors.white : textPrimary,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  onSelected: (val) {
                                    if (val) setState(() => _orderType = 'delivery');
                                  },
                                ),
                              ),
                            ],
                          ),
                          if (_orderType == 'delivery') ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF2B1212) : const Color(0xFFFEF2F2),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: isDark ? const Color(0xFF7F1D1D) : const Color(0xFFFCA5A5)),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(Icons.location_on, size: 18, color: Color(0xFFDC2626)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Delivery Area: Eksklusibo lamang sa Barangay Gatid, Santa Cruz, Laguna ang aming delivery. Kapag nasa labas ng Gatid, mangyaring piliin ang Store Pickup.',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFF991B1B),
                                        height: 1.3,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Customer Details ──
                  Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Customer Information', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: textPrimary)),
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: _nameController,
                            style: TextStyle(color: textPrimary),
                            decoration: const InputDecoration(
                              labelText: 'Your Name *',
                              prefixIcon: Icon(Icons.person_outline),
                            ),
                            validator: (val) {
                              if (val == null || val.trim().isEmpty) return 'Kailangan ilagay ang iyong pangalan (Name required)';
                              final trimmed = val.trim();
                              if (trimmed.length < 2 || trimmed.length > 60) {
                                return 'Ang pangalan ay dapat nasa pagitan ng 2 hanggang 60 characters';
                              }
                              // Reject 3 or more consecutive identical letters (e.g. 'jammmm', 'aaaa', 'Johnnnn')
                              if (RegExp(r'([a-zA-Z\u00C0-\u024F\u1E00-\u1EFF])\1{2,}', caseSensitive: false).hasMatch(trimmed)) {
                                return 'Hindi wastong pangalan: Huwag gumamit ng paulit-ulit na mga titik tulad ng "$trimmed"';
                              }
                              // Cannot start or end with hyphen, apostrophe, or space
                              if (RegExp(r"^[-'\s]|[-'\s]$").hasMatch(trimmed)) {
                                return 'Ang pangalan ay hindi maaaring magsimula o magtapos sa gitling, kudlit, o espasyo';
                              }
                              // Cannot have consecutive punctuation or multiple consecutive spaces
                              if (RegExp(r"[\'\-\.]{2,}").hasMatch(trimmed) || RegExp(r"\s{2,}").hasMatch(trimmed)) {
                                return 'Ang pangalan ay hindi maaaring magkaroon ng sunod-sunod na bantas o espasyo';
                              }
                              // Allowed characters: Latin and accented letters, spaces, hyphens, periods, apostrophes
                              if (!RegExp(r"^[a-zA-Z\u00C0-\u024F\u1E00-\u1EFF\s.'-]+$").hasMatch(trimmed)) {
                                return 'Ang pangalan ay maaari lamang maglaman ng mga titik, espasyo, gitling (-), tuldok (.), o kudlit (\')';
                              }
                              // Must contain at least 2 alphabetic letters
                              final letterCount = RegExp(r'[a-zA-Z\u00C0-\u024F\u1E00-\u1EFF]').allMatches(trimmed).length;
                              if (letterCount < 2) {
                                return 'Ang pangalan ay dapat maglaman ng hindi bababa sa 2 letra';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: _phoneController,
                            keyboardType: TextInputType.phone,
                            style: TextStyle(color: textPrimary),
                            decoration: const InputDecoration(
                              labelText: 'Phone Number (e.g. 09171234567) *',
                              prefixIcon: Icon(Icons.phone_outlined),
                            ),
                            validator: (val) {
                              if (val == null || val.trim().isEmpty) return 'Kailangan ilagay ang contact number (Phone required)';
                              final cleaned = val.trim().replaceAll(RegExp(r'[\s\-\(\)\.]'), '');
                              if (!RegExp(r'^\d+$').hasMatch(cleaned)) {
                                return 'Ang numero ng telepono ay dapat mga numero lamang';
                              }
                              if (RegExp(r'^(\d)\1+$').hasMatch(cleaned)) {
                                return 'Hindi wastong contact number: hindi maaaring pare-parehong digit';
                              }
                              if (!RegExp(r'^(\+639\d{9}|09\d{9}|9\d{9})$').hasMatch(cleaned) &&
                                  !(cleaned.length >= 7 && cleaned.length <= 13)) {
                                return 'Hindi wastong format ng telepono (Hal. 09XXXXXXXXX o +639XXXXXXXXX)';
                              }
                              return null;
                            },
                          ),
                          if (_orderType == 'delivery') ...[
                            const SizedBox(height: 12),
                            // Zone / Sitio Selector in Gatid
                            DropdownButtonFormField<String>(
                              initialValue: _selectedGatidSitio,
                              decoration: const InputDecoration(
                                labelText: 'Sitio / Zone sa Brgy. Gatid *',
                                prefixIcon: Icon(Icons.map_outlined),
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                              ),
                              items: _gatidSitios.map((sitio) {
                                return DropdownMenuItem(
                                  value: sitio,
                                  child: Text(sitio, style: const TextStyle(fontSize: 13.5)),
                                );
                              }).toList(),
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() => _selectedGatidSitio = val);
                                }
                              },
                            ),
                            const SizedBox(height: 10),
                            TextFormField(
                              controller: _addressController,
                              maxLines: 2,
                              decoration: const InputDecoration(
                                labelText: 'House No., Street & Landmark (sa Gatid) *',
                                prefixIcon: Icon(Icons.home_outlined),
                                border: OutlineInputBorder(),
                                hintText: 'Hal. House #070, Batisan, malapit sa Chapel',
                              ),
                              validator: (val) {
                                if (_orderType != 'delivery') return null;
                                if (val == null || val.trim().isEmpty) {
                                  return 'Address required for delivery';
                                }
                                final lower = val.toLowerCase();
                                final outsideKeywords = [
                                  'pagsanjan', 'pila', 'victoria', 'calamba', 'los banos', 'san pablo',
                                  'bubukal', 'bagumbayan', 'pagsawitan', 'calios', 'santisima cruz',
                                  'san jose', 'alipit', 'palasan', 'duhat', 'labuin', 'patimbao', 'manila'
                                ];
                                for (final out in outsideKeywords) {
                                  if (lower.contains(out) && !lower.contains('gatid')) {
                                    return 'Hindi sakop ang $out. Available lamang sa loob ng Brgy. Gatid!';
                                  }
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                const Icon(Icons.check_circle_rounded, size: 14, color: Colors.green),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    'Delivery to: Brgy. Gatid, Santa Cruz, Laguna (+₱30.00)',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.grey.shade700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: _notesController,
                            decoration: const InputDecoration(
                              labelText: 'Special Requests / Notes (Optional)',
                              prefixIcon: Icon(Icons.note_alt_outlined),
                              border: OutlineInputBorder(),
                              hintText: 'e.g. extra chili sauce, no calamansi',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Payment Method ──
                  Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Payment Method', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          InkWell(
                            onTap: () => setState(() => _paymentMethod = 'GCash'),
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: _paymentMethod == 'GCash' ? const Color(0xFF007DFE).withValues(alpha: 0.08) : Colors.transparent,
                                border: Border.all(
                                  color: _paymentMethod == 'GCash' ? const Color(0xFF007DFE) : Colors.grey.shade300,
                                  width: _paymentMethod == 'GCash' ? 2 : 1,
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF007DFE),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Text(
                                      'GCash',
                                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  const Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('GCash Digital e-Wallet', style: TextStyle(fontWeight: FontWeight.bold)),
                                        Text('Fast & contactless confirmation', style: TextStyle(fontSize: 12, color: Colors.grey)),
                                      ],
                                    ),
                                  ),
                                  if (_paymentMethod == 'GCash')
                                    const Icon(Icons.check_circle, color: Color(0xFF007DFE))
                                  else
                                    Icon(Icons.circle_outlined, color: Colors.grey.shade400),
                                ],
                              ),
                            ),
                          ),
                          if (_paymentMethod == 'GCash')
                            Builder(
                              builder: (context) {
                                final availAccounts = shop.availablePaymentAccounts;
                                PaymentAccount? selectedAcct;
                                bool selectedBecameUnavailable = false;
                                if (_selectedPaymentAccountId != null && _selectedPaymentAccountId!.isNotEmpty) {
                                  final candidate = shop.findAccountById(_selectedPaymentAccountId);
                                  if (candidate != null && candidate.isAvailable) {
                                    selectedAcct = candidate;
                                  } else {
                                    selectedBecameUnavailable = true;
                                  }
                                }
                                if (selectedAcct == null && !selectedBecameUnavailable && availAccounts.isNotEmpty) {
                                  selectedAcct = availAccounts.first;
                                }

                                if (availAccounts.isEmpty) {
                                  return Container(
                                    margin: const EdgeInsets.only(top: 8, bottom: 4),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: isDark ? const Color(0xFF2B1212) : const Color(0xFFFEF2F2),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: const Color(0xFFEF4444)),
                                    ),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Icon(Icons.error_outline_rounded, color: Color(0xFFEF4444), size: 22),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                'Online Payment Temporarily Unavailable',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                  fontSize: 13,
                                                  color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFF991B1B),
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                'All receiving online payment accounts have reached their transaction limits or are currently inactive. Please select Cash (Counter / COD) below.',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: isDark ? Colors.white70 : const Color(0xFF7F1D1D),
                                                  height: 1.35,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }

                                return Container(
                                  margin: const EdgeInsets.only(top: 8, bottom: 4),
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF007DFE).withValues(alpha: 0.05),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: const Color(0xFF007DFE).withValues(alpha: 0.25)),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (selectedBecameUnavailable)
                                        Container(
                                          width: double.infinity,
                                          padding: const EdgeInsets.all(10),
                                          margin: const EdgeInsets.only(bottom: 10),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFFEF2F2),
                                            borderRadius: BorderRadius.circular(10),
                                            border: Border.all(color: const Color(0xFFEF4444)),
                                          ),
                                          child: const Row(
                                            children: [
                                              Icon(Icons.warning_amber_rounded, color: Color(0xFFDC2626), size: 18),
                                              SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  'Your previously selected account became unavailable. Please select another available receiving account below.',
                                                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Color(0xFF991B1B)),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      Row(
                                        children: [
                                          const Icon(Icons.account_balance_wallet_outlined, color: Color(0xFF007DFE), size: 18),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              'Select Receiving Account (${availAccounts.length} Available)',
                                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: Color(0xFF0056B3)),
                                            ),
                                          ),
                                          if (selectedAcct != null)
                                            InkWell(
                                              onTap: () => GCashQRDialog.show(
                                                context,
                                                totalAmount: grandTotal,
                                                initialAccountId: selectedAcct!.accountId,
                                                onAccountSelected: (acct) {
                                                  setState(() => _selectedPaymentAccountId = acct.accountId);
                                                },
                                              ),
                                              child: const Padding(
                                                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                child: Text(
                                                  'Tap to Zoom QR',
                                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF007DFE)),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      ...availAccounts.map((acct) {
                                        final isSelected = selectedAcct?.accountId == acct.accountId;
                                        return Padding(
                                          padding: const EdgeInsets.only(bottom: 6),
                                          child: InkWell(
                                            onTap: () => setState(() => _selectedPaymentAccountId = acct.accountId),
                                            borderRadius: BorderRadius.circular(10),
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                              decoration: BoxDecoration(
                                                color: isSelected
                                                    ? const Color(0xFF007DFE).withValues(alpha: 0.12)
                                                    : (isDark ? const Color(0xFF222222) : Colors.white),
                                                borderRadius: BorderRadius.circular(10),
                                                border: Border.all(
                                                  color: isSelected
                                                      ? const Color(0xFF007DFE)
                                                      : (isDark ? const Color(0xFF383838) : Colors.grey.shade300),
                                                  width: isSelected ? 1.8 : 1,
                                                ),
                                              ),
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                                                    color: isSelected ? const Color(0xFF007DFE) : textSecondary,
                                                    size: 18,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment: CrossAxisAlignment.start,
                                                      children: [
                                                        Row(
                                                          children: [
                                                            Expanded(
                                                              child: Text(
                                                                acct.accountName,
                                                                style: TextStyle(
                                                                  fontWeight: FontWeight.w800,
                                                                  fontSize: 12.5,
                                                                  color: textPrimary,
                                                                ),
                                                              ),
                                                            ),
                                                            Container(
                                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                                              decoration: BoxDecoration(
                                                                color: const Color(0xFF007DFE),
                                                                borderRadius: BorderRadius.circular(5),
                                                              ),
                                                              child: Text(
                                                                acct.provider,
                                                                style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.bold),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                        const SizedBox(height: 2),
                                                        Text(
                                                          '${acct.accountHolderName} • ${acct.mobileNumber} (${acct.remainingLabel})',
                                                          style: TextStyle(fontSize: 11, color: textSecondary, fontWeight: FontWeight.w600),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        );
                                      }),
                                      if (selectedAcct != null) ...[
                                        const SizedBox(height: 6),
                                        InkWell(
                                          onTap: () => GCashQRDialog.show(
                                            context,
                                            totalAmount: grandTotal,
                                            initialAccountId: selectedAcct!.accountId,
                                            onAccountSelected: (acct) {
                                              setState(() => _selectedPaymentAccountId = acct.accountId);
                                            },
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.all(6),
                                            decoration: BoxDecoration(
                                              color: Colors.white,
                                              borderRadius: BorderRadius.circular(12),
                                              border: Border.all(color: Colors.grey.shade300),
                                            ),
                                            child: ClipRRect(
                                              borderRadius: BorderRadius.circular(8),
                                              child: GCashQRDialog.buildQrImageWidget(
                                                selectedAcct.qrImageUrl,
                                                height: 195,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Text('Receiver: ', style: TextStyle(fontSize: 11, color: textSecondary)),
                                            Flexible(
                                              child: Text(
                                                '${selectedAcct.accountHolderName} (${selectedAcct.mobileNumber}) • ${selectedAcct.provider}',
                                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: textPrimary),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                                );
                              },
                            ),
                          const SizedBox(height: 10),
                          InkWell(
                            onTap: () => setState(() => _paymentMethod = 'Cash'),
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: _paymentMethod == 'Cash' ? const Color(0xFFC62828).withValues(alpha: 0.08) : Colors.transparent,
                                border: Border.all(
                                  color: _paymentMethod == 'Cash' ? const Color(0xFFC62828) : Colors.grey.shade300,
                                  width: _paymentMethod == 'Cash' ? 2 : 1,
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFC62828),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Text(
                                      'Cash',
                                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  const Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('Cash (Counter / COD)', style: TextStyle(fontWeight: FontWeight.bold)),
                                        Text('Pay when you receive your siomai', style: TextStyle(fontSize: 12, color: Colors.grey)),
                                      ],
                                    ),
                                  ),
                                  if (_paymentMethod == 'Cash')
                                    const Icon(Icons.check_circle, color: Color(0xFFC62828))
                                  else
                                    Icon(Icons.circle_outlined, color: Colors.grey.shade400),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Total Summary & Checkout Button ──
                  Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(
                        color: isDark ? const Color(0xFF7F1D1D) : const Color(0xFFFECACA),
                      ),
                    ),
                    color: isDark ? const Color(0xFF261414) : Colors.red.shade50,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('Items Subtotal:', style: TextStyle(color: textPrimary)),
                              Text('₱${shop.cartTotal.toStringAsFixed(2)}', style: TextStyle(fontWeight: FontWeight.w600, color: textPrimary)),
                            ],
                          ),
                          if (_orderType == 'delivery') ...[
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Delivery Fee:', style: TextStyle(color: textPrimary)),
                                Text('₱${deliveryFee.toStringAsFixed(2)}', style: TextStyle(fontWeight: FontWeight.w600, color: textPrimary)),
                              ],
                            ),
                          ],
                          Divider(color: dividerCol),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Grand Total:',
                                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: textPrimary),
                              ),
                              Text(
                                '₱${grandTotal.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFFDC2626),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFC62828),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              icon: _isSubmitting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                    )
                                  : const Icon(Icons.check),
                              label: Text(
                                _isSubmitting
                                    ? 'Placing Order...'
                                    : 'Place Order • ₱${grandTotal.toStringAsFixed(2)}',
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                              ),
                              onPressed: _isSubmitting ? null : () => _handleCheckout(shop),
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
        ),
    );
  }
}
