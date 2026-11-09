import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/shop_provider.dart';
import 'screens/home_screen.dart';
import 'screens/queue_tracking_screen.dart';
import 'screens/store_location_screen.dart';
import 'screens/settings_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BossKevsApp());
}

class BossKevsApp extends StatelessWidget {
  const BossKevsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ShopProvider()),
      ],
      child: Consumer<ShopProvider>(
        builder: (context, shop, _) {
          return MaterialApp(
            title: 'KEVS SIOMAI',
            debugShowCheckedModeBanner: false,
            themeMode: shop.isDarkMode ? ThemeMode.dark : ThemeMode.light,
            theme: ThemeData(
              useMaterial3: true,
              brightness: Brightness.light,
              scaffoldBackgroundColor: const Color(0xFFF5F5F7),
              colorScheme: const ColorScheme.light(
                primary: Color(0xFFDC2626),
                onPrimary: Colors.white,
                secondary: Color(0xFFEF4444),
                surface: Colors.white,
                onSurface: Color(0xFF171717),
                error: Color(0xFFDC2626),
              ),
              appBarTheme: const AppBarTheme(
                backgroundColor: Color(0xFF171717),
                foregroundColor: Colors.white,
                elevation: 0,
                centerTitle: false,
                surfaceTintColor: Colors.transparent,
              ),
              cardTheme: CardThemeData(
                color: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: Color(0xFFE5E5E5)),
                ),
              ),
              dividerTheme: const DividerThemeData(
                color: Color(0xFFE5E5E5),
              ),
              inputDecorationTheme: InputDecorationTheme(
                labelStyle: const TextStyle(color: Color(0xFF525252)),
                hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
                prefixIconColor: const Color(0xFFDC2626),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFD4D4D8)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFDC2626), width: 1.8),
                ),
              ),
              navigationBarTheme: NavigationBarThemeData(
                backgroundColor: Colors.white,
                indicatorColor: const Color(0xFFDC2626).withValues(alpha: 0.14),
                surfaceTintColor: Colors.transparent,
                labelTextStyle: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) {
                    return const TextStyle(
                      color: Color(0xFFDC2626),
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    );
                  }
                  return const TextStyle(
                    color: Color(0xFF525252),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  );
                }),
                iconTheme: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) {
                    return const IconThemeData(color: Color(0xFFDC2626));
                  }
                  return const IconThemeData(color: Color(0xFF525252));
                }),
              ),
            ),
            darkTheme: ThemeData(
              useMaterial3: true,
              brightness: Brightness.dark,
              scaffoldBackgroundColor: const Color(0xFF121212),
              colorScheme: const ColorScheme.dark(
                primary: Color(0xFFDC2626),
                onPrimary: Colors.white,
                secondary: Color(0xFFEF4444),
                surface: Color(0xFF1E1E1E),
                onSurface: Colors.white,
                error: Color(0xFFEF4444),
              ),
              appBarTheme: const AppBarTheme(
                backgroundColor: Color(0xFF171717),
                foregroundColor: Colors.white,
                elevation: 0,
                centerTitle: false,
                surfaceTintColor: Colors.transparent,
              ),
              cardTheme: CardThemeData(
                color: const Color(0xFF1E1E1E),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                ),
              ),
              navigationBarTheme: NavigationBarThemeData(
                backgroundColor: const Color(0xFF171717),
                indicatorColor: const Color(0xFFDC2626).withValues(alpha: 0.22),
                labelTextStyle: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) {
                    return const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    );
                  }
                  return TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontWeight: FontWeight.w500,
                    fontSize: 12,
                  );
                }),
                iconTheme: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) {
                    return const IconThemeData(color: Color(0xFFDC2626));
                  }
                  return IconThemeData(color: Colors.white.withValues(alpha: 0.5));
                }),
              ),
            ),
            home: const MainNavigationShell(),
          );
        },
      ),
    );
  }
}

class MainNavigationShell extends StatefulWidget {
  const MainNavigationShell({super.key});

  @override
  State<MainNavigationShell> createState() => _MainNavigationShellState();
}

class _MainNavigationShellState extends State<MainNavigationShell> {
  int _currentIndex = 0;

  void _switchTab(int index) {
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final shop = context.watch<ShopProvider>();
    final activeCount = shop.activeOrders.where((o) => !o.isCompleted).length;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final pages = [
      HomeScreen(onGoToQueue: () => _switchTab(1)),
      const QueueTrackingScreen(),
      const StoreLocationScreen(),
      const SettingsScreen(),
    ];

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: IndexedStack(
        index: _currentIndex,
        children: pages,
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE5E5E5),
              width: 1,
            ),
          ),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: _switchTab,
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.restaurant_menu_outlined),
              selectedIcon: Icon(Icons.restaurant_menu),
              label: 'Menu',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: activeCount > 0,
                label: Text('$activeCount'),
                backgroundColor: const Color(0xFFDC2626),
                child: const Icon(Icons.confirmation_number_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: activeCount > 0,
                label: Text('$activeCount'),
                backgroundColor: const Color(0xFFDC2626),
                child: const Icon(Icons.confirmation_number),
              ),
              label: 'Queue',
            ),
            const NavigationDestination(
              icon: Icon(Icons.map_outlined),
              selectedIcon: Icon(Icons.map),
              label: 'Store Map',
            ),
            const NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}
