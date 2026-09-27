import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:director_ai/services/api_config_service.dart';
import 'package:director_ai/services/api_service.dart';
import 'package:director_ai/utils/app_logger.dart';

/// Agnes 四通道真机集成验证。
///
/// 运行方式（真机已连接 adb）：
/// ```bash
/// flutter test integration_test/agnes_smoke_test.dart \
///   -d <device-id> \
///   --dart-define=AGNES_API_KEY=<key> \
///   [--dart-define=AGNES_VERIFY_VIDEO=true]
/// ```
///
/// 覆盖：
/// 1. 文本通道 agnes-3.0-flash（sendToGLM）
/// 2. 图片理解通道（analyzeImageForCharacter，Agnes 多模态）
/// 3. 图像生成通道 agnes-image-2.5-flash（generateImage）
/// 4. 视频生成通道 agnes-video-2.5-flash（generateVideo + pollVideoStatus，默认关闭，
///    通过 AGNES_VERIFY_VIDEO=true 开启，免费账号视频通道可能受限）
///
/// 真机运行时需要真实但有效的 Agnes API Key（通过 --dart-define 注入，不落盘）。
/// 视频通道因耗时较长且消耗额度，默认不执行。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const agnesKey = String.fromEnvironment('AGNES_API_KEY');
  const verifyVideo = String.fromEnvironment('AGNES_VERIFY_VIDEO') == 'true';

  // 1x1 透明 PNG，作为图片理解输入
  const kTestImageBase64 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

  setUpAll(() async {
    await AppLogger.initialize();
    await ApiConfigService.initialize();
    if (agnesKey.isNotEmpty) {
      await ApiConfigService.setAgnesApiKey(agnesKey);
    }
  });

  testWidgets('Agnes 文本通道（agnes-3.0-flash）', (tester) async {
    final api = ApiService();

    final reply = await api.sendToGLM([
      {'role': 'user', 'content': '请只回复"ok"两个字。'},
    ]);

    expect(
      reply.trim().isNotEmpty,
      isTrue,
      reason: '文本通道应返回内容',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('Agnes 图片理解通道（多模态文本）', (tester) async {
    final api = ApiService();

    final description = await api.analyzeImageForCharacter(
      kTestImageBase64,
      mimeType: 'image/png',
    );

    expect(
      description.trim().isNotEmpty,
      isTrue,
      reason: '图片理解应返回角色特征描述',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('Agnes 图像生成通道（agnes-image-2.5-flash）', (tester) async {
    final api = ApiService();

    final imageUrl = await api.generateImage('一只可爱的橘猫的插画');

    expect(imageUrl.isNotEmpty, isTrue, reason: '图像生成应返回图片地址');
    expect(imageUrl.startsWith('http'), isTrue, reason: '图片地址应为可访问 URL');
  }, timeout: const Timeout(Duration(minutes: 3)));

  if (verifyVideo) {
    testWidgets('Agnes 视频生成通道（agnes-video-2.5-flash）', (tester) async {
      final api = ApiService();

      final created = await api.generateVideo(
        prompt: '一只橘猫在草地上缓慢走动',
        seconds: '5',
      );
      expect(created.id, isNotNull, reason: '视频任务应返回任务 ID');

      final done = await api.pollVideoStatus(
        taskId: created.id!,
        timeout: const Duration(minutes: 10),
        interval: const Duration(seconds: 5),
      );

      expect(done.isCompleted, isTrue, reason: '视频生成应完成：${done.error}');
      expect(done.hasVideoUrl, isTrue, reason: '应返回视频 URL');
    }, timeout: const Timeout(Duration(minutes: 15)));
  }
}