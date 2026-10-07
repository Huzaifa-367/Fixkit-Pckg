import 'package:flutter/widgets.dart';

/// Optional: gives a widget a name of your choosing.
///
/// fixkit already reports the file and line of every widget under the finger,
/// so nothing has to be marked. A name helps when the same widget class is used
/// in many places: the report leads with it, and the composer highlights the
/// whole named area.
///
/// ```dart
/// FixName('home.walletCard', child: WalletCard(card: card))
/// ```
///
/// Nested names resolve to the innermost one. The name may carry data, as in
/// `FixName('transaction.${tx.id}', child: ...)`. In release builds it only
/// returns [child].
class FixName extends StatelessWidget {
  const FixName(this.name, {super.key, required this.child});

  /// The name shown in the composer and sent with the report.
  final String name;

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Optional: names the screen on display, sent with every report from inside
/// it. Without it, fixkit reports the route name and the nearest widget whose
/// class name ends in `Screen`, `Page` or `View`.
///
/// ```dart
/// FixScreen('Checkout', child: Scaffold(...))
/// ```
class FixScreen extends StatelessWidget {
  const FixScreen(this.name, {super.key, required this.child});

  final String name;

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
