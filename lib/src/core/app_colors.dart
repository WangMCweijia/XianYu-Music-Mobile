import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/page_wallpaper.dart';
import '../widgets/glass_settings.dart';

/// 页面感知的壁纸激活态：当前页被主题包定义了壁纸，或全局用户壁纸开启。
/// 页面作用域之外（根层/chrome）pageId 为 null，等价于全局语义。
/// wallpaperActiveProvider 随 pageIdProvider 的每页 override 一起作用域化，
/// 必须声明直接依赖，否则嵌套作用域内读取会抛 Riverpod 断言。
final wallpaperActiveProvider = Provider<bool>((ref) {
  return ref.watch(pageWallpaperActiveProvider);
}, dependencies: [pageWallpaperActiveProvider]);

/// 页面脚手架恒透明：根层恒画的兜底红蓝光斑/用户壁纸同轨垫底，页面与
/// 横屏面板内嵌页直接透出，不再按壁纸激活态切换白实底。覆盖路由转场
/// 期间防透出下层的遮蔽由 RoutePageBackdrop 的实底垫负责，不经本函数。
Color appScaffoldBackground(BuildContext context, WidgetRef ref) {
  return Colors.transparent;
}

Color appSurfaceBg(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark ? const Color(0xFF222222) : const Color(0xFFF4F4F6);
}

/// 贴在滚动内容之上的浮层（排序条、列表工具条）底色。
///
/// 页面 Scaffold 恒透明（底色由根层 ColoredBox(appSurfaceBg) + 壁纸层自绘），
/// 所以 `Theme.of(context).scaffoldBackgroundColor` 也是 `Colors.transparent`
/// ——浮层照抄它就会变成「完全透明」，列表内容从浮层底下直接透出来。
/// 这里统一取真实的页面底：普通模式取 appSurfaceBg，壁纸模式取壁纸块填充
/// （与列表卡片同源），两种模式下浮层都有一层与页面一致的底。
Color appOverlayBarBg(BuildContext context, WidgetRef ref) =>
    ref.watch(wallpaperActiveProvider)
    ? wallpaperBlockFill(context, ref)
    : appSurfaceBg(context);

Color appCardColor(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark ? const Color(0xFF303030) : const Color(0xFFFFFFFF);
}

Color appCardFill(BuildContext context, WidgetRef ref) =>
    ref.watch(wallpaperActiveProvider)
    ? wallpaperBlockFill(context, ref)
    : appCardColor(context);

/// 次要前景色（文字/图标）：以 onSurface 为基底降透明。
/// onSurfaceVariant/outline 在壁纸文字颜色为「跟随主题」时不参与翻转，
/// 直接铺在壁纸上会发灰不可读；onSurface 始终跟随壁纸文字模式翻转。
Color appSecondaryFg(ColorScheme scheme) =>
    scheme.onSurface.withValues(alpha: 0.62);
