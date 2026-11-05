import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../core/app_http.dart';
import '../core/application_logger.dart';
import 'plugin_comments.dart';

const _pageSize = 20;

String? detectCommentPlatform({
  String? pluginName,
  Map<String, dynamic>? musicInfo,
}) {
  if (musicInfo == null && (pluginName == null || pluginName.isEmpty)) {
    return null;
  }

  const lxCodes = {
    'wy': 'wy',
    'tx': 'tx',
    'kg': 'kg',
    'kw': 'kw',
    'mg': 'mg',
  };
  final sourceKey = musicInfo?['source'];
  if (sourceKey is String && lxCodes.containsKey(sourceKey)) {
    return lxCodes[sourceKey];
  }

  String haystack = pluginName ?? '';
  void append(Object? v) {
    if (v is String && v.isNotEmpty) haystack = '$haystack|$v';
  }

  append(musicInfo?['platform']);
  final raw = musicInfo?['rawData'];
  if (raw is Map) {
    append(raw['platform']);
    append(raw['source']);
  }
  append(musicInfo?['source']);

  final patterns = <(String, RegExp)>[
    ('wy', RegExp(r'网易|netease|\bwy\b', caseSensitive: false)),
    ('tx', RegExp(r'qq', caseSensitive: false)),
    ('kg', RegExp(r'酷狗|kugou|\bkg\b', caseSensitive: false)),
    ('kw', RegExp(r'酷我|kuwo|\bkw\b', caseSensitive: false)),
    ('mg', RegExp(r'咪咕|migu|\bmg\b', caseSensitive: false)),
    ('qishui', RegExp(r'汽水|qishui', caseSensitive: false)),
  ];
  for (final (platform, pattern) in patterns) {
    if (pattern.hasMatch(haystack)) return platform;
  }
  return null;
}

Future<CommentPage?> fetchPlatformComments({
  required String platform,
  required Map<String, dynamic> musicInfo,
  int page = 1,
}) async {
  try {
    final result = switch (platform) {
      'wy' => await _fetchWy(musicInfo, page),
      'tx' => await _fetchTx(musicInfo, page),
      'kg' => await _fetchKg(musicInfo, page),
      'kw' => await _fetchKw(musicInfo, page),
      'mg' => await _fetchMg(musicInfo, page),
      'qishui' => await _fetchQishui(musicInfo, page),
      _ => null,
    };
    AppLog.debug('comment', 'platform=$platform page=$page '
        'items=${result?.items.length ?? -1} end=${result?.isEnd}');
    return result;
  } catch (e, st) {
    AppLog.warn('comment', 'platform=$platform page=$page 异常: $e\n$st');
    return const CommentPage(items: [], isEnd: true);
  }
}

// ==================== 网络 ====================

Future<Object?> _httpJson(
  String method,
  String url, {
  Map<String, String>? headers,
  String? body,
}) async {
  try {
    final resp = await appRequest(
      method,
      Uri.parse(url),
      headers: headers,
      body: method == 'POST' ? body : null,
    ).timeout(const Duration(seconds: 18));
    if (resp.statusCode < 200 || resp.statusCode >= 400) {
      await resp.drain<void>();
      AppLog.warn('comment', 'HTTP ${resp.statusCode} $url');
      return null;
    }
    final bytes = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    return jsonDecode(_decodeBody(bytes));
  } catch (e) {
    AppLog.warn('comment', '请求失败 $url: $e');
    return null;
  }
}

/// QQ 老的 fcg 接口默认按 GBK 输出，先按 UTF-8 解，失败再按 Latin1 兜底
/// （业务字段都是 JSON 里的 \u 转义，两种编码都能正常还原中文）。
String _decodeBody(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return latin1.decode(bytes);
  }
}

const _uaChrome =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

// ==================== 网易云 ====================

