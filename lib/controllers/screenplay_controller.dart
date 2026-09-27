import 'dart:async';
import '../models/screenplay.dart';
import '../models/script.dart';
import '../models/agent_command.dart';
import '../services/api_service.dart';
import '../services/screenplay_parser.dart';
import '../utils/app_logger.dart';

/// 剧本控制器
/// 负责协调剧本的生成流程：图片分析 → 解析 → 批量图片生成 → 批量视频生成
///
/// 新流程（有用户图片时）：
/// 1. 使用 GLM-4.5V 分析用户图片，提取角色特征
/// 2. 将特征描述 + 用户需求传给 GLM-4.7 生成剧本
/// 3. 生成第一张图片时，传入用户原图作为参考（图生图）
class ScreenplayController {
  final ApiService _apiService = ApiService();

  // 剧本状态
  Screenplay? _currentScreenplay;
  final StreamController<Screenplay> _screenplayController =
      StreamController<Screenplay>.broadcast();

  // 进度回调
  final StreamController<ScreenplayProgress> _progressController =
      StreamController<ScreenplayProgress>.broadcast();

  // 取消控制
  bool _isCancelled = false;
  final StreamController<bool> _cancelController =
      StreamController<bool>.broadcast();

  // 保存用户原始图片（用于图生图）
  List<String>? _userOriginalImages;

  // 保存角色三视图 URL（用于场景2+的人物一致性）
  List<String>? _characterReferenceUrls;

  // 流订阅
  Stream<Screenplay> get screenplayStream => _screenplayController.stream;
  Stream<ScreenplayProgress> get progressStream => _progressController.stream;
  Stream<bool> get cancelStream => _cancelController.stream;

  bool get isCancelled => _isCancelled;
  Screenplay? get currentScreenplay => _currentScreenplay;

  /// 处理用户请求，生成完整剧本
  /// [userImages] 用户上传的参考图片列表（base64格式），用于人物一致性
  Future<Screenplay> generateScreenplay(
    String userPrompt, {
    List<String>? userImages,
    void Function(double progress, String status)? onProgress,
  }) async {
    _isCancelled = false;
    _userOriginalImages = userImages; // 保存原始图片
    AppLogger.info('剧本生成', '开始处理用户请求: $userPrompt');
    if (userImages != null && userImages.isNotEmpty) {
      AppLogger.info('剧本生成', '用户提供了 ${userImages.length} 张参考图片');
    }

    try {
      String? characterAnalysis;

      // 步骤 0: 如果有用户图片，先用 GLM-4.5V 分析图片特征
      if (userImages != null && userImages.isNotEmpty) {
        _emitProgress(0.05, '正在分析图片特征...');
        characterAnalysis = await _analyzeUserImage(userImages.first);
        AppLogger.success('图片分析', '角色特征提取完成');
      }

      // 步骤 1: 调用 GLM-4.7 生成剧本（传入图片分析结果）
      _emitProgress(0.1, '正在规划剧本...');
      final screenplayJson = await _callGLMForScreenplay(userPrompt, characterAnalysis);

      if (_isCancelled) {
        AppLogger.warn('剧本生成', '用户取消操作');
        throw Exception('操作已取消');
      }

      // 步骤 2: 解析剧本
      _emitProgress(0.2, '正在解析剧本...');
      final screenplay = ScreenplayParser.parse(screenplayJson);
      _currentScreenplay = screenplay;
      _screenplayController.add(screenplay);

      AppLogger.success('剧本生成', '剧本生成成功: ${screenplay.scriptTitle}, ${screenplay.scenes.length} 个场景');
      _emitProgress(0.3, '剧本规划完成！开始生成图片...');

      // 步骤 3: 批量生成图片
      // 注意：_generateAllImages 会更新 _currentScreenplay
      await _generateAllImages(_currentScreenplay!, onProgress: (progress, status) {
        final totalProgress = 0.3 + (progress * 0.4); // 30%-70% for images
        _emitProgress(totalProgress, status);
        onProgress?.call(totalProgress, status);
      });

      if (_isCancelled) {
        AppLogger.warn('剧本生成', '用户取消操作');
        throw Exception('操作已取消');
      }

      // 步骤 4: 批量生成视频
      // 重要：必须使用更新后的 _currentScreenplay，因为图片 URL 已经填充
      await _generateAllVideos(_currentScreenplay!, onProgress: (progress, status) {
        final totalProgress = 0.7 + (progress * 0.3); // 70%-100% for videos
        _emitProgress(totalProgress, status);
        onProgress?.call(totalProgress, status);
      });

      if (_isCancelled) {
        AppLogger.warn('剧本生成', '用户取消操作');
        throw Exception('操作已取消');
      }

      AppLogger.success('剧本生成', '全部完成！${_currentScreenplay!.scriptTitle}');
      _emitProgress(1.0, '全部完成！');

      // 清理保存的图片
      _userOriginalImages = null;

      // 返回更新后的剧本（包含所有图片和视频 URL）
      return _currentScreenplay!;
    } catch (e) {
      _userOriginalImages = null;
      AppLogger.error('剧本生成', '生成失败', e, StackTrace.current);
      rethrow;
    }
  }

