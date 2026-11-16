import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketstrike/features/skills/data/skill_library.dart';
import 'package:pocketstrike/core/db/app_database.dart';
import 'package:pocketstrike/core/models/chat_models.dart';
import 'package:pocketstrike/features/agent/application/agent_prefs.dart';
import 'package:pocketstrike/features/agent/data/agent_engine.dart';
import 'package:pocketstrike/features/agent/data/context_compactor.dart';
import 'package:pocketstrike/features/agent/data/hermes_memory_store.dart';
import 'package:pocketstrike/features/agent/data/storage_tools.dart';
import 'package:pocketstrike/features/agent/data/termux_tools.dart';
import 'package:pocketstrike/features/agent/domain/agent_event.dart';
import 'package:pocketstrike/features/agent/domain/agent_tool.dart';
import 'package:pocketstrike/features/conversations/application/conversations_controller.dart';
import 'package:pocketstrike/features/local_models/data/local_model_engine.dart';
import 'package:pocketstrike/features/local_models/data/local_model_info.dart';
import 'package:pocketstrike/features/local_models/data/local_model_store.dart';
import 'package:pocketstrike/features/providers/application/providers_controller.dart';
import 'package:pocketstrike/features/providers/data/mock_provider.dart';
import 'package:pocketstrike/features/providers/domain/ai_provider.dart';
import 'package:pocketstrike/features/providers/domain/provider_types.dart';
import 'package:pocketstrike/shared/widgets/confirm_action_sheet.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

enum ChatMode { chat, agent, local }

typedef ConfirmHandler = Future<ConfirmResult> Function(
  AgentTool tool,
  ToolCallInfo call,
);

class ChatState {
  const ChatState({
    this.isGenerating = false,
    this.isGeneratingImage = false,
    this.imageGenerationPrompt,
    this.streamingText = '',
    this.agentMode = false,
    this.localMode = false,
    this.demoMode = false,
    this.tokensPerSecond,
    this.tokenCount,
    this.messageSpeeds = const {},
    this.status,
    this.error,
    this.runId,
    this.steps = const [],
  });

  final bool isGenerating;
  final bool isGeneratingImage;
  final String? imageGenerationPrompt;
  final String streamingText;

  /// ReAct agent mode (runs tool loop) vs plain completion.
  final bool agentMode;

  /// 100% Offline Local on-device GGUF / Image inference mode.
  final bool localMode;

  /// Demo mode uses [MockProvider] for offline testing without API keys.
  final bool demoMode;

  /// Live token generation speed in tokens per second.
  final double? tokensPerSecond;
  final int? tokenCount;

  /// Historical speed per message id.
  final Map<String, double> messageSpeeds;

  final String? status;
  final String? error;
  final String? runId;
  final List<AgentStep> steps;

  ChatMode get currentMode {
    if (localMode) return ChatMode.local;
    if (agentMode) return ChatMode.agent;
    return ChatMode.chat;
  }

  ChatState copyWith({
    bool? isGenerating,
    bool? isGeneratingImage,
    String? imageGenerationPrompt,
    bool clearImagePrompt = false,
    String? streamingText,
    bool? agentMode,
    bool? localMode,
    bool? demoMode,
    double? tokensPerSecond,
    bool clearTokensPerSecond = false,
    int? tokenCount,
    Map<String, double>? messageSpeeds,
    String? status,
    bool clearStatus = false,
    String? error,
    bool clearError = false,
    String? runId,
    List<AgentStep>? steps,
  }) {
    return ChatState(
      isGenerating: isGenerating ?? this.isGenerating,
      isGeneratingImage: isGeneratingImage ?? this.isGeneratingImage,
      imageGenerationPrompt: clearImagePrompt
          ? null
          : (imageGenerationPrompt ?? this.imageGenerationPrompt),
      streamingText: streamingText ?? this.streamingText,
      agentMode: agentMode ?? this.agentMode,
      localMode: localMode ?? this.localMode,
      demoMode: demoMode ?? this.demoMode,
      tokensPerSecond: clearTokensPerSecond
          ? null
          : (tokensPerSecond ?? this.tokensPerSecond),
      tokenCount: tokenCount ?? this.tokenCount,
      messageSpeeds: messageSpeeds ?? this.messageSpeeds,
      status: clearStatus ? null : (status ?? this.status),
      error: clearError ? null : (error ?? this.error),
      runId: runId ?? this.runId,
      steps: steps ?? this.steps,
    );
  }
}

class ChatController extends StateNotifier<ChatState> {
  ChatController(this.ref) : super(const ChatState());

  final Ref ref;

  /// Hook supplied by UI to present confirmation dialogs for destructive tools.
  ConfirmHandler? confirmHandler;

  CancelToken? _cancelToken;
  final Set<String> _sessionApprovedTools = {};

  void toggleAgentMode(bool enabled) {
    state = state.copyWith(agentMode: enabled, localMode: false);
  }

  void toggleLocalMode(bool enabled) {
    state = state.copyWith(localMode: enabled, agentMode: false);
  }

