import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/grid/media_grid.dart';
import 'package:r2_gallery/src/ui/media_tile.dart';

void main() {
  testWidgets('多数の日付でも画面付近だけ構築し、先走って続きは取得しない', (tester) async {
    final items = List.generate(
      1000,
      (i) => MediaItem(
        key: '$i.jpg',
        type: 'image',
        url: 'https://example.test/$i.jpg',
        createdAt: DateTime(
          2026,
          11,
          2,
        ).subtract(Duration(days: i)).millisecondsSinceEpoch,
      ),
    );
    var more = 0;
    int? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaGrid(
            items: items,
            dateHeaders: true,
            selection: const {},
            selectionMode: false,
            selLib: 'a',
            onOpenItem: (i) => opened = i,
            onToggleSelect: (_) {},
            onLongPress: (_) {},
            onNearEnd: () => more++,
            onRefresh: () async {},
          ),
        ),
      ),
    );
    expect(find.byType(MediaTile).evaluate().length, lessThan(40));
    expect(more, 0);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(find.byType(MediaTile).evaluate().length, lessThan(40));
    expect(find.byKey(const ValueKey('t::0.jpg')), findsNothing);
    expect(more, 0);
    final visible = find.byType(MediaTile).hitTestable().first;
    final tile = tester.widget<MediaTile>(visible);
    await tester.tap(visible);
    expect(opened, items.indexOf(tile.item));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
