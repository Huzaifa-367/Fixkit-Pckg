import 'package:flutter/material.dart';

import '../../data/models.dart';

const _income = Color(0xFF2B8A3E);
const _ink = Color(0xFF1F2430);

class TransactionRow extends StatelessWidget {
  const TransactionRow({super.key, required this.transaction});

  final Transaction transaction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: const Color(0xFFE7ECFF),
            child: Icon(_icon(transaction.category), color: const Color(0xFF3B5BDB), size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(transaction.merchant, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(height: 2),
                Text(transaction.note, style: const TextStyle(color: Colors.black54, fontSize: 13)),
              ],
            ),
          ),
          Text(
            money(transaction.amount),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              color: transaction.amount < 0 ? _income : _ink,
            ),
          ),
        ],
      ),
    );
  }

  IconData _icon(Category category) => switch (category) {
        Category.salary => Icons.work_outline,
        Category.groceries => Icons.shopping_basket_outlined,
        Category.transport => Icons.directions_transit_outlined,
        Category.dining => Icons.restaurant_outlined,
        Category.refund => Icons.replay_outlined,
      };
}