  void setChatMode(ChatMode mode) {
    switch (mode) {
      case ChatMode.chat:
        state = state.copyWith(agentMode: false, localMode: false);
      case ChatMode.agent:
        state = state.copyWith(agentMode: true, localMode: false);
      case ChatMode.local:
        state = state.copyWith(agentMode: false, localMode: true);
    }
  }

  void setDemoMode(bool enabled) {
    state = state.copyWith(demoMode: enabled);
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  Future<void> sendMessage({
    required String text,
    List<AttachmentMeta> attachments = const [],
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty && attachments.isEmpty) return;
    if (state.isGenerating) return;

    // 1. Ensure active conversation exists.
    final conversationId = await ref
        .read(conversationActionsProvider)
        .ensureActiveConversation();

    // 2. Resolve AI provider & model.
    AIProvider provider;
    String model;
    GenerationParams params;

    final lowerTrimmed = trimmed.toLowerCase();
    final isSlashImageCommand = lowerTrimmed.startsWith('/image') ||
        lowerTrimmed.startsWith('/img');
    final isNaturalImageCommand = lowerTrimmed.startsWith('generate image') ||
        lowerTrimmed.startsWith('generate an image') ||
        lowerTrimmed.startsWith('create image') ||
        lowerTrimmed.startsWith('create an image') ||
        lowerTrimmed.startsWith('draw ') ||
        lowerTrimmed.startsWith('paint ') ||
        lowerTrimmed.startsWith('image of');

    // In Agent Mode, natural language requests ("generate an image of...") are executed by the Agent using the generate_image tool.
    // In Plain Mode, both slash and natural language commands trigger direct synthesis.
    final isExplicitImage = state.agentMode
        ? isSlashImageCommand
        : (isSlashImageCommand || isNaturalImageCommand);

    if (state.localMode || isExplicitImage) {
      final localStore = ref.read(localModelStoreProvider);
      final activeLocal = localStore.activeModel;
      provider = LocalAIProvider(activeModel: activeLocal);
      model = activeLocal?.name ?? 'local-gguf-default';
      params = GenerationParams(
        // The offline agent answers in short steps; plain chat may run long.
        temperature: _localAgent ? 0.4 : 0.7,
        maxTokens: _localAgent ? 700 : (activeLocal?.contextSize ?? 2048),
      );
    } else if (state.demoMode) {
      provider = const MockProvider();
      model = 'mock-v1';
      params = const GenerationParams();
    } else {
      final activeConfig = await ref.read(activeProviderConfigProvider.future);
      if (activeConfig == null) {
        state = state.copyWith(
          error: 'No active AI provider configured. Add one in Settings or switch to Local mode.',
        );
        return;
      }
      final resolved = await ref
          .read(providerResolverProvider)
          .resolve(configId: activeConfig.id);
      if (resolved == null) {
        state = state.copyWith(error: 'Failed to initialize AI provider.');
        return;
      }
      provider = resolved;
      model = activeConfig.defaultModel;
      if (model.isEmpty) {
        model = ProviderTypeX.fromId(activeConfig.type).suggestedModels.first;
      }
      params = await ref
          .read(providerResolverProvider)
          .paramsFor(provider.configId);
    }

    // 3. Persist the user message.
    final userMessage = ChatMessage(
      id: _uuid.v4(),
      role: MessageRole.user,
      content: trimmed,
      attachments: attachments,
      createdAt: DateTime.now(),
    );
    await _persistMessage(conversationId, userMessage);
    await _maybeAutoTitle(conversationId, trimmed);

    // 4. Build provider history (system prompt from persona + prior msgs).
    var history = await _buildHistory(conversationId, params);

    final localStore = ref.read(localModelStoreProvider);
    final isImageRequest = (state.localMode && localStore.activeModel?.type == LocalModelType.imageModel) || isExplicitImage;

    state = state.copyWith(
      isGenerating: true,
      isGeneratingImage: isImageRequest,
      imageGenerationPrompt: isImageRequest ? trimmed : null,
      streamingText: '',
      status: isImageRequest ? 'Generating image…' : 'Thinking…',
      steps: const [],
      clearError: true,
    );
    _cancelToken = CancelToken();

    try {
      // 5. Compact the history if it has outgrown the budget, so a long
      // chat keeps working on a 2k-token local model and a long agent run
      // does not burn the whole window on cloud models.
      final compactor = ContextCompactor(
        provider: provider,
        model: model,
        params: params,
        budgetTokens: _compactBudget(
          local: state.localMode || isExplicitImage,
          activeLocal: localStore.activeModel,
        ),
        priorSummary: _priorSummary,
        cancelToken: _cancelToken,
      );
      if (!isImageRequest && compactor.needs(history)) {
        state = state.copyWith(status: 'Compacting context…');
        try {
          final result = await compactor.compact(history);
          if (result != null) {
            await _persistCompaction(conversationId, result.summary);
            history = result.messages;
          }
        } catch (_) {
          // Best effort; continue with the full history.
        }
      }

      if (state.agentMode || (_localAgent && !isImageRequest)) {
        await _runAgent(
          conversationId: conversationId,
          provider: provider,
          model: model,
          params: params,
          history: history,
          compactor: compactor,
          local: _localAgent && !state.agentMode,
        );
      } else {
        await _runPlainChat(
          conversationId: conversationId,
          provider: provider,
          model: model,
          params: params,
          history: history,
        );
      }
    } finally {
      state = state.copyWith(
        isGenerating: false,
        isGeneratingImage: false,
        clearImagePrompt: true,
        streamingText: '',
        clearStatus: true,
      );
      _cancelToken = null;
    }
  }

  /// Cancels in-flight generation or agent execution.
  void stopGeneration() {
    if (_cancelToken != null && !_cancelToken!.isCancelled) {
      _cancelToken!.cancel('User stopped generation');
      state = state.copyWith(
        isGenerating: false,
        isGeneratingImage: false,
        clearImagePrompt: true,
        clearStatus: true,
      );
      _cancelToken = null;
    }
  }

  /// Injects a scheduled reminder message into the active chat.
  Future<void> injectReminderMessage(String title, String content) async {
    final conversationId = await ref
        .read(conversationActionsProvider)
        .ensureActiveConversation();

    final reminderMessage = ChatMessage(
      id: _uuid.v4(),
      role: MessageRole.assistant,
      content: '⏰ **Reminder Alert: $title**\n\n$content',
      createdAt: DateTime.now(),
    );
    await _persistMessage(conversationId, reminderMessage);
  }

  void stop() => stopGeneration();

  /// Re-runs the last user message (regenerate).
  Future<void> regenerate() async {
    final conversationId = ref.read(currentConversationIdProvider);
    if (conversationId == null || state.isGenerating) return;
    final messages = await ref
        .read(appDatabaseProvider)
        .messagesDao
        .getForConversation(conversationId);
    final lastUser = messages.where((m) => m.role == 'user').lastOrNull;
    if (lastUser == null) return;
    // Drop the last exchange, then resend the same prompt.
    await ref
        .read(appDatabaseProvider)
        .messagesDao
        .deleteFrom(conversationId, lastUser.createdAt);
    await sendMessage(text: lastUser.content);
  }

  /// Edits a past user message and re-runs from that point.
  Future<void> editAndResend(Message message, String newText) async {
    if (state.isGenerating) return;
    await ref.read(appDatabaseProvider).messagesDao.deleteFrom(
          message.conversationId,
          message.createdAt,
        );
    await sendMessage(text: newText);
  }

  // ------------------------------------------------------------------
  // Plain streaming chat
  // ------------------------------------------------------------------

  Future<void> _runPlainChat({
    required String conversationId,
    required AIProvider provider,
    required String model,
    required GenerationParams params,
    required List<ChatMessage> history,
  }) async {
    final buffer = StringBuffer();
    UsageInfo? usageInfo;
    String? error;
    final stopwatch = Stopwatch()..start();
    var tokenCount = 0;
    double? lastTps;

    await for (final event in provider.streamMessage(ChatRequest(
      messages: history,
      model: model,
      params: params,
      cancelToken: _cancelToken,
    ))) {
      switch (event) {
        case TextDeltaEvent(:final text):
          buffer.write(text);
          tokenCount += (text.length > 4 ? (text.length / 3.8).ceil() : 1);
          final elapsed = stopwatch.elapsedMilliseconds / 1000.0;
          if (elapsed > 0.12) {
            lastTps = tokenCount / elapsed;
          }
          state = state.copyWith(
            streamingText: buffer.toString(),
            tokensPerSecond: lastTps,
            tokenCount: tokenCount,
          );
          break;
        case SpeedMetricsEvent(:final tokensPerSecond, :final tokenCount):
          lastTps = tokensPerSecond;
          state = state.copyWith(
            tokensPerSecond: tokensPerSecond,
            tokenCount: tokenCount ?? state.tokenCount,
          );
          break;
        case UsageEvent(:final usage):
          usageInfo = usage;
          break;
        case StreamErrorEvent(:final message):
          error = message;
          break;
        case ToolCallsEvent():
          break;
        case StreamDoneEvent():
          break;
      }
      if (_cancelToken?.isCancelled ?? false) break;
    }

    stopwatch.stop();
    final totalElapsedSec = stopwatch.elapsedMilliseconds / 1000.0;
    final finalTps = (totalElapsedSec > 0.15 && tokenCount > 0)
        ? (tokenCount / totalElapsedSec)
        : (lastTps ?? state.tokensPerSecond);

    if (error != null) {
      state = state.copyWith(error: error);
      return;
    }

    if (buffer.isNotEmpty) {
      final msgId = _uuid.v4();
      if (finalTps != null && finalTps > 0) {
        state = state.copyWith(
          messageSpeeds: {...state.messageSpeeds, msgId: finalTps},
        );
      }
      await _persistMessage(
        conversationId,
        ChatMessage(
          id: msgId,
          role: MessageRole.assistant,
          content: buffer.toString(),
          tokensPerSecond: finalTps,
          tokenCount: tokenCount > 0 ? tokenCount : null,
          createdAt: DateTime.now(),
        ),
        promptTokens: usageInfo?.promptTokens,
        completionTokens: usageInfo?.completionTokens ??
            (tokenCount > 0 ? tokenCount : null),
      );
    }
  }

  // ------------------------------------------------------------------
  // Agent mode (ReAct loop with tool calling)
  // ------------------------------------------------------------------

  Future<void> _runAgent({
    required String conversationId,
    required AIProvider provider,
    required String model,
    required GenerationParams params,
    required List<ChatMessage> history,
    ContextCompactor? compactor,
    bool local = false,
  }) async {
    // The project folder: relative file paths and Termux commands start there.
    final project = ref.read(projectDirProvider);
    StorageAgentTools.projectDir = project;
    TermuxTools.defaultWorkdir = project;

    final baseTools = await _availableTools(conversationId);
    final forceConfirm = await _forcedMcpConfirmations(conversationId);

    Future<ConfirmResult> confirm(AgentTool tool, ToolCallInfo call) async {
      final handler = confirmHandler;
      if (handler == null) return ConfirmResult.deny;
      final result = await handler(tool, call);
      if (result == ConfirmResult.allowAlways) {
        _sessionApprovedTools.add(tool.name);
      }
      return result;
    }

    // The on-device model gets a short tool list that fits its context, and
    // no helper agents.
    final tools = local
        ? [
            for (final t in baseTools)
              if (LocalAgentNotifier.tools.contains(t.name)) t,
          ]
        : [
      ...baseTools,
      _subagentTool(
        provider: provider,
        model: model,
        params: params,
        tools: baseTools,
        forceConfirm: forceConfirm,
        budgetTokens: compactor?.budgetTokens ?? 0,
        confirm: confirm,
      ),
    ];

    final runId = _uuid.v4();
    await ref.read(appDatabaseProvider).agentRunsDao.upsert(
          AgentRunsCompanion.insert(
            id: runId,
            conversationId: conversationId,
            createdAt: DateTime.now(),
          ),
        );
    state = state.copyWith(runId: runId);

    final engine = local
        ? AgentEngine(maxSteps: 8, maxObservationChars: 1500)
        : AgentEngine();
    final steps = <AgentStep>[];
    final buffer = StringBuffer();
    ChatMessage? finalAssistant;
    String? runError;
    var runStatus = 'done';
    final stopwatch = Stopwatch()..start();
    var tokenCount = 0;
    double? lastTps;

    await for (final event in engine.run(
      provider: provider,
      history: history,
      model: model,
      params: params,
      tools: tools,
      policy: _policy,
      sessionApproved: _sessionApprovedTools,
      forceConfirm: forceConfirm,
      cancelToken: _cancelToken,
      compactor: compactor,
      requestConfirmation: confirm,
    )) {
      switch (event) {
        case AgentStatusEvent(:final status):
          state = state.copyWith(status: status);
          break;
        case AgentTextDeltaEvent(:final text):
          buffer.write(text);
          tokenCount += (text.length > 4 ? (text.length / 3.8).ceil() : 1);
          final elapsed = stopwatch.elapsedMilliseconds / 1000.0;
          if (elapsed > 0.12) {
            lastTps = tokenCount / elapsed;
          }
          state = state.copyWith(
            streamingText: buffer.toString(),
            tokensPerSecond: lastTps,
            tokenCount: tokenCount,
          );
          break;
        case AgentToolCallStartedEvent(:final call):
          steps.add(AgentStep(
            type: 'toolCall',
            timestamp: DateTime.now(),
            toolName: call.name,
            argumentsJson: call.argumentsJson,
          ));
          state = state.copyWith(
            steps: List.unmodifiable(steps),
            status: 'Running ${call.name}…',
          );
          break;
        case AgentToolCallCompletedEvent(:final call, :final result, :final isError):
          steps.add(AgentStep(
            type: 'observation',
            timestamp: DateTime.now(),
            toolName: call.name,
            result: result,
            isError: isError,
          ));
          state = state.copyWith(
            steps: List.unmodifiable(steps),
            status: 'Reasoning…',
          );
          await _persistMessage(
            conversationId,
            ChatMessage(
              id: _uuid.v4(),
              role: MessageRole.tool,
              content: result,
              toolCallId: call.id,
              toolName: call.name,
              createdAt: DateTime.now(),
            ),
          );
          break;
        case AgentCompactedEvent(:final summary, :final droppedCount):
          steps.add(AgentStep(
            type: 'compaction',
            timestamp: DateTime.now(),
            text: 'Context compacted: $droppedCount earlier messages '
                'summarised to stay within the budget.',
          ));
          state = state.copyWith(
            steps: List.unmodifiable(steps),
            status: 'Thinking…',
          );
          await _persistCompaction(conversationId, summary);
          break;
        case AgentToolCallDeniedEvent(:final call):
          steps.add(AgentStep(
            type: 'denied',
            timestamp: DateTime.now(),
            toolName: call.name,
          ));
          state = state.copyWith(
            steps: List.unmodifiable(steps),
            status: 'Denied ${call.name}',
          );
          break;
        case AgentAssistantMessageEvent(:final message):
          finalAssistant = message;
          break;
        case AgentUsageEvent():
          break;
        case AgentRunErrorEvent(:final message):
          runStatus = 'error';
          runError = message;
          state = state.copyWith(error: message);
          break;
        case AgentRunFinishedEvent(:final cancelled):
          if (cancelled) runStatus = 'cancelled';
          break;
      }
    }

    stopwatch.stop();
    final totalElapsedSec = stopwatch.elapsedMilliseconds / 1000.0;
    final finalTps = (totalElapsedSec > 0.15 && tokenCount > 0)
        ? (tokenCount / totalElapsedSec)
        : (lastTps ?? state.tokensPerSecond);

    final finalText = buffer.toString().trim();
    String contentToPersist = finalText.isNotEmpty
        ? finalText
        : (finalAssistant != null && finalAssistant.content.trim().isNotEmpty
            ? finalAssistant.content.trim()
            : (steps.isNotEmpty
                ? '✅ Finished executing ${steps.where((s) => s.type == 'observation').length} actions.'
                : (runError != null
                    ? '⚠️ The request to the AI provider failed, so nothing was done.\n\n$runError'
                    : 'The model returned an empty answer and ran no tools. Try again, or '
                        'rephrase the request.')));

    // If the agent generated images, format cleanly with a single verified image card and heading
    final imageGenSteps = steps
        .where((s) => s.type == 'observation' && s.toolName == 'generate_image')
        .toList();

    if (imageGenSteps.isNotEmpty) {
      final verifiedImageTags = <String>[];
      for (final step in imageGenSteps) {
        if (step.result != null && step.result!.contains('![Generated Image](')) {
          final matches = RegExp(r'!\[Generated Image\]\([^)]+\)')
              .allMatches(step.result!);
          for (final m in matches) {
            final tag = m.group(0);
            if (tag != null && !verifiedImageTags.contains(tag)) {
              verifiedImageTags.add(tag);
            }
          }
        }
      }

      // Strip any hallucinated/dummy markdown image tags from the LLM's raw text
      var cleaned = finalText
          .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
          .replaceAll(
            RegExp(
              r'(?:\b(?:Saved|Stored|File|Image|Picture|Path|Location)\s*(?:at|to|path|location)?\s*[:\-]?\s*)?'
              r'(?:file://)?(?:/data/user/\d+/[^\s\)]+|/data/data/[^\s\)]+|/storage/emulated/\d+/[^\s\)]+|app_flutter/[^\s\)]+)(?![^\[]*\]|\))',
              caseSensitive: false,
            ),
            '',
          )
          .replaceAll(RegExp(r'\n{3,}'), '\n\n')
          .trim();

      final textLower = cleaned.toLowerCase();
      final isGeneric = cleaned.isEmpty ||
          textLower.startsWith('i have generated') ||
          textLower.startsWith('i\'ve generated') ||
          textLower.startsWith('here is the image') ||
          textLower.startsWith('here is your image') ||
          textLower.startsWith('here\'s the image') ||
          textLower.startsWith('here\'s your image') ||
          textLower.startsWith('image generated') ||
          textLower.startsWith('task completed') ||
          textLower.startsWith('✅ finished executing');

      if (isGeneric && verifiedImageTags.isNotEmpty) {
        contentToPersist = 'Here is your image:\n\n${verifiedImageTags.join('\n\n')}';
      } else if (verifiedImageTags.isNotEmpty) {
        contentToPersist = '$cleaned\n\n${verifiedImageTags.join('\n\n')}';
      }
    }

    final msgId = finalAssistant?.id ?? _uuid.v4();
    if (finalTps != null && finalTps > 0) {
      state = state.copyWith(
        messageSpeeds: {...state.messageSpeeds, msgId: finalTps},
      );
    }

    final toolCallsForMessage = <ToolCallInfo>[];
    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];
      if (step.type == 'toolCall') {
        AgentStep? observation;
        for (int j = i + 1; j < steps.length; j++) {
          if (steps[j].type == 'observation' &&
              steps[j].toolName == step.toolName) {
            observation = steps[j];
            break;
          }
        }
        toolCallsForMessage.add(
          ToolCallInfo(
            id: step.timestamp.toIso8601String(),
            name: step.toolName ?? 'tool',
            argumentsJson: step.argumentsJson ?? '{}',
            result: observation?.result,
            isError: observation?.isError ?? false,
          ),
        );
      }
    }

