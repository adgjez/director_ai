#!/usr/bin/env bash
# ============================================================
# director_ai 真机四通道验证脚本
#
# 功能：在已连接的 Android 真机上运行 Agnes 四通道集成验证
#   （文本 sendToGLM / 图片理解 analyzeImageForCharacter /
#    图像生成 generateImage / 视频生成 generateVideo）
#
# 用法：
#   AGNES_API_KEY=<key> ./scripts/device_verify.sh [--video] [--device <id>]
#   ./scripts/device_verify.sh --key <key> --video
#
# 参数：
#   --key <key>      Agnes API Key（也可用环境变量 AGNES_API_KEY，二者必填其一）
#   --device <id>    指定 adb 设备 ID（默认取已连接的第一台真机）
#   --video          额外执行视频生成通道验证（耗时长，默认跳过）
#   --help           显示本帮助
#
# 退出码：0 全部通过；非 0 失败。
# ============================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

AGNES_API_KEY="${AGNES_API_KEY:-}"
DEVICE_ID=""
RUN_VIDEO=false

usage() {
  sed -n '2,22p' "${BASH_SOURCE[0]}"
  exit 0
}

# ---- 参数解析 ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)
      AGNES_API_KEY="$2"
      shift 2
      ;;
    --device)
      DEVICE_ID="$2"
      shift 2
      ;;
    --video)
      RUN_VIDEO=true
      shift
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo "未知参数: $1" >&2
      usage
      ;;
  esac
done

if [[ -z "$AGNES_API_KEY" ]]; then
  echo "错误：缺少 Agnes API Key" >&2
  echo "请通过 --key <key> 或环境变量 AGNES_API_KEY 提供" >&2
  exit 1
fi

# ---- 环境检查 ----
for cmd in adb flutter; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "错误：未找到命令 $cmd，请先安装并加入 PATH" >&2
    exit 1
  fi
done

echo "==> 1/4 检查已连接的 Android 设备..."

# 收集真机（排除模拟器）
if [[ -n "$DEVICE_ID" ]]; then
  if ! adb -s "$DEVICE_ID" get-state >/dev/null 2>&1; then
    echo "错误：设备 $DEVICE_ID 未连接" >&2
    exit 1
  fi
  echo "使用指定设备: $DEVICE_ID"
else
  DEVICE_ID="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
  if [[ -z "$DEVICE_ID" ]]; then
    echo "错误：未检测到已连接的 Android 设备" >&2
    echo "请先用 USB 连接真机并开启开发者选项/USB 调试" >&2
    exit 1
  fi
  echo "自动选择设备: $DEVICE_ID"
fi

echo "==> 2/4 拉取依赖..."
flutter pub get

echo "==> 3/4 构建并安装到真机（首次较慢）..."
# 预构建并安装 debug 包，集成测试在此基础上运行
flutter build apk --debug
adb -s "$DEVICE_ID" install -r build/app/outputs/flutter-apk/app-debug.apk

echo "==> 4/4 在真机上运行 Agnes 四通道集成验证..."
DART_DEFINES="AGNES_API_KEY=$AGNES_API_KEY"
EXTRA_ARGS=()
if [[ "$RUN_VIDEO" == true ]]; then
  DART_DEFINES="$DART_DEFINES,AGNES_VERIFY_VIDEO=true"
  EXTRA_ARGS+=(--timeout 1200s)
  echo "视频生成通道已开启（耗时较长）"
else
  echo "视频生成通道默认跳过（加 --video 开启）"
fi

set +e
flutter test \
  integration_test/agnes_smoke_test.dart \
  -d "$DEVICE_ID" \
  --dart-define="$DART_DEFINES" \
  "${EXTRA_ARGS[@]}"
TEST_EXIT=$?
set -e

if [[ $TEST_EXIT -eq 0 ]]; then
  echo ""
  echo "======================================"
  echo "✅ 真机验证全部通过（设备: $DEVICE_ID）"
  echo "======================================"
else
  echo ""
  echo "======================================"
  echo "❌ 真机验证失败（退出码 $TEST_EXIT），请查看上方日志" >&2
  echo "======================================"
fi
exit $TEST_EXIT