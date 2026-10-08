import 'package:fixkit/fixkit.dart';
import 'package:fixkit/src/app/controller.dart';
import 'package:fixkit/src/app/inspector.dart';
import 'package:fixkit/src/protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeConnection implements FixConnection {
  FakeConnection({
    this.answer = const {'id': 'r1', 'status': 'live', 'message': 'Made it bold'},
    this.later,
    this.presenceAnswer,
  });

  final Map<String, Object?> answer;

  /// What status() answers; defaults to live.
  final Map<String, Object?>? later;
  final Map<String, Object?>? presenceAnswer;
  final List<Map<String, Object?>> reports = [];
  final List<String> signals = [];
  final List<String?> presenceFiles = [];
  int restarts = 0;

  @override
  String get description => 'fake';

  @override
  ({String label, String hint}) get offlineAdvice => (label: 'fixkit offline', hint: 'Run `dart run fixkit doctor`.');

  @override
  Future<Map<String, Object?>> report(Map<String, Object?> body) async {
    reports.add(body);
    return answer;
  }

  @override
  Future<Map<String, Object?>> status(String id, {int? since}) async => later ?? {'id': id, 'status': FixStatus.live};

  @override
  Future<Map<String, Object?>?> signal(String kind, {String? appFile}) async {
    signals.add(kind);
    return null;
  }

  @override
  Future<Map<String, Object?>?> presence({String? file}) async {
    presenceFiles.add(file);
    return presenceAnswer;
  }

  @override
  Future<bool> restartHub() async {
    restarts++;
    return true;
  }
}

class Unreachable extends FakeConnection {
  @override
  Future<Map<String, Object?>> report(Map<String, Object?> body) async => throw const FixHubUnreachable('test');
}

Widget app(FixConnection connection, {bool enabled = true, Widget? body}) => FixKit(
      connection: connection,
      screenshots: false,
      enabled: enabled,
      child: MaterialApp(
        home: Scaffold(
          body: body ??
              Center(
                child: FixName('checkout.pay', child: ElevatedButton(onPressed: () {}, child: const Text('Pay now'))),
              ),
        ),
      ),
    );

Future<void> openComposer(WidgetTester tester, String finderText) async {
  await tester.longPress(find.text(finderText));
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.byType(TextField), findsOneWidget);
}