CommentItem _mapWy(Object? raw) {
  final m = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
  String? id;
  final cid = m['commentId'];
  if (cid != null) id = cid.toString();
  String? avatar;
  final au = m['user'];
  if (au is Map) {
    avatar = (au['avatarUrl'] as String?) ?? (au['avatarImgUrlStr'] as String?);
  }
  final user = au is Map
      ? (au.cast<String, dynamic>()['nickname'] as String?) ?? ''
      : '';
  final ip = m['ipLocation'];
  String? location;
  if (ip is Map) location = ip['location'] as String?;
  return CommentItem(
    id: id ?? '',
    nickName: user,
    avatar: avatar,
    comment: (m['content'] as String?) ?? '',
    like: (m['likedCount'] as num?)?.toInt() ?? 0,
    createAt: (m['time'] as num?)?.toInt(),
    location: location,
    replies: [
      for (final r in (m['beReplied'] as List?) ?? const [])
        _mapWyReply(r),
    ],
  );
}

CommentItem _mapWyReply(Object? raw) {
  final m = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
  final u = m['user'];
  final user = u is Map
      ? (u.cast<String, dynamic>()['nickname'] as String?) ?? ''
      : '';
  final ip = m['ipLocation'];
  String? location;
  if (ip is Map) location = ip['location'] as String?;
  return CommentItem(
    id: (m['beRepliedCommentId'] as num?)?.toString() ?? '',
    nickName: user,
    comment: (m['content'] as String?) ?? '',
    createAt: (m['time'] as num?)?.toInt(),
    location: location,
  );
}

Future<CommentPage?> _fetchWy(Map<String, dynamic> musicInfo, int page) async {
  // LX 音源里网易云的歌 id 存在 songmid（数字串），MF 插件里叫 id
  final id = _pickId(musicInfo, ['id', 'songmid', 'song_id', 'songId']);
  if (id == null) {
    AppLog.warn('comment', 'wy 缺 id，musicInfo=${_briefKeys(musicInfo)}');
    return null;
  }
  final offset = (page - 1) * _pageSize;
  final data = await _httpJson(
    'GET',
    'https://music.163.com/api/v1/resource/comments/R_SO_4_$id'
        '?rid=R_SO_4_$id&limit=$_pageSize&offset=$offset',
    headers: {'Referer': 'https://music.163.com/', 'User-Agent': _uaChrome},
  );
  final m = data is Map ? data.cast<String, dynamic>() : null;
  if (m == null || m['code'] != 200) {
    return const CommentPage(items: [], isEnd: true);
  }

  final list = <CommentItem>[];
  final seen = <String>{};
  final hot = m['hotComments'];
  if (page == 1 && hot is List) {
    for (final c in hot) {
      final item = _mapWy(c);
      if (item.comment.trim().isEmpty) continue;
      if (item.id.isNotEmpty) seen.add(item.id);
      list.add(item);
    }
  }
  if (m['comments'] is List) {
    for (final c in (m['comments'] as List)) {
      final item = _mapWy(c);
      if (item.comment.trim().isEmpty) continue;
      if (item.id.isNotEmpty && seen.contains(item.id)) continue;
      if (item.id.isNotEmpty) seen.add(item.id);
      list.add(item);
    }
  }
  return CommentPage(items: list, isEnd: m['more'] != true);
}

// ==================== QQ 音乐 ====================

CommentItem _mapTx(Object? raw) {
  final m = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
  int? createAt;
  final t = m['time'];
  if (t is num) createAt = t.toInt() * 1000;
  final root = (m['rootcommentcontent'] as String?) ??
      (m['middlecommentcontent'] as String?) ??
      (m['Content'] as String?) ??
      '';
  return CommentItem(
    id: (m['commentid'] ?? m['CmId'] ?? '').toString(),
    nickName: ((m['nick'] ?? m['Nick']) as String?) ?? '',
    avatar: (m['avatarurl'] ?? m['Avatar']) as String?,
    comment: root,
    like: ((m['praisenum'] ?? m['PraiseNum']) as num?)?.toInt() ?? 0,
    createAt: createAt,
  );
}

