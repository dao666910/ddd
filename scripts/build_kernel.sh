#!/bin/bash
###############################################################################
# OnePlus Ace 6T (SM8845) 内核编译脚本
# 专为 GitHub Actions 环境设计
#
# 用法:
#   ./build_kernel.sh --platform sun --variant consolidate [--debug true]
#
# 参数:
#   --platform <name>   平台代号 (默认: sun, 即 SM8845)
#   --variant <name>    构建变体: consolidate (调试版,含完整符号) 或 perf (正式版)
#   --debug <true|false> 调试模式, 输出详细日志
###############################################################################

set -euo pipefail

# ============================================================
# 参数解析
# ============================================================
PLATFORM="sun"
VARIANT=""
DEBUG="true"
WORKSPACE_DIR="$(pwd)"

while [[ $# -gt 0 ]]; do
    case $1 in
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --variant)
            VARIANT="$2"
            shift 2
            ;;
        --debug)
            DEBUG="$2"
            shift 2
            ;;
        --workspace)
            WORKSPACE_DIR="$2"
            shift 2
            ;;
        *)
            echo "未知参数: $1" >&2
            echo "用法: $0 --platform sun --variant consolidate [--debug true]"
            exit 1
            ;;
    esac
done

if [ -z "$VARIANT" ]; then
    echo "错误: 必须指定 --variant (consolidate 或 perf)" >&2
    exit 1
fi

if [ "$VARIANT" != "consolidate" ] && [ "$VARIANT" != "perf" ]; then
    echo "错误: --variant 必须是 consolidate 或 perf" >&2
    exit 1
fi

# ============================================================
# 颜色输出
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2; }
info() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }

cd "$WORKSPACE_DIR"

log "============================================"
log "OnePlus Ace 6T (SM8845) 内核编译"
log "============================================"
info "工作目录: $WORKSPACE_DIR"
info "平台: $PLATFORM (SM8845)"
info "变体: $VARIANT ($([ "$VARIANT" = "consolidate" ] && echo "调试版/含完整符号" || echo "正式版"))"
info "调试模式: $DEBUG"
info "CPU 核心: $(nproc)"
info "内存: $(free -h | awk '/^Mem:/{print $2}')"
info "磁盘可用: $(df -h . | awk 'NR==2{print $4}')"
echo ""

# ============================================================
# 1. 验证源码完整性
# ============================================================
log "验证源码完整性..."
critical_paths=(
    "kernel_platform/common"
    "kernel_platform/soc-repo"
    "kernel_platform/build"
    "kernel_platform/oplus"
    "vendor/qcom"
)
missing=0
for path in "${critical_paths[@]}"; do
    if [ -d "$path" ]; then
        info "  OK: $path"
    else
        err "  MISSING: $path"
        missing=1
    fi
done

if [ "$missing" -eq 1 ]; then
    err "关键目录缺失, 无法继续编译"
    err "请检查源码同步是否成功"
    exit 1
fi

# 检查构建脚本是否存在
BUILD_SCRIPT="kernel_platform/oplus/build/oplus_build_kernel.sh"
if [ ! -f "$BUILD_SCRIPT" ]; then
    err "构建脚本不存在: $BUILD_SCRIPT"
    err "请确认 kernel_platform/oplus 目录已正确同步"
    exit 1
fi
info "  OK: $BUILD_SCRIPT"
echo ""

# ============================================================
# 2. 环境准备
# ============================================================
log "准备构建环境..."

# 设置环境变量 (来自 oplus_setup.sh 的关键变量)
export TOPDIR="$(readlink -f ${PWD})"
export ANDROID_BUILD_TOP="${TOPDIR}"
export CHIPSET_COMPANY="QCOM"
export OPLUS_VND_BUILD_PLATFORM="SM8845"
export TARGET_BOARD_PLATFORM="$PLATFORM"
export TARGET_BUILD_VARIANT="user"
export ANDROID_PRODUCT_OUT="${TOPDIR}/out/target/product/$PLATFORM"
export EXTRA_KBUILD_ARGS="--skip abl"
export PATH="${TOPDIR}/kernel_platform/prebuilts/kernel-build-tools/linux-x86/bin:${PATH}"
export PATH="${TOPDIR}/kernel_platform/build/build-tools/path/linux-x86:${PATH}"

