import 'package:dio/dio.dart' show CancelToken;
import 'package:uuid/uuid.dart';

import '../../../core/models/chat_models.dart';
import '../../providers/domain/ai_provider.dart';

/// Marker stored in [ChatMessage.toolName] on the persisted summary row so
/// the history builder knows where the compacted part of a conversation ends.
const kCompactionMarker = 'compaction';

/// Result of one compaction pass.
class CompactionResult {
  const CompactionResult({
    required this.messages,
    required this.summary,
    required this.droppedCount,
  });

  /// The new, shorter message list (system first, then the kept tail).
  final List<ChatMessage> messages;

  /// Plain-text summary of everything that was dropped.
  final String summary;

  /// How many messages were replaced by the summary.
  final int droppedCount;
}

/// Keeps a conversation inside a token budget the way coding agents do:
/// when the history grows past the budget, the oldest turns are summarised
/// by the model itself and replaced with that summary, so a long chat or a
/// long agent run keeps going instead of overflowing the context window.
///
/// The budget is in estimated tokens (about 3.6 characters each). On the
/// local GGUF engine it is derived from the model's context size; on cloud
/// providers it is a user setting (saves tokens and money).
class ContextCompactor {
  ContextCompactor({
    required this.provider,
    required this.model,
    required this.params,
    required this.budgetTokens,
    this.priorSummary,
    this.cancelToken,
  });

  final AIProvider provider;
  final String model;
  final GenerationParams params;
  final int budgetTokens;

  /// Summary from an earlier compaction of the same conversation, so the
  /// new summary carries it forward rather than losing it.
  final String? priorSummary;
  final CancelToken? cancelToken;

  static const _uuid = Uuid();

  /// Share of the budget the kept tail may use after compaction.
  static const _tailShare = 0.4;

  static int estimateTokens(ChatMessage m) {
    var chars = m.content.length;
    for (final c in m.toolCalls) {
      chars += c.name.length + c.argumentsJson.length;
    }
    return (chars / 3.6).ceil() + 6;
  }

  static int estimateAll(Iterable<ChatMessage> messages) =>
      messages.fold(0, (acc, m) => acc + estimateTokens(m));

  bool needs(List<ChatMessage> messages) =>
      budgetTokens > 0 && estimateAll(messages) > budgetTokens;

  /// Returns null when the history already fits or nothing can be dropped.
  Future<CompactionResult?> compact(List<ChatMessage> messages) async {
    if (!needs(messages)) return null;

    final hasSystem =
        messages.isNotEmpty && messages.first.role == MessageRole.system;
    final system = hasSystem ? messages.first : null;
    final body = hasSystem ? messages.sublist(1) : messages;
    if (body.length < 2) return null;

    // Walk back from the end and find the latest turn boundary where the
    // kept tail still fits its share of the budget. A boundary is a user
    // turn or an assistant turn (so tool results stay with the call that
    // produced them); never cut right before a tool result.
    final tailBudget = (budgetTokens * _tailShare).floor();
    var acc = 0;
    var cut = -1;
    for (var i = body.length - 1; i >= 1; i--) {
      acc += estimateTokens(body[i]);
      if (acc > tailBudget) break;
      final role = body[i].role;
      if (role == MessageRole.user || role == MessageRole.assistant) cut = i;
    }
    if (cut < 1) {
      // Even the newest turn is too big for the tail share: keep just the
      // last boundary we can and summarise the rest.
      for (var i = body.length - 1; i >= 1; i--) {
        final role = body[i].role;
        if (role == MessageRole.user || role == MessageRole.assistant) {
          cut = i;
          break;
        }
      }
      if (cut < 1) return null;
    }

    final head = body.sublist(0, cut);
    final tail = body.sublist(cut);

    String summary;
    try {
      summary = await _summarise(head);
    } catch (_) {
      summary = '';
    }
    if (summary.trim().isEmpty) {
      summary = _mechanicalSummary(head);
    }

    final section = '## Earlier in this conversation (compacted summary)\n'
        'The older messages were replaced by this summary to save space. '
        'Treat it as what happened so far and continue from it.\n\n$summary';

    final newSystem = ChatMessage(
      id: system?.id ?? 'system',
      role: MessageRole.system,
      content: system == null || system.content.trim().isEmpty
          ? section
          : '${system.content}\n\n$section',
      createdAt: system?.createdAt ?? DateTime.now(),
    );

    final out = <ChatMessage>[newSystem];
    if (tail.first.role == MessageRole.assistant) {
      // Keep user/assistant alternation valid for strict providers.
      out.add(ChatMessage(
        id: _uuid.v4(),
        role: MessageRole.user,
        content: 'Continue the task from the compacted summary in your instructions.',
        createdAt: DateTime.now(),
      ));
    }
    out.addAll(tail);

    return CompactionResult(
      messages: out,
      summary: summary,
      droppedCount: head.length,
    );
  }

