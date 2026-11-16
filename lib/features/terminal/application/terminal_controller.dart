import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketstrike/features/agent/data/termux_bridge.dart';

/// One command and what it printed.
class TerminalEntry {
  const TerminalEntry({
    required this.id,
    required this.cwd,
    required this.command,
    this.stdout = '',
    this.stderr = '',
    this.exitCode,
    this.error,
    this.running = false,
    this.elapsed,
  });

  final int id;
  final String cwd;
  final String command;
  final String stdout;
  final String stderr;
  final int? exitCode;

  /// Set when the command never ran (Termux missing, permission, timeout).
  final String? error;
  final bool running;
  final Duration? elapsed;
}

class TerminalState {
  const TerminalState({
    this.entries = const [],
    this.cwd = TerminalController.home,
    this.history = const [],
    this.busy = false,
    this.installed = true,
    this.granted = true,
  });

  final List<TerminalEntry> entries;
  final String cwd;

  /// Commands typed so far, oldest first, for recall.
  final List<String> history;
  final bool busy;
  final bool installed;
  final bool granted;

  TerminalState copyWith({
    List<TerminalEntry>? entries,
    String? cwd,
    List<String>? history,
    bool? busy,
    bool? installed,
    bool? granted,
  }) =>
      TerminalState(
        entries: entries ?? this.entries,
        cwd: cwd ?? this.cwd,
        history: history ?? this.history,
        busy: busy ?? this.busy,
        installed: installed ?? this.installed,
        granted: granted ?? this.granted,
      );
}

/// A line-at-a-time terminal over the Termux bridge. Each command is its own
/// non-interactive shell, so the controller carries the working directory from
/// one command to the next to make `cd` behave the way a terminal does.
class TerminalController extends Notifier<TerminalState> {
  static const home = '/data/data/com.termux/files/home';
  static const _marker = '__PS_CWD__';
  static const _maxEntries = 200;
  static const _maxOutput = 20000;

  var _nextId = 1;

  @override
  TerminalState build() => const TerminalState();

  Future<void> refreshStatus() async {
    final s = await TermuxBridge.status();
    state = state.copyWith(installed: s.installed, granted: s.granted);
  }

  Future<void> requestPermission() async {
    await TermuxBridge.requestPermission();
  }

  void clear() => state = state.copyWith(entries: const []);

  /// `~/project` for the prompt.
  static String pretty(String path) =>
      path == home ? '~' : (path.startsWith('$home/') ? '~${path.substring(home.length)}' : path);

  Future<void> run(String input, {Duration timeout = const Duration(minutes: 5)}) async {
    final command = input.trim();
    if (command.isEmpty || state.busy) return;

    final history = [...state.history.where((h) => h != command), command];
    if (command == 'clear' || command == 'cls') {
      state = state.copyWith(entries: const [], history: history);
      return;
    }

    final id = _nextId++;
    final cwd = state.cwd;
    var entries = [...state.entries, TerminalEntry(id: id, cwd: cwd, command: command, running: true)];
    if (entries.length > _maxEntries) entries = entries.sublist(entries.length - _maxEntries);
    state = state.copyWith(entries: entries, history: history, busy: true);

    // Start in the remembered directory, run the command, then report where
    // the shell ended up so the next command starts there.
    final wrapped = 'cd -- ${_quote(cwd)} 2>/dev/null\n'
        '$command\n'
        '__ps_rc=\$?; printf \'\\n$_marker%s\\n\' "\$PWD"; exit \$__ps_rc';

    final watch = Stopwatch()..start();
    final res = await TermuxBridge.run(wrapped, timeout: timeout);
    watch.stop();

    var out = res.stdout;
    var newCwd = cwd;
    final at = out.lastIndexOf('\n$_marker');
    if (at >= 0) {
      final rest = out.substring(at + 1 + _marker.length);
      final line = rest.split('\n').first.trim();
      if (line.startsWith('/')) newCwd = line;
      out = out.substring(0, at);
    }

    final done = TerminalEntry(
      id: id,
      cwd: cwd,
      command: command,
      stdout: _clip(out.trimRight()),
      stderr: _clip(res.stderr.trimRight()),
      exitCode: res.ok ? res.exitCode : null,
      error: res.ok ? null : res.error,
      elapsed: watch.elapsed,
    );
    state = state.copyWith(
      entries: [for (final e in state.entries) e.id == id ? done : e],
      cwd: newCwd,
      busy: false,
    );
    if (!res.ok) await refreshStatus();
  }

  static String _quote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  static String _clip(String s) => s.length <= _maxOutput
      ? s
      : '…[${s.length - _maxOutput} earlier characters hidden]\n${s.substring(s.length - _maxOutput)}';
}

final terminalControllerProvider =
    NotifierProvider<TerminalController, TerminalState>(TerminalController.new);
