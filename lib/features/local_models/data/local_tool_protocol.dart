import 'dart:convert';

import 'package:pocketstrike/core/models/chat_models.dart';
import 'package:pocketstrike/features/providers/domain/provider_types.dart';

/// Tool calling for on-device GGUF models, which have no tool API.
///
/// The tools are described in the system prompt in a compact form, the model
/// asks for one by writing a single line `TOOL {"name": ..., "args": {...}}`,
/// and results go back as a user turn. Small models follow one simple,
/// explicit format far more reliably than a full JSON-schema tool spec, and
/// the whole description has to fit a 4k-token context.
class LocalToolProtocol {
  const LocalToolProtocol._();

  static const marker = 'TOOL';

  /// One line per tool: `name(arg1, arg2?) - what it does`.
  static String toolPrompt(List<ProviderToolSpec> tools) {
    final b = StringBuffer(
      'You can use tools on this phone. To use one, reply with ONLY this single line and nothing else:\n'
      '$marker {"name": "tool_name", "args": {"arg": "value"}}\n'
      'You then receive the result and continue. Use one tool per reply. When you have what you '
      'need, answer the user in plain text without a $marker line. Never invent a tool result.\n\n'
      'Tools:\n',
    );
    for (final t in tools) {
      final props = (t.parameters['properties'] as Map?) ?? const {};
      final required = ((t.parameters['required'] as List?) ?? const []).map((e) => e.toString()).toSet();
      final args = [for (final k in props.keys) required.contains(k) ? '$k' : '$k?'].join(', ');
      var desc = t.description.split(RegExp(r'(?<=[.!?])\s')).first.trim();
      if (desc.length > 110) desc = '${desc.substring(0, 110)}…';
      b.writeln('- ${t.name}($args) - $desc');
    }
    return b.toString().trimRight();
  }

  /// Rewrites an agent history into plain user/model turns a chat template
  /// can render: tool calls become the model's TOOL line, results a user turn.
  static List<ChatMessage> prepare(List<ChatMessage> messages, List<ProviderToolSpec> tools) {
    final out = <ChatMessage>[];
    final prompt = toolPrompt(tools);
    var hasSystem = false;
    for (final m in messages) {
      switch (m.role) {
        case MessageRole.system:
          hasSystem = true;
          out.add(_msg(m, MessageRole.system, '${m.content.trim()}\n\n$prompt'.trim()));
        case MessageRole.user:
          out.add(m);
        case MessageRole.assistant:
          final lines = <String>[
            if (m.content.trim().isNotEmpty) m.content.trim(),
            for (final c in m.toolCalls) '$marker {"name": "${c.name}", "args": ${_argsJson(c.argumentsJson)}}',
          ];
          if (lines.isNotEmpty) out.add(_msg(m, MessageRole.assistant, lines.join('\n')));
        case MessageRole.tool:
          var result = m.content.trim();
          if (result.length > 1500) {
            result = '${result.substring(0, 1500)}\n…[${result.length - 1500} more characters cut]';
          }
          out.add(_msg(
            m,
            MessageRole.user,
            'TOOL RESULT (${m.toolName ?? 'tool'}):\n${result.isEmpty ? '(no output)' : result}\n\n'
            'Continue: use another tool, or give the final answer.',
          ));
      }
    }
    if (!hasSystem) {
      out.insert(0, ChatMessage(id: 'system', role: MessageRole.system, content: prompt, createdAt: DateTime.now()));
    }
    return out;
  }

  static ChatMessage _msg(ChatMessage m, MessageRole role, String content) =>
      ChatMessage(id: m.id, role: role, content: content, createdAt: m.createdAt);

  static String _argsJson(String raw) {
    try {
      final d = jsonDecode(raw);
      return d is Map ? jsonEncode(d) : '{}';
    } catch (_) {
      return '{}';
    }
  }

  /// Where a tool request starts in [text], or -1. Also true for a reply that
  /// is nothing but a JSON object or a fenced block (models drift that way).
  static int requestStart(String text) {
    final m = RegExp('$marker\\s*[:=]?\\s*\\{').firstMatch(text);
    if (m != null) return m.start;
    final t = text.trimLeft();
    if (t.startsWith('{') || t.startsWith('```')) return text.length - t.length;
    return -1;
  }

  /// True once the JSON object of a tool request is complete.
  static bool isComplete(String text) {
    // Only a request that actually parses counts, so a code block that
    // happens to contain braces is not cut short.
    return parse(text, 0).call != null;
  }

  /// The tool call in [text], if any, and the plain text written before it.
  static ({String before, ToolCallInfo? call}) parse(String text, int callIndex) {
    final start = requestStart(text);
    if (start < 0) return (before: text, call: null);
    final json = _balancedObject(text, start);
    if (json == null) return (before: text, call: null);
    try {
      final d = jsonDecode(json);
      if (d is! Map) return (before: text, call: null);
      final name = (d['name'] ?? d['tool'] ?? d['function'])?.toString();
      if (name == null || name.isEmpty) return (before: text, call: null);
      final args = d['args'] ?? d['arguments'] ?? d['parameters'] ?? d['input'] ?? const <String, dynamic>{};
      return (
        before: text.substring(0, start).trim(),
        call: ToolCallInfo(
          id: 'local_$callIndex',
          name: name,
          argumentsJson: jsonEncode(args is Map ? args : const <String, dynamic>{}),
        ),
      );
    } catch (_) {
      return (before: text, call: null);
    }
  }

  /// The first balanced `{...}` at or after [from], respecting strings.
  static String? _balancedObject(String text, int from) {
    final open = text.indexOf('{', from);
    if (open < 0) return null;
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = open; i < text.length; i++) {
      final c = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (c == '\\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      if (c == '"') {
        inString = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) return text.substring(open, i + 1);
      }
    }
    return null;
  }
}