  /// 从已确认的剧本生成图片和视频（新流程）
  /// 这是两阶段流程的第二阶段：剧本已由用户确认，直接生成图片和视频
  /// 新版本：逐场景生成，每个场景生成完图片后立即生成视频
  /// [confirmedScreenplay] 用户确认的剧本（status = confirmed）
  /// [userImages] 用户上传的参考图片列表（可选，用于场景1图生图）
  /// [characterImageUrls] 角色三视图 URL 列表（用于场景2+的人物一致性）
  Future<Screenplay> generateFromConfirmed(
    Screenplay confirmedScreenplay, {
    List<String>? userImages,
    List<String>? characterImageUrls,
    void Function(double progress, String status)? onProgress,
  }) async {
    _isCancelled = false;
    _userOriginalImages = userImages;
    _characterReferenceUrls = characterImageUrls;
    _currentScreenplay = confirmedScreenplay;

    final totalScenes = confirmedScreenplay.scenes.length;
    AppLogger.info('剧本生成（从确认）',
        '开始并行生成图片和视频: ${confirmedScreenplay.scriptTitle}, $totalScenes 个场景');
    if (characterImageUrls != null && characterImageUrls.isNotEmpty) {
      AppLogger.info('剧本生成（从确认）', '使用角色三视图: ${characterImageUrls.length} 张');
    }

    try {
      // 更新状态为生成中
      _currentScreenplay = _currentScreenplay!.updateStatus(ScreenplayStatus.generating);
      _screenplayController.add(_currentScreenplay!);

      // 获取角色组合三视图 URL（最多2个角色）
      final characterUrls = _characterReferenceUrls?.take(2).toList() ?? [];

      // 用于跟踪进度的计数器
      final completedSteps = <String>[];
      final totalSteps = totalScenes * 2; // 每个场景：图片 + 视频

      // 更新进度的辅助函数
      void updateProgress() {
        final progress = completedSteps.length / totalSteps;
        final completedImages = completedSteps.where((s) => s.startsWith('image_')).length;
        final completedVideos = completedSteps.where((s) => s.startsWith('video_')).length;
        _emitProgress(progress, '$completedImages/$totalScenes 图片完成, $completedVideos/$totalScenes 视频完成');
        onProgress?.call(progress, '$completedImages/$totalScenes 图片完成, $completedVideos/$totalScenes 视频完成');
      }

      // 获取并发配置
      final concurrency = ApiConfig.concurrentScenes > 0 ? ApiConfig.concurrentScenes : 3;
      AppLogger.info('剧本生成（从确认）', '并发模式: 每批 $concurrency 个场景并行处理');

      // 处理单个场景的函数
      Future<void> processScene(Scene scene) async {
        final sceneNum = confirmedScreenplay.scenes.indexOf(scene) + 1;
        final sceneIdKey = 'scene_${scene.sceneId}';

        // 🆕 检查场景当前状态 - 如果已被手动触发处理或已完成，则跳过
        final currentScene = _currentScreenplay!.scenes.firstWhere(
          (s) => s.sceneId == scene.sceneId,
        );
        if (currentScene.status != SceneStatus.pending) {
          AppLogger.info('剧本生成', '场景 $sceneNum 已被处理（状态: ${currentScene.status.displayName}），跳过');
          // 仍然标记为已完成以更新进度
          if (!completedSteps.contains('image_$sceneIdKey')) {
            completedSteps.add('image_$sceneIdKey');
          }
          if (!completedSteps.contains('video_$sceneIdKey')) {
            completedSteps.add('video_$sceneIdKey');
          }
          updateProgress();
          return;
        }

        String? imageUrl;

        // === 步骤1: 生成场景图片 ===
        if (_isCancelled) {
          throw Exception('操作已取消');
        }

        // 更新状态为图片生成中
        _currentScreenplay = _currentScreenplay!.updateScene(
          scene.sceneId,
          scene.copyWith(status: SceneStatus.imageGenerating),
        );
        _screenplayController.add(_currentScreenplay!);

        try {
          // 优先使用用户原图（图生图），否则使用角色三视图
          if (_userOriginalImages != null && _userOriginalImages!.isNotEmpty) {
            AppLogger.info('图片生成', '场景 $sceneNum 使用用户原图进行图生图');
            imageUrl = await _apiService.generateImage(
              scene.imagePrompt,
              referenceImages: _userOriginalImages,
            );
          } else if (characterUrls.isNotEmpty) {
            // 使用角色三视图进行图生图
            AppLogger.info('图片生成', '场景 $sceneNum 使用角色三视图进行图生图');
            imageUrl = await _apiService.generateImageWithCharacterReference(
              scene.imagePrompt,
              characterImageUrls: characterUrls,
            );
          } else {
            // 没有任何参考图，使用纯文本生成（降级）
            AppLogger.warn('图片生成', '场景 $sceneNum 没有参考图，使用纯文本生成（人物可能不一致）');
            imageUrl = await _apiService.generateImage(scene.imagePrompt);
          }

          // 更新场景图片
          _currentScreenplay = _currentScreenplay!.updateScene(
            scene.sceneId,
            scene.copyWith(imageUrl: imageUrl, status: SceneStatus.imageCompleted),
          );
          _screenplayController.add(_currentScreenplay!);
          AppLogger.success('图片生成', '场景 $sceneNum 图片生成完成: $imageUrl');

          // 更新进度
          completedSteps.add('image_$sceneIdKey');
          updateProgress();
        } catch (e) {
          AppLogger.error('图片生成', '场景 $sceneNum 图片生成失败: $e');
          _currentScreenplay = _currentScreenplay!.updateScene(
            scene.sceneId,
            scene.copyWith(status: SceneStatus.failed),
          );
          _screenplayController.add(_currentScreenplay!);
          completedSteps.add('image_$sceneIdKey');
          completedSteps.add('video_$sceneIdKey'); // 跳过视频生成
          updateProgress();
          return; // 跳过视频生成
        }

        if (_isCancelled) {
          throw Exception('操作已取消');
        }

        // === 步骤2: 生成场景视频 ===
        // 更新状态为视频生成中
        final updatedScene = _currentScreenplay!.scenes.firstWhere((s) => s.sceneId == scene.sceneId);
        _currentScreenplay = _currentScreenplay!.updateScene(
          scene.sceneId,
          updatedScene.copyWith(status: SceneStatus.videoGenerating),
        );
        _screenplayController.add(_currentScreenplay!);

        try {
          // 构建参考图列表：角色三视图（最多2张）+ 当前场景图（1张）= 最多3张
          final List<String> referenceUrls = [];
          referenceUrls.addAll(characterUrls);
          if (imageUrl != null) {
            referenceUrls.add(imageUrl);
          }

          AppLogger.info('视频生成', '场景 $sceneNum 参考图: ${referenceUrls.length} 张');

          // 构建视频提示词
          final characterDescription = scene.characterDescription;
          String scenePrompt = scene.videoPrompt;
          if (characterDescription.isNotEmpty) {
            scenePrompt = 'Character reference: $characterDescription. Scene: ${scene.videoPrompt}';
          }

          // 调用视频生成API（启用提示词净化，避免触发管控）
          final videoResponse = await _apiService.generateVideo(
            imageUrls: referenceUrls,
            prompt: scenePrompt,
            seconds: '5',
            sanitizePrompt: true, // 净化提示词，移除敏感词
          );

          // 等待视频生成完成
          final finalResponse = await _apiService.pollVideoStatus(
            taskId: videoResponse.id!,
            timeout: const Duration(minutes: 10),
            interval: const Duration(seconds: 2),
            onProgress: (progress, status) {
              // 不更新总体进度，因为这是单个场景的进度
              AppLogger.info('视频生成', '场景 $sceneNum 视频生成中... $progress%');
            },
            isCancelled: () => _isCancelled,
          );

          // 更新场景视频
          final sceneWithVideo = _currentScreenplay!.scenes.firstWhere((s) => s.sceneId == scene.sceneId);
          _currentScreenplay = _currentScreenplay!.updateScene(
            scene.sceneId,
            sceneWithVideo.copyWith(videoUrl: finalResponse.videoUrl, status: SceneStatus.completed),
          );
          _screenplayController.add(_currentScreenplay!);
          AppLogger.success('视频生成', '场景 $sceneNum 视频生成完成: ${finalResponse.videoUrl}');

          // 更新进度
          completedSteps.add('video_$sceneIdKey');
          updateProgress();
        } catch (e) {
          AppLogger.error('视频生成', '场景 $sceneNum 视频生成失败: $e');
          final failedScene = _currentScreenplay!.scenes.firstWhere((s) => s.sceneId == scene.sceneId);
          _currentScreenplay = _currentScreenplay!.updateScene(
            scene.sceneId,
            failedScene.copyWith(status: SceneStatus.failed),
          );
          _screenplayController.add(_currentScreenplay!);
          completedSteps.add('video_$sceneIdKey');
          updateProgress();
        }
      }

      // 分批并行处理：每批 concurrency 个场景
      for (int i = 0; i < confirmedScreenplay.scenes.length; i += concurrency) {
        if (_isCancelled) {
          throw Exception('操作已取消');
        }

        final batchStart = i;
        final batchEnd = (i + concurrency).clamp(0, confirmedScreenplay.scenes.length);
        final batch = confirmedScreenplay.scenes.sublist(batchStart, batchEnd);

        AppLogger.info('剧本生成（从确认）', '处理批次 ${batchStart + 1}-$batchEnd (${batch.length} 个场景)');

        // 并行处理当前批次的所有场景
        await Future.wait(
          batch.map((scene) => processScene(scene)),
          eagerError: false,
        );
      }

      if (_isCancelled) {
        throw Exception('操作已取消');
      }

      // 更新状态为完成
      _currentScreenplay = _currentScreenplay!.updateStatus(ScreenplayStatus.completed);
      _screenplayController.add(_currentScreenplay!);

      AppLogger.success('剧本生成（从确认）', '全部完成！${_currentScreenplay!.scriptTitle}');
      _emitProgress(1.0, '全部完成！');

      // 清理保存的图片
      _userOriginalImages = null;
      _characterReferenceUrls = null;

      return _currentScreenplay!;
    } catch (e) {
      _currentScreenplay = _currentScreenplay!.updateStatus(ScreenplayStatus.failed);
      _screenplayController.add(_currentScreenplay!);
      _userOriginalImages = null;
      _characterReferenceUrls = null;
      AppLogger.error('剧本生成（从确认）', '生成失败', e, StackTrace.current);
      rethrow;
    }
  }

