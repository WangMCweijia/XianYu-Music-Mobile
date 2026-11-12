import 'dart:convert';
import 'dart:io';

import '../core/app_http.dart';
import '../core/application_logger.dart';

/// 判断一首歌是不是粤语。
///
/// 粤拼只在粤语歌上才有意义：国语歌按粤音标注是错的（「没」mui6 / mei6），
/// 所以不能「所有中文歌词一律转」。判断分两步，先免费的后花钱的：
///
/// 1. **看歌词**：出现粤语专用字（唔、嘅、係、咗、佢、哋、冇、睇、喺、嚟…）
///    基本可以认定是粤语。绝大多数港乐歌词是口语化的，这一步就能定。
/// 2. **看歌曲语言**：老派港乐（梅艳芳《梦伴》、BEYOND《海阔天空》）写的是
///    标准书面语，歌词里一个粤语专用字都没有 —— 只能按歌名 + 歌手去 QQ
///    查一次曲目详情，`language == 1` 就是粤语（实测：海阔天空/富士山下/
///    囍帖街 = 1，稻香/江南 = 0，Lemon = 3，Love Story = 5）。
///
/// 查不到（离线、接口抽风、歌太冷门）就当不是粤语：宁可不出粤拼，
/// 也不要把国语歌标成粤音。结果按「歌名|歌手」缓存 12 小时，失败结果不缓存。
class CantoneseDetector {
  CantoneseDetector._();

  static final CantoneseDetector instance = CantoneseDetector._();

  /// 缓存有效期。歌不会中途换语言，长一点没坏处。
  static const Duration _ttl = Duration(hours: 12);

  /// 一次识别的总预算。歌词显示不该为了转写等太久。
  static const Duration _budget = Duration(milliseconds: 2500);

  static const int _cacheMax = 200;

  /// 粤语口语/书面里只属于粤语的字。'呢' 在国语里也有（呢喃），
  /// 所以要求**不同字**出现 2 个以上才判定，避免误伤。
  static const String _markers = '嘅咗唔係佢哋冇睇喺嚟嗰咁咩啲乜噉畀攞嘢瞓諗';

  /// 合集常见的占位歌手，等价于「歌手未知」（比较前已归一化）。
  static const Set<String> _placeholderArtists = {
    '群星',
    '未知',
    '佚名',
    '未知歌手',
    '未知艺人',
    'variousartists',
    'various',
    'va',
  };

  final Map<String, (bool, DateTime)> _cache = {};

  Future<bool> isCantonese({
    required String title,
    required String artist,
    required String lyricText,
  }) async {
    if (_lyricLooksCantonese(lyricText)) return true;
    final key = '${_norm(title)}|${_norm(artist)}';
    if (key == '|') return false;
    final hit = _cache[key];
    final now = DateTime.now();
    if (hit != null && now.difference(hit.$2) < _ttl) return hit.$1;

    bool? probed;
    try {
      probed = await _probeQq(title, artist).timeout(
        _budget,
        onTimeout: () => null,
      );
    } catch (e) {
      AppLog.debug('lyric', '粤语识别异常: $e');
    }
    if (probed == null) return false;
    _remember(key, probed, now);
    AppLog.debug('lyric', '粤语识别: $title / $artist -> $probed');
    return probed;
  }

  bool _lyricLooksCantonese(String text) {
    if (text.isEmpty) return false;
    final seen = <String>{};
    for (final ch in _markers.split('')) {
      if (text.contains(ch)) seen.add(ch);
      if (seen.length >= 2) return true;
    }
    return false;
  }

  void _remember(String key, bool value, DateTime at) {
    _cache[key] = (value, at);
    if (_cache.length > _cacheMax) _cache.remove(_cache.keys.first);
  }

