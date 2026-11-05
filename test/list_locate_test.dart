import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xianyu_music_mobile/src/widgets/song_list_scroll_fabs.dart';

/// 定位当前播放歌曲：不能依赖「i × 行高」的估算。
///
/// 线上现场：第 52 首点定位后顶部显示第 55 首 —— 估算与真实布局脱节
/// （列表顶部内边距随折叠搜索栏/统计条变化、行高由内容实测）。这些用例
/// 锁住两件事：估算故意给错时仍能落到真实行顶；顶部内边距由列表自己
/// 的 precedingScrollExtent 提供，而不是调用方手算的 topInset。
void main() {
  const rowExtent = 72.0;

  Future<void> pumpList(
    WidgetTester tester,
    ScrollController controller, {
    required double padTop,
    int count = 80,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView.builder(
          controller: controller,
          padding: EdgeInsets.only(top: padTop, bottom: 40),
          itemExtent: rowExtent,
          itemCount: count,
          itemBuilder: (c, i) => SizedBox(
            height: rowExtent,
            child: Text('row $i'),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  /// revealListRow 内部是多轮 animateTo，测试里逐帧推进直到 Future 完成。
  Future<void> runLocate(
    WidgetTester tester,
    Future<void> future,
  ) async {
    var done = false;
    future.whenComplete(() => done = true);
    for (var i = 0; i < 400 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(done, isTrue, reason: 'revealListRow 未在 6.4s 内完成');
  }

  testWidgets('估算漏掉顶部内边距时仍精确对齐目标行', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpList(tester, controller, padTop: 120);

    // 故意给错估算：漏掉 120 的顶部内边距（线上就是这类偏差）
    await runLocate(
      tester,
      revealListRow(controller, 50, rowTopOf: (i) => i * rowExtent),
    );

    expect(controller.offset, closeTo(120 + 50 * rowExtent, 1.0));
  });

  testWidgets('无任何行高信息（播放队列传 null）也能落行', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpList(tester, controller, padTop: 0);

    await runLocate(tester, revealListRow(controller, 30));

    expect(controller.offset, closeTo(30 * rowExtent, 1.0));
  });

  testWidgets('行高不等（混排组头）时按实测行距外插', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    // 每 10 首插一个 26 高的组头，模拟字母索引列表
    double extentOf(int i) => i % 11 == 10 ? 26 : rowExtent;
    final offsets = <double>[];
    var acc = 0.0;
    for (var i = 0; i < 80; i++) {
      offsets.add(acc);
      acc += extentOf(i);
    }
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView.builder(
          controller: controller,
          itemCount: 80,
          itemExtentBuilder: (i, _) => extentOf(i),
          itemBuilder: (c, i) => SizedBox(
            height: extentOf(i),
            child: Text(i % 11 == 10 ? 'header' : 'row $i'),
          ),
        ),
      ),
    ));
    await tester.pump();

    await runLocate(tester, revealListRow(controller, 40));

    expect(controller.offset, closeTo(offsets[40], 1.0));
  });
}
