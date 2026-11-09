import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/kevs_logo.dart';

class StoreLocationScreen extends StatelessWidget {
  const StoreLocationScreen({super.key});

  static const double storeLat = 14.2604;
  static const double storeLng = 121.3836;
  static const String storeName = 'KEVS SIOMAI';
  static const String storeAddress = '070 Batisan, Gatid, Santa Cruz, Laguna';
  static const String storeHours = 'Open Daily: 4:00 PM - 12:00 AM';
  static const String storePhone = '0921-296-1820';

  Future<void> _openGoogleMaps(BuildContext context) async {
    final destination = Uri.encodeComponent(storeAddress);
    final url = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$destination');
    final coordUrl = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$storeLat,$storeLng');

    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else if (await canLaunchUrl(coordUrl)) {
        await launchUrl(coordUrl, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(url, mode: LaunchMode.platformDefault);
      }
    } catch (e) {
      try {
        await launchUrl(url, mode: LaunchMode.platformDefault);
      } catch (err) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error launching navigation: $err')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
          'Store Location & Map',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // ── Store Visual Card (Tappable Map Card) ──
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => _openGoogleMaps(context),
                    child: Container(
                      height: 180,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        gradient: const LinearGradient(
                          colors: [Color(0xFF1E1E1E), Color(0xFF262626), Color(0xFF7F1D1D)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        border: Border.all(color: const Color(0xFFDC2626).withValues(alpha: 0.35)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.4),
                            blurRadius: 10,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: Stack(
                        children: [
                          Positioned(
                            right: -20,
                            bottom: -20,
                            child: Icon(Icons.location_on, size: 160, color: Colors.white.withValues(alpha: 0.08)),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(20.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFDC2626).withValues(alpha: 0.3),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: const Color(0xFFDC2626).withValues(alpha: 0.5)),
                                  ),
                                  child: const Text(
                                    'TAP TO NAVIGATE',
                                    style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                const KevsBrandLockup(height: 42),
                                const SizedBox(height: 6),
                                const Text(
                                  '070 Batisan, Gatid, Santa Cruz, Laguna',
                                  style: TextStyle(color: Colors.white70, fontSize: 14),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ── One-Click Navigation CTA ──
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFDC2626),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      elevation: 2,
                    ),
                    icon: const Icon(Icons.directions, size: 24),
                    label: const Text(
                      'Navigate in Google Maps',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    onPressed: () => _openGoogleMaps(context),
                  ),
                ),
                const SizedBox(height: 16),

                // ── Store Information Details ──
                Card(
                  color: cardBg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: cardBorder),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        _buildInfoRow(
                          Icons.place,
                          'Address',
                          storeAddress,
                          const Color(0xFFDC2626),
                          textPrimary,
                          textSecondary,
                        ),
                        Divider(height: 24, color: cardBorder),
                        _buildInfoRow(
                          Icons.access_time,
                          'Operating Hours',
                          storeHours,
                          const Color(0xFF3B82F6),
                          textPrimary,
                          textSecondary,
                        ),
                        Divider(height: 24, color: cardBorder),
                        _buildInfoRow(
                          Icons.phone,
                          'Contact Number',
                          storePhone,
                          const Color(0xFF10B981),
                          textPrimary,
                          textSecondary,
                        ),
                        Divider(height: 24, color: cardBorder),
                        _buildInfoRow(
                          Icons.fastfood,
                          'Pickup Instructions',
                          'Show your queue ticket number at the counter upon arrival.',
                          const Color(0xFFF59E0B),
                          textPrimary,
                          textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ── Coordinates Info Pill ──
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: cardBorder),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.gps_fixed, size: 16, color: Color(0xFFDC2626)),
                      const SizedBox(width: 8),
                      Text(
                        'GPS: $storeLat, $storeLng',
                        style: TextStyle(fontSize: 12, color: textSecondary, fontWeight: FontWeight.w500),
                      ),
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

  Widget _buildInfoRow(IconData icon, String title, String subtitle, Color color, Color textPrimary, Color textSecondary) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(fontSize: 12, color: textSecondary, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: textPrimary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
