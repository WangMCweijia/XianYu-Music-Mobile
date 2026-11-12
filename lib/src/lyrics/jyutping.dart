import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import '../core/application_logger.dart';

/// 粤语歌词的「罗马音」：本地生成粤拼（Jyutping）。
///
/// 为什么必须本地生成：歌词源对粤语歌基本不给 roma 字段。实测 QQ 歌词接口
/// 梅艳芳《梦伴》（002jXeXq1t8FMR）、关淑怡《梦伴》（004Wsy0v1HCes9）的
/// `roma` 长度都是 0 —— 日语歌有，粤语歌没有。所以「打开罗马音」在粤语歌上
/// 一直是空的，只能自己转写。
///
/// 词表取自 ToJyutping（LSHK 粤拼方案，MIT），48k 条，压成 gz 约 282KB。
/// 按「最长词优先」切分：单字多音（行 haang4/hong4、长 coeng4/zoeng2、
/// 重 cung5/zung6）靠词条消歧，比逐字取第一个读音准得多；词表里没有的
/// 生僻字按单字读音，再没有就原样保留。
class JyutpingConverter {
  JyutpingConverter._();

  static const String _assetPath = 'assets/data/jyutping.tsv.gz';

  /// 词 → 读音（取词表第一条，最常用读音）。
  static Map<String, String>? _dict;

  /// 词条最长字数，决定每步回溯多少次。
  static int _maxKeyLen = 1;

  static Future<void>? _loading;

  static bool get isReady => (_dict?.isNotEmpty ?? false);

  /// 首次使用时加载词表（整个 app 生命周期只加载一次）。
  /// 失败不抛：粤语歌退回「没有罗马音」，其它功能不受影响。
  static Future<void> ensureLoaded() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      final data = await rootBundle.load(_assetPath);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final text = utf8.decode(gzip.decode(bytes));
      final map = <String, String>{};
      var maxLen = 1;
      for (final line in const LineSplitter().convert(text)) {
        final tab = line.indexOf('\t');
        if (tab <= 0 || tab >= line.length - 1) continue;
        map[line.substring(0, tab)] = line.substring(tab + 1);
        // 键全是 BMP 汉字，UTF-16 码元数即字数
        if (tab > maxLen) maxLen = tab;
      }
      _dict = map;
      _maxKeyLen = maxLen;
      AppLog.info('lyric', '粤拼词表已加载: ${map.length} 条，最长词 $_maxKeyLen 字');
    } catch (e) {
      AppLog.warn('lyric', '粤拼词表加载失败: $e');
      _dict = const {};
    }
  }

  /// 一行歌词 → 粤拼。非汉字（英文、数字、标点）原样保留。
  ///
  /// 汉字太少（例如整行是英文副歌）返回空串：否则会把原歌词再抄一遍，
  /// 白占一行版面。
  static String romanize(String text) {
    final dict = _dict;
    if (dict == null || dict.isEmpty || text.isEmpty) return '';
    final cps = text.runes.toList();
    final tokens = <String>[];
    final latin = StringBuffer();
    var hanCount = 0;

    void flushLatin() {
      if (latin.isEmpty) return;
      tokens.add(latin.toString());
      latin.clear();
    }

    var i = 0;
    while (i < cps.length) {
      final cp = cps[i];
      if (_isHan(cp)) {
        flushLatin();
        var hit = '';
        var consumed = 1;
        final remain = cps.length - i;
        final maxHere = remain < _maxKeyLen ? remain : _maxKeyLen;
        for (var len = maxHere; len >= 1; len--) {
          final key = String.fromCharCodes(cps.sublist(i, i + len));
          final value = dict[key];
          if (value != null) {
            hit = value;
            consumed = len;
            break;
          }
        }
        tokens.add(hit.isEmpty ? String.fromCharCode(cp) : hit);
        hanCount++;
        i += consumed;
      } else if (_isLatin(cp)) {
        latin.writeCharCode(cp);
        i++;
      } else {
        flushLatin();
        tokens.add(String.fromCharCode(cp));
        i++;
      }
    }
    flushLatin();
    // 整行没有汉字（英文副歌、拟声词）就不生成：否则只是把原词再抄一行。
    if (hanCount < 1) return '';
    return _joinTokens(tokens);
  }

  /// 标点前后不留空格，音节之间用一个空格。
  static String _joinTokens(List<String> tokens) {
    final buffer = StringBuffer();
    var prev = '';
    for (final token in tokens) {
      if (token.trim().isEmpty) continue;
      final isPunct = token.length == 1 && _isPunct(token.runes.first);
      if (buffer.isNotEmpty && !isPunct && !_isLeftPunct(prev)) {
        buffer.write(' ');
      }
      buffer.write(token);
      prev = token;
    }
    return buffer.toString().trim();
  }

  static bool _isHan(int cp) =>
      (cp >= 0x3400 && cp <= 0x4DBF) ||
      (cp >= 0x4E00 && cp <= 0x9FFF) ||
      (cp >= 0xF900 && cp <= 0xFAFF) ||
      (cp >= 0x20000 && cp <= 0x2FA1F);

  static bool _isLatin(int cp) =>
      (cp >= 0x30 && cp <= 0x39) ||
      (cp >= 0x41 && cp <= 0x5A) ||
      (cp >= 0x61 && cp <= 0x7A) ||
      cp == 0x27 || // '
      cp == 0x2019 || // ’
      cp == 0x2D; // -

  static const String _punctChars = '，。、！？；：,.!?;:·…—～「」『』【】《》（）()""\'';

  static bool _isPunct(int cp) => _punctChars.runes.contains(cp);

  static bool _isLeftPunct(String token) =>
      token.isNotEmpty && '（(「『【《'.contains(token);
}

/// 把粤拼写进已解析载荷里**空着**的 `romaji` 字段。
///
/// 只填空位：歌词源已经给了罗马音（日语歌）就不动，避免两种转写混在一行。
/// 逐字歌词的 `romajiWords` 不生成 —— 粤拼按词切分与逐字时间戳对不上，
/// 硬塞会让动效错位，整行显示反而更稳。
String injectJyutpingIntoPayload(String payloadJson) {
  if (payloadJson.isEmpty || payloadJson == 'null') return payloadJson;
  if (!JyutpingConverter.isReady) return payloadJson;
  final dynamic decoded;
  try {
    decoded = jsonDecode(payloadJson);
  } catch (_) {
    return payloadJson;
  }
  if (decoded is! Map<String, dynamic>) return payloadJson;
  final lines = decoded['displayLines'];
  if (lines is! List || lines.isEmpty) return payloadJson;

  var changed = false;
  for (final line in lines) {
    if (line is! Map<String, dynamic>) continue;
    final existing = (line['romaji'] as String?)?.trim() ?? '';
    if (existing.isNotEmpty) continue;
    final text = (line['text'] as String?) ?? '';
    if (text.trim().isEmpty) continue;
    final romaji = JyutpingConverter.romanize(text);
    if (romaji.isEmpty) continue;
    line['romaji'] = romaji;
    changed = true;
  }
  return changed ? jsonEncode(decoded) : payloadJson;
}
