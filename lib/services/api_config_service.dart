import 'package:shared_preferences/shared_preferences.dart';
import '../utils/app_logger.dart';

/// API 配置服务
/// 使用 SharedPreferences 持久化存储 API Key
///
/// 自多服务商统一接入 Agnes 后，文本/图像/视频/图片理解四类能力
/// 共用同一个 Agnes API Key（配置存储 key 沿用旧字段以兼容既有已保存配置）。
class ApiConfigService {
  // 四个旧 key 字段保留读取，但都映射到 agnes_api_key：
  // 存量用户升级时既能读到旧值，新设置也统一写入 agnes_api_key。
  static const String _keyAgnesApiKey = 'agnes_api_key';
  @Deprecated('统一使用 Agnes API Key，字段保留仅为兼容旧配置读取')
  static const String _keyZhipuApiKey = 'zhipu_api_key';
  @Deprecated('统一使用 Agnes API Key，字段保留仅为兼容旧配置读取')
  static const String _keyVideoApiKey = 'video_api_key';
  @Deprecated('统一使用 Agnes API Key，字段保留仅为兼容旧配置读取')
  static const String _keyImageApiKey = 'image_api_key';
  @Deprecated('统一使用 Agnes API Key，字段保留仅为兼容旧配置读取')
  static const String _keyDoubaoApiKey = 'doubao_api_key';

  // 空字符串表示未配置
  static const String _unconfigured = '';

  static SharedPreferences? _prefs;
  static bool _initialized = false;

  /// 初始化服务
  static Future<void> initialize() async {
    if (_initialized) return;

    try {
      _prefs = await SharedPreferences.getInstance();
      _initialized = true;

      // 迁移：若旧四通道 key 已配置而 agnes key 未配置，沿用旧值
      // 保证升级存量设置时不丢 Key（多服务商场景共用同一把 Key）。
      if ((_prefs!.getString(_keyAgnesApiKey) ?? '').isEmpty) {
        final legacyKeys = <String>[
          _keyZhipuApiKey,
          _keyVideoApiKey,
          _keyImageApiKey,
          _keyDoubaoApiKey,
        ];
        for (final legacyKey in legacyKeys) {
          final legacyValue = _prefs!.getString(legacyKey) ?? '';
          if (legacyValue.isNotEmpty) {
            await _prefs!.setString(_keyAgnesApiKey, legacyValue);
            break; // 只取第一把非空旧 key
          }
        }
      }

      AppLogger.success('ApiConfigService', 'API 配置服务初始化完成');
    } catch (e) {
      AppLogger.error('ApiConfigService', '初始化失败', e);
      rethrow;
    }
  }

  /// 获取 Agnes API Key（文本/图像/视频/图片理解共用）
  static String getAgnesApiKey() {
    _ensureInitialized();
    return _prefs!.getString(_keyAgnesApiKey) ?? _getLegacyApiKeyOrEmpty();
  }

  /// 设置 Agnes API Key
  static Future<void> setAgnesApiKey(String key) async {
    _ensureInitialized();
    await _prefs!.setString(_keyAgnesApiKey, key);
    AppLogger.info('ApiConfigService', '已更新 Agnes API Key: ${_mask(key)}');
  }

  /// 从旧四通道 key 中读取第一把非空 Key（兼容降级读取）
  static String _getLegacyApiKeyOrEmpty() {
    final legacyKeys = <String>[
      _keyZhipuApiKey,
      _keyVideoApiKey,
      _keyImageApiKey,
      _keyDoubaoApiKey,
    ];
    for (final legacyKey in legacyKeys) {
      final value = _prefs?.getString(legacyKey) ?? '';
      if (value.isNotEmpty) return value;
    }
    return _unconfigured;
  }

  /// 获取智谱 GLM API Key（已统一为 Agnes Key，保留方法名兼容）
  @Deprecated('统一使用 getAgnesApiKey()')
  static String getZhipuApiKey() => getAgnesApiKey();

  /// 设置智谱 GLM API Key（已统一为 Agnes Key，保留方法名兼容）
  @Deprecated('统一使用 setAgnesApiKey()')
  static Future<void> setZhipuApiKey(String key) => setAgnesApiKey(key);

  /// 获取视频生成 API Key（已统一为 Agnes Key，保留方法名兼容）
  @Deprecated('统一使用 getAgnesApiKey()')
  static String getVideoApiKey() => getAgnesApiKey();

  /// 设置视频生成 API Key（已统一为 Agnes Key，保留方法名兼容）
  @Deprecated('统一使用 setAgnesApiKey()')
  static Future<void> setVideoApiKey(String key) => setAgnesApiKey(key);

  /// 获取图像生成 API Key（已统一为 Agnes Key，保留方法名兼容）
  @Deprecated('统一使用 getAgnesApiKey()')
  static String getImageApiKey() => getAgnesApiKey();

  /// 设置图像生成 API Key（已统一为 Agnes Key，保留方法名兼容）
  @Deprecated('统一使用 setAgnesApiKey()')
  static Future<void> setImageApiKey(String key) => setAgnesApiKey(key);

  /// 获取豆包 API Key（已统一为 Agnes Key，保留方法名兼容）
  @Deprecated('统一使用 getAgnesApiKey()')
  static String getDoubaoApiKey() => getAgnesApiKey();

  /// 设置豆包 API Key（已统一为 Agnes Key，保留方法名兼容）
  @Deprecated('统一使用 setAgnesApiKey()')
  static Future<void> setDoubaoApiKey(String key) => setAgnesApiKey(key);

  /// 检查 Agnes API Key 是否已配置
  static bool isAgnesApiKeyConfigured() {
    final key = getAgnesApiKey();
    return key.isNotEmpty && key != _unconfigured;
  }