# 确保构建工具链可用
if [ -d "kernel_platform/prebuilts/clang/host/linux-x86" ]; then
    export PATH="${TOPDIR}/kernel_platform/prebuilts/clang/host/linux-x86/clang-r510928c/bin:${PATH}"
fi

info "TOPDIR: $TOPDIR"
info "PATH 已配置"
echo ""

# ============================================================
# 3. 磁盘空间检查
# ============================================================
log "磁盘空间检查..."
AVAILABLE_GB=$(df -BG . | awk 'NR==2{print $4}' | tr -d 'G')
info "可用磁盘: ${AVAILABLE_GB}GB"
if [ "$AVAILABLE_GB" -lt 20 ]; then
    warn "磁盘空间不足 20GB, 编译可能失败"
    warn "建议清理: sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc"
fi
echo ""

# ============================================================
# 4. 执行编译
# ============================================================
log "============================================"
log "开始编译 (这可能需要 60-120 分钟)"
log "============================================"
info "构建命令: ./kernel_platform/oplus/build/oplus_build_kernel.sh $PLATFORM $VARIANT"
echo ""

BUILD_LOG="$WORKSPACE_DIR/build.log"
BUILD_START=$(date +%s)

# 执行构建
# oplus_build_kernel.sh 接受两个参数: <platform> <variant>
# 它会调用 prepare_vendor.sh, 最终通过 bazel/kleaf 构建内核
set +e
./kernel_platform/oplus/build/oplus_build_kernel.sh "$PLATFORM" "$VARIANT" 2>&1 | tee "$BUILD_LOG"
BUILD_EXIT=${PIPESTATUS[0]}
set -e

BUILD_END=$(date +%s)
BUILD_DURATION=$((BUILD_END - BUILD_START))

echo ""
if [ "$BUILD_EXIT" -eq 0 ]; then
    log "============================================"
    log "编译成功! 耗时 $((BUILD_DURATION / 60)) 分 $((BUILD_DURATION % 60)) 秒"
    log "============================================"
else
    err "============================================"
    err "编译失败! exit=$BUILD_EXIT, 耗时 $((BUILD_DURATION / 60)) 分 $((BUILD_DURATION % 60)) 秒"
    err "============================================"
    err "查看构建日志最后 100 行:"
    tail -100 "$BUILD_LOG" >&2 || true
    exit $BUILD_EXIT
fi

# ============================================================
# 5. 查找编译产物
# ============================================================
echo ""
log "查找编译产物..."

info "搜索 vmlinux..."
VMLINUX_PATHS=$(find "$WORKSPACE_DIR" -name "vmlinux" -type f 2>/dev/null | head -20)
if [ -z "$VMLINUX_PATHS" ]; then
    warn "未找到 vmlinux (可能被 strip 或在 bazel-bin 深处)"
    warn "尝试在 bazel-bin 中搜索..."
    VMLINUX_PATHS=$(find "$WORKSPACE_DIR" -path "*/bazel-bin/*" -name "vmlinux" 2>/dev/null | head -20)
fi
echo "$VMLINUX_PATHS" | while read -r p; do
    [ -n "$p" ] && info "  vmlinux: $p ($(ls -lh "$p" | awk '{print $5}'))"
done

info "搜索 Image..."
find "$WORKSPACE_DIR" -name "Image" -type f 2>/dev/null | head -10 | while read -r p; do
    info "  Image: $p ($(ls -lh "$p" | awk '{print $5}'))"
done

info "搜索 dist 目录..."
find "$WORKSPACE_DIR" -type d -name "dist" 2>/dev/null | head -10 | while read -r d; do
    info "  dist: $d"
    ls -lh "$d" 2>/dev/null | head -20
done

echo ""
log "编译脚本完成"
info "产物提取请运行: extract_artifacts.sh"
