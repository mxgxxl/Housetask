import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/data/models/task.dart';
import 'package:homesync/presentation/widgets/task_tile.dart';

import '../fakes.dart';

Widget _host(Task task) {
  return MaterialApp(
    home: Scaffold(body: TaskTile(task: task)),
  );
}

void main() {
  group('TaskTile offline indicators (TD-003)', () {
    testWidgets('isSynced true shows no pending-sync cloud icon', (tester) async {
      final task = buildTask('1');
      expect(task.isSynced, isTrue); // sanity: the model's own default

      await tester.pumpWidget(_host(task));

      expect(find.byIcon(Icons.cloud_queue), findsNothing);
    });

    testWidgets('isSynced false shows the pending-sync cloud icon', (tester) async {
      final task = buildTask('1').copyWith(isSynced: false);

      await tester.pumpWidget(_host(task));

      expect(find.byIcon(Icons.cloud_queue), findsOneWidget);
    });

    testWidgets('isDeleted true renders the row struck through and dimmed', (tester) async {
      final task = buildTask('1', title: 'Pendiente de borrar')
          .copyWith(isDeleted: true, isSynced: false);

      await tester.pumpWidget(_host(task));

      final titleWidget = tester.widget<Text>(find.text('Pendiente de borrar'));
      expect(titleWidget.style?.decoration, TextDecoration.lineThrough);

      final opacityWidget = tester.widget<Opacity>(find.byType(Opacity));
      expect(opacityWidget.opacity, lessThan(1.0));
    });

    testWidgets('a normal pending task is not dimmed', (tester) async {
      final task = buildTask('1');

      await tester.pumpWidget(_host(task));

      final opacityWidget = tester.widget<Opacity>(find.byType(Opacity));
      expect(opacityWidget.opacity, 1.0);
    });
  });
}