  /// 更新场景的自定义视频提示词
  void updateSceneCustomPrompt(int sceneId, String customPrompt) {
    if (_currentScreenplay == null) {
      throw StateError('没有当前剧本');
    }

    final scene = _currentScreenplay!.scenes.firstWhere(
      (s) => s.sceneId == sceneId,
      orElse: () => throw Exception('场景 $sceneId 不存在'),
    );

    AppLogger.info('场景更新', '场景 ${scene.sceneId} 设置自定义提示词: $customPrompt');

    _currentScreenplay = _currentScreenplay!.updateScene(
      sceneId,
      scene.copyWith(customVideoPrompt: customPrompt),
    );
    _screenplayController.add(_currentScreenplay!);
  }

  /// 重试单个失败的场景
  /// 根据当前状态智能重试：
  /// - 如果图片已生成，只重试视频
  /// - 如果图片未生成，重试图片和视频
  Future<void> retryScene(int sceneId, {void Function(double progress, String status)? onProgress, bool forceRegenerateImage = false}) async {
    if (_currentScreenplay == null) {
      throw StateError('没有当前剧本');
    }

    final scene = _currentScreenplay!.scenes.firstWhere(
      (s) => s.sceneId == sceneId,
      orElse: () => throw Exception('场景 $sceneId 不存在'),
    );

    final sceneNum = _currentScreenplay!.scenes.indexOf(scene) + 1;
    // 检查是否需要重新生成图片
    final hasImage = scene.imageUrl != null && scene.imageUrl!.isNotEmpty;
    final shouldRegenerateImage = forceRegenerateImage || !hasImage;

    AppLogger.info('场景重试', '开始重试场景 $sceneNum, 已有图片: $hasImage, 强制重新生成图片: $forceRegenerateImage');

    // 获取角色组合三视图 URL
    final characterUrls = _characterReferenceUrls?.take(2).toList() ?? [];

    String? imageUrl = scene.imageUrl; // 使用已有的图片URL

    try {
      // === 步骤1: 生成场景图片（如果需要）===
      if (shouldRegenerateImage) {
        // 更新状态为图片生成中
        _currentScreenplay = _currentScreenplay!.updateScene(
          sceneId,
          scene.copyWith(status: SceneStatus.imageGenerating),
        );
        _screenplayController.add(_currentScreenplay!);

        onProgress?.call(0.1, forceRegenerateImage ? '场景 $sceneNum 正在重新生成图片...' : '场景 $sceneNum 正在生成图片...');

        // 优先使用用户原图（图生图），否则使用角色三视图
        if (_userOriginalImages != null && _userOriginalImages!.isNotEmpty) {
          AppLogger.info('图片生成', '场景 $sceneNum 使用用户原图进行图生图');
          imageUrl = await _apiService.generateImage(
            scene.imagePrompt,
            referenceImages: _userOriginalImages,
          );
        } else if (characterUrls.isNotEmpty) {
          // 使用角色三视图进行图生图
          AppLogger.info('图片生成', '场景 $sceneNum 使用角色三视图进行图生图');
          imageUrl = await _apiService.generateImageWithCharacterReference(
            scene.imagePrompt,
            characterImageUrls: characterUrls,
          );
        } else {
          // 没有任何参考图，使用纯文本生成（降级）
          AppLogger.warn('图片生成', '场景 $sceneNum 没有参考图，使用纯文本生成（人物可能不一致）');
          imageUrl = await _apiService.generateImage(scene.imagePrompt);
        }

        // 更新场景图片
        _currentScreenplay = _currentScreenplay!.updateScene(
          sceneId,
          scene.copyWith(imageUrl: imageUrl, status: SceneStatus.imageCompleted),
        );
        _screenplayController.add(_currentScreenplay!);
        AppLogger.success('图片生成', '场景 $sceneNum 图片生成完成');
      } else {
        AppLogger.info('场景重试', '场景 $sceneNum 图片已存在，跳过图片生成');
      }

      // === 步骤2: 生成场景视频 ===
      onProgress?.call(shouldRegenerateImage ? 0.6 : 0.5, '场景 $sceneNum 正在生成视频...');

      // 更新状态为视频生成中
      final updatedScene = _currentScreenplay!.scenes.firstWhere((s) => s.sceneId == sceneId);
      _currentScreenplay = _currentScreenplay!.updateScene(
        sceneId,
        updatedScene.copyWith(status: SceneStatus.videoGenerating),
      );
      _screenplayController.add(_currentScreenplay!);

      // 构建参考图列表
      final List<String> referenceUrls = [];
      referenceUrls.addAll(characterUrls);
      if (imageUrl != null) {
        referenceUrls.add(imageUrl);
      }

      // === 准备视频提示词 ===
      onProgress?.call(shouldRegenerateImage ? 0.55 : 0.45, '场景 $sceneNum 正在准备视频提示词...');

      // 优先使用用户自定义提示词，否则使用 AI 重写的安全版本
      String scenePrompt;
      if (scene.customVideoPrompt != null && scene.customVideoPrompt!.isNotEmpty) {
        // 用户提供了自定义提示词，直接使用
        scenePrompt = scene.customVideoPrompt!;
        if (scene.characterDescription.isNotEmpty) {
          scenePrompt = 'Character reference: ${scene.characterDescription}. $scenePrompt';
        }
        AppLogger.info('场景重试', '使用用户自定义提示词: $scenePrompt');
      } else {
        // 使用 AI 重写提示词为安全版本
        final rewrittenPrompt = await _apiService.rewriteVideoPromptForSafety(
          originalPrompt: scene.videoPrompt,
          sceneNarration: scene.narration,
        );

        // 构建最终提示词（包含角色描述）
        if (scene.characterDescription.isNotEmpty) {
          scenePrompt = 'Character reference: ${scene.characterDescription}. Scene: $rewrittenPrompt';
        } else {
          scenePrompt = rewrittenPrompt;
        }

        AppLogger.info('场景重试', '原始提示词: ${scene.videoPrompt}');
        AppLogger.info('场景重试', '重写后提示词: $rewrittenPrompt');
      }

      // 调用视频生成API（使用重写后的安全提示词）
      final videoResponse = await _apiService.generateVideo(
        imageUrls: referenceUrls,
        prompt: scenePrompt,
        seconds: '5',
      );

      // 等待视频生成完成
      final finalResponse = await _apiService.pollVideoStatus(
        taskId: videoResponse.id!,
        timeout: const Duration(minutes: 10),
        interval: const Duration(seconds: 2),
        onProgress: (progress, status) {
          final baseProgress = shouldRegenerateImage ? 0.6 : 0.5;
          final overallProgress = baseProgress + (progress / 100) * (1 - baseProgress);
          onProgress?.call(overallProgress, '场景 $sceneNum 视频生成中... $progress%');
        },
      );

      // 更新场景视频
      final sceneWithVideo = _currentScreenplay!.scenes.firstWhere((s) => s.sceneId == sceneId);
      _currentScreenplay = _currentScreenplay!.updateScene(
        sceneId,
        sceneWithVideo.copyWith(videoUrl: finalResponse.videoUrl, status: SceneStatus.completed),
      );
      _screenplayController.add(_currentScreenplay!);
      AppLogger.success('场景重试', '场景 $sceneNum 重试成功');
      onProgress?.call(1.0, '场景 $sceneNum 重试完成');
    } catch (e) {
      AppLogger.error('场景重试', '场景 $sceneNum 重试失败: $e');
      _currentScreenplay = _currentScreenplay!.updateScene(
        sceneId,
        scene.copyWith(status: SceneStatus.failed),
      );
      _screenplayController.add(_currentScreenplay!);
      rethrow;
    }
  }