  /// 检查智谱 API Key 是否已配置（等价 Agnes Key 检查）
  @Deprecated('统一使用 isAgnesApiKeyConfigured()')
  static bool isZhipuApiKeyConfigured() => isAgnesApiKeyConfigured();

  /// 检查视频 API Key 是否已配置（等价 Agnes Key 检查）
  @Deprecated('统一使用 isAgnesApiKeyConfigured()')
  static bool isVideoApiKeyConfigured() => isAgnesApiKeyConfigured();

  /// 检查图像 API Key 是否已配置（等价 Agnes Key 检查）
  @Deprecated('统一使用 isAgnesApiKeyConfigured()')
  static bool isImageApiKeyConfigured() => isAgnesApiKeyConfigured();

  /// 检查豆包 API Key 是否已配置（等价 Agnes Key 检查）
  @Deprecated('统一使用 isAgnesApiKeyConfigured()')
  static bool isDoubaoApiKeyConfigured() => isAgnesApiKeyConfigured();

  /// 检查所有必需的 API Key 是否已配置（仅需一把 Agnes Key）
  static ApiConfigStatus checkRequiredKeys() {
    final hasAgnes = isAgnesApiKeyConfigured();

    if (hasAgnes) {
      return ApiConfigStatus.allConfigured;
    }

    return ApiConfigStatus(
      isAllConfigured: false,
      missingKeys: const ['Agnes API Key (对话/图像/视频)'],
    );
  }

  /// 检查聊天所需的 API Key（仅需 Agnes Key）
  static ApiConfigStatus checkChatKeys() {
    if (isAgnesApiKeyConfigured()) {
      return ApiConfigStatus.allConfigured;
    }

    return ApiConfigStatus(
      isAllConfigured: false,
      missingKeys: const ['Agnes API Key (对话)'],
    );
  }

  /// 检查视频生成所需的 API Key（仅需 Agnes Key）
  static ApiConfigStatus checkVideoGenerationKeys() {
    if (isAgnesApiKeyConfigured()) {
      return ApiConfigStatus.allConfigured;
    }

    return ApiConfigStatus(
      isAllConfigured: false,
      missingKeys: const ['Agnes API Key (对话/图像/视频)'],
    );
  }

  /// 获取所有配置（用于显示，统一为 Agnes 单 Key）
  @Deprecated('统一使用 getAgnesApiKey()')
  static Map<String, String> getAllConfigs() {
    _ensureInitialized();
    final agnesKey = getAgnesApiKey();
    return {
      'agnes': agnesKey,
      'zhipu': agnesKey,
      'video': agnesKey,
      'image': agnesKey,
      'doubao': agnesKey,
    };
  }

  /// 批量设置所有配置（统一写入 Agnes Key，使用第一个非空参数）
  static Future<void> setAllConfigs({
    String? zhipuKey,
    String? videoKey,
    String? imageKey,
    String? doubaoKey,
    String? agnesKey,
  }) async {
    _ensureInitialized();
    final String key;
    if (agnesKey != null && agnesKey.isNotEmpty) {
      key = agnesKey;
    } else if (zhipuKey != null && zhipuKey.isNotEmpty) {
      key = zhipuKey;
    } else if (videoKey != null && videoKey.isNotEmpty) {
      key = videoKey;
    } else if (imageKey != null && imageKey.isNotEmpty) {
      key = imageKey;
    } else {
      key = doubaoKey ?? '';
    }
    await _prefs!.setString(_keyAgnesApiKey, key);
    AppLogger.success('ApiConfigService', '已更新 Agnes API Key');
  }

  /// 清空所有配置
  static Future<void> clearAll() async {
    _ensureInitialized();
    await _prefs!.remove(_keyAgnesApiKey);
    await _prefs!.remove(_keyZhipuApiKey);
    await _prefs!.remove(_keyVideoApiKey);
    await _prefs!.remove(_keyImageApiKey);
    await _prefs!.remove(_keyDoubaoApiKey);
    AppLogger.warn('ApiConfigService', '已清空所有 API Key');
  }

  /// 检查是否已初始化
  static void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('ApiConfigService 未初始化，请先调用 initialize()');
    }
  }

  /// 截断显示 Key（日志用，避免完整泄露）
  static String _mask(String key) {
    if (key.isEmpty) return '(空)';
    if (key.length <= 10) return '${key.substring(0, 4)}***';
    return '${key.substring(0, 8)}...${key.substring(key.length - 4)}';
  }

  /// 格式化 API Key 用于显示（隐藏中间部分）
  static String maskApiKey(String key) {
    if (key.isEmpty) return '未设置';
    if (key.length <= 10) return '${key.substring(0, 4)}***';
    return '${key.substring(0, 8)}...${key.substring(key.length - 4)}';
  }
}

/// API 配置状态
class ApiConfigStatus {
  final bool isAllConfigured;
  final List<String> missingKeys;

  const ApiConfigStatus({
    required this.isAllConfigured,
    this.missingKeys = const [],
  });

  /// 已全部配置的便捷构造
  static const allConfigured = ApiConfigStatus(isAllConfigured: true);

  /// 是否已配置
  bool get isConfigured => isAllConfigured;

  /// 获取未配置数量
  int get missingCount => missingKeys.length;

  /// 获取首个缺失的 Key
  String? get firstMissing => missingKeys.isNotEmpty ? missingKeys.first : null;

  /// 获取友好的提示消息
  String get friendlyMessage {
    if (isAllConfigured) return '所有 API Key 已配置';
    return '缺少以下 API Key：${missingKeys.join('、')}';
  }
}
