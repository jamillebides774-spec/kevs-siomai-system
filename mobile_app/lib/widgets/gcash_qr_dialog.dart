import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/order.dart';
import '../models/payment_account.dart';
import '../providers/shop_provider.dart';

class GCashQRDialog extends StatefulWidget {
  final CustomerOrder? order;
  final double totalAmount;
  final String? initialAccountId;
  final ValueChanged<PaymentAccount>? onAccountSelected;
  final VoidCallback? onCompleted;

  const GCashQRDialog({
    super.key,
    this.order,
    required this.totalAmount,
    this.initialAccountId,
    this.onAccountSelected,
    this.onCompleted,
  });

  static Future<bool?> show(
    BuildContext context, {
    CustomerOrder? order,
    required double totalAmount,
    String? initialAccountId,
    ValueChanged<PaymentAccount>? onAccountSelected,
    VoidCallback? onCompleted,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) => GCashQRDialog(
        order: order,
        totalAmount: totalAmount,
        initialAccountId: initialAccountId,
        onAccountSelected: onAccountSelected,
        onCompleted: onCompleted,
      ),
    );
  }

  static Widget buildQrImageWidget(String qrUrl, {double height = 280}) {
    final trimmed = qrUrl.trim();
    if (trimmed.startsWith('data:image/')) {
      try {
        final commaIdx = trimmed.indexOf(',');
        if (commaIdx != -1) {
          final bytes = base64Decode(trimmed.substring(commaIdx + 1));
          return Image.memory(
            bytes,
            width: double.infinity,
            height: height,
            fit: BoxFit.contain,
          );
        }
      } catch (_) {}
    }

    String assetPath = 'assets/images/gcash_instapay_qr_1.jpg';
    if (trimmed.startsWith('/images/')) {
      assetPath = 'assets$trimmed';
    } else if (trimmed.startsWith('assets/')) {
      assetPath = trimmed;
    }

    return Image.asset(
      assetPath,
      width: double.infinity,
      height: height,
      fit: BoxFit.contain,
      errorBuilder: (ctx, err, stack) {
        final netUrl = trimmed.startsWith('http')
            ? trimmed
            : 'http://localhost:5000${trimmed.startsWith('/') ? trimmed : '/$trimmed'}';
        return Image.network(
          netUrl,
          width: double.infinity,
          height: height,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => Image.asset(
            'assets/images/gcash_instapay_qr_1.jpg',
            width: double.infinity,
            height: height,
            fit: BoxFit.contain,
          ),
        );
      },
    );
  }

  @override
  State<GCashQRDialog> createState() => _GCashQRDialogState();
}

class _GCashQRDialogState extends State<GCashQRDialog> {
  bool _isProcessing = false;
  bool _isSwitchingAccount = false;
  String? _selectedAccountId;

