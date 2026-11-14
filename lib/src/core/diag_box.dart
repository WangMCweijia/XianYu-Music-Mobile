/// 通用「黑匣子」：把关键诊断样本留在内存里，随日志一起导出。
///
/// 为什么需要它：应用日志是 300 条环形缓冲，用户往往在复现之后过一会儿才
/// 导出，中间的正常操作把现场挤掉；更常见的是「装完包→导出」时现场还没
/// 发生，导出的日志只有启动那十几秒。黑匣子独立于日志环，按固定采样把
/// 最近 N 条样本与「最差样本」留在内存，导出时一起带出来，现场就不会丢。
class DiagBox {
  DiagBox(this.name, {this.capacity = 240}) {
    all.add(this);
  }

  /// 所有已注册的黑匣子，导出日志时逐个 dump。
  static final List<DiagBox> all = <DiagBox>[];

  final String name;
  final int capacity;

  final List<String> _lines = <String>[];

  /// 最差样本（按 [add] 传入的 severity 取最大），带链信息才有定位价值。
  String? _worst;
  double _worstSeverity = double.negativeInfinity;

  /// 历史累计采样条数（含已被挤掉的），用来判断「有没有采到过」。
  int total = 0;

  String? get worst => _worst;

  /// 记一条样本。[severity] 越大越异常，用于挑出最差样本（重置类事件传 0）。
  void add(String line, {double severity = 0}) {
    total++;
    _lines.add(line);
    if (_lines.length > capacity) {
      _lines.removeRange(0, _lines.length - capacity);
    }
    if (severity > _worstSeverity) {
      _worstSeverity = severity;
      _worst = line;
    }
  }

  void clear() {
    _lines.clear();
    _worst = null;
    _worstSeverity = double.negativeInfinity;
    total = 0;
  }

  /// 导出用文本；[tail] 为最多带出的尾部样本数。
  String dump({int tail = 60}) {
    if (total == 0) return '';
    final buf = StringBuffer()
      ..writeln('【$name 黑匣子】累计采样 $total 条，内存保留 ${_lines.length} 条');
    if (_worst != null) buf.writeln('最差样本：$_worst');
    final from = _lines.length > tail ? _lines.length - tail : 0;
    for (var i = from; i < _lines.length; i++) {
      buf.writeln(_lines[i]);
    }
    return buf.toString().trimRight();
  }

  /// 导出时拼接所有黑匣子；没有任何样本时返回空串。
  static String dumpAll() {
    final parts = <String>[];
    for (final b in all) {
      final s = b.dump();
      if (s.isNotEmpty) parts.add(s);
    }
    return parts.join('\n\n');
  }
}
