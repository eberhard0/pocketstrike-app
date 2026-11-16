import 'package:pocketstrike/features/agent/domain/agent_tool.dart';
import 'package:pocketstrike/features/agent/data/termux_bridge.dart';

/// The agent's shell: runs commands inside the Termux app. Separate from the sandboxed file tools
/// because this reaches a real Linux environment and can install and run software.
class TermuxTools {
  const TermuxTools._();

  static List<AgentTool> all() => [runInTermux()];

  static AgentTool runInTermux() => AgentTool(
        name: 'run_in_termux',
        description:
            'Run a shell command in the Termux app (a full Linux environment on this phone with '
            'bash, git, python, pip and more) and return its stdout, stderr and exit code. Use this '
            'to install and run command-line tools and scripts. Each call is a fresh non-interactive '
            '`bash -lc` shell, so chain steps with && and set the working directory with the '
            '"workdir" argument rather than relying on a previous `cd`. The command cannot read '
            'keyboard input: pass answers with flags, a heredoc, echo piped in, or environment '
            'variables. Long installs may take a while; raise "timeoutSeconds" for them. Requires '
            'Termux installed with allow-external-apps enabled; if a call reports Termux cannot be '
            'reached, tell the user how to fix it instead of retrying.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'command': {
              'type': 'string',
              'description': 'The shell command to run, e.g. "pkg install -y git python" or '
                  '"cd ~/GhostTrack && python ghostrack.py --help".',
            },
            'workdir': {
              'type': 'string',
              'description': 'Optional working directory, e.g. "/data/data/com.termux/files/home".',
            },
            'timeoutSeconds': {
              'type': 'integer',
              'description': 'How long to wait, 10–900. Default 180. Use a large value for installs.',
            },
          },
          'required': ['command'],
        },
        risk: ToolRisk.destructive,
        run: (args) async {
          final command = (args['command'] as String?)?.trim() ?? '';
          if (command.isEmpty) return 'Error: no command given.';
          final workdir = (args['workdir'] as String?)?.trim();
          final secs = (args['timeoutSeconds'] as num?)?.toInt().clamp(10, 900) ?? 180;
          final res = await TermuxBridge.run(
            command,
            workdir: workdir?.isNotEmpty == true ? workdir : null,
            timeout: Duration(seconds: secs),
          );
          if (!res.ok) return 'Could not run the command. ${res.error}';
          final b = StringBuffer('exit code: ${res.exitCode ?? "?"}');
          final out = _clip(res.stdout.trimRight());
          final err = _clip(res.stderr.trimRight());
          if (out.isNotEmpty) b.write('\n--- stdout ---\n$out');
          if (err.isNotEmpty) b.write('\n--- stderr ---\n$err');
          if (out.isEmpty && err.isEmpty) b.write('\n(no output)');
          return b.toString();
        },
      );

  static String _clip(String s, {int max = 8000}) =>
      s.length <= max ? s : '${s.substring(0, max)}\n…[${s.length - max} more characters]';
}
