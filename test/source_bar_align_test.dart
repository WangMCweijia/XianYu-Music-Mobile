import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xianyu_music_mobile/src/widgets/source_bar_scroll_view.dart';

/// 平台选择行左对齐回归。
///
/// 线上现场（2.0.7 ~ 2.0.15）：搜索结果页「平台选择」这一行左侧空出半屏，
/// 第一颗胶囊落在屏幕中间、右侧胶囊被裁，随手滑一下就归位。根因是滚动位置
/// 可以被本文件之外的代码写成负值。2.0.16 起这一行不再使用任何滚动组件，
/// 位置只由自己维护并在绘制处钳一次，这里锁住下面几条不变式。
Widget _host(Widget bar) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 460, height: 40, child: bar),
    ),
  );
}

List<Widget> _pills(List<GlobalKey> keys) {
  return [
    for (var i = 0; i < keys.length; i++)
      Padding(
        key: keys[i],
        padding: const EdgeInsets.only(right: 8),
        child: Container(
          width: 90,
          height: 40,
          color: Colors.white,
          alignment: Alignment.center,
          child: Text('P$i'),
        ),
      ),
  ];
}

double _barLeft(WidgetTester tester) =>
    tester.getTopLeft(find.byType(SourceBarScrollView)).dx;

double _firstPillLeft(WidgetTester tester, GlobalKey key) =>
    tester.getTopLeft(find.byKey(key)).dx - _barLeft(tester);

SourceBarScrollViewState _state(WidgetTester tester) =>
    tester.state<SourceBarScrollViewState>(find.byType(SourceBarScrollView));

void main() {
  testWidgets('首帧：第一颗胶囊贴左内边距', (tester) async {
    final keys = List.generate(10, (_) => GlobalKey());
    await tester.pumpWidget(
      _host(SourceBarScrollView(children: _pills(keys))),
    );
    await tester.pump();
    expect(_firstPillLeft(tester, keys[0]), closeTo(14.0, 0.5));
    expect(_state(tester).offset, 0.0);
  });

  // 老版本这里能写进负值：整行内容被推到右半边，用户滑一下才被物理钳回。
  testWidgets('负位置写不进去：钳成 0，第一颗仍在左内边距', (tester) async {
    final keys = List.generate(10, (_) => GlobalKey());
    await tester.pumpWidget(
      _host(SourceBarScrollView(children: _pills(keys))),
    );
    await tester.pump();

    final state = _state(tester);
    state.jumpToForTest(-200);
    await tester.pump();

    expect(state.offset, 0.0, reason: '写入入口必须把负值钳成 0');
    expect(
      _firstPillLeft(tester, keys[0]),
      closeTo(14.0, 0.5),
      reason: '负位置一旦落到绘制上，第一颗胶囊就会被推到屏幕中间',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('revealChild：第 0 项居中必须钳到 0', (tester) async {
    final keys = List.generate(10, (_) => GlobalKey());
    await tester.pumpWidget(
      _host(SourceBarScrollView(children: _pills(keys))),
    );
    await tester.pump();

    // 居中式子：内容坐标 14 - (460 - 90) / 2 = -171，必须钳成 0
    _state(tester).revealChild(keys[0].currentContext!,
        duration: Duration.zero);
    await tester.pump();

    expect(_state(tester).offset, 0.0);
    expect(_firstPillLeft(tester, keys[0]), closeTo(14.0, 0.5));
  });

  testWidgets('revealChild：目标尺寸为 0 时放弃，位置不动', (tester) async {
    final keys = List.generate(4, (_) => GlobalKey());
    final zeroKey = GlobalKey();
    await tester.pumpWidget(
      _host(SourceBarScrollView(children: [
        ..._pills(keys),
        SizedBox(key: zeroKey, width: 0, height: 40),
      ])),
    );
    await tester.pump();

    _state(tester).revealChild(zeroKey.currentContext!, duration: Duration.zero);
    await tester.pump();

    expect(_state(tester).offset, 0.0,
        reason: '宽 0 的目标会退化成「坐标 - 视口/2」，必须直接放弃');
  });

  // 2.0.13 现场核算：胶囊行右移 197.7dp ≈ 视口宽/2，正是
  // getOffsetToReveal(alignment: 0.5) 打在宽 0 目标上的取值。这条负值由
  // forcePixels 直接写进滚动位置、不通知监听者，用户滑动才被物理钳回。
  // 2.0.16 这一行不再是 Scrollable，框架的居中请求无处可写。
  testWidgets('框架 ensureVisible(alignment:0.5) 无法再推动这一行', (tester) async {
    final keys = List.generate(10, (_) => GlobalKey());
    final zeroKey = GlobalKey();
    await tester.pumpWidget(
      _host(SourceBarScrollView(children: [
        SizedBox(key: zeroKey, width: 0, height: 40),
        ..._pills(keys),
      ])),
    );
    await tester.pump();

    await Scrollable.ensureVisible(zeroKey.currentContext!, alignment: 0.5);
    await tester.pump();

    expect(_state(tester).offset, 0.0);
    expect(_firstPillLeft(tester, keys[0]), closeTo(14.0, 0.5));
  });

  testWidgets('拖动越界被钳住：左拖到底不超 max，右拖过头回 0', (tester) async {
    final keys = List.generate(10, (_) => GlobalKey());
    await tester.pumpWidget(
      _host(SourceBarScrollView(children: _pills(keys))),
    );
    await tester.pump();

    // 内容 10 * 98 + 28 = 1008，视口 460，可滚 548
    await tester.drag(
      find.byType(SourceBarScrollView),
      const Offset(-5000, 0),
    );
    await tester.pumpAndSettle();

    final state = _state(tester);
    expect(state.offset, greaterThan(0.0));
    expect(state.offset, lessThanOrEqualTo(548.0 + 0.5),
        reason: '不能滚出内容边界');
    expect(
      tester.getTopLeft(find.byKey(keys[0])).dx - _barLeft(tester),
      lessThan(20.0),
    );

    // 往右猛拖，越过起点
    await tester.drag(
      find.byType(SourceBarScrollView),
      const Offset(8000, 0),
    );
    await tester.pumpAndSettle();
    expect(state.offset, 0.0, reason: '越过起点必须钳回 0，不能留负值');
    expect(_firstPillLeft(tester, keys[0]), closeTo(14.0, 0.5));
  });

  testWidgets('内容比视口窄时不能滚动', (tester) async {
    final keys = List.generate(2, (_) => GlobalKey());
    await tester.pumpWidget(
      _host(SourceBarScrollView(children: _pills(keys))),
    );
    await tester.pump();

    await tester.drag(
      find.byType(SourceBarScrollView),
      const Offset(-400, 0),
    );
    await tester.pumpAndSettle();

    expect(_state(tester).offset, 0.0);
    expect(_firstPillLeft(tester, keys[0]), closeTo(14.0, 0.5));
  });

  testWidgets('松约束父级（Column 居中排布）下这一行必须吃满宽度', (tester) async {
    final keys = List.generate(6, (_) => GlobalKey());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 424,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 48),
                SourceBarScrollView(children: _pills(keys)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.getSize(find.byType(SourceBarScrollView)).width,
      424.0,
      reason: 'Column 给的是松约束，这一行不能缩成内容宽度',
    );
    expect(
      tester.getTopLeft(find.byKey(keys[0])).dx -
          tester.getTopLeft(find.byType(SourceBarScrollView)).dx,
      closeTo(14.0, 0.5),
    );
  });
}
