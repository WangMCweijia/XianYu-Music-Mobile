import 'package:flutter_test/flutter_test.dart';

import 'package:xianyu_music_mobile/src/lyrics/lyrics_repository.dart';

/// 插件译文的两件事：时间戳对齐 + raw 组装（QRC 外壳哨兵）。
///
/// 线上实测（同一首英文歌，连续五次）：插件返回 `keys=[lyric, tlyric, …]`、
/// `tLen=821`、译文时间戳与主行逐个一致，界面却一个中文都没有。原因是 Rust 侧
/// 挂载插件译文的唯一入口要求文本里存在 `</QrcInfos>`：
///
///     if !qrc_candidate.is_empty() {
///         if let Some(end) = normalized.find("</QrcInfos>") {
///             attach_lrc_translation_lines(&mut qrc_candidate, tail);   // ±2s 就近挂载
///
/// 插件主文是 QRC 内层行（`[540,4170]You (540,480)make`）但没有 XML 外壳，
/// 于是整段挂载逻辑从未执行。
///
/// 罗马音不走这条路径：它要经过解析器的脚本特征判断「这一行是不是罗马音」，
/// 判错就会落进译文槽，导致开关关不掉、且因检测不到罗马音轨而长期禁用
/// （2026-11-11 真机复现）。改为解析完成后按时间戳写 `displayLines[*].romaji`。
void main() {
  const main = '[00:10.000]Hello world\n'
      '[00:14.000]Second line\n'
      '[00:18.000]Third line';

  /// 造一份和 Rust 输出同形的载荷：`time` 为秒，另有 text/translation/romaji。
  String payload(List<(double, String)> lines) {
    final items = lines
        .map((e) =>
            '{"time":${e.$1},"endTime":${e.$1 + 2},"text":"${e.$2}",'
            '"translation":"","romaji":"","isBg":false,"isDuet":false,'
            '"isDuetPartner":false}')
        .join(',');
    return '{"rawLyrics":"","meta":{},"displayLines":[$items]}';
  }

  List<String> readRomaji(String json) {
    final match = RegExp(r'"romaji":"([^"]*)"').allMatches(json).toList();
    return match.map((m) => m.group(1)!).toList();
  }

  List<String> readTranslation(String json) {
    final match = RegExp(r'"translation":"([^"]*)"').allMatches(json).toList();
    return match.map((m) => m.group(1)!).toList();
  }

  group('时间戳对齐', () {
    test('译文与主歌词同刻时保留，并补上角色前缀', () {
      final aligned = alignTranslationToMainLyric(
          main, '[00:10.000]你好世界\n[00:14.000]第二行\n[00:18.000]第三行');

      expect(aligned, contains('[00:10.000]【翻译】你好世界'));
      expect(aligned, contains('[00:14.000]【翻译】第二行'));
      expect(aligned, contains('[00:18.000]【翻译】第三行'));
    });

    test('译文时间戳错位时吸附回对应主行', () {
      final aligned = alignTranslationToMainLyric(
          main, '[00:10.200]你好世界\n[00:14.200]第二行\n[00:18.200]第三行');

      expect(aligned, contains('[00:10.000]【翻译】你好世界'));
      expect(aligned, contains('[00:14.000]【翻译】第二行'));
      expect(aligned, contains('[00:18.000]【翻译】第三行'));
    });

    test('译文完全没有时间戳时按行序补齐', () {
      final aligned = alignTranslationToMainLyric(main, '你好世界\n第二行\n第三行');

      expect(aligned, contains('[00:10.000]【翻译】你好世界'));
      expect(aligned, contains('[00:14.000]【翻译】第二行'));
      expect(aligned, contains('[00:18.000]【翻译】第三行'));
    });

    test('译文缺行时剩下的不会被整体错位', () {
      final aligned = alignTranslationToMainLyric(
          main, '[00:10.000]你好世界\n[00:18.000]第三行');

      expect(aligned, contains('[00:10.000]【翻译】你好世界'));
      expect(aligned, contains('[00:18.000]【翻译】第三行'));
      expect(aligned, isNot(contains('[00:14.000]【翻译】第三行')));
    });

    test('译文自带 QRC 行首时剥掉再对齐（译文必须保持 LRC 形状）', () {
      // 译文写成 [起,时长] 会被 parse_qrc 当成主文行重复收录，必须还原成 LRC。
      const krcMain = '[10000,1200]Hello world\n[14000,1200]Second line';
      final aligned = alignTranslationToMainLyric(
          krcMain, '[10000,1200]你好世界\n[14000,1200]第二行');

      expect(aligned, contains('[00:10.000]【翻译】你好世界'));
      expect(aligned, contains('[00:14.000]【翻译】第二行'));
    });
  });

  group('raw 组装（QRC 外壳哨兵）', () {
    test('主文是 QRC 内层行时补出外壳，译文留在 Infos 之后', () {
      const qrcBody = '[540,4170]You (540,480)make (1020,540)me\n'
          '[5760,4170]Every (5760,480)time';
      const tlyric = '[00:00.540]是你让我想为爱高歌\n[00:05.760]每当我一抬头';

      final raw = composePluginLyricsRaw(qrcBody, tlyric);

      expect(raw, contains('</QrcInfos>'), reason: '缺这个哨兵标记 Rust 不会挂载译文');
      expect(raw.indexOf(qrcBody), lessThan(raw.indexOf('</QrcInfos>')),
          reason: '主文应在 QRC 文档内');
      expect(raw.indexOf(tlyric), greaterThan(raw.indexOf('</QrcInfos>')),
          reason: '译文应在 Infos 之后，作为尾部 LRC 被挂载');
    });

    test('主文是普通 LRC 时不加外壳，按原样拼接', () {
      final raw = composePluginLyricsRaw(main, '[00:10.000]【翻译】你好世界');

      expect(raw, isNot(contains('QrcInfos')));
      expect(raw, startsWith(main));
    });

    test('没有译文时原样返回主文', () {
      const qrcBody = '[540,4170]You (540,480)make';
      expect(composePluginLyricsRaw(qrcBody, ''), contains(qrcBody));
      expect(composePluginLyricsRaw(qrcBody, ''), isNot(contains('QrcInfos')));
    });

    test('组装不掺入罗马音：主文里不会出现罗马音行', () {
      final raw = composePluginLyricsRaw(main, '[00:10.000]【翻译】你好世界');
      expect(raw, isNot(contains('罗马音')));
      expect(raw.split('\n').length, main.split('\n').length + 1);
    });
  });

  group('罗马音注入（解析后按时间戳写 romaji 字段）', () {
    // 粤语样本取自线上 romalrc 实测（《海阔天空》网易返回的粤拼）
    const cantoRoma = '[00:10.000]gam tin o hon yei lei hon sv piu guo\n'
        '[00:14.000]wai zoe lang koe liu di sam wo piu yvn fong';

    test('粤拼写进对应行的 romaji，译文保持为空', () {
      final json = payload([(10.0, '今天我'), (14.0, '原谅我这一生')]);
      final out = injectRomajiIntoPayload(json, cantoRoma);

      expect(readRomaji(out), ['gam tin o hon yei lei hon sv piu guo',
        'wai zoe lang koe liu di sam wo piu yvn fong']);
      expect(readTranslation(out), ['', '']);
    });

    test('罗马音时间戳错位时吸附到最近行', () {
      final json = payload([(10.0, '今天我'), (14.0, '原谅我这一生')]);
      final out = injectRomajiIntoPayload(
          json, '[00:10.320]gam tin o hon\n[00:14.280]wai zoe lang koe');

      expect(readRomaji(out), ['gam tin o hon', 'wai zoe lang koe']);
    });

    test('空行与纯伴奏行被丢掉，不会生成空 romaji', () {
      final json = payload([(10.0, '今天我'), (14.0, '原谅我这一生')]);
      final out = injectRomajiIntoPayload(
          json, '[00:10.000]\n[00:14.000]wai zoe lang koe');

      expect(readRomaji(out), ['', 'wai zoe lang koe']);
    });

    test('已有 romaji 的行不被覆盖（原生解析结果优先）', () {
      const json = '{"displayLines":[{"time":10.0,"text":"今天我",'
          '"translation":"","romaji":"原生罗马音"}]}';
      final out = injectRomajiIntoPayload(json, '[00:10.000]gam tin o hon');

      expect(readRomaji(out), ['原生罗马音']);
    });

    test('时间差超过窗口时不硬塞', () {
      final json = payload([(10.0, '今天我')]);
      final out = injectRomajiIntoPayload(json, '[00:59.000]gam tin o hon');

      expect(readRomaji(out), ['']);
      expect(out, json, reason: '没有任何改动时原样返回，避免白构造一份载荷');
    });

    test('空罗马音轨或坏载荷时原样返回', () {
      final json = payload([(10.0, '今天我')]);
      expect(injectRomajiIntoPayload(json, ''), json);
      expect(injectRomajiIntoPayload('not json', cantoRoma), 'not json');
    });

    test('QRC 逐字行的时间标注被清掉，不污染罗马音文本', () {
      final json = payload([(10.0, '今天我')]);
      final out = injectRomajiIntoPayload(
          json, '[00:10.000]gam(10000,200) tin(10200,180) o(10380,200) hon');

      expect(readRomaji(out), ['gam tin o hon']);
    });
  });
}
