// 临时几何探针：把真实层级逐层搭出来，打印平台行的实际 x 坐标。
// 目的：判断「平台行从屏幕中线开始」是布局链造成的，还是滚动偏移造成的。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const double kTopInset = 54; // 真机状态栏

/// 与 _buildSourceBar 等价：SizedBox(height:40) + 横向 ListView + padding
Widget sourceBar({double pad = 14, List<GlobalKey>? keys, int n = 8}) {
  return SizedBox(
    height: 40,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: pad),
      children: [
        for (var i = 0; i < n; i++)
          Padding(
            key: keys?[i],
            padding: const EdgeInsets.only(right: 8),
            child: Container(
              height: 40,
              width: 80,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              alignment: Alignment.center,
              child: Text('平台$i', style: const TextStyle(fontSize: 13)),
            ),
          ),
      ],
    ),
  );
}

Widget tabBar() => DefaultTabController(
      length: 4,
      child: TabBar(
        dividerColor: Colors.transparent,
        tabs: const [
          Tab(text: '单曲'),
          Tab(text: '歌手'),
          Tab(text: '专辑'),
          Tab(text: '歌单'),
        ],
      ),
    );

Widget chromeBottom({List<GlobalKey>? keys}) => SizedBox(
      height: 46 + 40,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: 46, child: tabBar()),
          sourceBar(keys: keys),
        ],
      ),
    );

/// 与 GlassTopBar._bar 等价：Column(默认 center) + statusBar + toolbar + bottom
Widget glassBar({List<GlobalKey>? keys}) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: kTopInset),
        SizedBox(
          height: kToolbarHeight,
          child: Row(
            children: [
              const SizedBox(width: 48, child: BackButton()),
              Expanded(
                child: Container(
                  height: 40,
                  margin: const EdgeInsets.only(right: 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
              const SizedBox(width: 48, child: Icon(Icons.search)),
            ],
          ),
        ),
        chromeBottom(keys: keys),
      ],
    );

Future<void> mount(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(1272, 2800);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(backgroundColor: const Color(0xFFF4F4F6), body: page),
    ),
  );
  await tester.pump();
}

String report(String tag, List<GlobalKey> keys, WidgetTester tester) {
  final xs = <String>[];
  for (final k in keys) {
    final ctx = k.currentContext;
    if (ctx == null) {
      xs.add('null');
      continue;
    }
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) {
      xs.add('nobox');
      continue;
    }
    final tl = box.localToGlobal(Offset.zero);
    xs.add(tl.dx.toStringAsFixed(1));
  }
  var tabCenters = '';
  for (final t in ['单曲', '歌手', '专辑', '歌单']) {
    final f = find.text(t);
    if (f.evaluate().isNotEmpty) {
      final c = tester.getCenter(f);
      tabCenters += '${c.dx.toStringAsFixed(0)} ';
    }
  }
  return 'PROBE[$tag] pillX=${xs.join(",")} tabCenters=$tabCenters';
}

void main() {
  testWidgets('A: 裸 Column（TabBar + 平台行）', (tester) async {
    final keys = List.generate(8, (_) => GlobalKey());
    await mount(
      tester,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: kTopInset),
          SizedBox(height: 46, child: tabBar()),
          sourceBar(keys: keys),
        ],
      ),
    );
    debugPrint(report('A', keys, tester));
  });

  testWidgets('B: 完整玻璃顶栏（Column + toolbar + bottom）', (tester) async {
    final keys = List.generate(8, (_) => GlobalKey());
    await mount(tester, glassBar(keys: keys));
    debugPrint(report('B', keys, tester));
  });

  testWidgets('C: 顶栏放进 Stack + Positioned（真实页结构）', (tester) async {
    final keys = List.generate(8, (_) => GlobalKey());
    await mount(
      tester,
      Stack(
        children: [
          const SizedBox.expand(child: ColoredBox(color: Color(0xFFF4F4F6))),
          Positioned(top: 0, left: 0, right: 0, child: glassBar(keys: keys)),
        ],
      ),
    );
    debugPrint(report('C', keys, tester));
  });

  testWidgets('D: 平台行单独 mount（基线）', (tester) async {
    final keys = List.generate(8, (_) => GlobalKey());
    await mount(tester, Align(alignment: Alignment.topLeft, child: sourceBar(keys: keys)));
    debugPrint(report('D', keys, tester));
  });
}
