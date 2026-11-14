import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xianyu_music_mobile/src/widgets/source_bar_scroll_view.dart';

/// 平台选择行左对齐回归。
///
/// 线上现场：搜索结果页「平台选择」这一行左侧空出一大段，第一颗胶囊
/// 落在屏幕中间、右侧胶囊被裁。原因是横向弹性滚动允许位置停在负值，
/// 整行内容被整体推到右边。这里锁住三件事：第一颗胶囊贴左内边距、
/// 负滚动位置会被回正、切平台自动居中时滚动位置不越界。
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

void main() {
  testWidgets('平台选择行左对齐：第一颗胶囊贴左内边距，负偏移可回正',
      (tester) async {
    final keys = List.generate(10, (_) => GlobalKey());
    await tester.pumpWidget(
      _host(SourceBarScrollView(children: _pills(keys))),
    );
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(keys[0])).dx - _barLeft(tester),
      closeTo(14.0, 0.5),
    );

    // 模拟残留的负滚动位置（弹性 overscroll 的回弹被打断 / PageStorage 读回）
    final state = tester.state<SourceBarScrollViewState>(
      find.byType(SourceBarScrollView),
    );
    state.controller.jumpTo(-200);
    await tester.pump();
    expect(
      state.controller.offset,
      0.0,
      reason: '负偏移必须立刻回正，不能停留在越界位置等下一次滚动结束',
    );
    expect(
      tester.getTopLeft(find.byKey(keys[0])).dx - _barLeft(tester),
      closeTo(14.0, 0.5),
      reason: '负滚动位置没有被回正，第一颗胶囊没有贴左',
    );

    // 兜底入口保留且幂等
    state.clampToStart();
    await tester.pump();
    expect(state.controller.offset, 0.0);
  });

  testWidgets('切平台居中滚动不越界、不把整行推到右侧', (tester) async {
    final keys = List.generate(10, (_) => GlobalKey());
    await tester.pumpWidget(
      _host(SourceBarScrollView(children: _pills(keys))),
    );
    await tester.pump();

    // duration 默认 0，直接 jumpTo，不引入动画等待
    await Scrollable.ensureVisible(
      keys[2].currentContext!,
      alignment: 0.5,
    );
    await tester.pump();

    final state = tester.state<SourceBarScrollViewState>(
      find.byType(SourceBarScrollView),
    );
    expect(state.controller.offset, greaterThanOrEqualTo(0.0));
    expect(
      state.controller.offset,
      lessThanOrEqualTo(state.controller.position.maxScrollExtent),
    );
    final double selectedX =
        tester.getTopLeft(find.byKey(keys[2])).dx - _barLeft(tester);
    expect(selectedX, greaterThanOrEqualTo(0.0));
    expect(selectedX, lessThan(460.0));
  });

  // 线上复现（2026-11-13，2.0.7 正式版）：第一颗胶囊落在屏幕中央、左侧
  // 空出约半个屏宽、右侧胶囊被裁。数值吻合「居中目标算成 L - 视口宽/2」，
  // 即 ensureVisible(alignment:0.5) 拿到一个还没完成布局（宽 0）的目标。
  testWidgets('revealChild：第 0 项居中必须钳到 0，不能把整行推到右半边',
      (tester) async {
    final keys = List.generate(10, (_) => GlobalKey());
    await tester.pumpWidget(
      _host(SourceBarScrollView(children: _pills(keys))),
    );
    await tester.pump();

    final state = tester.state<SourceBarScrollViewState>(
      find.byType(SourceBarScrollView),
    );
    // 第 0 项居中：内容坐标 14 - (460 - 90) / 2 = -171，必须钳成 0
    state.revealChild(keys[0].currentContext!, duration: Duration.zero);
    await tester.pump();

    expect(state.controller.offset, 0.0,
        reason: '第 0 项居中会算出负目标，必须钳成 0');
    expect(
      tester.getTopLeft(find.byKey(keys[0])).dx - _barLeft(tester),
      closeTo(14.0, 0.5),
      reason: '负目标没有被钳住，第一颗胶囊没贴左',
    );
  });

  testWidgets('revealChild：目标尺寸为 0 时放弃滚动，不产生负偏移', (tester) async {
    final keys = List.generate(4, (_) => GlobalKey());
    final zeroKey = GlobalKey();
    await tester.pumpWidget(
      _host(SourceBarScrollView(children: [
        ..._pills(keys),
        SizedBox(key: zeroKey, width: 0, height: 40),
      ])),
    );
    await tester.pump();

    final state = tester.state<SourceBarScrollViewState>(
      find.byType(SourceBarScrollView),
    );
    state.revealChild(zeroKey.currentContext!, duration: Duration.zero);
    await tester.pump();

    expect(state.controller.offset, 0.0,
        reason: '宽 0 的目标会退化成「坐标 - 视口/2」，必须直接放弃');
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
