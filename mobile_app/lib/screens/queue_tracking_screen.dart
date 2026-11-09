import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/shop_provider.dart';
import '../models/order.dart';
import '../widgets/order_status_badge.dart';
import '../widgets/gcash_qr_dialog.dart';
import '../widgets/kevs_logo.dart';

class QueueTrackingScreen extends StatelessWidget {
  const QueueTrackingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final shop = context.watch<ShopProvider>();
    final queue = shop.queueStatus;
    final activeOrders = shop.activeOrders;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final cardBorder = isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE5E5E5);
    final textPrimary = isDark ? Colors.white : const Color(0xFF171717);
    final textSecondary = isDark ? Colors.white60 : const Color(0xFF525252);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: const Color(0xFF171717),
        foregroundColor: Colors.white,
        elevation: 0,
        leading: const Padding(
          padding: EdgeInsets.all(8.0),
          child: KevsLogo(size: 28),
        ),
        title: const Text(
          'Live Queue & Orders',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh Queue',
            onPressed: () async {
              await shop.refreshQueue();
              await shop.refreshPaymentAccounts();
              await shop.refreshActiveOrders();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        color: const Color(0xFFDC2626),
        backgroundColor: cardBg,
        onRefresh: () async {
          await shop.refreshQueue();
          await shop.refreshPaymentAccounts();
          await shop.refreshActiveOrders();
        },
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── Live Unified Queue Header Card (ESP32 / OLED synchronized) ──
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF1E1E1E), Color(0xFF262626), Color(0xFF7F1D1D)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFDC2626).withValues(alpha: 0.35)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 12,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
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
                              const Text(
                                'ESP32 UNIFIED QUEUE',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1,
                                ),
                              ),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                            ),
                            child: Text(
                              '${queue?.activeOrders ?? 0} active in line',
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'NOW SERVING',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          queue != null && queue.hasActive && queue.nowServing > 0
                              ? '#${queue.nowServing}'
                              : 'No orders yet!',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 42,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        queue != null && queue.currentQueueNo > 0
                            ? 'Latest Ticket Assigned: #${queue.currentQueueNo}'
                            : 'Counter is ready for new orders',
                        style: const TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // ── Section Title ──
                Text(
                  'Your Active Orders',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: textPrimary),
                ),
                const SizedBox(height: 10),

                if (activeOrders.isEmpty && shop.pendingOfflineOrders.isEmpty)
                  Card(
                    color: cardBg,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: cardBorder),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
                      child: Column(
                        children: [
                          Icon(Icons.receipt_long_outlined, size: 54, color: isDark ? Colors.white24 : Colors.black26),
                          const SizedBox(height: 12),
                          Text(
                            'No orders placed yet',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textPrimary),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Order delicious siomai from the menu to get a queue ticket number!',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 13, color: textSecondary),
                          ),
                        ],
                      ),
                    ),
                  )
                else ...[
                  // Pending offline orders
                  ...shop.pendingOfflineOrders.map((o) => _buildOfflineCard(context, shop, o)),
                  // Active orders
                  ...activeOrders.map((order) => _buildOrderTrackerCard(context, shop, order, queue?.nowServing ?? 0)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOfflineCard(BuildContext context, ShopProvider shop, CustomerOrder order) {
    return Card(
      color: const Color(0xFF2E2412),
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.amber.shade700.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_off, color: Colors.amber.shade400, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Pending Offline Sync',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
                ),
                const Spacer(),
                Text(
                  '₱${order.totalAmount.toStringAsFixed(2)}',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${order.orderType.toUpperCase()} • ${order.paymentMethod} • ${order.items.length} item(s)',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber.shade800,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
              icon: const Icon(Icons.sync, size: 16),
              label: const Text('Sync to Server Now'),
              onPressed: () async {
                final count = await shop.syncOfflineOrders();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Synced $count order(s) to backend!')),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderTrackerCard(BuildContext context, ShopProvider shop, CustomerOrder order, int nowServing) {
    final isServing = order.hasValidTicket && nowServing == order.queueNo && !order.isCompleted;
    final isAhead = order.hasValidTicket && order.queueNo > nowServing && !order.isCompleted;
    final ordersAhead = (order.hasValidTicket && order.queueNo > nowServing) ? order.queueNo - nowServing : 0;
    final canCancel = !order.isCompleted && order.status.toLowerCase() != 'cancelled';
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final cardBorder = isDark ? Colors.white.withValues(alpha: 0.1) : const Color(0xFFE5E5E5);
    final textPrimary = isDark ? Colors.white : const Color(0xFF171717);
    final textSecondary = isDark ? Colors.white70 : const Color(0xFF525252);

    return Card(
      color: cardBg,
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: isServing
            ? const BorderSide(color: Color(0xFF00E676), width: 2)
            : BorderSide(color: cardBorder),
      ),
      elevation: isServing ? 4 : (isDark ? 0 : 1),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with Ticket No & Status
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: isServing ? const Color(0xFF00E676) : const Color(0xFFDC2626),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        order.ticketDisplay,
                        style: TextStyle(
                          color: isServing ? Colors.black : Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        order.orderType.toUpperCase(),
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: textSecondary),
                      ),
                    ),
                  ],
                ),
                OrderStatusBadge(status: order.status),
              ],
            ),
            if (order.formattedDate.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.access_time_rounded, size: 12, color: textSecondary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      order.formattedDate,
                      style: TextStyle(fontSize: 11, color: textSecondary),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),

            // Live Queue Position banner
            if (isServing)
              Container(
                margin: const EdgeInsets.symmetric(vertical: 6),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF00E676).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF00E676).withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.campaign, color: isDark ? const Color(0xFF00E676) : const Color(0xFF059669)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'YOUR TICKET IS NOW BEING SERVED! Please proceed to counter / await rider.',
                        style: TextStyle(
                          color: isDark ? const Color(0xFF00E676) : const Color(0xFF047857),
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else if (isAhead)
              Container(
                margin: const EdgeInsets.symmetric(vertical: 6),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.shade900.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.amber.shade700.withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.timelapse, color: isDark ? Colors.amber.shade400 : Colors.amber.shade800, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '$ordersAhead order(s) ahead in line • Est. ${ordersAhead * 3} mins',
                      style: TextStyle(
                        color: isDark ? Colors.amber.shade300 : Colors.amber.shade900,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),

            // Status Progress Visualizer
            const SizedBox(height: 8),
            _buildStatusTimeline(context, order.status, order.orderType),
            const SizedBox(height: 12),

            // Items List
            Text('Items Ordered:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textSecondary)),
            const SizedBox(height: 4),
            ...order.items.map((it) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          '• ${it.quantity}x ${it.productName}',
                          style: TextStyle(fontSize: 13, color: textPrimary),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '₱${it.subtotal.toStringAsFixed(2)}',
                        style: TextStyle(fontSize: 13, color: textSecondary),
                      ),
                    ],
                  ),
                )),
            Divider(color: cardBorder),

            if (shop.isOrderAccountUnavailable(order)) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFEF4444), width: 1.5),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: Color(0xFFDC2626), size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Selected payment account (${order.paymentAccountName ?? order.paymentAccountId}) is no longer available before payment confirmation. Please select another available receiving account.',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF991B1B),
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFDC2626),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.swap_horiz_rounded, size: 15),
                        label: const Text('Select Available Account', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        onPressed: () async {
                          await GCashQRDialog.show(
                            context,
                            order: order,
                            totalAmount: order.totalAmount,
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Payment and Actions
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Payment: ${order.paymentMethod}',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: textSecondary),
                      ),
                      if (order.isOnlinePayment && order.paymentAccountName != null && order.paymentAccountName!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2.0, bottom: 2.0),
                          child: Text(
                            'Account: ${order.paymentAccountName}${order.paymentProvider != null && order.paymentProvider!.isNotEmpty ? " (${order.paymentProvider})" : ""}',
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF007DFE)),
                          ),
                        ),
                      Row(
                        children: [
                          Icon(
                            order.isPaid
                                ? Icons.check_circle_rounded
                                : Icons.access_time_rounded,
                            size: 13,
                            color: order.isPaid
                                ? (isDark ? const Color(0xFF00E676) : const Color(0xFF059669))
                                : (isDark ? Colors.amber.shade400 : Colors.amber.shade800),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            order.isPaid
                                ? 'Paid'
                                : 'Pending Payment',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: order.isPaid
                                  ? (isDark ? const Color(0xFF00E676) : const Color(0xFF059669))
                                  : (isDark ? Colors.amber.shade400 : Colors.amber.shade800),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'Total: ₱${order.totalAmount.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFFDC2626)),
                    ),
                    if (order.paymentMethod == 'GCash' && !order.isPaid && !order.isCancelled)
                      Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: TextButton.icon(
                          style: TextButton.styleFrom(
                            backgroundColor: shop.isOrderAccountUnavailable(order)
                                ? const Color(0xFFDC2626)
                                : const Color(0xFF007DFE),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            minimumSize: Size.zero,
                          ),
                          icon: Icon(
                            shop.isOrderAccountUnavailable(order) ? Icons.swap_horiz_rounded : Icons.qr_code_2,
                            size: 14,
                          ),
                          label: Text(
                            shop.isOrderAccountUnavailable(order)
                                ? 'Change Payment Account'
                                : 'Pay with GCash QR',
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                          onPressed: () async {
                            await GCashQRDialog.show(
                              context,
                              order: order,
                              totalAmount: order.totalAmount,
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ],
            ),

            // Cancel Order Action for active uncompleted orders
            if (canCancel) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFEF4444),
                    side: BorderSide(color: const Color(0xFFEF4444).withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.cancel_outlined, size: 15),
                  label: const Text('Cancel Order', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: cardBg,
                        title: Text('Cancel Order', style: TextStyle(color: textPrimary)),
                        content: Text(
                          order.hasValidTicket
                              ? 'Are you sure you want to cancel Ticket #${order.queueNo}?'
                              : 'Are you sure you want to cancel this order?',
                          style: TextStyle(color: textSecondary),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: Text('Keep Order', style: TextStyle(color: textSecondary)),
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFDC2626),
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Yes, Cancel'),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      final ok = await shop.cancelOrder(order.id, order: order);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(ok
                                ? (order.hasValidTicket
                                    ? 'Ticket #${order.queueNo} cancelled'
                                    : 'Order cancelled')
                                : 'Could not cancel order'),
                            backgroundColor: ok ? const Color(0xFFDC2626) : Colors.black87,
                          ),
                        );
                      }
                    }
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusTimeline(BuildContext context, String status, String orderType) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inactiveColor = isDark ? Colors.white.withValues(alpha: 0.15) : const Color(0xFFE2E8F0);
    final inactiveTextColor = isDark ? Colors.white70 : const Color(0xFF475569);

    if (status.toLowerCase() == 'cancelled') {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFEF4444).withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.4)),
        ),
        child: const Row(
          children: [
            Icon(Icons.cancel, color: Color(0xFFEF4444), size: 18),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'This order has been cancelled',
                style: TextStyle(
                  color: Color(0xFFEF4444),
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final steps = [
      'Placed',
      'Accepted',
      'Preparing',
      orderType == 'delivery' ? 'Out for Delivery' : 'Ready for Pickup',
      orderType == 'delivery' ? 'Delivered' : 'Completed',
    ];

    int currentStep = 0;
    switch (status.toLowerCase()) {
      case 'pending':
        currentStep = 0;
        break;
      case 'accepted':
        currentStep = 1;
        break;
      case 'preparing':
        currentStep = 2;
        break;
      case 'ready_pickup':
      case 'ready_delivery':
      case 'out_for_delivery':
        currentStep = 3;
        break;
      case 'completed':
      case 'delivered':
        currentStep = 4;
        break;
      default:
        currentStep = 0;
    }

    return Row(
      children: List.generate(steps.length * 2 - 1, (index) {
        if (index.isOdd) {
          final stepIndex = index ~/ 2;
          final isPast = stepIndex < currentStep;
          return Expanded(
            child: Container(
              height: 3,
              color: isPast ? const Color(0xFFDC2626) : inactiveColor,
            ),
          );
        } else {
          final stepIndex = index ~/ 2;
          final isDone = stepIndex <= currentStep;
          return Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: isDone ? const Color(0xFFDC2626) : inactiveColor,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: isDone
                  ? const Icon(Icons.check, size: 11, color: Colors.white)
                  : Text('${stepIndex + 1}', style: TextStyle(fontSize: 9, color: inactiveTextColor)),
            ),
          );
        }
      }),
    );
  }
}
