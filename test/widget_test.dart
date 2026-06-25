// Verifies the Overview summary cards (Leak detection, Data balance, Speed
// test) act as shortcuts that invoke their "open section" callbacks when
// tapped. The full app `main()` does platform-plugin init that isn't available
// under flutter_test, so we exercise the card → callback wiring directly.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ir_net/ui/balance_widgets.dart';
import 'package:ir_net/ui/leak_widgets.dart';
import 'package:ir_net/ui/sections.dart';
import 'package:ir_net/ui/speed_widgets.dart';

void main() {
  testWidgets('Overview summary cards invoke their open-section callbacks',
      (tester) async {
    final opened = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: OverviewSection(
              compact: true,
              onOpenLeaks: () => opened.add('leaks'),
              onOpenBalance: () => opened.add('balance'),
              onOpenSpeed: () => opened.add('speed'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byType(LeakSummaryCard));
    await tester.tap(find.byType(BalanceSummaryCard));
    await tester.tap(find.byType(SpeedSummaryCard));
    await tester.pump();

    expect(opened, ['leaks', 'balance', 'speed']);
  });
}