  /// 🆕 手动触发单个场景的生成（图片+视频）
  /// 可以在任务运行期间调用，立即开始处理指定场景
  /// 自动任务会检测场景状态变化并跳过已处理的场景
  Future<void> startSceneGeneration(
    int sceneId, {
    void Function(double progress, String status)? onProgress,
  }) async {
    if (_currentScreenplay == null) {
      throw StateError('没有当前剧本');
    }

    final scene = _currentScreenplay!.scenes.firstWhere(
      (s) => s.sceneId == sceneId,
      orElse: () => throw Exception('场景 $sceneId 不存在'),
    );

    // 检查场景状态，只有 pending 状态可以手动触发（failed 状态用 retryScene）
    if (scene.status != SceneStatus.pending) {
      AppLogger.warn('手动生成', '场景 $sceneId 状态为 ${scene.status.displayName}，无法手动触发');
      if (scene.status == SceneStatus.failed) {
        // 如果是失败状态，调用重试逻辑
        AppLogger.info('手动生成', '场景 $sceneId 为失败状态，转为重试');
        await retryScene(sceneId, onProgress: onProgress, forceRegenerateImage: true);
      }
      return;
    }

    final sceneNum = _currentScreenplay!.scenes.indexOf(scene) + 1;
    AppLogger.info('手动生成', '🖐️ 手动触发场景 $sceneNum 生成');

    // 直接调用 retryScene 来执行实际的生成逻辑
    // retryScene 会处理图片和视频的生成
    await retryScene(sceneId, onProgress: onProgress, forceRegenerateImage: true);
  }

