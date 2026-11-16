import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketstrike/app/theme/glass_tokens.dart';
import 'package:pocketstrike/features/agent/application/agent_prefs.dart';
import 'package:pocketstrike/features/agent/domain/agent_tool.dart';
import 'package:pocketstrike/shared/widgets/app_icons.dart';

/// One-line permission-mode picker shown under the mode switcher while the
/// agent is active: tap to choose how often the agent stops for a tap.
class AgentPolicyBar extends ConsumerWidget {
  const AgentPolicyBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.glass;
    final policy = ref.watch(confirmPolicyProvider);
    final color = switch (policy) {
      ConfirmationPolicy.alwaysAsk => tokens.textSecondary,
      ConfirmationPolicy.destructiveOnly => tokens.accent,
      ConfirmationPolicy.autonomous => Colors.orangeAccent,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: GestureDetector(
        onTap: () => showAgentPolicySheet(context),
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: tokens.glassColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.5), width: 0.8),
          ),
          child: Row(
            children: [
              Icon(AppIcons.shieldCheck, size: 13, color: color),
              const SizedBox(width: 6),
              Text(
                'Permissions: ',
                style: TextStyle(fontSize: 11.5, color: tokens.textSecondary),
              ),
              Expanded(
                child: Text(
                  policy.shortLabel,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
              Icon(AppIcons.chevronDown, size: 16, color: tokens.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showAgentPolicySheet(BuildContext context) {
  HapticFeedback.selectionClick();
  return showModalBottomSheet<void>(
    context: context,
    builder: (_) => const _AgentPolicySheet(),
  );
}

class _AgentPolicySheet extends ConsumerWidget {
  const _AgentPolicySheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.glass;
    final current = ref.watch(confirmPolicyProvider);

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(tokens.radiusLg)),
        border: Border(top: BorderSide(color: tokens.glassBorder)),
      ),
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        16 + MediaQuery.of(context).viewPadding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Agent permissions', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'How often the agent stops and waits for your tap. Applies to '
            'every run until you change it.',
            style: TextStyle(color: tokens.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 12),
          for (final p in ConfirmationPolicy.values)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                color: current == p
                    ? tokens.accent.withValues(alpha: 0.12)
                    : tokens.glassColor,
                borderRadius: BorderRadius.circular(tokens.radiusSm),
                border: Border.all(
                  color: current == p ? tokens.accent : tokens.glassBorder,
                ),
              ),
              child: ListTile(
                dense: true,
                title: Text(p.shortLabel),
                subtitle: Text(
                  p.description,
                  style: TextStyle(color: tokens.textSecondary, fontSize: 12),
                ),
                trailing: current == p
                    ? Icon(AppIcons.checkCircle2, color: tokens.accent)
                    : null,
                onTap: () {
                  ref.read(confirmPolicyProvider.notifier).set(p);
                  Navigator.of(context).pop();
                },
              ),
            ),
        ],
      ),
    );
  }
}