  Future<bool?> _probeQq(String title, String artist) async {
    final t = title.trim();
    if (t.isEmpty) return null;
    final artistText = _isPlaceholderArtist(artist) ? '' : artist.trim();
    final keyword = artistText.isEmpty ? t : '$t $artistText';
    final searchBody = await _get(
      Uri.https('c.y.qq.com', '/soso/fcgi-bin/client_search_cp', {
        'format': 'json',
        'n': '10',
        'w': keyword,
      }),
    );
    if (searchBody == null) return null;
    final mid = _pickSongMid(searchBody, t, artist);
    if (mid == null) return null;

    final detailBody = await _get(
      Uri.https('c.y.qq.com', '/v8/fcg-bin/fcg_play_single_song.fcg', {
        'songmid': mid,
        'format': 'json',
        'platform': 'yqq',
      }),
    );
    if (detailBody == null) return null;
    final dynamic decoded;
    try {
      decoded = jsonDecode(detailBody);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final songs = decoded['data'];
    if (songs is! List || songs.isEmpty) return null;
    final first = songs.first;
    if (first is! Map) return null;
    final language = first['language'];
    if (language is! int) return null;
    // QQ 的 language：0=国语 1=粤语 3=日语 5=英语/其他
    return language == 1;
  }

  String? _pickSongMid(String searchBody, String title, String artist) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(searchBody);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final data = decoded['data'];
    if (data is! Map) return null;
    final song = data['song'];
    if (song is! Map) return null;
    final list = song['list'];
    if (list is! List) return null;

    final wantTitle = _norm(title);
    final wantArtist = _norm(_firstArtist(artist));
    final artistUnknown =
        wantArtist.isEmpty || _placeholderArtists.contains(wantArtist);
    String? bestMid;
    var bestScore = 0;
    for (final item in list) {
      if (item is! Map) continue;
      final mid = item['songmid'];
      if (mid is! String || mid.isEmpty) continue;
      final name = _norm('${item['songname'] ?? ''}');
      if (name.isEmpty || wantTitle.isEmpty) continue;
      if (!_titleAlike(wantTitle, name)) continue;
      final singers = item['singer'];
      final candArtist = _norm(
        singers is List
            ? singers
                  .map((s) => (s is Map ? '${s['name'] ?? ''}' : ''))
                  .where((s) => s.isNotEmpty)
                  .join('/')
            : '',
      );
      var score = 10;
      if (artistUnknown || candArtist.isEmpty) {
        score += 1;
      } else if (candArtist == wantArtist) {
        score += 100;
      } else if (candArtist.contains(wantArtist) ||
          wantArtist.contains(candArtist)) {
        score += 60;
      } else {
        continue;
      }
      if (score > bestScore) {
        bestScore = score;
        bestMid = mid;
      }
    }
    return bestMid;
  }

  Future<String?> _get(Uri uri) async {
    HttpClientResponse? resp;
    try {
      resp = await appGet(
        uri,
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
          'Referer': 'https://y.qq.com/',
        },
      );
      if (resp.statusCode != 200) return null;
      return await resp.transform(utf8.decoder).join();
    } catch (e) {
      AppLog.debug('lyric', '粤语识别请求失败: $e');
      return null;
    }
  }

  /// 歌名/歌手比对前的归一化：去括号补充、去标点空白、统一小写。
  static String _norm(String s) {
    var t = s.toLowerCase();
    t = t.replaceAll(RegExp(r'[\(（\[【].*?[\)）\]】]'), '');
    t = t.replaceAll(RegExp(r'[\s\-_·•,，、/&+!！?？.。:：]'), '');
    return t.trim();
  }

  static bool _isPlaceholderArtist(String artist) =>
      _placeholderArtists.contains(_norm(_firstArtist(artist)));

  static String _firstArtist(String artist) {
    final parts = artist.split(RegExp(r'[/、,&]'));
    return parts.isEmpty ? '' : parts.first.trim();
  }

  /// 歌名是否算同一首：互相包含，或长度 3 字以上时允许 1 个字的差异。
  /// 「喜帖街」和 QQ 的「囍帖街」是同一首，只差一个异体字 —— 卡死相等
  /// 会让这类歌永远查不到语言。
  static bool _titleAlike(String a, String b) {
    if (a == b) return true;
    if (a.length >= 3 && b.length >= 3) {
      if (a.contains(b) || b.contains(a)) return true;
    }
    if (a.length < 3 || b.length < 3) return false;
    return _editDistance(a, b) <= 1;
  }

  static int _editDistance(String a, String b) {
    final prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      var last = prev[0];
      prev[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final temp = prev[j];
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        prev[j] = [prev[j] + 1, prev[j - 1] + 1, last + cost].reduce(
          (x, y) => x < y ? x : y,
        );
        last = temp;
      }
    }
    return prev[b.length];
  }
}