  /// 🆕 手动触发所有待处理场景的生成（串行，一个一个来）
  Future<void> startAllPendingScenesGeneration({
    void Function(double progress, String status)? onProgress,
  }) async {
    if (_currentScreenplay == null) {
      throw StateError('没有当前剧本');
    }

    // 找出所有 pending 状态的场景
    final pendingScenes = _currentScreenplay!.scenes
        .where((s) => s.status == SceneStatus.pending)
        .toList();

    if (pendingScenes.isEmpty) {
      AppLogger.info('手动生成', '没有待处理的场景');
      onProgress?.call(1.0, '所有场景已完成');
      return;
    }

    AppLogger.info('手动生成', '🖐️ 开始手动生成 ${pendingScenes.length} 个场景（串行模式）');

    int completed = 0;
    for (final scene in pendingScenes) {
      if (_isCancelled) {
        AppLogger.warn('手动生成', '用户取消操作');
        throw Exception('操作已取消');
      }

      // 重新检查场景状态（可能已被自动任务处理）
      final currentScene = _currentScreenplay!.scenes.firstWhere(
        (s) => s.sceneId == scene.sceneId,
      );
      if (currentScene.status != SceneStatus.pending) {
        AppLogger.info('手动生成', '场景 ${scene.sceneId} 已被处理，跳过');
        completed++;
        continue;
      }

      final sceneNum = _currentScreenplay!.scenes.indexOf(scene) + 1;
      final overallProgress = completed / pendingScenes.length;
      onProgress?.call(overallProgress, '正在生成场景 $sceneNum...');

      try {
        await startSceneGeneration(
          scene.sceneId,
          onProgress: (progress, status) {
            final sceneProgress = completed / pendingScenes.length;
            final inSceneProgress = progress / pendingScenes.length;
            onProgress?.call(sceneProgress + inSceneProgress, status);
          },
        );
        completed++;
      } catch (e) {
        AppLogger.error('手动生成', '场景 $sceneNum 生成失败: $e');
        completed++;
        // 继续处理下一个场景
      }
    }

    onProgress?.call(1.0, '手动生成完成');
    AppLogger.success('手动生成', '手动生成完成，共处理 $completed 个场景');
  }

