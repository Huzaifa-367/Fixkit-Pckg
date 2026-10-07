import 'package:fixkit/fixkit.dart';
import 'package:flutter/material.dart';

import '../../data/models.dart';
import 'transaction_row.dart';

class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key});

  @override
  Widget build(BuildContext context) {
    final income = transactions.where((t) => t.isIncome).fold<double>(0, (sum, t) => sum + t.amount);
    final spent = transactions.where((t) => !t.isIncome).fold<double>(0, (sum, t) => sum + t.amount);

    return FixScreen(
      'Activity',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Text('Activity', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: _Total(label: 'In', value: money(income))),
              const SizedBox(width: 12),
              Expanded(child: _Total(label: 'Out', value: money(spent))),
            ],
          ),
          const SizedBox(height: 20),
          for (final transaction in transactions) TransactionRow(transaction: transaction),
        ],
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