Future<void> sendReport(WidgetTester tester, String finderText, String comment) async {
  await openComposer(tester, finderText);
  await tester.enterText(find.byType(TextField), comment);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// Lets the card's hide timer run out and its exit animation finish.
Future<void> settleCard(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 8));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('tells the hub the app launched', (tester) async {
    final connection = FakeConnection();
    await tester.pumpWidget(app(connection));
    await tester.pump();
    expect(connection.signals, ['launch']);
  });

  testWidgets('a long press sends the comment, the widget and its source line', (tester) async {
    final connection = FakeConnection();
    await tester.pumpWidget(app(connection));
    await tester.pump();

    await sendReport(tester, 'Pay now', 'Make it bold');

    expect(connection.reports, hasLength(1));
    final report = connection.reports.single;
    expect(report['comment'], 'Make it bold');
    expect(report['protocol'], fixkitProtocol);

    // The deepest widget from this file is the Text the finger was on.
    final target = report['target'] as Map;
    expect(target['widget'], 'Text');
    expect('${target['file']}', endsWith('fixkit_widget_test.dart'));
    expect(target['line'], isA<int>());
    expect(report['targetText'], 'Pay now');

    // The FixName around it, and the chain up through this file.
    expect((report['named'] as Map)['name'], 'checkout.pay');
    final chain = (report['chain'] as List).cast<Map>();
    final widgets = chain.map((frame) => frame['widget']).toList();
    expect(widgets, containsAllInOrder(['Text', 'ElevatedButton', 'FixName', 'Center', 'Scaffold', 'MaterialApp']));

    // The agent card shows the outcome and types out the summary, then folds away.
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Fixed'), findsOneWidget);
    expect(find.text('Made it bold'), findsOneWidget);
    expect(find.text('“Make it bold”'), findsOneWidget);
    await settleCard(tester);
    expect(find.text('Fixed'), findsNothing);
  });

  testWidgets('the agent card follows the steps the hub reports', (tester) async {
    final connection = FakeConnection(
      answer: const {
        'id': 'r1',
        'status': FixStatus.fixing,
        'agent': 'Cursor',
        'activity': [
          {'text': 'Sent to Cursor', 'kind': 'step'},
          {'text': 'Reading lib/home.dart:42', 'kind': 'step'},
        ],
      },
      later: const {
        'id': 'r1',
        'status': FixStatus.live,
        'agent': 'Cursor',
        'message': 'Income is green now',
        'activity': [
          {'text': 'Sent to Cursor', 'kind': 'step'},
          {'text': 'Reading lib/home.dart:42', 'kind': 'step'},
          {'text': 'Edited home.dart', 'kind': 'step'},
          {'text': 'Fix is on screen', 'kind': 'done'},
        ],
      },
    );
    await tester.pumpWidget(app(connection));
    await tester.pump();
    await sendReport(tester, 'Pay now', 'Income should be green');
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Cursor is fixing it'), findsOneWidget);
    expect(find.text('Sent to Cursor'), findsOneWidget);
    expect(find.text('Reading lib/home.dart:42'), findsOneWidget);

    // The next poll brings the edit and the outcome.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Edited home.dart'), findsOneWidget);
    expect(find.text('Income is green now'), findsOneWidget);
    await settleCard(tester);
  });

  testWidgets('the composer names the watching agent and offers suggestions', (tester) async {
    final connection = FakeConnection(presenceAnswer: const {'agent': 'Cursor', 'watching': true});
    await tester.pumpWidget(app(connection));
    await tester.pump();
    await openComposer(tester, 'Pay now');
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Cursor is watching'), findsOneWidget);
    expect(find.text('What should change here?'), findsOneWidget);

    await tester.tap(find.text('Change the colour'));
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Change the colour');

    await tester.tapAt(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('the badge tells offline, outdated and idle apart', (tester) async {
    Future<void> badge(FakeConnection connection, String expected) async {
      await tester.pumpWidget(app(connection));
      await tester.pump();
      await openComposer(tester, 'Pay now');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(expected), findsOneWidget);
      // The pressed widget's file goes along, so the hub names that project's agent.
      expect(connection.presenceFiles.last, endsWith('fixkit_widget_test.dart'));
      await tester.tapAt(const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpWidget(const SizedBox());
    }

    await badge(FakeConnection(), 'fixkit offline');
    await badge(FakeConnection(presenceAnswer: const {'agent': 'Cursor', 'watching': false}), 'Cursor is idle');
    await badge(FakeConnection(presenceAnswer: const {'agent': 'Cursor', 'busy': true}), 'Cursor is busy');
    await badge(FakeConnection(presenceAnswer: const {'agent': null}), 'No agent');

    final outdated = FakeConnection(presenceAnswer: const {'outdated': true, 'version': '0.1.0'});
    await badge(outdated, 'Update fixkit');
    // It is left running: an older editor would not start a new one.
    expect(outdated.restarts, 0);
  });

  testWidgets('an older hub that sends no steps still gets status steps', (tester) async {
    final connection = FakeConnection(
      answer: const {'id': 'r1', 'status': FixStatus.fixing},
      later: const {'id': 'r1', 'status': FixStatus.fixing},
      presenceAnswer: const {'agent': 'Cursor', 'watching': true},
    );
    await tester.pumpWidget(app(connection));
    await tester.pump();
    await sendReport(tester, 'Pay now', 'Fix the spacing');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Cursor is fixing it'), findsOneWidget);
    expect(find.text('Sent to Cursor'), findsOneWidget);
    expect(find.text('Working on the code'), findsOneWidget);
    expect(find.text('Waiting for the hub'), findsNothing);
    // Closing the card stops following the report.
    await tester.tap(find.text('✕'));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Cursor is fixing it'), findsNothing);
  });

  testWidgets('the press does not also tap the button', (tester) async {
    var taps = 0;
    final connection = FakeConnection();
    await tester.pumpWidget(app(
      connection,
      body: Center(child: ElevatedButton(onPressed: () => taps++, child: const Text('Tap me'))),
    ));
    await tester.pump();
    await tester.longPress(find.text('Tap me'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(taps, 0);
    // A normal tap still works once the composer is gone.
    await tester.tapAt(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Tap me'));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('tapping outside the composer cancels it', (tester) async {
    final connection = FakeConnection();
    await tester.pumpWidget(app(connection));
    await tester.pump();
    await openComposer(tester, 'Pay now');
    await tester.tapAt(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(TextField), findsNothing);
    expect(connection.reports, isEmpty);
  });

  testWidgets('says so when the hub is not listening', (tester) async {
    await tester.pumpWidget(app(Unreachable()));
    await tester.pump();
    await sendReport(tester, 'Pay now', 'Make it bold');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('fixkit is not listening'), findsOneWidget);
    await settleCard(tester);
  });

  testWidgets('does nothing when disabled', (tester) async {
    final connection = FakeConnection();
    await tester.pumpWidget(app(connection, enabled: false));
    await tester.pump();
    expect(connection.signals, isEmpty);
    await tester.longPress(find.text('Pay now'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(TextField), findsNothing);
  });

  test('runs have a title and tone for every status', () {
    for (final status in [FixRun.sending, ...FixStatus.all]) {
      final run = FixRun(status: status, comment: 'x', agent: 'Cursor');
      expect(run.title, isNotEmpty, reason: status);
    }
    expect(const FixRun(status: FixStatus.fixing, comment: '', agent: 'Cursor').title, 'Cursor is fixing it');
    expect(const FixRun(status: FixStatus.fixing, comment: '').title, 'Your agent is fixing it');
    expect(const FixRun(status: FixStatus.live, comment: '').tone, FixTone.success);
    expect(const FixRun(status: FixStatus.needsInput, comment: '').tone, FixTone.warning);
  });

  test('suggestions fit the selected widget', () {
    FixInspection pressed(String widget, {String? text}) => FixInspection(
          touch: Offset.zero,
          chain: [FixFrame(widget: widget)],
          tracking: true,
          scopes: [FixScope(frame: FixFrame(widget: widget), rect: Rect.zero, chainIndex: 0, text: text)],
        );
    expect(suggestionsFor(pressed('Text', text: 'Hi')), contains('Change the colour'));
    expect(suggestionsFor(pressed('ElevatedButton')), contains('Match the other buttons'));
    expect(suggestionsFor(pressed('Icon')), contains('Change the icon'));
    expect(suggestionsFor(pressed('Row', text: 'Hi')), contains('Align the items'));
    expect(suggestionsFor(pressed('Column')), contains('Fix the spacing'));
  });

  testWidgets('long press works on a text field and does not select its text', (tester) async {
    final field = TextEditingController(text: 'alex@example.com');
    addTearDown(field.dispose);
    final connection = FakeConnection();
    await tester.pumpWidget(app(connection, body: Center(child: SizedBox(width: 300, child: TextField(controller: field)))));
    await tester.pump();

    await tester.longPress(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 300));

    // The composer is open, and the app's field neither selected a word nor took focus.
    expect(find.text('What should change here?'), findsOneWidget);
    expect(field.selection.isCollapsed, isTrue);
    // The app's field comes first in the tree; the composer's is drawn above it.
    final editable = tester.widget<EditableText>(find.byType(EditableText).first);
    expect(editable.focusNode.hasFocus, isFalse);

    // The report is about the TextField written in this file.
    await tester.enterText(find.byType(TextField).last, 'Use the email keyboard');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    final report = connection.reports.single;
    expect((report['target'] as Map)['widget'], 'TextField');
    await settleCard(tester);
  });

  testWidgets('long press wins over widgets with their own long press', (tester) async {
    var longPresses = 0;
    var taps = 0;
    final connection = FakeConnection();
    await tester.pumpWidget(app(
      connection,
      body: Center(
        child: InkWell(
          onTap: () => taps++,
          onLongPress: () => longPresses++,
          child: const Padding(padding: EdgeInsets.all(20), child: Text('Hold me')),
        ),
      ),
    ));
    await tester.pump();
    await openComposer(tester, 'Hold me');
    expect(longPresses, 0);
    expect(taps, 0);
    await tester.tapAt(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('a moving finger is a scroll, not a long press', (tester) async {
    final connection = FakeConnection();
    await tester.pumpWidget(app(
      connection,
      body: ListView(children: [for (var i = 0; i < 40; i++) SizedBox(height: 60, child: Text('Row $i'))]),
    ));
    await tester.pump();
    final gesture = await tester.startGesture(tester.getCenter(find.text('Row 3')));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('a press on the gap in a Row selects the Row, not the whole screen', (tester) async {
    final connection = FakeConnection();
    await tester.pumpWidget(app(
      connection,
      body: const Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [Text('Ahmed Khan'), SizedBox(width: 160), Text('Bell')],
          ),
        ),
      ),
    ));
    await tester.pump();
    final name = tester.getRect(find.text('Ahmed Khan'));
    await tester.longPressAt(Offset(name.right + 80, name.center.dy));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(TextField), findsOneWidget);
    expect(find.textContaining('Row  ·  '), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Align these');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect((connection.reports.single['target'] as Map)['widget'], 'Row');
    await settleCard(tester);
  });

  testWidgets('the selection widens to the Row, Column or card around the press', (tester) async {
    final connection = FakeConnection();
    await tester.pumpWidget(app(connection));
    await tester.pump();
    await openComposer(tester, 'Pay now');

    // The bar lists the pressed Text and the widgets of this file around it.
    expect(find.text('Text'), findsOneWidget);
    expect(find.text('ElevatedButton'), findsOneWidget);
    expect(find.text('"checkout.pay"'), findsOneWidget);
    expect(find.text('Center'), findsOneWidget);

    // + widens to the button; a chip jumps straight to its widget.
    await tester.tap(find.text('+'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('ElevatedButton  ·  '), findsOneWidget);

    await tester.tap(find.text('Center'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('−'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('"checkout.pay"  ·  '), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'More space around it');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    final report = connection.reports.single;
    expect((report['target'] as Map)['widget'], 'FixName');
    expect((report['pressed'] as Map)['widget'], 'Text');
    expect((report['pressed'] as Map)['text'], 'Pay now');
    expect(((report['chain'] as List).first as Map)['widget'], 'FixName');
    expect((report['selection'] as Map)['index'], 2);
    expect((report['named'] as Map)['name'], 'checkout.pay');
    await settleCard(tester);
  });
}
