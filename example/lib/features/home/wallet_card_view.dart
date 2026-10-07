import 'package:flutter/material.dart';

import '../../data/models.dart';

class WalletCardView extends StatelessWidget {
  const WalletCardView({super.key, required this.card});

  final WalletCard card;

  @override
  Widget build(BuildContext context) {
    const label = TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 0.4);
    const value = TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600);

    return Container(
      height: 200,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          colors: [Color(0xFF3B5BDB), Color(0xFF7048E8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: const [BoxShadow(color: Color(0x403B5BDB), blurRadius: 24, offset: Offset(0, 12))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Text('TALLY', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, letterSpacing: 2)),
              Spacer(),
              Text('VISA', style: TextStyle(color: Colors.white, fontStyle: FontStyle.italic, fontWeight: FontWeight.w800)),
            ],
          ),
          const Spacer(),
          Text(card.number, style: value.copyWith(fontSize: 20, letterSpacing: 2)),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('CARD HOLDER', style: label),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: 120,
                    child: Text(card.holderName, style: value, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text('EXPIRES', style: label),
                  const SizedBox(height: 4),
                  Text(card.expiry, style: value),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
