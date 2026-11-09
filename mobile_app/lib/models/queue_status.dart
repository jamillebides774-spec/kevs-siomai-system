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

    final bool hasActiveVal = (q['has_active'] == true || stats['has_active'] == true);
    final int rawServing = int.tryParse((stats['now_serving'] ?? q['now_serving'] ?? 0).toString()) ?? 0;
    final int nowServingVal = hasActiveVal ? rawServing : 0;

    return QueueStatus(
      currentQueueNo: int.tryParse((q['current_queue_no'] ?? 0).toString()) ?? 0,
      nowServing: nowServingVal,
      hasActive: hasActiveVal,
      activeOrders: int.tryParse((stats['active_orders'] ?? 0).toString()) ?? 0,
      pendingOrders: int.tryParse((stats['pending_orders'] ?? 0).toString()) ?? 0,
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
