import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xianyu_music_mobile/src/widgets/source_bar_scroll_view.dart';

/// 平台选择行左对齐回归。
///
/// 线上现场：搜索结果页「平台选择」这一行左侧空出一大段，第一颗胶囊
/// 落在屏幕中间、右侧胶囊被裁。原因是横向弹性滚动允许位置停在负值，
/// 整行内容被整体推到右边。这里锁住三件事：第一颗胶囊贴左内边距、
/// 手势/程序化负偏移都不留白、切平台只滚到左边缘且不越界。
Widget _host(Widget bar) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 460, height: 40, child: bar),
    ),
  );
}

List<Widget> _pills(List<GlobalKey> keys) {
  return [
    for (var i = 0; i < 5; i++)
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

double _firstX(WidgetTester tester, GlobalKey key) {
  return tester.getTopLeft(find.byKey(key)).dx -
      tester.getTopLeft(find.byType(SourceBarScrollView)).dx;
}

void main() {
  testWidgets('平台选择行始终左对齐：拖拽与负偏移都不留白', (tester) async {
    final keys = List.generate(5, (_) => GlobalKey());
    await tester.pumpWidget(
      _host(SourceBarScrollView(children: _pills(keys))),
    );
    await tester.pumpAndSettle();
    expect(_firstX(tester, keys[0]), closeTo(14.0, 0.5));

    // 用户向右拖拽（弹性 overscroll 的主要来源）：夹紧物理不应产生负偏移
    await tester.drag(find.byType(ListView), const Offset(200, 0));
    await tester.pump();
    expect(
      _firstX(tester, keys[0]),
      closeTo(14.0, 0.5),
      reason: '向右拖拽后整行被推到右侧，左侧出现空白',
    );

    // 程序化负偏移（旧状态残留 / 动画被打断）：帧尾必须回正
    final state = tester.state<SourceBarScrollViewState>(
      find.byType(SourceBarScrollView),
    );
    state.controller.jumpTo(-200);
    await tester.pump();
    await tester.pump();
    expect(
      _firstX(tester, keys[0]),
      closeTo(14.0, 0.5),
      reason: '负滚动位置没有被回正，第一颗胶囊没有贴左',
    );
  });

  testWidgets('切平台把选中胶囊滚到左边缘且滚动位置非负', (tester) async {
    final keys = List.generate(5, (_) => GlobalKey());
    await tester.pumpWidget(
      _host(SourceBarScrollView(children: _pills(keys))),
    );
    await tester.pumpAndSettle();

    await Scrollable.ensureVisible(
      keys[2].currentContext!,
      alignment: 0.0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.fastLinearToSlowEaseIn,
    );
    await tester.pumpAndSettle();

    final state = tester.state<SourceBarScrollViewState>(
      find.byType(SourceBarScrollView),
    );
    expect(state.controller.offset, greaterThanOrEqualTo(0.0));
    expect(
      tester.getTopLeft(find.byKey(keys[2])).dx -
          tester.getTopLeft(find.byType(SourceBarScrollView)).dx,
      closeTo(14.0, 0.5),
    );
  });
}