    await _persistMessage(
      conversationId,
      ChatMessage(
        id: msgId,
        role: MessageRole.assistant,
        content: contentToPersist,
        toolCalls: toolCallsForMessage,
        tokensPerSecond: finalTps,
        tokenCount: tokenCount > 0 ? tokenCount : null,
        createdAt: DateTime.now(),
      ),
      completionTokens: tokenCount > 0 ? tokenCount : null,
    );

    state = state.copyWith(steps: List.unmodifiable(steps));
    await ref.read(appDatabaseProvider).agentRunsDao.updateRun(
          runId,
          runStatus,
          jsonEncode(steps.map((s) => s.toJson()).toList()),
        );
  }

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------

  Future<List<AgentTool>> _availableTools(String conversationId) async {
    return ref.read(providerResolverProvider).availableTools(conversationId);
  }

  Future<Set<String>> _forcedMcpConfirmations(
      String conversationId) async {
    return ref
        .read(providerResolverProvider)
        .forcedMcpConfirmations(conversationId);
  }

  ConfirmationPolicy get _policy => ref.read(confirmPolicyProvider);

  /// Local mode with the offline agent switched on.
  bool get _localAgent => state.localMode && ref.read(localAgentProvider);

  /// Rebuilds a valid tool-call sequence from what is stored.
  ///
  /// An agent turn is saved as loose tool-result rows followed by one assistant
  /// message that lists the calls (with their results, for the chat UI) under
  /// made-up ids. Sent back as is, the results come before the calls and the
  /// ids neither match nor fit the providers' id rules, so every follow-up
  /// message in an agent chat was rejected. Here each stored call becomes a
  /// proper pair: an assistant call with a clean id, then its result, and
  /// after all pairs the assistant's text.
  static List<ChatMessage> _normalizeToolHistory(List<ChatMessage> stored) {
    final out = <ChatMessage>[];
    var n = 0;
    for (final m in stored) {
      if (m.role == MessageRole.tool) continue; // re-created from the calls below
      if (m.role != MessageRole.assistant || m.toolCalls.isEmpty) {
        out.add(m);
        continue;
      }
      for (final call in m.toolCalls) {
        final id = 'call_${n++}';
        var result = call.result ?? 'No result was recorded for this call.';
        if (result.length > 4000) {
          result = '${result.substring(0, 4000)}\n…[${result.length - 4000} more characters]';
        }
        out.add(ChatMessage(
          id: '${m.id}_$id',
          role: MessageRole.assistant,
          content: '',
          toolCalls: [ToolCallInfo(id: id, name: call.name, argumentsJson: call.argumentsJson)],
          createdAt: m.createdAt,
        ));
        out.add(ChatMessage(
          id: '${m.id}_${id}_result',
          role: MessageRole.tool,
          content: result,
          toolCallId: id,
          toolName: call.name,
          createdAt: m.createdAt,
        ));
      }
      out.add(m.copyWith(toolCalls: const []));
    }
    return out;
  }

  /// Text describing the project folder for the system prompt, including the
  /// project's own POCKETSTRIKE.md instructions when present. Empty = no project.
  Future<String> _projectBlock({int maxNotes = 6000}) async {
    final project = ref.read(projectDirProvider);
    if (project == null || project.isEmpty) return '';
    final b = StringBuffer(
      '## Project folder\n'
      'You are working in the project folder "$project". Relative paths in the file tools '
      'resolve to it and run_in_termux starts there. Keep your work inside it unless told '
      'otherwise. To change an existing file use edit_file with exact text, not write_file.',
    );
    try {
      final notes = File('$project/POCKETSTRIKE.md');
      if (await notes.exists()) {
        var text = await notes.readAsString();
        if (text.length > maxNotes) text = '${text.substring(0, maxNotes)}\n…[truncated]';
        if (text.trim().isNotEmpty) {
          b.write('\n\n## Project instructions (POCKETSTRIKE.md)\n$text');
        }
      }
    } catch (_) {
      // Unreadable notes file: carry on without it.
    }
    return b.toString();
  }

  /// A tool that hands a self-contained task to a fresh agent loop and returns
  /// only its final report, keeping the main conversation's context small.
  AgentTool _subagentTool({
    required AIProvider provider,
    required String model,
    required GenerationParams params,
    required List<AgentTool> tools,
    required Set<String> forceConfirm,
    required int budgetTokens,
    required Future<ConfirmResult> Function(AgentTool, ToolCallInfo) confirm,
  }) =>
      AgentTool(
        name: 'run_subagent',
        description:
            'Hand one self-contained sub-task to a fresh helper agent that has the same tools, and get '
            'back only its final report. Use it to keep your own context small: reading or searching '
            'many files, researching a question, or making one isolated change. The helper cannot see '
            'this conversation, so put everything it needs into "task": the goal, the relevant paths, '
            'and what to report back. Run helpers one at a time.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'task': {
              'type': 'string',
              'description': 'Complete instructions for the helper, including what to report back.',
            },
          },
          'required': ['task'],
        },
        risk: ToolRisk.safe,
        run: (args) async {
          final task = (args['task'] as String?)?.trim() ?? '';
          if (task.isEmpty) return 'Error: no task given.';
          final projectBlock = await _projectBlock();
          final history = [
            ChatMessage(
              id: 'system',
              role: MessageRole.system,
              content: 'You are a helper agent working on one task for a lead agent. Do the task with '
                  'your tools, then reply with a short, factual report: what you found or changed, '
                  'the paths involved, and anything you could not do or verify. No preamble.'
                  '${projectBlock.isEmpty ? '' : '\n\n$projectBlock'}',
              createdAt: DateTime.now(),
            ),
            ChatMessage(id: _uuid.v4(), role: MessageRole.user, content: task, createdAt: DateTime.now()),
          ];
          String? report;
          String? error;
          var toolCalls = 0;
          await for (final event in AgentEngine(maxSteps: 25).run(
            provider: provider,
            history: history,
            model: model,
            params: params,
            tools: tools,
            policy: _policy,
            sessionApproved: _sessionApprovedTools,
            forceConfirm: forceConfirm,
            cancelToken: _cancelToken,
            compactor: ContextCompactor(
              provider: provider,
              model: model,
              params: params,
              budgetTokens: budgetTokens,
              cancelToken: _cancelToken,
            ),
            requestConfirmation: confirm,
          )) {
            if (event is AgentAssistantMessageEvent) {
              report = event.message.content;
            } else if (event is AgentRunErrorEvent) {
              error = event.message;
            } else if (event is AgentToolCallStartedEvent) {
              toolCalls++;
            }
          }
          if (report != null && report.trim().isNotEmpty) {
            return 'Helper report ($toolCalls tool calls):\n$report';
          }
          return 'The helper finished without a report'
              '${error == null ? '' : ' (error: $error)'} after $toolCalls tool calls.';
        },
      );

  /// Summary left by the latest compaction of the active conversation, set
  /// while building the history; carried into the next compaction.
  String? _priorSummary;

  /// Estimated-token budget for the conversation sent to the model.
  /// Local: a share of the engine's real context window (the engine caps it
  /// at 2048). Cloud: the user's compaction setting (0 = off).
  int _compactBudget({required bool local, LocalModelInfo? activeLocal}) {
    if (local) {
      final loaded = LocalLlamaNativeService.instance.loadedContextSize;
      final ctx = loaded > 0 ? loaded : (activeLocal?.contextSize ?? 2048).clamp(512, 4096);
      // The offline agent also needs room for the tool list and its answer.
      return (ctx * (_localAgent ? 0.45 : 0.6)).floor();
    }
    return ref.read(compactBudgetProvider);
  }

  Future<void> _persistCompaction(
    String conversationId,
    String summary,
  ) async {
    _priorSummary = summary;
    await _persistMessage(
      conversationId,
      ChatMessage(
        id: _uuid.v4(),
        role: MessageRole.system,
        content: summary,
        toolName: kCompactionMarker,
        createdAt: DateTime.now(),
      ),
    );
  }

  Future<List<ChatMessage>> _buildHistory(
    String conversationId,
    GenerationParams params,
  ) async {
    final rawMsgs = await ref
        .read(appDatabaseProvider)
        .messagesDao
        .getForConversation(conversationId);

    // A stored compaction row marks where the summarised part ends: only
    // the rows after the latest one are sent, the summary rides along in
    // the system prompt.
    final lastCompaction = rawMsgs.lastIndexWhere(
      (m) => m.role == MessageRole.system.name && m.toolName == kCompactionMarker,
    );
    _priorSummary = lastCompaction >= 0 ? rawMsgs[lastCompaction].content : null;
    final liveMsgs = lastCompaction >= 0
        ? rawMsgs.sublist(lastCompaction + 1)
        : rawMsgs;

    final storedMsgs = liveMsgs.map((m) {
      List<AttachmentMeta>? atts;
      if (m.attachmentsJson != null) {
        try {
          atts = [
            for (final raw in jsonDecode(m.attachmentsJson!) as List)
              AttachmentMeta.fromJson(raw as Map<String, dynamic>),
          ];
        } catch (_) {}
      }
      List<ToolCallInfo>? toolCalls;
      if (m.toolCallsJson != null) {
        try {
          toolCalls = [
            for (final raw in jsonDecode(m.toolCallsJson!) as List)
              ToolCallInfo.fromJson(raw as Map<String, dynamic>),
          ];
        } catch (_) {}
      }
      return ChatMessage(
        id: m.id,
        role: MessageRole.values.where((r) => r.name == m.role).firstOrNull ?? MessageRole.user,
        content: m.content,
        toolCallId: m.toolCallId,
        toolName: m.toolName,
        toolCalls: toolCalls ?? const [],
        attachments: atts ?? const [],
        createdAt: m.createdAt,
      );
    }).toList();
    final chatMsgs = _normalizeToolHistory(storedMsgs);

    final persona = await ref.read(activePersonaProvider.future);
    String systemPrompt = params.systemPrompt ?? '';

    if (persona != null && persona.systemPrompt.trim().isNotEmpty) {
      final pPrompt = persona.systemPrompt;
      systemPrompt = systemPrompt.isEmpty
          ? pPrompt
          : '$systemPrompt\n\n$pPrompt';
    }

    if (!state.localMode) {
      final hermesContext = ref.read(hermesMemoryProvider.notifier).buildHermesSystemPrompt();
      systemPrompt = systemPrompt.isEmpty
          ? hermesContext
          : '$systemPrompt\n\n$hermesContext';
    } else if (systemPrompt.isEmpty) {
      systemPrompt = 'You are PocketStrike AI, a helpful, intelligent, and concise assistant.';
    }

    final localAgent = _localAgent;
    if (localAgent) {
      systemPrompt = 'You are PocketStrike, an assistant running fully offline on an Android phone. '
          'Be brief. For tasks that need files or commands, use your tools step by step instead '
          'of explaining how the user could do it. Termux is the Linux shell on this phone '
          '(bash, python, git). File paths without a folder go to the Download folder or the '
          'project folder.';
      final projectBlock = await _projectBlock(maxNotes: 800);
      if (projectBlock.isNotEmpty) systemPrompt = '$systemPrompt\n\n$projectBlock';
    }

    // A loaded red-team skill (claude-red) primes the model for the current
    // attack surface. Matched on the most recent user turn.
    final lastUser = chatMsgs.lastWhere(
      (m) => m.role == MessageRole.user,
      orElse: () => ChatMessage(id: '', role: MessageRole.user, content: '', createdAt: DateTime.now()),
    );
    // Skill texts are far too long for the offline agent's context.
    final skill = localAgent ? null : await SkillLibrary.select(lastUser.content);
    SkillLibrary.active.value = skill;
    if (skill != null) {
      final block = await SkillLibrary.promptBlock(skill);
      systemPrompt = systemPrompt.isEmpty ? block : '$systemPrompt\n\n$block';
    }

    if (state.agentMode) {
      const agentImageInstruction =
          'You have full capabilities to generate images using the "generate_image" tool. When the user asks you to generate, create, draw, paint, design, or render an image, artwork, illustration, photo, or wallpaper, ALWAYS call the "generate_image" tool with a detailed, creative visual prompt and "1:1" aspect ratio unless specified otherwise.';
      systemPrompt = systemPrompt.isEmpty
          ? agentImageInstruction
          : '$systemPrompt\n\n$agentImageInstruction';

      final projectBlock = await _projectBlock();
      if (projectBlock.isNotEmpty) {
        systemPrompt = '$systemPrompt\n\n$projectBlock';
      }
    }

    final summary = _priorSummary;
    if (summary != null && summary.trim().isNotEmpty) {
      final section = '## Earlier in this conversation (compacted summary)\n'
          'The older messages were replaced by this summary to save space. '
          'Treat it as what happened so far and continue from it.\n\n$summary';
      systemPrompt = systemPrompt.isEmpty ? section : '$systemPrompt\n\n$section';
    }

    if (systemPrompt.isNotEmpty) {
      return [
        ChatMessage(
          id: 'system',
          role: MessageRole.system,
          content: systemPrompt,
          createdAt: DateTime.now(),
        ),
        ...chatMsgs,
      ];
    }
    return chatMsgs;
  }

  Future<void> _persistMessage(
    String conversationId,
    ChatMessage msg, {
    int? promptTokens,
    int? completionTokens,
  }) async {
    String? attsJson;
    if (msg.attachments.isNotEmpty) {
      attsJson = jsonEncode(msg.attachments.map((a) => a.toJson()).toList());
    }
    String? callsJson;
    if (msg.toolCalls.isNotEmpty) {
      callsJson = jsonEncode(msg.toolCalls.map((c) => c.toJson()).toList());
    }

    await ref.read(appDatabaseProvider).messagesDao.insertMessage(
          MessagesCompanion.insert(
            id: msg.id,
            conversationId: conversationId,
            role: msg.role.name,
            content: Value(msg.content),
            toolCallId: Value(msg.toolCallId),
            toolName: Value(msg.toolName),
            toolCallsJson: Value(callsJson),
            attachmentsJson: Value(attsJson),
            promptTokens: Value(promptTokens),
            completionTokens: Value(completionTokens),
            createdAt: msg.createdAt ?? DateTime.now(),
          ),
        );
  }

  Future<void> _maybeAutoTitle(String conversationId, String text) async {
    final conv = await ref
        .read(appDatabaseProvider)
        .conversationsDao
        .getById(conversationId);
    if (conv != null && (conv.title == 'New chat' || conv.title.isEmpty)) {
      final title = text.length > 30 ? '${text.substring(0, 30)}…' : text;
      await ref
          .read(conversationActionsProvider)
          .rename(conversationId, title);
    }
  }
}

final chatControllerProvider =
    StateNotifierProvider<ChatController, ChatState>((ref) {
  return ChatController(ref);
});
