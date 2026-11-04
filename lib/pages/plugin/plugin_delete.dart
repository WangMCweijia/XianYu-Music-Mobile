import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/i18n/i18n.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/widgets/predictive_dialog_route.dart';

Future<void> confirmRemovePlugin(
    BuildContext context, WidgetRef ref, PluginSource source) async {
  final manager = ref.read(pluginManagerProvider.notifier);
  await showPredictiveDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('卸载插件')),
      content: Text(tr('确定要卸载「{name}」吗？', {'name': source.name})),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(tr('取消')),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            manager.remove(source.id);
          },
          child: Text(tr('卸载')),
        ),
      ],
    ),
  );
}
