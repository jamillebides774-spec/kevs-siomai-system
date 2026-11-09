class QueueStatus {
  final int currentQueueNo;
  final int nowServing;
  final bool hasActive;
  final int activeOrders;
  final int pendingOrders;
  final String timestamp;

  QueueStatus({
    required this.currentQueueNo,
    required this.nowServing,
    this.hasActive = false,
    this.activeOrders = 0,
    this.pendingOrders = 0,
    required this.timestamp,
  });

  factory QueueStatus.fromJson(Map<String, dynamic> json) {
    final q = json['queue'] as Map<String, dynamic>? ?? {};
    final stats = json['stats'] as Map<String, dynamic>? ?? {};

    return QueueStatus(
      currentQueueNo: q['current_queue_no'] ?? 0,
      nowServing: stats['now_serving'] ?? q['now_serving'] ?? 0,
      hasActive: q['has_active'] ?? stats['has_active'] ?? false,
      activeOrders: stats['active_orders'] ?? 0,
      pendingOrders: stats['pending_orders'] ?? 0,
      timestamp: json['timestamp'] ?? DateTime.now().toIso8601String(),
    );
  }

  // Calculate wait position for a specific ticket
  int ordersAhead(int customerQueueNo) {
    if (customerQueueNo <= nowServing) return 0;
    return customerQueueNo - nowServing;
  }

  String estimatedWait(int customerQueueNo) {
    final ahead = ordersAhead(customerQueueNo);
    if (ahead <= 0) return 'Ready / Serving Now!';
    final estMinutes = ahead * 3; // Approx 3 mins per siomai batch
    return '$estMinutes mins (~$ahead orders ahead)';
  }
}
