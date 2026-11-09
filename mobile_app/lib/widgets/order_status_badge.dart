import 'package:flutter/material.dart';

class OrderStatusBadge extends StatelessWidget {
  final String status;

  const OrderStatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    String label;
    IconData icon;

    switch (status.toLowerCase()) {
      case 'pending':
        bg = Colors.amber.shade100;
        fg = Colors.amber.shade900;
        label = 'Pending';
        icon = Icons.hourglass_top;
        break;
      case 'accepted':
        bg = Colors.blue.shade100;
        fg = Colors.blue.shade900;
        label = 'Accepted';
        icon = Icons.thumb_up_alt_outlined;
        break;
      case 'preparing':
        bg = Colors.orange.shade100;
        fg = Colors.orange.shade900;
        label = 'Preparing';
        icon = Icons.outdoor_grill_outlined;
        break;
      case 'ready_pickup':
        bg = Colors.teal.shade100;
        fg = Colors.teal.shade900;
        label = 'Ready for Pickup';
        icon = Icons.shopping_bag_outlined;
        break;
      case 'ready_delivery':
        bg = Colors.purple.shade100;
        fg = Colors.purple.shade900;
        label = 'Ready for Delivery';
        icon = Icons.delivery_dining;
        break;
      case 'out_for_delivery':
        bg = Colors.indigo.shade100;
        fg = Colors.indigo.shade900;
        label = 'Out for Delivery';
        icon = Icons.moped;
        break;
      case 'completed':
      case 'delivered':
        bg = Colors.green.shade100;
        fg = Colors.green.shade900;
        label = status == 'delivered' ? 'Delivered' : 'Completed';
        icon = Icons.check_circle_outline;
        break;
      case 'cancelled':
        bg = Colors.red.shade100;
        fg = Colors.red.shade900;
        label = 'Cancelled';
        icon = Icons.cancel_outlined;
        break;
      default:
        bg = Colors.grey.shade200;
        fg = Colors.grey.shade800;
        label = status;
        icon = Icons.info_outline;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}
