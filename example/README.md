# Tally: the fixkit demo

A small wallet app with four seeded UI bugs, each a one-line slip.

## Run it

```bash
cd example
flutter create . --platforms=android,ios   # adds the platform folders; keeps lib/
flutter pub get
dart run fixkit init
```

Reload your editor window, run the app (F5 or `flutter run`), and say **watch for fixes** in your agent chat.

## The bugs

| Where | Long press | A comment that works |
| --- | --- | --- |
| Home | the **Send** button | button is shifted |
| Home | the **Top up** button | corners don't match the others |
| Home | the card holder name | name is cut off |
| Home or Activity | an income amount such as the salary | income should be green |

The card is wrapped in `FixName('home.walletCard', ...)`: press it outside the text and the report leads with that name.

To put the bugs back after your agent fixed them: `git checkout -- lib`.
