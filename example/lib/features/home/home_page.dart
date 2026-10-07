import 'package:fixkit/fixkit.dart';
import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../activity/transaction_row.dart';
import 'quick_actions.dart';
import 'wallet_card_view.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return FixScreen(
      'Home',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Text('Good morning', style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.black54)),
          const SizedBox(height: 4),
          Text('Your wallet', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 20),
          // A name makes reports about the card lead with "home.walletCard".
          const FixName('home.walletCard', child: WalletCardView(card: card)),
          const SizedBox(height: 24),
          const QuickActions(),
          const SizedBox(height: 28),
          Text('Recent', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final transaction in transactions.take(4)) TransactionRow(transaction: transaction),
        ],
      ),
    );
  }
}
