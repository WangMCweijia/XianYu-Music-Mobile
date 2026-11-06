import 'package:flutter_test/flutter_test.dart';
import 'package:xianyu_music_mobile/src/plugin/plugin_models.dart';

PluginSource _p(String id, int? order) => PluginSource(
      id: id,
      name: id,
      format: PluginFormat.lx,
      importedAt: 0,
      sortOrder: order,
    );

List<String> _ids(List<PluginSource> list) => list.map((e) => e.id).toList();

void main() {
  group('reorderAfterPluginUpdate', () {
    test('更新后回到旧下标，而不是留在末尾', () {
      // 场景：a/b/c/d 四个插件，b 更新后换 id 为 b2（安装时追加在末尾）
      final before = [_p('a', 0), _p('b', 1), _p('c', 2), _p('d', 3)];
      final oldIndex = before.indexWhere((s) => s.id == 'b');
      final afterInstall = [...before, _p('b2', 4)];
      final got = reorderAfterPluginUpdate(
        afterInstall,
        'b2',
        oldIndex,
        dropId: 'b',
      );
      expect(_ids(got), ['a', 'b2', 'c', 'd']);
    });

    test('旧记录已被提前移除时也回到原位（下标不再前移）', () {
      final before = [_p('a', 0), _p('b', 1), _p('c', 2)];
      final afterRemove = [_p('a', 0), _p('c', 2), _p('b2', 3)];
      final got = reorderAfterPluginUpdate(afterRemove, 'b2', 1);
      expect(_ids(got), ['a', 'b2', 'c']);
    });

    test('更新列表末尾的插件时位置不变', () {
      final got = reorderAfterPluginUpdate(
        [_p('a', 0), _p('b', 1), _p('c', 2), _p('c2', 3)],
        'c2',
        2,
        dropId: 'c',
      );
      expect(_ids(got), ['a', 'b', 'c2']);
    });

    test('下标越界按末尾处理，不抛异常', () {
      final got = reorderAfterPluginUpdate(
        [_p('a', 0), _p('b', 1), _p('c', 2), _p('c2', 3)],
        'c2',
        99,
        dropId: 'c',
      );
      expect(_ids(got), ['a', 'b', 'c2']);
    });

    test('找不到新记录时只做剔除', () {
      final got = reorderAfterPluginUpdate(
        [_p('a', 0), _p('b', 1)],
        'ghost',
        0,
        dropId: 'b',
      );
      expect(_ids(got), ['a']);
    });
  });

  group('renumberPluginSources', () {
    test('sortOrder 与下标对齐', () {
      final got = renumberPluginSources([
        _p('a', 0),
        _p('b', 5),
        _p('c', 2),
      ]);
      expect(got.map((e) => e.sortOrder).toList(), [0, 1, 2]);
    });

    test('历史数据里的 null 序号一并收敛', () {
      final got = renumberPluginSources([
        _p('a', null),
        _p('b', null),
        _p('c', 1),
      ]);
      expect(got.map((e) => e.sortOrder).toList(), [0, 1, 2]);
      expect(_ids(got), ['a', 'b', 'c']);
    });

    test('序号已正确时不重建对象（避免无谓的状态抖动）', () {
      final src = [_p('a', 0), _p('b', 1)];
      final got = renumberPluginSources(src);
      expect(identical(got[0], src[0]), isTrue);
      expect(identical(got[1], src[1]), isTrue);
    });
  });
}
