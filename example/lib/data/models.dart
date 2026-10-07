/// Sample data for Tally, the fixkit demo wallet.
class WalletCard {
  const WalletCard({required this.number, required this.holderName, required this.expiry, required this.balance});

  final String number;
  final String holderName;
  final String expiry;
  final double balance;
}

enum Category { salary, groceries, transport, dining, refund }

class Transaction {
  const Transaction({required this.merchant, required this.note, required this.amount, required this.category});

  final String merchant;
  final String note;

  /// Positive for money in, negative for money out.
  final double amount;
  final Category category;

  bool get isIncome => amount > 0;
}

const card = WalletCard(
  number: '•••• •••• •••• 4417',
  holderName: 'Alexandra Montgomery-Whitfield',
  expiry: '09/29',
  balance: 12480.55,
);

const transactions = [
  Transaction(merchant: 'Northwind GmbH', note: 'Salary, September', amount: 4650, category: Category.salary),
  Transaction(merchant: 'Fresh Market', note: 'Groceries', amount: -86.40, category: Category.groceries),
  Transaction(merchant: 'Metro Transit', note: 'Monthly pass', amount: -49, category: Category.transport),
  Transaction(merchant: 'Café Lumen', note: 'Lunch with Sam', amount: -23.80, category: Category.dining),
  Transaction(merchant: 'Gadget Hub', note: 'Refund, headphones', amount: 129.99, category: Category.refund),
  Transaction(merchant: 'Fresh Market', note: 'Groceries', amount: -54.15, category: Category.groceries),
];

String money(double amount) {
  final sign = amount < 0 ? '−' : '+';
  final value = amount.abs().toStringAsFixed(2);
  final parts = value.split('.');
  final whole = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '$sign€$whole.${parts[1]}';
}
