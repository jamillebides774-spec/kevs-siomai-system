import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class UnitQuantitySelector extends StatelessWidget {
  final int quantity;
  final int maxStock;
  final String unit;
  final ValueChanged<int> onChanged;
  final bool isCompact;
  final Color primaryColor;

  const UnitQuantitySelector({
    super.key,
    required this.quantity,
    required this.maxStock,
    this.unit = 'pcs',
    required this.onChanged,
    this.isCompact = false,
    this.primaryColor = const Color(0xFFDC2626),
  });

  void _showDirectInputDialog(BuildContext context) {
    final controller = TextEditingController(text: '$quantity');
    String? localError;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final dialogBg = isDark ? const Color(0xFF1E1E1E) : Colors.white;
            final borderCol = isDark ? const Color(0xFF333333) : const Color(0xFFE5E5E5);
            final textPrimary = isDark ? Colors.white : const Color(0xFF171717);
            final textSecondary = isDark ? Colors.white70 : const Color(0xFF525252);

            return AlertDialog(
              backgroundColor: dialogBg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: borderCol, width: 1),
              ),
              title: Row(
                children: [
                  Icon(Icons.edit_note_rounded, color: primaryColor),
                  const SizedBox(width: 8),
                  Text(
                    'Enter Quantity',
                    style: TextStyle(color: textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Max Allowed: $maxStock $unit',
                    style: TextStyle(color: textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    style: TextStyle(color: textPrimary, fontSize: 20, fontWeight: FontWeight.bold),
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    decoration: InputDecoration(
                      labelText: 'Desired Quantity ($unit)',
                      labelStyle: TextStyle(color: textSecondary),
                      suffixText: unit,
                      suffixStyle: TextStyle(color: textSecondary, fontWeight: FontWeight.bold),
                      errorText: localError,
                      errorStyle: const TextStyle(color: Color(0xFFEF4444)),
                      filled: true,
                      fillColor: isDark ? const Color(0xFF121212) : const Color(0xFFF5F5F7),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: primaryColor, width: 2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Quick selection pills
                  Wrap(
                    spacing: 8,
                    children: [1, 2, 4, 6, 10]
                        .where((q) => q <= maxStock)
                        .map((q) => ActionChip(
                              label: Text('$q $unit', style: const TextStyle(fontSize: 12)),
                              backgroundColor: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF1F5F9),
                              labelStyle: TextStyle(color: textPrimary),
                              onPressed: () {
                                controller.text = '$q';
                                setDialogState(() => localError = null);
                              },
                            ))
                        .toList(),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('Cancel', style: TextStyle(color: textSecondary)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () {
                    final text = controller.text.trim();
                    if (text.isEmpty) {
                      setDialogState(() => localError = 'Please enter a quantity');
                      return;
                    }
                    final parsed = int.tryParse(text);
                    if (parsed == null || parsed < 0) {
                      setDialogState(() => localError = 'Please enter a valid whole number');
                      return;
                    }
                    if (parsed > maxStock) {
                      setDialogState(() => localError = 'Exceeds allowed limit ($maxStock $unit)');
                      return;
                    }

                    Navigator.pop(ctx);
                    onChanged(parsed);
                  },
                  child: const Text('Apply Quantity', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (isCompact) {
      // Compact Stepper for Product Cards
      return Container(
        height: 30,
        decoration: BoxDecoration(
          color: primaryColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: primaryColor.withValues(alpha: 0.4), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: () => onChanged(quantity - 1),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 7),
                child: Icon(Icons.remove, size: 14, color: primaryColor),
              ),
            ),
            GestureDetector(
              onTap: () => _showDirectInputDialog(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$quantity',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        color: primaryColor,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Text(
                      unit,
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w600,
                        color: primaryColor.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            GestureDetector(
              onTap: quantity < maxStock ? () => onChanged(quantity + 1) : null,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 7),
                child: Icon(
                  Icons.add,
                  size: 14,
                  color: quantity < maxStock
                      ? primaryColor
                      : (isDark ? Colors.white30 : Colors.black26),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Full Size Stepper for Cart & Bottom Sheet
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1A1A) : const Color(0xFFF5F5F7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDark ? const Color(0xFF333333) : const Color(0xFFE5E5E5), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(Icons.remove, size: 18, color: primaryColor),
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
            onPressed: () => onChanged(quantity - 1),
            tooltip: 'Decrease quantity',
          ),
          InkWell(
            onTap: () => _showDirectInputDialog(context),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF262626) : Colors.white,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$quantity',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : const Color(0xFF171717),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    unit,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white60 : const Color(0xFF525252),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.edit, size: 12, color: isDark ? Colors.white38 : Colors.black38),
                ],
              ),
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.add,
              size: 18,
              color: quantity < maxStock
                  ? primaryColor
                  : (isDark ? Colors.white24 : Colors.black26),
            ),
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
            onPressed: quantity < maxStock ? () => onChanged(quantity + 1) : null,
            tooltip: quantity < maxStock ? 'Increase quantity' : 'Limit reached ($maxStock $unit)',
          ),
        ],
      ),
    );
  }
}
