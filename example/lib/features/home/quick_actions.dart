import 'package:flutter/material.dart';

class QuickActions extends StatelessWidget {
  const QuickActions({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 14),
          child: _ActionButton(icon: Icons.arrow_upward_rounded, label: 'Send'),
        ),
        const _ActionButton(icon: Icons.arrow_downward_rounded, label: 'Request'),
        const _ActionButton(icon: Icons.add_rounded, label: 'Top up', radius: 4),
        const _ActionButton(icon: Icons.more_horiz_rounded, label: 'More'),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.icon, required this.label, this.radius = 18});

  final IconData icon;
  final String label;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Material(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(radius),
          child: InkWell(
            borderRadius: BorderRadius.circular(radius),
            onTap: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label tapped'))),
            child: SizedBox(width: 60, height: 60, child: Icon(icon, color: scheme.onPrimaryContainer)),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