/// 把 mid 换成 QQ 的数字 songId（评论接口只认数字 id）。
Future<String?> _resolveTxSongId(Map<String, dynamic> musicInfo) async {
  final rid = _pickId(musicInfo, ['songId', 'song_id', 'id']);
  if (rid != null && RegExp(r'^\d+$').hasMatch(rid) && int.tryParse(rid) != 0) {
    return rid;
  }
  final songmid = _pickId(musicInfo, ['songmid', 'mid', 'strMediaMid']);
  if (songmid == null) return null;
  final body = jsonEncode({
    'comm': {'ct': '19', 'cv': '1859', 'uin': '0'},
    'req': {
      'module': 'music.trackInfo.UniformRuleCtrl',
      'method': 'CgiGetTrackInfo',
      'param': {
        'types': [1],
        'ids': [0],
        'mids': [songmid],
        'ctx': 0,
      },
    },
  });
  final data = await _httpJson('POST', 'https://u.y.qq.com/cgi-bin/musicu.fcg',
      headers: {
        'Referer': 'https://y.qq.com',
        'User-Agent': _uaChrome,
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: body);
  final req = data is Map ? data['req'] : null;
  final reqMap = req is Map ? req.cast<String, dynamic>() : null;
  final dd = reqMap?['data'];
  final tracks = dd is Map ? dd['tracks'] : null;
  final first = tracks is List && tracks.isNotEmpty ? tracks.first : null;
  final trackId = first is Map ? first['id'] : null;
  final resolved = trackId?.toString();
  if (resolved == null || resolved.isEmpty || resolved == '0') return null;
  return resolved;
}

/// QQ 评论列表。musicu 的 GetHotCommentList 现在恒返回 0 条（实测 code=0、
/// Comments=[]），改走网页版仍在用的 fcg_global_comment_h5：
/// `cmd=6` 热评、`cmd=8` 最新。
Future<({List<CommentItem> items, int total})?> _txComments(
  String topId, {
  required int cmd,
  required int page,
}) async {
  final query = Uri(queryParameters: {
    'g_tk': '5381',
    'loginUin': '0',
    'hostUin': '0',
    'format': 'json',
    'inCharset': 'utf8',
    'outCharset': 'utf8',
    'notice': '0',
    'platform': 'yqq.json',
    'needNewCode': '0',
    'cid': '205360772',
    'reqtype': '2',
    'biztype': '1',
    'topid': topId,
    'cmd': '$cmd',
    'needmusiccrit': '0',
    'pagenum': '$page',
    'pagesize': '$_pageSize',
  }).query;
  final data = await _httpJson(
    'GET',
    'https://c.y.qq.com/base/fcgi-bin/fcg_global_comment_h5.fcg?$query',
    headers: {
      'User-Agent': _uaChrome,
      'Referer': 'https://y.qq.com/',
    },
  );
  final m = data is Map ? data.cast<String, dynamic>() : null;
  final comment = m?['comment'];
  if (comment is! Map) return null;
  final cm = comment.cast<String, dynamic>();
  final list = (cm['commentlist'] as List?) ?? const [];
  final items = <CommentItem>[];
  for (final raw in list) {
    final item = _mapTx(raw);
    if (item.comment.trim().isEmpty) continue; // 热评里混着空壳条目
    items.add(item);
  }
  final total = (cm['commenttotal'] as num?)?.toInt() ?? 0;
  return (items: items, total: total);
}

Future<CommentPage?> _fetchTx(Map<String, dynamic> musicInfo, int page) async {
  final songId = await _resolveTxSongId(musicInfo);
  if (songId == null) {
    AppLog.warn('comment', 'tx 无法解析 songId，musicInfo=${_briefKeys(musicInfo)}');
    return null;
  }
  final seen = <String>{};
  final items = <CommentItem>[];
  void absorb(List<CommentItem> src) {
    for (final it in src) {
      if (it.id.isNotEmpty && !seen.add(it.id)) continue;
      items.add(it);
    }
  }

  var total = 0;
  if (page == 1) {
    // 首页热评置顶，再补一页最新，避免只有零星热评
    final hot = await _txComments(songId, cmd: 6, page: 0);
    if (hot != null) absorb(hot.items);
    final newest = await _txComments(songId, cmd: 8, page: 0);
    if (newest != null) {
      absorb(newest.items);
      total = newest.total;
    }
  } else {
    final newest = await _txComments(songId, cmd: 8, page: page - 1);
    if (newest == null) {
      return const CommentPage(items: [], isEnd: true);
    }
    absorb(newest.items);
    total = newest.total;
  }
  final isEnd = total > 0
      ? page * _pageSize >= total
      : items.length < _pageSize;
  return CommentPage(items: items, isEnd: isEnd);
}

// ==================== 酷狗 ====================

const _kgSaltAndroid = 'OIlwieks28dk2k092lksi2UIkp';

String _md5Hex(String input) => md5.convert(utf8.encode(input)).toString();

String _kugouSign(String params, {String body = ''}) {
  final list = params.split('&')..sort();
  final input = '$_kgSaltAndroid${list.join()}$body$_kgSaltAndroid';
  return _md5Hex(input);
}

/// hash → mixsongid（评论接口要的资源 id）。
///
/// 注意 `data` 是**二维数组**（`[[{...}]]`），只取 `data.first` 会拿到 List，
/// 后面所有字段都读不到——这正是酷狗评论此前一直空的原因。
Future<String?> _resolveKgMixsongId(String hash) async {
  final body = jsonEncode({
    'area_code': '1',
    'show_privilege': 1,
    'show_album_info': '1',
    'is_publish': '',
    'appid': 1005,
    'clientver': 11451,
    'mid': '1',
    'dfid': '-',
    'clienttime': DateTime.now().millisecondsSinceEpoch,
    'key': _kgSaltAndroid,
    'fields': 'album_info,author_name,audio_info,ori_audio_name,base,'
        'songname,classification',
    'data': [
      {'hash': hash}
    ],
  });
  final data = await _httpJson(
    'POST',
    'http://gateway.kugou.com/v3/album_audio/audio',
    headers: {
      'KG-THash': '13a3164',
      'KG-RC': '1',
      'KG-Fake': '0',
      'KG-RF': '00869891',
      'User-Agent': 'Android712-AndroidPhone-11451-376-0-FeeCacheUpdate-wifi',
      'x-router': 'kmr.service.kugou.com',
      'Content-Type': 'application/json',
    },
    body: body,
  );
  final rows = data is Map ? data['data'] : null;
  if (rows is! List || rows.isEmpty) return null;
  dynamic first = rows.first;
  while (first is List) {
    if (first.isEmpty) return null;
    first = first.first;
  }
  if (first is! Map) return null;
  final audio = first.cast<String, dynamic>();
  final cls = audio['classification'];
  if (cls is List) {
    for (final c in cls) {
      if (c is! Map) continue;
      final resId = c['res_id'];
      if (resId != null && resId.toString().isNotEmpty) return resId.toString();
    }
  }
  final base = audio['base'];
  if (base is Map) {
    final id = (base as Map)['album_audio_id'];
    if (id != null && id.toString().isNotEmpty) return id.toString();
  }
  return null;
}

int? _kgTime(Map<String, dynamic> raw) {
  final ts = raw['addtimestamp'];
  if (ts is num && ts > 0) return ts.toInt() * 1000;
  final s = raw['addtime'];
  if (s is num && s > 0) return s.toInt() * 1000;
  if (s is String && s.isNotEmpty) {
    final d = DateTime.tryParse(s.replaceFirst(' ', 'T'));
    if (d != null) return d.millisecondsSinceEpoch;
  }
  return null;
}

CommentItem _mapKg(Map<String, dynamic> raw) {
  final like = raw['like'];
  int likeCount = 0;
  if (like is Map) {
    likeCount = ((like['likenum'] ?? like['count']) as num?)?.toInt() ?? 0;
  }
  final replies = <CommentItem>[];
  final rawReplies = raw['replys'];
  if (rawReplies is List) {
    for (final r in rawReplies) {
      if (r is Map) replies.add(_mapKg(r.cast<String, dynamic>()));
    }
  }
  return CommentItem(
    id: raw['id']?.toString() ?? '',
    nickName: (raw['user_name'] as String?) ?? '',
    avatar: raw['user_pic'] as String?,
    comment: (raw['content'] as String?) ?? '',
    like: likeCount,
    createAt: _kgTime(raw),
    location: raw['location'] as String?,
    replies: replies,
  );
}

Future<CommentPage?> _fetchKg(Map<String, dynamic> musicInfo, int page) async {
  final hash = _pickId(musicInfo, ['hash', 'fileHash', 'id', 'songmid']);
  if (hash == null) {
    AppLog.warn('comment', 'kg 缺 hash，musicInfo=${_briefKeys(musicInfo)}');
    return null;
  }
  final mixsongId = await _resolveKgMixsongId(hash);
  if (mixsongId == null) {
    AppLog.warn('comment', 'kg hash=$hash 未解析出 mixsongid');
    return null;
  }

  // 签名用参数串，顺序无关（内部会 sort）
  final params = [
    'appid=1005',
    'clienttime=${DateTime.now().millisecondsSinceEpoch}',
    'clienttoken=0',
    'clientver=11409',
    'code=fc4be23b4e972707f36b8a828a93ba8a',
    'dfid=0',
    'extdata=$hash',
    'kugouid=0',
    'mid=16249512204336365674023395779019',
    'mixsongid=$mixsongId',
    'p=$page',
    'pagesize=$_pageSize',
    'uuid=0',
    'ver=10',
  ].join('&');
  final signature = _kugouSign(params);

  final data = await _httpJson(
    'GET',
    'http://m.comment.service.kugou.com/r/v1/rank/newest'
        '?$params&signature=$signature',
    headers: {
      'accept': 'application/json',
      'user-agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 '
          'Edg/107.0.1418.24',
    },
  );
  final m = data is Map ? data.cast<String, dynamic>() : null;
  final list = m?['list'];
  if (list is! List) return const CommentPage(items: [], isEnd: true);
  final items = <CommentItem>[];
  for (final item in list) {
    if (item is! Map) continue;
    final c = _mapKg(item.cast<String, dynamic>());
    if (c.comment.trim().isEmpty) continue;
    items.add(c);
  }
  final total = (m?['count'] as num?)?.toInt() ?? 0;
  final isEnd =
      total > 0 ? page * _pageSize >= total : items.length < _pageSize;
  return CommentPage(items: items, isEnd: isEnd);
}

// ==================== 酷我 ====================

CommentItem _mapKw(Object? raw) {
  final m = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
  int? createAt;
  final t = m['time'];
  if (t is num) createAt = t.toInt() * 1000;
  return CommentItem(
    id: m['id']?.toString() ?? '',
    nickName: (m['u_name'] as String?) ?? '',
    avatar: m['u_pic'] as String?,
    comment: (m['msg'] as String?) ?? '',
    like: num.tryParse('${m['like_num'] ?? 0}')?.toInt(),
    createAt: createAt,
    replies: [
      for (final c in (m['child_comments'] as List?) ?? const [])
        _mapKw(c),
    ],
  );
}

Future<CommentPage?> _fetchKw(Map<String, dynamic> musicInfo, int page) async {
  // 酷我 rid 在 LX 音源里存 songmid，MF 插件里叫 id / rid / musicrid
  final id = _pickId(musicInfo, ['id', 'rid', 'musicrid', 'songmid']);
  if (id == null) {
    AppLog.warn('comment', 'kw 缺 rid，musicInfo=${_briefKeys(musicInfo)}');
    return null;
  }
  final start = (page - 1) * _pageSize;
  final data = await _httpJson(
    'GET',
    'http://ncomment.kuwo.cn/com.s?f=web&type=get_comment&aapiver=1'
        '&prod=kwplayer_ar_10.5.2.0&digest=15&sid=${Uri.encodeComponent(id)}'
        '&start=$start&msgflag=1&count=$_pageSize&newver=3&uid=0',
    headers: {'User-Agent': 'Dalvik/2.1.0 (Linux; U; Android 9;)'},
  );
  final m = data is Map ? data.cast<String, dynamic>() : null;
  if (m == null || m['code']?.toString() != '200') {
    return const CommentPage(items: [], isEnd: true);
  }
  final total =
      num.tryParse((m['comments_counts'] ?? '').toString())?.toInt() ?? 0;
  final comments = (m['comments'] as List?) ?? const [];
  final items = <CommentItem>[];
  for (final c in comments) {
    final item = _mapKw(c);
    if (item.comment.trim().isEmpty) continue;
    items.add(item);
  }
  return CommentPage(
    items: items,
    isEnd: total > 0 ? page * _pageSize >= total : items.length < _pageSize,
  );
}

// ==================== 咪咕 ====================

Future<CommentPage?> _fetchMg(Map<String, dynamic> musicInfo, int page) async {
  // 咪咕网页版接口已下线：music.migu.cn/v3/api/* 全线 301 跳 /v5/ 首页，
  // 新版只提供需要 App 签名头的 app.c.nf.migu.cn 接口。这里如实返回
  // null（页面提示「当前音源不支持评论」），不再假装成功给一个空列表。
  AppLog.debug('comment', 'mg 平台评论接口已下线，跳过');
  return null;
}

// ==================== 汽水 ====================

Future<CommentPage?> _fetchQishui(
  Map<String, dynamic> musicInfo,
  int page,
) async {
  final id = _pickId(musicInfo, ['id', 'item_id', 'track_id', 'songmid']);
  if (id == null) return null;
  final params = {
    'aid': '386088',
    'app_name': 'luna_pc',
    'region': 'cn',
    'geo_region': 'cn',
    'os_region': 'cn',
    'sim_region': '',
    'device_id': '100000305367703244',
    'cdid': '',
    'iid': '',
    'version_name': '3.2.1',
    'version_code': '30020100',
    'channel': 'official',
    'build_mode': 'master',
    'network_carrier': '',
    'ac': 'wifi',
    'tz_name': 'Asia/Shanghai',
    'resolution': '',
    'device_platform': 'windows',
    'device_type': 'Windows',
    'os_version': 'Windows 11 Home China',
    'fp': '100000305367703244',
    'group_id': id,
    'cursor': '${(page - 1) * _pageSize}',
    'count': '$_pageSize',
    'group_type': '1',
    'image_strategy': '2',
  };
  final query = Uri(queryParameters: params).query;
  final data = await _httpJson(
    'GET',
    'https://api.qishui.com/luna/pc/comments?$query',
    headers: {
      'Accept': '*/*',
      'Content-Type': 'application/json; charset=utf-8',
      'User-Agent': 'LunaPC/3.2.1(343009595)',
      'x-luna-background-type': 'foreground',
      'x-luna-is-background-req': '0',
      'x-luna-is-local-user': '0',
    },
  );
  final m = data is Map ? data.cast<String, dynamic>() : null;
  if (m == null || (m['status_code'] as num?)?.toInt() != 0) {
    return const CommentPage(items: [], isEnd: true);
  }
  final comments = (m['comments'] as List?) ?? const [];
  final items = <CommentItem>[];
  for (final raw in comments) {
    final c = raw is Map ? raw.cast<String, dynamic>() : const {};
    final user = c['user'] is Map
        ? (c['user'] as Map).cast<String, dynamic>()
        : null;
    final av = user?['medium_avatar_url'];
    num? rawTime = c['time_created'];
    if (rawTime is! num) rawTime = 0;
    final t = rawTime.toInt();
    final createAt = t > 0 && t < 1000000000000 ? t * 1000 : t;
    final content = (c['content'] as String?) ?? '';
    if (content.trim().isEmpty) continue;
    items.add(CommentItem(
      id: c['id']?.toString() ?? '',
      nickName: (user?['nickname'] as String?) ?? '',
      avatar: av is String ? av : null,
      comment: content,
      like: (c['count_digged'] as num?)?.toInt(),
      createAt: createAt > 0 ? createAt : null,
    ));
  }
  return CommentPage(
    items: items,
    isEnd: m['has_more'] == false || items.length < _pageSize,
  );
}

// ==================== 工具 ====================

/// 取字段：先看顶层，再看 rawData（LX 音源原始条目），并兼容
/// camelCase / snake_case 两种写法。返回第一个非空字符串。
String? _pickId(Map<String, dynamic> musicInfo, List<String> keys) {
  final maps = <Map<String, dynamic>>[musicInfo];
  final raw = musicInfo['rawData'];
  if (raw is Map) maps.add(raw.cast<String, dynamic>());

  final expanded = <String>[];
  for (final k in keys) {
    expanded.add(k);
    final snake = k.replaceAllMapped(
        RegExp(r'[A-Z]'), (m) => '_${m.group(0)!.toLowerCase()}');
    if (snake != k) expanded.add(snake);
  }

  for (final m in maps) {
    for (final k in expanded) {
      final v = m[k];
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isEmpty || s == 'null' || s == '0') continue;
      return s;
    }
  }
  return null;
}

/// 日志用：只打 key，不打整串 JSON
String _briefKeys(Map<String, dynamic> musicInfo) {
  final raw = musicInfo['rawData'];
  final rawKeys = raw is Map ? raw.keys.take(12).join(',') : '-';
  return 'top=[${musicInfo.keys.take(12).join(',')}] raw=[$rawKeys]';
}