  Future<String> _summarise(List<ChatMessage> head) async {
    // Transcript size is capped so the summarising call itself fits the
    // same budget (matters most on the 2k-token local engine).
    final maxChars = (budgetTokens * 0.55 * 3.6).floor().clamp(1500, 60000).toInt();
    final transcript = _transcript(head, maxChars);

    final prompt = <ChatMessage>[
      ChatMessage(
        id: 'system',
        role: MessageRole.system,
        content:
            'You compress conversations. Write a summary that lets an assistant '
            'continue the conversation without seeing the original messages. Keep: '
            'the user\'s goal and standing instructions; names, numbers, file paths, '
            'URLs and other facts discovered; what has already been done and the '
            'results; what is still pending. Plain text, under 250 words, no preamble.',
        createdAt: DateTime.now(),
      ),
      ChatMessage(
        id: _uuid.v4(),
        role: MessageRole.user,
        content: (priorSummary != null && priorSummary!.trim().isNotEmpty
                ? 'Summary of the conversation before this part:\n$priorSummary\n\n'
                : '') +
            'Conversation to summarise:\n$transcript\n\nSummary:',
        createdAt: DateTime.now(),
      ),
    ];

    final buffer = StringBuffer();
    String? error;
    await for (final event in provider.streamMessage(ChatRequest(
      messages: prompt,
      model: model,
      params: GenerationParams(
        temperature: 0.3,
        topP: params.topP,
        maxTokens: 500,
      ),
      tools: const [],
      cancelToken: cancelToken,
    ))) {
      switch (event) {
        case TextDeltaEvent(:final text):
          buffer.write(text);
        case StreamErrorEvent(:final message):
          error = message;
        default:
          break;
      }
      if (cancelToken?.isCancelled ?? false) break;
    }
    if (error != null && buffer.isEmpty) throw StateError(error);
    return buffer.toString().trim();
  }

  static String _transcript(List<ChatMessage> head, int maxChars) {
    final lines = <String>[];
    for (final m in head) {
      switch (m.role) {
        case MessageRole.user:
          lines.add('USER: ${_clip(m.content, 2000)}');
        case MessageRole.assistant:
          final calls = m.toolCalls
              .map((c) => '[called ${c.name} ${_clip(c.argumentsJson, 300)}]')
              .join(' ');
          lines.add('ASSISTANT: ${_clip(m.content, 2000)} $calls'.trim());
        case MessageRole.tool:
          lines.add('TOOL ${m.toolName ?? ''}: ${_clip(m.content, 1200)}');
        case MessageRole.system:
          break;
      }
    }
    var text = lines.join('\n');
    if (text.length > maxChars) {
      // Keep the newest part; the oldest is least likely to still matter.
      text = '…\n${text.substring(text.length - maxChars)}';
    }
    return text;
  }

  static String _mechanicalSummary(List<ChatMessage> head) {
    final users = head
        .where((m) => m.role == MessageRole.user)
        .map((m) => '- ${_clip(m.content.replaceAll('\n', ' '), 200)}')
        .toList();
    final tools = head
        .where((m) => m.role == MessageRole.tool)
        .map((m) => m.toolName ?? 'tool')
        .toSet();
    return 'The model could not write a summary, so this is a mechanical one.\n'
        'Earlier user requests:\n${users.join('\n')}\n'
        '${tools.isEmpty ? '' : 'Tools used: ${tools.join(', ')}.'}';
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…[+${s.length - max} chars]';
}
