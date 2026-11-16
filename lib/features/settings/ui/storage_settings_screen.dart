import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketstrike/app/theme/glass_tokens.dart';
import 'package:pocketstrike/core/storage/prefs_provider.dart';
import 'package:pocketstrike/shared/widgets/app_icons.dart';
import 'package:pocketstrike/shared/widgets/glass_button.dart';
import 'package:pocketstrike/features/agent/application/agent_prefs.dart';
import 'package:pocketstrike/features/agent/domain/agent_tool.dart';

class StorageSettingsScreen extends ConsumerStatefulWidget {
  const StorageSettingsScreen({super.key});

  @override
  ConsumerState<StorageSettingsScreen> createState() =>
      _StorageSettingsScreenState();
}

class _StorageSettingsScreenState
    extends ConsumerState<StorageSettingsScreen> {
  final List<String> _allowedFolders = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final prefs = ref.read(sharedPreferencesProvider);
    final storedFolders = prefs.getStringList('storage_allowed_folders') ?? [];
    setState(() {
      _allowedFolders.addAll(storedFolders);
    });
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.getDirectoryPath();
    if (path != null && !_allowedFolders.contains(path)) {
      setState(() => _allowedFolders.add(path));
      await _save();
    }
  }

  Future<void> _removeFolder(String path) async {
    setState(() => _allowedFolders.remove(path));
    await _save();
  }

  Future<void> _save() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setStringList('storage_allowed_folders', _allowedFolders);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.glass;
    final policy = ref.watch(confirmPolicyProvider);
    final budget = ref.watch(compactBudgetProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Storage & Permissions',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Storage Sandboxing Info
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: tokens.glassColor,
              borderRadius: BorderRadius.circular(tokens.radiusSm),
              border: Border.all(color: tokens.glassBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(AppIcons.shieldCheck,
                        color: tokens.accent, size: 20),
                    const SizedBox(width: 8),
                    Text('Storage Access Framework (SAF)',
                        style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'The PocketStrike agent can only read, write, or list files inside '
                  'explicitly permitted root folders. Full device storage is never accessed.',
                  style: TextStyle(color: tokens.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          Text(
            'CONFIRMATION SAFETY LEVEL',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                  color: tokens.textSecondary,
                ),
          ),
          const SizedBox(height: 8),
          for (final p in ConfirmationPolicy.values)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                color: policy == p
                    ? tokens.accent.withValues(alpha: 0.12)
                    : tokens.glassColor,
                borderRadius: BorderRadius.circular(tokens.radiusSm),
                border: Border.all(
                  color: policy == p ? tokens.accent : tokens.glassBorder,
                ),
              ),
              child: ListTile(
                title: Text(p.shortLabel),
                subtitle: Text(
                  p.description,
                  style: TextStyle(color: tokens.textSecondary, fontSize: 12),
                ),
                trailing: policy == p
                    ? Icon(AppIcons.checkCircle2, color: tokens.accent)
                    : null,
                onTap: () => ref.read(confirmPolicyProvider.notifier).set(p),
              ),
            ),
          const SizedBox(height: 16),

          Text(
            'CONTEXT COMPACTION (CLOUD MODELS)',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                  color: tokens.textSecondary,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            'When a conversation or agent run grows past this many tokens, the '
            'older turns are summarised by the model and replaced with the '
            'summary, so long runs keep going and cost less. Local models '
            'always compact to fit their context window.',
            style: TextStyle(color: tokens.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in CompactBudgetNotifier.choices)
                ChoiceChip(
                  label: Text(CompactBudgetNotifier.label(c)),
                  selected: budget == c,
                  onSelected: (_) =>
                      ref.read(compactBudgetProvider.notifier).set(c),
                ),
            ],
          ),
          const SizedBox(height: 16),

          Text(
            'ALLOWED ROOT FOLDERS (${_allowedFolders.length})',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                  color: tokens.textSecondary,
                ),
          ),
          const SizedBox(height: 8),

          if (_allowedFolders.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No external folders added. Default app sandbox will be used.',
                style: TextStyle(color: tokens.textSecondary),
              ),
            )
          else
            for (final folder in _allowedFolders)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: tokens.glassColor,
                  borderRadius: BorderRadius.circular(tokens.radiusSm),
                  border: Border.all(color: tokens.glassBorder),
                ),
                child: ListTile(
                  leading: Icon(AppIcons.folder, color: tokens.accent),
                  title: Text(folder, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    icon: const Icon(AppIcons.trash2,
                        color: Colors.redAccent),
                    onPressed: () => _removeFolder(folder),
                  ),
                ),
              ),

          const SizedBox(height: 12),
          GlassButton(
            label: 'Add Allowed Root Folder',
            icon: AppIcons.folderPlus,
            expanded: true,
            onPressed: _pickFolder,
          ),
        ],
      ),
    );
  }
}
