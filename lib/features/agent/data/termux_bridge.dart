import 'package:flutter/services.dart';

/// Result of running a command in Termux.
class TermuxResult {
  const TermuxResult({required this.ok, this.stdout = '', this.stderr = '', this.exitCode, this.error});
  final bool ok;
  final String stdout;
  final String stderr;
  final int? exitCode;

  /// Set when the command could not be run at all (Termux missing, timed out).
  final String? error;
}

/// Runs shell commands in the Termux app over the RUN_COMMAND intent. Termux is a full Linux
/// userland (git, python, pip…) that PocketStrike's own sandbox does not have, so this is how the
/// agent installs and runs command-line tools.
class TermuxBridge {
  const TermuxBridge._();

  static const _channel = MethodChannel('com.pocketstrike.app/termux');

  /// Whether Termux is installed and PocketStrike holds its run-command permission.
  static Future<({bool installed, bool granted})> status() async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('status');
      return (installed: res?['installed'] == true, granted: res?['granted'] == true);
    } catch (_) {
      return (installed: false, granted: false);
    }
  }

  /// Shows Android's permission prompt for running commands in Termux.
  static Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod('requestPermission');
    } catch (_) {}
  }

  /// Runs [command] with `bash -lc`, optionally in [workdir]. Waits up to [timeout] for Termux to
  /// report back. Never throws: on any failure it returns a result with `ok == false`.
  static Future<TermuxResult> run(
    String command, {
    String? workdir,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('run', {
        'command': command,
        'workdir': workdir,
        'timeoutMs': timeout.inMilliseconds,
      });
      if (res == null) return const TermuxResult(ok: false, error: 'No response from the bridge');
      if (res['ok'] != true) {
        return TermuxResult(ok: false, error: (res['error'] as String?) ?? 'Termux call failed');
      }
      return TermuxResult(
        ok: true,
        stdout: (res['stdout'] as String?) ?? '',
        stderr: (res['stderr'] as String?) ?? '',
        exitCode: res['exitCode'] as int?,
      );
    } on PlatformException catch (e) {
      return TermuxResult(ok: false, error: e.message ?? 'Platform error');
    } catch (e) {
      return TermuxResult(ok: false, error: '$e');
    }
  }
}