  @override
  void initState() {
    super.initState();
    _selectedAccountId = widget.order?.paymentAccountId ?? widget.initialAccountId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<ShopProvider>().refreshPaymentAccounts(silent: true);
      }
    });
  }

  Future<void> _handleSelectAccount(ShopProvider shop, PaymentAccount acct) async {
    if (!acct.isAvailable) return;
    setState(() {
      _selectedAccountId = acct.accountId;
    });
    widget.onAccountSelected?.call(acct);

    if (widget.order != null && !widget.order!.isPaid) {
      setState(() => _isSwitchingAccount = true);
      final updated = await shop.selectOrderPaymentAccount(widget.order!, acct.accountId);
      if (!mounted) return;
      setState(() => _isSwitchingAccount = false);
      if (updated != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Selected receiving account: ${acct.accountName} (${acct.accountHolderName})'),
            backgroundColor: const Color(0xFF007DFE),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _handleConfirmPayment(ShopProvider shop, PaymentAccount? selectedAccount) async {
    if (selectedAccount == null || !selectedAccount.isAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select an available payment account first.'),
          backgroundColor: Color(0xFFDC2626),
        ),
      );
      return;
    }

    if (widget.order == null) {
      widget.onAccountSelected?.call(selectedAccount);
      Navigator.pop(context, true);
      widget.onCompleted?.call();
      return;
    }

    setState(() => _isProcessing = true);
    final success = await shop.processGCashPayment(
      widget.order!,
      paymentAccountId: selectedAccount.accountId,
    );

    if (!mounted) return;
    setState(() => _isProcessing = false);

    Navigator.pop(context, success);
    widget.onCompleted?.call();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Payment details recorded for ${selectedAccount.accountName}. Status remains Pending Payment until confirmed by administrator.'
              : (shop.errorMessage ?? 'Could not record payment details. Please check account availability.'),
        ),
        backgroundColor: success ? const Color(0xFF007DFE) : const Color(0xFFDC2626),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shop = context.watch<ShopProvider>();
    final hasOrder = widget.order != null;
    final order = widget.order;
    final availableAccounts = shop.availablePaymentAccounts;

    // Check if the order had a sticky selected account that became unavailable
    final String? orderAcctId = order?.paymentAccountId;
    final PaymentAccount? orderOriginalAcct = shop.findAccountById(orderAcctId);
    final bool isStickyOrderAccountUnavailable = hasOrder &&
        order != null &&
        !order.isPaid &&
        orderAcctId != null &&
        orderAcctId.isNotEmpty &&
        (orderOriginalAcct == null || !orderOriginalAcct.isAvailable);

    // Determine which account to display
    PaymentAccount? activeAccount;
    if (_selectedAccountId != null && _selectedAccountId!.isNotEmpty) {
      final candidate = shop.findAccountById(_selectedAccountId);
      if (candidate != null && candidate.isAvailable) {
        activeAccount = candidate;
      }
    }
    // Only auto-pick the first available account when creating a new order (or when order had no account assigned yet).
    // CRITICAL RULE: If an existing order's selected account became unavailable, do NOT silently switch it — require the customer to tap an available account!
    if (activeAccount == null && !isStickyOrderAccountUnavailable && availableAccounts.isNotEmpty) {
      activeAccount = availableAccounts.first;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dialogBg = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final textPrimary = isDark ? Colors.white : Colors.black87;
    final textSecondary = isDark ? Colors.white70 : Colors.grey.shade600;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Container(
          decoration: BoxDecoration(
            color: dialogBg,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Blue Header Bar ──
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0xFF0056B3), Color(0xFF007DFE)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.qr_code_2, color: Colors.white, size: 24),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              activeAccount != null
                                  ? '${activeAccount.provider} QR Payment'
                                  : 'Online QR Payment',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Text(
                              'Select an available account & scan QR to pay',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.pop(context),
                        tooltip: 'Close',
                      ),
                    ],
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Amount To Pay Banner ──
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF007DFE).withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFF007DFE).withValues(alpha: 0.25)),
                        ),
                        child: Column(
                          children: [
                            const Text(
                              'TOTAL AMOUNT TO PAY',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                                color: Color(0xFF0056B3),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '₱${widget.totalAmount.toStringAsFixed(2)}',
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF007DFE),
                              ),
                            ),
                            if (hasOrder && order != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                '${order.ticketDisplay} • ${order.isPaid ? "Paid" : "Pending Payment"}',
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFFC62828),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      // ── Sticky Account Unavailable Warning (Requirement 2) ──
                      if (isStickyOrderAccountUnavailable && activeAccount == null) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF2F2),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFEF4444), width: 1.5),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.warning_amber_rounded, color: Color(0xFFDC2626), size: 22),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Selected Payment Account Unavailable',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 13,
                                        color: Color(0xFF991B1B),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Your previously selected account (${order.paymentAccountName ?? orderOriginalAcct?.accountName ?? orderAcctId}) is no longer available because it reached its transaction limit or was deactivated. Please select another available receiving account below to view its QR code.',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF7F1D1D),
                                        height: 1.35,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      // ── All Accounts Unavailable Banner ──
                      if (availableAccounts.isEmpty) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF2B1212) : const Color(0xFFFEF2F2),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFFEF4444)),
                          ),
                          child: Column(
                            children: [
                              const Icon(Icons.error_outline_rounded, color: Color(0xFFEF4444), size: 36),
                              const SizedBox(height: 8),
                              Text(
                                'Online Payment Temporarily Unavailable',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                  color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFF991B1B),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'All receiving online payment accounts have reached their transaction limits or are currently inactive. Please pay with Cash at the counter or wait for an administrator to enable an account.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: isDark ? Colors.white70 : const Color(0xFF7F1D1D),
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        // ── Available Receiving Accounts Selector ──
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Available Receiving Accounts (${availableAccounts.length})',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800,
                                color: textPrimary,
                              ),
                            ),
                            if (_isSwitchingAccount)
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF007DFE)),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ...availableAccounts.map((acct) {
                          final isSelected = activeAccount?.accountId == acct.accountId;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: InkWell(
                              onTap: () => _handleSelectAccount(shop, acct),
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? const Color(0xFF007DFE).withValues(alpha: 0.12)
                                      : (isDark ? const Color(0xFF262626) : Colors.grey.shade50),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isSelected
                                        ? const Color(0xFF007DFE)
                                        : (isDark ? const Color(0xFF383838) : Colors.grey.shade300),
                                    width: isSelected ? 2 : 1,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                                      color: isSelected ? const Color(0xFF007DFE) : textSecondary,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 10),
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
                                                    fontSize: 13,
                                                    color: textPrimary,
                                                  ),
                                                ),
                                              ),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFF007DFE),
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: Text(
                                                  acct.provider,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            '${acct.accountHolderName} • ${acct.mobileNumber}',
                                            style: TextStyle(fontSize: 11.5, color: textSecondary, fontWeight: FontWeight.w600),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            'Remaining Capacity: ${acct.remainingLabel}',
                                            style: const TextStyle(fontSize: 10.5, color: Color(0xFF10B981), fontWeight: FontWeight.w700),
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

                        const SizedBox(height: 8),

                        if (activeAccount != null) ...[
                          // ── QR Code Image for Selected Account ──
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.grey.shade300, width: 1.5),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.06),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: GCashQRDialog.buildQrImageWidget(activeAccount.qrImageUrl, height: 290),
                            ),
                          ),

                          const SizedBox(height: 12),

                          // ── Account Details Card ──
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF262626) : Colors.grey.shade50,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: isDark ? const Color(0xFF333333) : Colors.grey.shade200),
                            ),
                            child: Column(
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text('Receiving Account:', style: TextStyle(fontSize: 12, color: textSecondary)),
                                    Flexible(
                                      child: Text(
                                        activeAccount.accountName,
                                        textAlign: TextAlign.right,
                                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textPrimary),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text('Payment Provider:', style: TextStyle(fontSize: 12, color: textSecondary)),
                                    Text(
                                      activeAccount.provider,
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF007DFE)),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text('Account Holder:', style: TextStyle(fontSize: 12, color: textSecondary)),
                                    Text(
                                      activeAccount.accountHolderName,
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF007DFE)),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text('Mobile No:', style: TextStyle(fontSize: 12, color: textSecondary)),
                                    Text(
                                      activeAccount.mobileNumber,
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: textPrimary),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 12),

                          // ── Clear Payment Instructions ──
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF007DFE).withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0xFF007DFE).withValues(alpha: 0.2)),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.info_outline, color: Color(0xFF007DFE), size: 16),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '1. Scan this QR code using your GCash or banking app (${activeAccount.provider}).\n'
                                    '2. Verify receiver "${activeAccount.accountHolderName}" (${activeAccount.mobileNumber}) and send ₱${widget.totalAmount.toStringAsFixed(2)}.\n'
                                    '3. Tap the button below after sending. Your order will stay "Pending Payment" until verified and confirmed by the store administrator.',
                                    style: TextStyle(fontSize: 11.2, color: textPrimary, height: 1.35),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],

                      const SizedBox(height: 18),

                      // ── Action Buttons ──
                      if (hasOrder) ...[
                        if (availableAccounts.isNotEmpty)
                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF007DFE),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                elevation: 2,
                              ),
                              icon: _isProcessing
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                    )
                                  : const Icon(Icons.check_circle_outline, size: 20),
                              label: Text(
                                _isProcessing
                                    ? 'Recording Payment Details...'
                                    : (activeAccount != null
                                        ? 'I Have Sent Payment (${activeAccount.accountHolderName})'
                                        : 'Select an Available Account Above'),
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                              ),
                              onPressed: (_isProcessing || activeAccount == null || !activeAccount.isAvailable)
                                  ? null
                                  : () => _handleConfirmPayment(shop, activeAccount),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Center(
                          child: TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Close / Pay Later', style: TextStyle(color: Colors.grey)),
                          ),
                        ),
                      ] else ...[
                        SizedBox(
                          width: double.infinity,
                          height: 46,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF007DFE),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: () {
                              if (activeAccount != null) {
                                widget.onAccountSelected?.call(activeAccount);
                              }
                              Navigator.pop(context, true);
                            },
                            child: Text(
                              activeAccount != null
                                  ? 'Use ${activeAccount.accountName} & Return to Cart'
                                  : 'Return to Cart',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ],
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
