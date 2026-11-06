import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/application_logger.dart';
import 'plugin_models.dart';

class PluginStore {
  static const _sourcesKey = 'xianyu_plugin_sources_v4';
  static const _aliasesKey = 'xianyu_plugin_id_aliases_v1';
  static const _platformPriorityKey = 'xianyu_plugin_platform_priority_v1';

  final String dataDir;

  PluginStore(this.dataDir);

  String get _pluginsDir => p.join(dataDir, 'plugins');

  Future<List<PluginSource>> loadSources() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sourcesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => PluginSource.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveSources(List<PluginSource> sources) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _sourcesKey, jsonEncode(sources.map((e) => e.toJson()).toList()));
  }

  /// 插件 id 别名表（旧 id → 现行 id）：插件更新即换 sha256 id（脚本内容
  /// 哈希），收藏/播放队列里存的旧 pluginId 靠这张表换算，避免来源标签
  /// 降级「在线」、播放解析走失效分支
  Future<Map<String, String>> loadAliases() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_aliasesKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return j.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return const {};
    }
  }

  Future<void> saveAliases(Map<String, String> aliases) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_aliasesKey, jsonEncode(aliases));
  }

  /// 平台优先源表：平台键（kw/wy/kg/tx/mg）→ 优先插件 id。
  ///
  /// 全局 sortOrder 只能表达一条源顺序，而不同平台的实际强弱并不一致
  /// （主源 kw/wy 上游冗余多，备用源 kg/tx/mg 更强）。这张表允许按平台
  /// 单独把一个源顶到最前面，其余仍按 sortOrder 兜底；空表＝完全不生效。
  Future<Map<String, String>> loadPlatformPriority() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_platformPriorityKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final out = <String, String>{};
      j.forEach((k, v) {
        final id = v?.toString() ?? '';
        if (k.isNotEmpty && id.isNotEmpty) out[k] = id;
      });
      return out;
    } catch (_) {
      return const {};
    }
  }

  Future<void> savePlatformPriority(Map<String, String> priority) async {
    final prefs = await SharedPreferences.getInstance();
    if (priority.isEmpty) {
      await prefs.remove(_platformPriorityKey);
      return;
    }
    await prefs.setString(_platformPriorityKey, jsonEncode(priority));
  }

  /// 读取平台优先源，并把插件 id 经别名表换算到现行 id。
  ///
  /// 插件内容一变 id 就变（sha256），用户选中的源若更新过，直接比对 id 会
  /// 失效；别名表已覆盖全部换 id 路径（手动更新/订阅更新），这里统一换算。
  Future<Map<String, String>> resolvedPlatformPriority() async {
    final raw = await loadPlatformPriority();
    if (raw.isEmpty) return raw;
    final aliases = await loadAliases();
    if (aliases.isEmpty) return raw;
    return raw.map((k, v) => MapEntry(k, aliases[v] ?? v));
  }

  Future<String> saveScript(String pluginId, String script) async {
    final dir = Directory(_pluginsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final path = p.join(_pluginsDir, '$pluginId.js');
    await File(path).writeAsString(script, flush: true);
    return path;
  }

  Future<String?> readScript(String pluginId) async {
    final path = p.join(_pluginsDir, '$pluginId.js');
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteScript(String pluginId) async {
    final path = p.join(_pluginsDir, '$pluginId.js');
    final file = File(path);
    if (file.existsSync()) {
      try {
        await file.delete();
      } catch (e) {
        AppLog.warn('plugin', '删除插件脚本失败($pluginId): $e');
      }
    }
  }

  Future<void> clearAll() async {
    final dir = Directory(_pluginsDir);
    if (dir.existsSync()) {
      try {
        await dir.delete(recursive: true);
      } catch (e) {
        AppLog.warn('plugin', '清空插件脚本目录失败: $e');
      }
    }
    await saveSources(const []);
  }
}