  /// 使用 GLM-4.5V 分析用户图片，提取角色特征
  /// [imageBase64] 用户图片的 base64 编码
  Future<String> _analyzeUserImage(String imageBase64) async {
    try {
      AppLogger.info('图片分析', '开始分析用户图片...');
      final analysis = await _apiService.analyzeImageForCharacter(imageBase64);
      AppLogger.success('图片分析', '分析完成');
      return analysis;
    } catch (e) {
      AppLogger.error('图片分析', '分析失败', e);
      // 图片分析失败不影响流程，返回空字符串
      return '';
    }
  }

  /// 调用 GLM-4.7 获取剧本 JSON
  /// [characterAnalysis] 用户图片的角色特征分析结果（如果有）
  Future<String> _callGLMForScreenplay(String userPrompt, String? characterAnalysis) async {
    try {
      // 构建增强的提示词
      String enhancedPrompt = userPrompt;
      if (characterAnalysis != null && characterAnalysis.isNotEmpty) {
        enhancedPrompt = '''用户需求：$userPrompt

用户提供的参考图片角色特征分析：
$characterAnalysis

请根据上述角色特征分析结果，生成剧本中的 character_description 字段，确保生成的角色形象与用户提供的图片一致。''';
      }

      final messages = [
        {'role': 'user', 'content': enhancedPrompt},
      ];

      AppLogger.info('GLM-4.7', '发送剧本规划请求（使用文本模型）');

      // 使用流式 API，只收集最终内容（不收集思考过程）
      final buffer = StringBuffer();
      await _apiService.sendToGLMStream(messages).forEach((chunk) {
        if (_isCancelled) {
          throw Exception('操作已取消');
        }
        // 只收集最终内容
        if (chunk.isContent) {
          buffer.write(chunk.text);
        }
      });

      final response = buffer.toString();
      AppLogger.success('GLM-4.7', '收到响应，长度: ${response.length}');
      return response;
    } catch (e) {
      AppLogger.error('GLM-4.7', '请求失败', e, StackTrace.current);
      throw Exception('GLM 请求失败: $e');
    }
  }

