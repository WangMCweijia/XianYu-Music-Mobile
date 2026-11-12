// 临时布局探针：确认「平台选择行左侧整段空白」的机制。
// 与 _buildSourceBar 等价的横向 ListView：固定高 40、水平内边距 14、
// 5 个 90x40 的胶囊、右间距 8，视口 460 逻辑像素。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _bar(
  ScrollPhysics physics,
  ScrollController controller,
  List<GlobalKey> keys,
) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(460, 900)),
      child: Center(
        child: SizedBox(
          width: 460,
          height: 40,
          child: ListView(
            controller: controller,
            scrollDirection: Axis.horizontal,
            physics: physics,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            children: [
              for (var i = 0; i < 5; i++)
                Padding(
                  key: keys[i],
                  padding: const EdgeInsets.only(right: 8),
                  child: Container(
                    width: 90,
                    height: 40,
                    color: i == 0 ? Colors.red : Colors.white,
                    alignment: Alignment.center,
                    child: Text('P$i'),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

double _firstPillX(List<GlobalKey> keys) {
  final box = keys[0].currentContext!.findRenderObject()! as RenderBox;
  return box.localToGlobal(Offset.zero).dx;
}

void main() {
  for (final entry in <String, ScrollPhysics>{
    'Bouncing': const BouncingScrollPhysics(),
    'Clamping': const ClampingScrollPhysics(),
  }.entries) {
    testWidgets('PROBE ${entry.key}', (tester) async {
      final ctrl = ScrollController();
      addTearDown(ctrl.dispose);
      final keys = List.generate(5, (_) => GlobalKey());
      await tester.pumpWidget(_bar(entry.value, ctrl, keys));
      await tester.pumpAndSettle();
      // ignore: avoid_print
      print('PROBE ${entry.key} INITIAL offset=${ctrl.offset} '
          'min=${ctrl.position.minScrollExtent} '
          'max=${ctrl.position.maxScrollExtent} firstPillX=${_firstPillX(keys)}');

      // 切平台时 _onSourcePageChanged / _ensureVisibleSource 的真实调用
      await Scrollable.ensureVisible(
        keys[0].currentContext!,
        alignment: 0.5,
        duration: const Duration(milliseconds: 300),
        curve: Curves.fastLinearToSlowEaseIn,
      );
      await tester.pumpAndSettle();
      // ignore: avoid_print
      print('PROBE ${entry.key} ENSURE_VISIBLE_FIRST offset=${ctrl.offset} '
          'firstPillX=${_firstPillX(keys)}');

      // 模拟弹性 overscroll 停在负偏移（回弹动画被 animateTo 打断的场景）
      ctrl.jumpTo(-200);
      await tester.pump();
      // ignore: avoid_print
      print('PROBE ${entry.key} NEGATIVE_OFFSET offset=${ctrl.offset} '
          'firstPillX=${_firstPillX(keys)}');
      await tester.pumpAndSettle();
      // ignore: avoid_print
      print('PROBE ${entry.key} AFTER_SETTLE offset=${ctrl.offset} '
          'firstPillX=${_firstPillX(keys)}');
    });
  }
}
