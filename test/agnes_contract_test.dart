import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:director_ai/models/agent_command.dart';
import 'package:director_ai/services/api_config_service.dart';
import 'package:director_ai/services/api_service.dart';

/// Agnes 接入相关的契约与配置迁移测试。
///
/// 覆盖 CI 守门的最小价值断言：
/// 1. Agnes 端点与模型常量与官方契约一致；
/// 2. 旧四通道 Key 自动迁移为单一 agnes key，四个旧 getter 与 agnes key 同源；
/// 3. 视频响应模型兼容 Agnes 的 video_id / 顶层 url / detail 字段。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ApiConfigService 单 Key 迁移', () {
    test('旧 zhipu key 迁移为 agnes key', () async {
      SharedPreferences.setMockInitialValues({
        'zhipu_api_key': 'legacy-key',
        'video_api_key': '',
        'image_api_key': '',
        'doubao_api_key': '',
      });
      await ApiConfigService.initialize();
      expect(ApiConfigService.getAgnesApiKey(), 'legacy-key');
    });

    test('setAgnesApiKey 后四个旧 getter 均读到新值', () async {
      await ApiConfigService.setAgnesApiKey('agnes-new-key');
      expect(ApiConfigService.getAgnesApiKey(), 'agnes-new-key');
      expect(ApiConfigService.getZhipuApiKey(), 'agnes-new-key');
      expect(ApiConfigService.getVideoApiKey(), 'agnes-new-key');
      expect(ApiConfigService.getImageApiKey(), 'agnes-new-key');
      expect(ApiConfigService.getDoubaoApiKey(), 'agnes-new-key');
    });
  });

  group('Agnes 契约常量', () {
    test('端点与模型常量符合 Agnes 官方契约', () {
      expect(ApiConfig.agnesBaseUrl, 'https://apihub.agnes-ai.com/v1');
      expect(ApiConfig.agnesRootUrl, 'https://apihub.agnes-ai.com');
      expect(ApiConfig.agnesTextModel, 'agnes-3.0-flash');
      expect(ApiConfig.agnesImageModel, 'agnes-image-2.5-flash');
      expect(ApiConfig.agnesVideoModel, 'agnes-video-v2.0');
    });

    test('四个旧通道 getter 与 agnesApiKey 同源', () {
      expect(ApiConfig.zhipuApiKey, ApiConfig.agnesApiKey);
      expect(ApiConfig.videoApiKey, ApiConfig.agnesApiKey);
      expect(ApiConfig.imageApiKey, ApiConfig.agnesApiKey);
      expect(ApiConfig.doubaoApiKey, ApiConfig.agnesApiKey);
    });
  });

  group('视频响应模型 Agnes 兼容', () {
    test('video_id 优先解析为任务 id', () {
      final resp = VideoGenerationResponse.fromJson({
        'video_id': 'v-123',
        'id': 'i-456',
      });
      expect(resp.id, 'v-123');
    });

    test('顶层 url 解析为 videoUrl', () {
      final resp = VideoGenerationResponse.fromJson({
        'url': 'https://cdn.example.com/clips/v.mp4',
      });
      expect(resp.videoUrl, 'https://cdn.example.com/clips/v.mp4');
      expect(resp.hasVideoUrl, isTrue);
    });

    test('detail 字段解析为 error', () {
      final resp = VideoGenerationResponse.fromJson({
        'detail': '生成失败：余额不足',
      });
      expect(resp.error, '生成失败：余额不足');
      expect(resp.isFailed, isFalse); // 状态字段缺失时视为进行中，不误判失败
    });
  });
}