  /// 批量生成所有场景的图片
  /// 第一张场景使用用户原图作为参考（图生图）
  /// 后续场景使用角色三视图作为参考（人物一致性）
  Future<void> _generateAllImages(
    Screenplay screenplay, {
    required void Function(double progress, String status) onProgress,
  }) async {
    final scenes = screenplay.scenes;
    int completed = 0;

    // 获取第一张场景的人物描述（备用）
    final characterDescription = scenes.isNotEmpty
        ? scenes.first.characterDescription
        : '';

    if (characterDescription.isNotEmpty) {
      AppLogger.info('人物一致性', '人物描述: $characterDescription');
    }

    // 检查是否有角色三视图可用
    final hasCharacterRefs = _characterReferenceUrls != null && _characterReferenceUrls!.isNotEmpty;
    if (hasCharacterRefs) {
      AppLogger.info('人物一致性', '使用角色三视图: ${_characterReferenceUrls!.length} 张');
    }

    for (int i = 0; i < scenes.length; i++) {
      if (_isCancelled) {
        AppLogger.warn('图片生成', '用户取消操作');
        throw Exception('操作已取消');
      }

      final scene = scenes[i];

      // 跳过已生成图片的场景
      if (scene.imageUrl != null) {
        completed++;
        continue;
      }

      // 更新状态为生成中
      _currentScreenplay = _currentScreenplay!.updateScene(
        scene.sceneId,
        scene.copyWith(status: SceneStatus.imageGenerating),
      );
      _screenplayController.add(_currentScreenplay!);

      onProgress(
        completed / scenes.length,
        '正在生成场景 ${i + 1}/${scenes.length} 的图片...',
      );

      try {
        String imageUrl;

        // 第一张场景：如果有用户原图，使用图生图
        if (i == 0 && _userOriginalImages != null && _userOriginalImages!.isNotEmpty) {
          AppLogger.info('图片生成', '场景 1 使用用户原图进行图生图');
          imageUrl = await _apiService.generateImage(
            scene.imagePrompt,
            referenceImages: _userOriginalImages,
          );
        }
        // 后续场景：优先使用角色三视图
        else if (i > 0 && hasCharacterRefs) {
          AppLogger.info('图片生成', '场景 ${i + 1} 使用角色三视图进行图生图');
          // 使用新的 chat 格式图生图 API，传入角色三视图
          imageUrl = await _apiService.generateImageWithCharacterReference(
            scene.imagePrompt,
            characterImageUrls: _characterReferenceUrls!,
          );
        }
        // 降级：使用文本描述
        else {
          String enhancedPrompt = scene.imagePrompt;
          if (i > 0 && characterDescription.isNotEmpty) {
            enhancedPrompt = 'Character reference: $characterDescription. Scene: ${scene.imagePrompt}';
            AppLogger.info('图片生成', '场景 ${i + 1} 使用文本描述（无三视图）');
          }
          imageUrl = await _apiService.generateImage(enhancedPrompt);
        }

        // 更新场景
        final updatedScene = scene.copyWith(
          imageUrl: imageUrl,
          status: SceneStatus.imageCompleted,
        );
        _currentScreenplay = _currentScreenplay!.updateScene(scene.sceneId, updatedScene);
        _screenplayController.add(_currentScreenplay!);

        completed++;
        AppLogger.success('图片生成', '场景 ${scene.sceneId} 图片生成完成: $imageUrl');
      } catch (e) {
        AppLogger.error('图片生成', '场景 ${scene.sceneId} 图片生成失败: $e');
        // 标记失败但继续
        final failedScene = scene.copyWith(status: SceneStatus.failed);
        _currentScreenplay = _currentScreenplay!.updateScene(scene.sceneId, failedScene);
        _screenplayController.add(_currentScreenplay!);
        completed++;
      }
    }

    onProgress(1.0, '图片生成完成');
  }

  /// 逐场景生成视频
  /// 新版本：每个场景生成独立的分镜视频，最后合并
  /// 人物一致性策略：传入角色组合三视图(最多2张) + 分镜图(1张) = 3张图片
  Future<void> _generateAllVideos(
    Screenplay screenplay, {
    required void Function(double progress, String status) onProgress,
  }) async {
    // 重要：使用 _currentScreenplay 而不是传入的 screenplay
    // 因为图片 URL 是在 _generateAllImages 中更新到 _currentScreenplay 的
    final currentScenes = _currentScreenplay!.scenes;

    // 筛选出有图片的场景
    final scenesWithImages = currentScenes
        .where((s) => s.imageUrl != null)
        .toList();

    if (scenesWithImages.isEmpty) {
      AppLogger.warn('视频生成', '没有可用的分镜图片');
      throw Exception('没有可用的分镜图片来生成视频');
    }

    AppLogger.info('视频生成', '准备为 ${scenesWithImages.length} 个场景生成视频');

    // 获取角色组合三视图 URL（最多2个角色）
    final characterUrls = _characterReferenceUrls?.take(2).toList() ?? [];
    AppLogger.info('视频生成', '使用角色三视图: ${characterUrls.length} 张');

    // 存储所有场景的视频URL（用于后续合并）
    final List<String> sceneVideoUrls = [];

    // 逐场景生成视频
    for (int i = 0; i < scenesWithImages.length; i++) {
      if (_isCancelled) {
        throw Exception('操作已取消');
      }

      final scene = scenesWithImages[i];
      final sceneProgress = i / scenesWithImages.length;
      onProgress(sceneProgress, '正在生成场景 ${i + 1}/${scenesWithImages.length} 的视频...');

      // 更新场景状态为生成中
      _currentScreenplay = _currentScreenplay!.updateScene(
        scene.sceneId,
        scene.copyWith(status: SceneStatus.videoGenerating),
      );
      _screenplayController.add(_currentScreenplay!);

      try {
        // 构建参考图列表：角色三视图（最多2张）+ 当前场景图（1张）= 最多3张
        final List<String> referenceUrls = [];

        // 添加角色组合三视图
        referenceUrls.addAll(characterUrls);

        // 添加当前场景的分镜图
        referenceUrls.add(scene.imageUrl!);

        AppLogger.info('视频生成', '场景 ${i + 1} 参考图: ${referenceUrls.length} 张 (角色: ${characterUrls.length}, 分镜: 1)');

        // 构建场景视频提示词
        final characterDescription = scene.characterDescription;
        String scenePrompt = scene.videoPrompt;
        if (characterDescription.isNotEmpty) {
          scenePrompt = 'Character reference: $characterDescription. Scene: ${scene.videoPrompt}';
        }

        // 调用视频生成API（启用提示词净化，避免触发管控）
        final videoResponse = await _apiService.generateVideo(
          imageUrls: referenceUrls,
          prompt: scenePrompt,
          seconds: '5', // 每个场景5秒
            sanitizePrompt: true, // 净化提示词，移除敏感词
        );

        // 等待视频生成完成
        VideoGenerationResponse finalResponse;
        if (videoResponse.isCompleted) {
          finalResponse = videoResponse;
        } else {
          finalResponse = await _apiService.pollVideoStatus(
            taskId: videoResponse.id!,
            timeout: const Duration(minutes: 5),
            interval: const Duration(seconds: 2),
            onProgress: (progress, status) {
              final overallProgress = (i + progress / 100) / scenesWithImages.length;
              onProgress(overallProgress, '场景 ${i + 1} 视频生成中... $progress%');
            },
            isCancelled: () => _isCancelled, // 传递取消检查
          );
        }

        // 更新场景视频URL
        final updatedScene = scene.copyWith(
          videoUrl: finalResponse.videoUrl,
          status: SceneStatus.completed,
        );
        _currentScreenplay = _currentScreenplay!.updateScene(scene.sceneId, updatedScene);
        _screenplayController.add(_currentScreenplay!);

        // 记录视频URL用于后续合并
        if (finalResponse.videoUrl != null) {
          sceneVideoUrls.add(finalResponse.videoUrl!);
        }

        AppLogger.success('视频生成', '场景 ${scene.sceneId} 视频生成完成: ${finalResponse.videoUrl}');
      } catch (e) {
        AppLogger.error('视频生成', '场景 ${scene.sceneId} 视频生成失败: $e');
        // 标记失败但继续其他场景
        final failedScene = scene.copyWith(status: SceneStatus.failed);
        _currentScreenplay = _currentScreenplay!.updateScene(scene.sceneId, failedScene);
        _screenplayController.add(_currentScreenplay!);
      }
    }

    if (_isCancelled) {
      throw Exception('操作已取消');
    }

    AppLogger.success('视频生成', '所有场景视频生成完成: ${sceneVideoUrls.length}/${scenesWithImages.length} 成功');
    onProgress(1.0, '所有场景视频生成完成！');

    // TODO: 后续可以在这里添加视频合并逻辑
    // 目前各场景视频独立存储，用户可以在播放时连续播放
    if (sceneVideoUrls.length > 1) {
      AppLogger.info('视频生成', '共有 ${sceneVideoUrls.length} 个分镜视频，可进行合并');
    }
  }

