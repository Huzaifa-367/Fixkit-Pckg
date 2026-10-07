import 'package:fixkit/fixkit.dart';
import 'package:flutter/material.dart';

import 'features/activity/activity_page.dart';
import 'features/home/home_page.dart';

// FixKit wraps the app: long press anything, say what is wrong, and your
// agent fixes it. In release builds it does nothing.
void main() => runApp(const FixKit(child: TallyApp()));

class TallyApp extends StatelessWidget {
  const TallyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tally',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B5BDB)),
        scaffoldBackgroundColor: const Color(0xFFF6F7FB),
      ),
      home: const RootPage(),
    );
  }
}

class RootPage extends StatefulWidget {
  const RootPage({super.key});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _tab,
          children: const [HomePage(), ActivityPage()],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (tab) => setState(() => _tab = tab),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), label: 'Activity'),
        ],
      ),
    );
  }
}
