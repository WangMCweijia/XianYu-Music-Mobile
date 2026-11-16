import 'package:flutter_test/flutter_test.dart';

import 'package:xianyu_music_mobile/src/lyrics/lyric_timing.dart';

/// 「当前行」判定的回归测试。
///
/// 现场 bug（2026-11-16，真机音狐 2.0.16）：歌曲播到中后段拖动进度条，
/// 歌词详情页整屏糊成一片、没有一行清晰。原因是进度被 seek 回 0 时
/// `_activeIndexFor` 返回 -1 —— 渲染层拿不到任何 isActive 行，所有行都落进
/// `dist >= 1` 的模糊分支；而自动滚动那边是从 0 起算的，两边语义不一致。
void main() {
  group('activeLineIndexFor', () {
    test('空歌词返回 -1', () {
      expect(activeLineIndexFor(const <int>[], 0), -1);
      expect(activeLineIndexFor(const <int>[], 30000), -1);
    });

    test('进度早于首行时间戳时取第 0 行（本次 bug 的根因）', () {
      // 首行 12s 才进来（前奏长 / 歌词偏移为正），进度被拖到 0。
      const times = [12000, 18000, 24000];
      expect(activeLineIndexFor(times, 0), 0);
      expect(activeLineIndexFor(times, 11999), 0);
      // 歌词偏移把 curMs 推成负数也一样。
      expect(activeLineIndexFor(times, -3500), 0);
    });

    test('命中边界时取该行（<= 语义）', () {
      const times = [0, 5000, 10000];
      expect(activeLineIndexFor(times, 0), 0);
      expect(activeLineIndexFor(times, 4999), 0);
      expect(activeLineIndexFor(times, 5000), 1);
      expect(activeLineIndexFor(times, 10000), 2);
    });

    test('超出末行停在最后一行', () {
      const times = [0, 5000, 10000];
      expect(activeLineIndexFor(times, 999999), 2);
    });

    test('重复时间戳取最后一个', () {
      const times = [0, 5000, 5000, 9000];
      expect(activeLineIndexFor(times, 5000), 2);
    });

    test('返回下标永远落在 [0, length-1]，绝不会是 -1（有词时）', () {
      const times = [3000, 8000, 15000, 22000];
      for (var cur = -10000; cur <= 30000; cur += 250) {
        final idx = activeLineIndexFor(times, cur);
        expect(idx, inInclusiveRange(0, times.length - 1),
            reason: 'curMs=$cur 时越界');
      }
    });
  });
}
