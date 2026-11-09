import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/shop_provider.dart';
import '../services/offline_service.dart';
import '../services/api_service.dart';
import '../widgets/kevs_logo.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _addressController = TextEditingController();
  final _serverUrlController = TextEditingController();
  bool _isLoading = true;
  bool _isTestingConnection = false;
  bool? _connectionHealthy;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final profile = await OfflineService.getCustomerProfile();
    final currentUrl = await OfflineService.getBaseUrl();
    if (mounted) {
      setState(() {
        _nameController.text = profile['name'] ?? '';
        _phoneController.text = profile['phone'] ?? '';
        _addressController.text = profile['address'] ?? '';
        _serverUrlController.text = currentUrl;
        _isLoading = false;
      });
    }
    _runHealthCheck(currentUrl);
  }

  Future<void> _runHealthCheck(String url) async {
    if (!mounted) return;
    setState(() => _isTestingConnection = true);
    final ok = await ApiService.testConnection(url);
    if (mounted) {
      setState(() {
        _connectionHealthy = ok;
        _isTestingConnection = false;
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _addressController.dispose();
    _serverUrlController.dispose();
    super.dispose();
  }

  Future<void> _testAndSaveServerUrl() async {
    final raw = _serverUrlController.text.trim();
    if (raw.isEmpty) return;
    setState(() => _isTestingConnection = true);
    final ok = await ApiService.testConnection(raw);
    await OfflineService.setBaseUrl(raw);
    if (mounted) {
      setState(() {
        _connectionHealthy = ok;
        _isTestingConnection = false;
      });
      final shop = context.read<ShopProvider>();
      shop.loadProducts();
      shop.refreshQueue();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(ok ? Icons.check_circle : Icons.warning_amber_rounded, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text(ok
                    ? 'Server URL saved and connected successfully!'
                    : 'Server URL saved, but could not reach server. Verify IP & port.'),
              ),
            ],
          ),
          backgroundColor: ok ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _resetServerUrl() async {
    await OfflineService.resetBaseUrl();
    final defaultUrl = await OfflineService.getBaseUrl();
    if (mounted) {
      setState(() => _serverUrlController.text = defaultUrl);
      _runHealthCheck(defaultUrl);
      final shop = context.read<ShopProvider>();
      shop.loadProducts();
      shop.refreshQueue();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Server URL reset to automatic auto-detection.'),
          backgroundColor: Color(0xFF10B981),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;

    await OfflineService.saveCustomerProfile(
      _nameController.text.trim(),
      _phoneController.text.trim(),
      _addressController.text.trim(),
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white),
              SizedBox(width: 8),
              Text('Customer profile saved successfully!'),
            ],
          ),
          backgroundColor: Color(0xFF10B981),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final shop = context.watch<ShopProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final cardBorder = isDark ? const Color(0xFF2E2E2E) : const Color(0xFFE5E5E5);
    final textPrimary = isDark ? Colors.white : const Color(0xFF171717);
    final textSecondary = isDark ? Colors.white60 : const Color(0xFF525252);
    final textMuted = isDark ? Colors.white38 : const Color(0xFF737373);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Row(
          children: const [
            KevsLogo(size: 26),
            SizedBox(width: 8),
            Text('Profile & Settings'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: isDark ? 'Switch to Light Mode' : 'Switch to Dark Mode',
            icon: Icon(
              isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
              color: isDark ? Colors.amber.shade300 : Colors.white,
            ),
            onPressed: () => shop.toggleTheme(),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFDC2626)))
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                    children: [
                      // ── Appearance / Theme Mode Card ──
                      Card(
                        color: cardBg,
                        elevation: isDark ? 2 : 1,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(color: cardBorder, width: 1),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: const Color(0xFFDC2626).withValues(alpha: 0.15),
                                    child: Icon(
                                      isDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                                      color: const Color(0xFFDC2626),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Appearance & Theme',
                                          style: TextStyle(
                                            fontSize: 17,
                                            fontWeight: FontWeight.bold,
                                            color: textPrimary,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Choose between Light Mode and Dark Mode across the app.',
                                          style: TextStyle(fontSize: 12, color: textSecondary),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Switch(
                                    value: shop.isDarkMode,
                                    activeThumbColor: Colors.white,
                                    activeTrackColor: const Color(0xFFDC2626),
                                    onChanged: (val) => shop.setDarkMode(val),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              Row(
                                children: [
                                  Expanded(
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(12),
                                      onTap: () => shop.setDarkMode(false),
                                      child: AnimatedContainer(
                                        duration: const Duration(milliseconds: 180),
                                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                                        decoration: BoxDecoration(
                                          color: !isDark
                                              ? const Color(0xFFDC2626).withValues(alpha: 0.1)
                                              : (isDark ? const Color(0xFF141414) : const Color(0xFFF5F5F7)),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(
                                            color: !isDark ? const Color(0xFFDC2626) : cardBorder,
                                            width: !isDark ? 2 : 1,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              Icons.light_mode_rounded,
                                              size: 18,
                                              color: !isDark ? const Color(0xFFDC2626) : textSecondary,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              'Light Mode',
                                              style: TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 13.5,
                                                color: !isDark ? const Color(0xFFDC2626) : textPrimary,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(12),
                                      onTap: () => shop.setDarkMode(true),
                                      child: AnimatedContainer(
                                        duration: const Duration(milliseconds: 180),
                                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                                        decoration: BoxDecoration(
                                          color: isDark
                                              ? const Color(0xFFDC2626).withValues(alpha: 0.16)
                                              : const Color(0xFFF5F5F7),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(
                                            color: isDark ? const Color(0xFFDC2626) : cardBorder,
                                            width: isDark ? 2 : 1,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              Icons.dark_mode_rounded,
                                              size: 18,
                                              color: isDark ? const Color(0xFFDC2626) : textSecondary,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              'Dark Mode',
                                              style: TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 13.5,
                                                color: isDark ? Colors.white : textPrimary,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // ── Customer Information Card ──
                      Card(
                        color: cardBg,
                        elevation: isDark ? 2 : 1,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(color: cardBorder, width: 1),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: const Color(0xFFDC2626).withValues(alpha: 0.15),
                                    child: const Icon(Icons.person, color: Color(0xFFDC2626)),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Customer Information',
                                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: textPrimary),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Saved details will auto-fill during checkout for pickup & delivery.',
                                          style: TextStyle(fontSize: 12, color: textSecondary),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              Divider(height: 28, color: cardBorder),

                              // Default Name
                              TextFormField(
                                controller: _nameController,
                                textCapitalization: TextCapitalization.words,
                                style: TextStyle(color: textPrimary),
                                decoration: const InputDecoration(
                                  prefixIcon: Icon(Icons.person_outline),
                                  labelText: 'Default Name',
                                  hintText: 'e.g. Juan Dela Cruz',
                                ),
                                validator: (val) {
                                  if (val == null || val.trim().isEmpty) return null; // optional in profile
                                  final trimmed = val.trim();
                                  if (trimmed.length < 2 || trimmed.length > 60) {
                                    return 'Ang pangalan ay dapat nasa pagitan ng 2 hanggang 60 characters';
                                  }
                                  if (RegExp(r'([a-zA-Z\u00C0-\u024F\u1E00-\u1EFF])\1{2,}', caseSensitive: false).hasMatch(trimmed)) {
                                    return 'Hindi wastong pangalan: Huwag gumamit ng paulit-ulit na mga titik tulad ng "$trimmed"';
                                  }
                                  if (RegExp(r"^[-'\s]|[-'\s]$").hasMatch(trimmed)) {
                                    return 'Ang pangalan ay hindi maaaring magsimula o magtapos sa gitling, kudlit, o espasyo';
                                  }
                                  if (RegExp(r"[\'\-\.]{2,}").hasMatch(trimmed) || RegExp(r"\s{2,}").hasMatch(trimmed)) {
                                    return 'Ang pangalan ay hindi maaaring magkaroon ng sunod-sunod na bantas o espasyo';
                                  }
                                  if (!RegExp(r"^[a-zA-Z\u00C0-\u024F\u1E00-\u1EFF\s.'-]+$").hasMatch(trimmed)) {
                                    return 'Ang pangalan ay maaari lamang maglaman ng mga titik, espasyo, gitling, tuldok, o kudlit';
                                  }
                                  final letterCount = RegExp(r'[a-zA-Z\u00C0-\u024F\u1E00-\u1EFF]').allMatches(trimmed).length;
                                  if (letterCount < 2) {
                                    return 'Ang pangalan ay dapat maglaman ng hindi bababa sa 2 letra';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: 16),

                              // Default Contact Number
                              TextFormField(
                                controller: _phoneController,
                                keyboardType: TextInputType.phone,
                                style: TextStyle(color: textPrimary),
                                decoration: const InputDecoration(
                                  prefixIcon: Icon(Icons.phone_outlined),
                                  labelText: 'Default Contact Number',
                                  hintText: 'e.g. 09123456789',
                                ),
                                validator: (val) {
                                  if (val == null || val.trim().isEmpty) return null;
                                  final cleaned = val.trim().replaceAll(RegExp(r'[\s\-\(\)\.]'), '');
                                  if (!RegExp(r'^\d+$').hasMatch(cleaned)) {
                                    return 'Ang numero ay dapat mga numero lamang';
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
                              const SizedBox(height: 16),

                              // Current Address
                              TextFormField(
                                controller: _addressController,
                                keyboardType: TextInputType.streetAddress,
                                maxLines: 2,
                                style: TextStyle(color: textPrimary),
                                decoration: const InputDecoration(
                                  prefixIcon: Icon(Icons.location_on_outlined),
                                  labelText: 'Default Address',
                                  hintText: 'Hal. House #070, Sitio Batisan, Brgy. Gatid',
                                  alignLabelWithHint: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // ── Server & Network Connection Card ──
                      Card(
                        color: cardBg,
                        elevation: isDark ? 2 : 1,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(color: cardBorder, width: 1),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: const Color(0xFFDC2626).withValues(alpha: 0.15),
                                    child: const Icon(Icons.dns_rounded, color: Color(0xFFDC2626)),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Server & Network Sync',
                                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: textPrimary),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Connects the mobile app to the Admin Dashboard (Port 5000).',
                                          style: TextStyle(fontSize: 12, color: textSecondary),
                                        ),
                                      ],
                                    ),
                                  ),
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 250),
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: _isTestingConnection
                                          ? Colors.amber.withValues(alpha: 0.15)
                                          : (_connectionHealthy == true
                                              ? const Color(0xFF10B981).withValues(alpha: 0.15)
                                              : Colors.red.withValues(alpha: 0.15)),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: _isTestingConnection
                                            ? Colors.amber
                                            : (_connectionHealthy == true ? const Color(0xFF10B981) : Colors.red),
                                        width: 1,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_isTestingConnection)
                                          const SizedBox(
                                            width: 10,
                                            height: 10,
                                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amber),
                                          )
                                        else
                                          Icon(
                                            _connectionHealthy == true ? Icons.check_circle_rounded : Icons.cancel_rounded,
                                            size: 14,
                                            color: _connectionHealthy == true ? const Color(0xFF10B981) : Colors.red,
                                          ),
                                        const SizedBox(width: 5),
                                        Text(
                                          _isTestingConnection
                                              ? 'Testing...'
                                              : (_connectionHealthy == true ? 'Connected' : 'Offline'),
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: _isTestingConnection
                                                ? Colors.amber
                                                : (_connectionHealthy == true ? const Color(0xFF10B981) : Colors.red),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              Divider(height: 28, color: cardBorder),

                              // Backend URL Field
                              TextFormField(
                                controller: _serverUrlController,
                                keyboardType: TextInputType.url,
                                style: TextStyle(color: textPrimary, fontSize: 13.5),
                                decoration: InputDecoration(
                                  prefixIcon: const Icon(Icons.link_rounded),
                                  labelText: 'Backend API Base URL',
                                  hintText: 'http://localhost:5000/api',
                                  helperText: 'Default: http://<PC-IP>:5000/api or Render cloud',
                                  helperStyle: TextStyle(fontSize: 11, color: textMuted),
                                ),
                              ),
                              const SizedBox(height: 16),

                              // Action Buttons
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: const Color(0xFFDC2626),
                                        side: const BorderSide(color: Color(0xFFDC2626)),
                                        padding: const EdgeInsets.symmetric(vertical: 12),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      ),
                                      icon: const Icon(Icons.refresh_rounded, size: 18),
                                      label: const Text('Auto-Detect', style: TextStyle(fontWeight: FontWeight.bold)),
                                      onPressed: _isTestingConnection ? null : _resetServerUrl,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFFDC2626),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(vertical: 12),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      ),
                                      icon: const Icon(Icons.check_rounded, size: 18),
                                      label: const Text('Test & Save', style: TextStyle(fontWeight: FontWeight.bold)),
                                      onPressed: _isTestingConnection ? null : _testAndSaveServerUrl,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFDC2626),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 2,
                        ),
                        icon: const Icon(Icons.save_rounded),
                        label: const Text(
                          'Save Profile',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        onPressed: _saveProfile,
                      ),
                      const SizedBox(height: 32),

                      // Proposal / System Info
                      Center(
                        child: Column(
                          children: [
                            Text(
                              'KEVS SIOMAI: Order & Unified Real-Time Queue System',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: textSecondary),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'Laguna University • Santa Cruz, Laguna',
                              style: TextStyle(fontSize: 11, color: textMuted),
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
}