  /// 生成总体视频提示词（兼容旧版）
  @Deprecated('新版本使用逐场景生成')
  String _generateOverallPrompt(Screenplay screenplay) {
    final sb = StringBuffer();
    sb.write('A video with ${screenplay.scenes.length} scenes: ');

    for (int i = 0; i < screenplay.scenes.length; i++) {
      final scene = screenplay.scenes[i];
      sb.write('Scene ${i + 1}: ${scene.videoPrompt}');
      if (i < screenplay.scenes.length - 1) {
        sb.write('. ');
      }
    }

    return sb.toString();
  }

  /// 重试失败的场景
  Future<void> retryFailedScenes({
    void Function(double progress, String status)? onProgress,
  }) async {
    if (_currentScreenplay == null) {
      throw Exception('没有正在进行的剧本');
    }

    final screenplay = _currentScreenplay!;
    final failedScenes = screenplay.scenes.where((s) => s.status == SceneStatus.failed).toList();

    if (failedScenes.isEmpty) {
      AppLogger.info('重试', '没有失败的场景');
      return;
    }

    AppLogger.info('重试', '重试 ${failedScenes.length} 个失败的场景');
    _isCancelled = false;

    // 重新生成失败的图片
    final imageFailedScenes = failedScenes.where((s) => s.imageUrl == null).toList();
    if (imageFailedScenes.isNotEmpty) {
      await _generateAllImages(
        screenplay,
        onProgress: (progress, status) => onProgress?.call(progress * 0.5, status),
      );
    }

    // 重新生成失败的视频
    final videoFailedScenes = failedScenes.where((s) => s.imageUrl != null && s.videoUrl == null).toList();
    if (videoFailedScenes.isNotEmpty) {
      await _generateAllVideos(
        screenplay,
        onProgress: (progress, status) => onProgress?.call(0.5 + progress * 0.5, status),
      );
    }
  }

  /// 取消当前操作
  void cancel() {
    AppLogger.warn('剧本控制器', '用户请求取消操作');
    _isCancelled = true;
    _cancelController.add(true);
  }

  /// 发送进度更新
  void _emitProgress(double progress, String status) {
    _progressController.add(ScreenplayProgress(
      progress: progress,
      status: status,
      timestamp: DateTime.now(),
    ));
  }

  /// 释放资源
  void dispose() {
    _screenplayController.close();
    _progressController.close();
    _cancelController.close();
  }
}

/// 剧本生成进度数据
class ScreenplayProgress {
  final double progress; // 0.0 - 1.0
  final String status;
  final DateTime timestamp;

  ScreenplayProgress({
    required this.progress,
    required this.status,
    required this.timestamp,
  });

  @override
  String toString() => 'ScreenplayProgress(${(progress * 100).round()}%, $status)';
}
