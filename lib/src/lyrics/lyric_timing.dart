/// 歌词「当前行」的时间判定。
///
/// 单独抽出来是因为这条判定有**两个调用方**（渲染高亮 + 自动滚动），历史上
/// 各写了一套，语义还不同：滚动那边从 0 起算，渲染那边没有命中就返回 -1。
/// 结果就是「进度被拖回开头 / seek 期间播放器回 0 / 歌词首行不是 00:00」时，
/// 渲染层拿不到任何 isActive 行，整屏歌词一起走模糊分支，糊成一片。
///
/// 契约：**有词时永远返回合法下标**（最小 0，最大 length-1）；只有空歌词返回 -1。
/// 进度早于首行时间戳时，第 0 行就是当前行（还没唱到，但它是下一句）。
int activeLineIndexFor(Iterable<int> timeMs, int curMs) {
  var seen = false;
  var index = 0;
  var i = 0;
  for (final t in timeMs) {
    seen = true;
    if (t <= curMs) {
      index = i;
    } else {
      break;
    }
    i++;
  }
  return seen ? index : -1;
}
