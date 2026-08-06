import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'theme/app_theme.dart';
import 'screens/sizing_screen.dart';
import 'screens/scanner_screen.dart';
import 'screens/guide_screen.dart';
import 'screens/history_screen.dart';
import 'services/ble_service.dart';
import 'services/database_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BleService()),
        ChangeNotifierProvider(create: (_) => DatabaseService()),
      ],
      child: const SolarOBDApp(),
    ),
  );
}

class SolarOBDApp extends StatelessWidget {
  const SolarOBDApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Solar OBD',
      theme: AppTheme.darkTheme,
      debugShowCheckedModeBanner: false,
      home: const MainNavigation(),
    );
  }
}

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;

  final List<Widget> _screens = [
    const ScannerScreen(),
    const SizingScreen(),
    const GuideScreen(),
    const HistoryScreen(),
  ];

  final List<String> _titles = [
    'OBD Scanner',
    'System Sizing',
    'Installation Guide',
    'Performance History',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppTheme.primaryDark,
              AppTheme.primaryMid,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Custom app bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppTheme.accentBlue.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.solar_power,
                        color: AppTheme.accentBlue,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'SolarMEDICS',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        Text(
                          _titles[_currentIndex],
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                    const Spacer(),
                    // BLE connection status indicator
                    Consumer<BleService>(
                      builder: (context, bleService, _) {
                        final isConnected = bleService.isConnected;
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: isConnected
                              ? AppTheme.accentGreen.withOpacity(0.15)
                              : AppTheme.accentOrange.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isConnected
                                ? AppTheme.accentGreen.withOpacity(0.3)
                                : AppTheme.accentOrange.withOpacity(0.3),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.circle,
                                size: 8,
                                color: isConnected ? AppTheme.accentGreen : AppTheme.accentOrange,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                isConnected ? 'Online' : 'Offline',
                                style: TextStyle(
                                  color: isConnected ? AppTheme.accentGreen : AppTheme.accentOrange,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              // Screen content
              Expanded(child: _screens[_currentIndex]),
            ],
          ),
        ),
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: AppTheme.primaryMid,
          border: Border(
            top: BorderSide(color: AppTheme.cardBorder, width: 0.5),
          ),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) => setState(() => _currentIndex = index),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.speed),
              label: 'Scanner',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.calculate),
              label: 'Sizing',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.menu_book),
              label: 'Guide',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.timeline),
              label: 'History',
            ),
          ],
        ),
      ),
    );
  }
}
