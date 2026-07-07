#!/usr/bin/env bash
# director_ai Android APK 一键构建脚本
# 默认使用 debug 签名打 release 包（仅用于内部测试）
# 用法:
#   ./build_apk.sh              # 自增 versionCode 后构建
#   ./build_apk.sh --no-bump    # 不自增版本号，直接构建

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBSPEC="$PROJECT_DIR/pubspec.yaml"
cd "$PROJECT_DIR"

# ---------- 颜色输出 ----------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()  { echo -e "\n${CYAN}=== $* ===${NC}"; }

# ---------- 参数解析 ----------
BUMP_VERSION=1
for arg in "$@"; do
  case "$arg" in
    --no-bump) BUMP_VERSION=0 ;;
    -h|--help)
      echo "用法: ./build_apk.sh [--no-bump]"
      echo "  --no-bump  不自增 versionCode，保持当前版本号构建"
      exit 0
      ;;
    *) warn "未知参数: $arg" ;;
  esac
done

# ---------- 环境检查 ----------
step "1/5 环境检查"
if ! command -v flutter >/dev/null 2>&1; then
  err "未找到 flutter 命令，请先安装 Flutter SDK 并加入 PATH。"
  exit 1
fi
FLUTTER_VER="$(flutter --version | head -1)"
info "$FLUTTER_VER"

# ---------- 版本号自增 ----------
step "2/5 版本号处理"
if [[ ! -f "$PUBSPEC" ]]; then
  err "未找到 pubspec.yaml: $PUBSPEC"
  exit 1
fi

# 解析 pubspec.yaml 中的 version: major.minor.patch+buildNumber
VERSION_LINE="$(grep -E "^version:" "$PUBSPEC")"
VERSION_VAL="$(echo "$VERSION_LINE" | sed -E 's/^version:[[:space:]]*//')"
VERSION_NAME="${VERSION_VAL%%+*}"
VERSION_CODE="${VERSION_VAL##*+}"
# 兼容没有 +buildNumber 的情况
if [[ "$VERSION_CODE" == "$VERSION_NAME" ]]; then
  VERSION_CODE="1"
fi

info "当前版本: name=$VERSION_NAME  code=$VERSION_CODE"

if [[ "$BUMP_VERSION" == "1" ]]; then
  NEW_CODE=$((VERSION_CODE + 1))
  # 用 perl 做原地替换，兼容 macOS / Linux
  if perl -i -pe "s/^version:[[:space:]]*${VERSION_NAME}\+${VERSION_CODE}\s*\$/version: ${VERSION_NAME}+${NEW_CODE}/" "$PUBSPEC"; then
    info "versionCode 自增: $VERSION_CODE -> $NEW_CODE"
  else
    warn "版本号自增失败，保持原版本号继续构建。"
  fi
else
  info "跳过版本号自增 (--no-bump)"
  NEW_CODE="$VERSION_CODE"
fi

# ---------- 清理 ----------
step "3/5 清理构建产物"
flutter clean
flutter pub get

# ---------- 构建 ----------
step "4/5 构建 release APK"
# release 构建类型当前使用 debug 签名 (见 android/app/build.gradle)
flutter build apk --release --no-tree-shake-icons

# ---------- 输出信息 ----------
step "5/5 构建完成"
APK_PATH="$PROJECT_DIR/build/app/outputs/flutter-apk/app-release.apk"
if [[ -f "$APK_PATH" ]]; then
  APK_SIZE=$(du -h "$APK_PATH" | cut -f1)
  echo ""
  echo -e "${GREEN}构建成功!${NC}"
  echo -e "  版本:   ${VERSION_NAME}+${NEW_CODE}"
  echo -e "  路径:   ${APK_PATH}"
  echo -e "  大小:   ${APK_SIZE}"
  echo -e "  签名:   debug (仅用于内部测试，不可上架)"
  echo ""
  echo "安装到已连接设备:"
  echo "  flutter install"
else
  err "未找到输出 APK: $APK_PATH"
  err "请检查上方构建日志。"
  exit 1
fi
