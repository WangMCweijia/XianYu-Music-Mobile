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
///             attach_lrc_aux_lines(&mut qrc_candidate, tail);   // ±2s 就近挂载，按角色分流
///
/// 插件主文是 QRC 内层行（`[540,4170]You (540,480)make`）但没有 XML 外壳，
/// 于是整段挂载逻辑从未执行。
///
/// 罗马音（日语罗马字 / 粤语粤拼）走同一条挂载路径：前缀 `【罗马音】` 由 Rust
/// detect_explicit_role 识别为 Roman，写进 roman_text；`【翻译】` 写 translated_text。
/// 两轨必须分开，否则粤语歌的粤拼会被当成译文顶掉真正的中文翻译。
void main() {
  const main = '[00:10.000]Hello world\n'
      '[00:14.000]Second line\n'
      '[00:18.000]Third line';

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
  });

  group('罗马音轨（日语罗马字 / 粤语粤拼）', () {
    // 粤语样本取自线上 romalrc 实测（《海阔天空》网易返回的粤拼）
    const canto = '[00:18.850]今天我\n[00:25.500]原谅我这一生';
    const cantoRoma = '[00:18.850]gam tin o hon yei lei hon sv piu guo\n'
        '[00:25.500]wai zoe lang koe liu di sam wo piu yvn fong';

    test('对齐后带【罗马音】前缀，不会串成译文', () {
      final aligned = alignRomanizationToMainLyric(canto, cantoRoma);

      expect(aligned, contains('[00:18.850]【罗马音】gam tin o hon'));
      expect(aligned, contains('[00:25.500]【罗马音】wai zoe lang koe'));
      expect(aligned, isNot(contains('【翻译】')));
    });

    test('罗马音时间戳错位时吸附回对应主行', () {
      final aligned = alignRomanizationToMainLyric(
          canto, '[00:19.050]gam tin o hon\n[00:25.700]wai zoe lang koe');

      expect(aligned, contains('[00:18.850]【罗马音】gam tin o hon'));
      expect(aligned, contains('[00:25.500]【罗马音】wai zoe lang koe'));
    });

    test('空行被丢掉，不生成只有时间戳的裸行', () {
      // 网易粤语 romalrc 前几行常是空（纯伴奏），不过滤会得到一堆空时间戳行
      final aligned = alignRomanizationToMainLyric(
          canto, '[00:18.850]\n[00:25.500]wai zoe lang koe');

      final lines = aligned
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      expect(lines.length, 1);
      expect(lines.single, contains('【罗马音】wai zoe lang koe'));
    });

    test('译文与罗马音同曲共存：两条前缀都保留', () {
      final translation =
          alignTranslationToMainLyric(canto, '[00:18.850]今天我');
      final romaji = alignRomanizationToMainLyric(canto, cantoRoma);

      final raw =
          composeLyricsRaw(canto, translation: translation, romaji: romaji);

      expect(raw, contains('【翻译】今天我'));
      expect(raw, contains('【罗马音】gam tin o hon'));
    });

    test('没有罗马音时组装结果与旧行为一致', () {
      final wrapped = composeLyricsRaw(main, translation: '');

      expect(wrapped, main);
      expect(wrapped, isNot(contains('QrcInfos')));
    });
  });
}
