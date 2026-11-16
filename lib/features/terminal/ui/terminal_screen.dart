import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketstrike/app/theme/app_theme.dart';
import 'package:pocketstrike/app/theme/glass_tokens.dart';
import 'package:pocketstrike/features/terminal/application/terminal_controller.dart';
import 'package:pocketstrike/shared/widgets/app_icons.dart';

/// A terminal that runs real Linux commands in the Termux app and shows the
/// output. One command at a time, non-interactive: full-screen programs
/// (vim, htop) and prompts that wait for typing are not supported.
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();

  /// Position in the history while recalling; null = not recalling.
  int? _recall;

  static const _quick = <String>[
    'ls -la',
    'pwd',
    'cd ..',
    'cd ~',
    'git status',
    'python --version',
    'df -h .',
    'clear',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(() => ref.read(terminalControllerProvider.notifier).refreshStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the permission prompt or from Termux.
    if (state == AppLifecycleState.resumed) {
      ref.read(terminalControllerProvider.notifier).refreshStatus();
    }
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _submit([String? text]) {
    final command = (text ?? _input.text).trim();
    if (command.isEmpty) return;
    if (ref.read(terminalControllerProvider).busy) return;
    _input.clear();
    _recall = null;
    ref.read(terminalControllerProvider.notifier).run(command);
    _toBottom();
  }

  void _recallStep(int delta) {
    final history = ref.read(terminalControllerProvider).history;
    if (history.isEmpty) return;
    var i = (_recall ?? history.length) + delta;
    if (i < 0) i = 0;
    if (i >= history.length) {
      _recall = null;
      _input.clear();
      return;
    }
    _recall = i;
    _input.text = history[i];
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.glass;
    final state = ref.watch(terminalControllerProvider);
    final ready = state.installed && state.granted;

    ref.listen(terminalControllerProvider.select((s) => s.entries), (_, __) => _toBottom());

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Terminal', style: Theme.of(context).textTheme.titleMedium),
            Text(
              ready ? 'Linux shell in Termux' : 'Termux not connected',
              style: TextStyle(fontSize: 11.5, color: ready ? tokens.textSecondary : Colors.orangeAccent),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Clear the screen',
            icon: const Icon(AppIcons.trash2),
            onPressed: state.entries.isEmpty ? null : () => ref.read(terminalControllerProvider.notifier).clear(),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (!ready) _SetupCard(installed: state.installed),
            Expanded(
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
                decoration: BoxDecoration(
                  color: tokens.terminalSurface,
                  borderRadius: BorderRadius.circular(tokens.radiusMd),
                  border: Border.all(color: tokens.glassBorder),
                ),
                child: state.entries.isEmpty
                    ? _EmptyHint(onTap: _submit)
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(12),
                        itemCount: state.entries.length,
                        itemBuilder: (context, i) => _EntryView(entry: state.entries[i]),
                      ),
              ),
            ),

            // Quick commands.
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                itemCount: _quick.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, i) => GestureDetector(
                  onTap: state.busy ? null : () => _submit(_quick[i]),
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: tokens.glassColor,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: tokens.glassBorder, width: 0.8),
                    ),
                    child: Text(_quick[i], style: AppTheme.mono(fontSize: 11.5, color: tokens.textSecondary)),
                  ),
                ),
              ),
            ),

            // Prompt line.
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Container(
                padding: const EdgeInsets.only(left: 12, right: 4),
                decoration: BoxDecoration(
                  color: tokens.glassColor,
                  borderRadius: BorderRadius.circular(tokens.radiusMd),
                  border: Border.all(color: tokens.glassBorder),
                ),
                child: Row(
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: Text(
                        '${TerminalController.pretty(state.cwd)} \$',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.mono(fontSize: 12.5, color: tokens.accent, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _input,
                        focusNode: _focus,
                        autocorrect: false,
                        enableSuggestions: false,
                        textCapitalization: TextCapitalization.none,
                        keyboardType: TextInputType.visiblePassword,
                        textInputAction: TextInputAction.send,
                        style: AppTheme.mono(fontSize: 13.5),
                        decoration: InputDecoration(
                          hintText: state.busy ? 'Running…' : 'Type a command',
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        onSubmitted: (_) {
                          _submit();
                          _focus.requestFocus();
                        },
                      ),
                    ),
                    IconButton(
                      tooltip: 'Previous command',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(AppIcons.chevronUp),
                      onPressed: () => _recallStep(-1),
                    ),
                    IconButton(
                      tooltip: 'Next command',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(AppIcons.chevronDown),
                      onPressed: () => _recallStep(1),
                    ),
                    state.busy
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                          )
                        : IconButton(
                            tooltip: 'Run',
                            icon: Icon(AppIcons.play, color: tokens.accent),
                            onPressed: _submit,
                          ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EntryView extends StatelessWidget {
  const _EntryView({required this.entry});

  final TerminalEntry entry;

  @override
  Widget build(BuildContext context) {
    final tokens = context.glass;
    final failed = entry.error != null || (entry.exitCode != null && entry.exitCode != 0);
    final all = [
      if (entry.stdout.isNotEmpty) entry.stdout,
      if (entry.stderr.isNotEmpty) entry.stderr,
    ].join('\n');

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: () {
              Clipboard.setData(ClipboardData(text: all.isEmpty ? entry.command : '\$ ${entry.command}\n$all'));
              HapticFeedback.selectionClick();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
              );
            },
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${TerminalController.pretty(entry.cwd)} \$ ',
                    style: AppTheme.mono(fontSize: 12.5, color: tokens.accent, fontWeight: FontWeight.w600),
                  ),
                  TextSpan(text: entry.command, style: AppTheme.mono(fontSize: 12.5, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
          if (entry.running)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6)),
                  const SizedBox(width: 8),
                  Text('running…', style: AppTheme.mono(fontSize: 12, color: tokens.textSecondary)),
                ],
              ),
            ),
          if (entry.stdout.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SelectableText(entry.stdout, style: AppTheme.mono(fontSize: 12.5)),
            ),
          if (entry.stderr.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SelectableText(
                entry.stderr,
                style: AppTheme.mono(fontSize: 12.5, color: failed ? Colors.redAccent : Colors.orangeAccent),
              ),
            ),
          if (entry.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SelectableText(entry.error!, style: AppTheme.mono(fontSize: 12.5, color: Colors.redAccent)),
            ),
          if (!entry.running && entry.error == null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                [
                  if (entry.exitCode != null && entry.exitCode != 0) 'exit ${entry.exitCode}',
                  if (entry.stdout.isEmpty && entry.stderr.isEmpty && (entry.exitCode ?? 0) == 0) 'done, no output',
                  if (entry.elapsed != null && entry.elapsed!.inMilliseconds >= 1500)
                    '${(entry.elapsed!.inMilliseconds / 1000).toStringAsFixed(1)} s',
                ].join(' · '),
                style: AppTheme.mono(fontSize: 11, color: failed ? Colors.redAccent : tokens.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.onTap});

  final void Function(String) onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.glass;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(AppIcons.terminal, color: tokens.accent, size: 28),
          const SizedBox(height: 8),
          Text('A real Linux shell', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Commands run in the Termux app on this phone: git, python, pip, pkg and '
            'anything else installed there. The working directory is remembered between '
            'commands, so cd works as usual.',
            style: TextStyle(color: tokens.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Text(
            'One command at a time. Programs that wait for typing or take over the screen '
            '(vim, htop, an interactive menu) cannot be used here; open Termux for those. '
            'Long-press a command to copy it with its output.',
            style: TextStyle(color: tokens.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 12),
          Text('Try', style: TextStyle(color: tokens.textSecondary, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          for (final c in const [
            'uname -a',
            'ls ~',
            'python ~/GhostTrack/ghost.py myip',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: GestureDetector(
                onTap: () => onTap(c),
                child: Text('\$ $c', style: AppTheme.mono(fontSize: 12.5, color: tokens.accent)),
              ),
            ),
        ],
      ),
    );
  }
}

class _SetupCard extends ConsumerWidget {
  const _SetupCard({required this.installed});

  final bool installed;

  static const _allow =
      "echo 'allow-external-apps=true' >> ~/.termux/termux.properties && termux-reload-settings";

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.glass;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            installed ? 'Allow PocketStrike to use Termux' : 'Termux is not installed',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            installed
                ? 'Android asks once for the "Run commands in Termux environment" permission. '
                    'Termux must also allow other apps; if commands still fail, run the line below in Termux.'
                : 'The terminal and the agent\'s shell tool run inside Termux. Install Termux from '
                    'F-Droid or its GitHub releases (not the Play Store build), open it once, then come back.',
            style: TextStyle(color: tokens.textSecondary, fontSize: 12.5),
          ),
          if (installed) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  onPressed: () => ref.read(terminalControllerProvider.notifier).requestPermission(),
                  child: const Text('Allow'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    Clipboard.setData(const ClipboardData(text: _allow));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Line copied. Paste it in Termux.'), duration: Duration(seconds: 2)),
                    );
                  },
                  child: const Text('Copy the Termux line'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
