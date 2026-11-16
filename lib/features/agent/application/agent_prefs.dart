import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketstrike/core/storage/prefs_provider.dart';
import 'package:pocketstrike/features/agent/domain/agent_tool.dart';

/// The agent's confirmation policy ("permission mode"), shared by the
/// settings screen and the quick picker above the chat, persisted in prefs.
final confirmPolicyProvider =
    NotifierProvider<ConfirmPolicyNotifier, ConfirmationPolicy>(
  ConfirmPolicyNotifier.new,
);

class ConfirmPolicyNotifier extends Notifier<ConfirmationPolicy> {
  static const _key = 'confirm_policy';

  @override
  ConfirmationPolicy build() => ConfirmationPolicyX.fromId(
        ref.read(sharedPreferencesProvider).getString(_key),
      );

  Future<void> set(ConfirmationPolicy policy) async {
    state = policy;
    await ref.read(sharedPreferencesProvider).setString(_key, policy.id);
  }
}

extension ConfirmationPolicyDescription on ConfirmationPolicy {
  String get shortLabel => switch (this) {
        ConfirmationPolicy.alwaysAsk => 'Ask every time',
        ConfirmationPolicy.destructiveOnly => 'Ask for risky actions',
        ConfirmationPolicy.autonomous => 'Run without asking',
      };

  String get description => switch (this) {
        ConfirmationPolicy.alwaysAsk =>
          'Every tool call waits for your tap, including reads.',
        ConfirmationPolicy.destructiveOnly =>
          'Reads, file edits and safe tools run freely. Network calls, Termux '
              'commands and deletes wait for your tap.',
        ConfirmationPolicy.autonomous =>
          'Nothing waits for you. Use for tasks you trust; the agent can '
              'delete and overwrite files inside its allowed folders.',
      };
}

/// Cloud-provider compaction budget in estimated tokens. 0 turns compaction
/// off for cloud models. The local engine always compacts to its context size.
final compactBudgetProvider =
    NotifierProvider<CompactBudgetNotifier, int>(CompactBudgetNotifier.new);

class CompactBudgetNotifier extends Notifier<int> {
  static const _key = 'compact_budget_tokens';
  static const defaultBudget = 24000;
  static const choices = <int>[0, 8000, 16000, 24000, 48000, 96000];

  @override
  int build() =>
      ref.read(sharedPreferencesProvider).getInt(_key) ?? defaultBudget;

  Future<void> set(int tokens) async {
    state = tokens;
    await ref.read(sharedPreferencesProvider).setInt(_key, tokens);
  }

  static String label(int tokens) => switch (tokens) {
        0 => 'Off',
        _ => '${tokens ~/ 1000}k tokens',
      };
}

/// The folder the agent works in (its "project"). Relative paths in the file
/// tools resolve against it, Termux commands start there, and a
/// POCKETSTRIKE.md inside it is read as project instructions. Null = none.
final projectDirProvider =
    NotifierProvider<ProjectDirNotifier, String?>(ProjectDirNotifier.new);

class ProjectDirNotifier extends Notifier<String?> {
  static const _key = 'project_dir';

  @override
  String? build() {
    final v = ref.read(sharedPreferencesProvider).getString(_key);
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> set(String? path) async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (path == null || path.isEmpty) {
      state = null;
      await prefs.remove(_key);
    } else {
      state = path;
      await prefs.setString(_key, path);
    }
  }
}

/// Offline agent: lets the on-device model in Local mode call a small set of
/// tools (files, Termux, calculator, time). Off by default because the tool
/// list takes context and small models follow it less reliably.
final localAgentProvider =
    NotifierProvider<LocalAgentNotifier, bool>(LocalAgentNotifier.new);

class LocalAgentNotifier extends Notifier<bool> {
  static const _key = 'local_agent_tools';

  /// The tools a 4k-context model is offered; the full list would not fit.
  static const tools = <String>{
    'run_in_termux',
    'list_files',
    'read_file',
    'write_file',
    'edit_file',
    'search_files',
    'calculator',
    'get_current_time',
  };

  @override
  bool build() => ref.read(sharedPreferencesProvider).getBool(_key) ?? false;

  Future<void> set(bool on) async {
    state = on;
    await ref.read(sharedPreferencesProvider).setBool(_key, on);
  }
}
