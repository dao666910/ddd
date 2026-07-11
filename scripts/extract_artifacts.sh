#!/bin/bash
###############################################################################
# OnePlus Ace 6T (SM8845) 编译产物提取脚本
# 从编译输出中提取 vmlinux, Image, kallsyms 等关键文件
#
# 用法:
#   ./extract_artifacts.sh --output-dir <dir> [--extract-vmlinux true] [--extract-kallsyms true]
###############################################################################

set -euo pipefail

# ============================================================
# 参数解析
# ============================================================
OUTPUT_DIR=""
EXTRACT_VMLINUX="true"
EXTRACT_KALLSYMS="true"
DEBUG="false"
WORKSPACE_DIR="$(pwd)"

while [[ $# -gt 0 ]]; do
    case $1 in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --extract-vmlinux)
            EXTRACT_VMLINUX="$2"
            shift 2
            ;;
        --extract-kallsyms)
            EXTRACT_KALLSYMS="$2"
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
            exit 1
            ;;
    esac
done

if [ -z "$OUTPUT_DIR" ]; then
    echo "错误: 必须指定 --output-dir" >&2
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

mkdir -p "$OUTPUT_DIR"
cd "$WORKSPACE_DIR"

log "============================================"
log "提取编译产物"
log "============================================"
info "工作目录: $WORKSPACE_DIR"
info "输出目录: $OUTPUT_DIR"
info "提取 vmlinux: $EXTRACT_VMLINUX"
info "提取 kallsyms: $EXTRACT_KALLSYMS"
echo ""

# ============================================================
# 1. 查找 vmlinux
# ============================================================
log "搜索 vmlinux..."

# vmlinux 可能在多个位置:
# - bazel-bin/kernel_platform/common/vmlinux
# - out/msm-kernel-sun-consolidate/dist/vmlinux
# - 其他 bazel 输出路径
VMLINUX=""
for candidate in \
    "bazel-bin/kernel_platform/common/vmlinux" \
    "out/msm-kernel-sun-consolidate/dist/vmlinux" \
    "out/msm-kernel-sun-perf/dist/vmlinux"; do
    if [ -f "$candidate" ]; then
        VMLINUX="$candidate"
        info "  找到: $candidate ($(ls -lh "$candidate" | awk '{print $5}'))"
        break
    fi
done

# 如果预设路径没找到, 全局搜索
if [ -z "$VMLINUX" ]; then
    info "  预设路径未找到, 全局搜索..."
    # 排除 .git 目录, 限制深度避免太慢
    VMLINUX=$(find . -path ./.git -prune -o -name "vmlinux" -type f -print 2>/dev/null | head -1)
    if [ -n "$VMLINUX" ]; then
        info "  找到: $VMLINUX ($(ls -lh "$VMLINUX" | awk '{print $5}'))"
    fi
fi

if [ -z "$VMLINUX" ]; then
    warn "未找到 vmlinux!"
    warn "可能原因:"
    warn "  1. 编译失败 (请检查 build.log)"
    warn "  2. vmlinux 被 strip (perf 变体可能如此)"
    warn "  3. 路径在 bazel 缓存深处"
    warn ""
    warn "尝试列出所有 vmlinux 文件:"
    find . -name "vmlinux" -type f 2>/dev/null | head -20 || true
fi

# ============================================================
# 2. 提取 vmlinux
# ============================================================
if [ "$EXTRACT_VMLINUX" = "true" ] && [ -n "$VMLINUX" ]; then
    log "复制 vmlinux 到输出目录..."
    cp -L "$VMLINUX" "$OUTPUT_DIR/vmlinux"
    info "  vmlinux: $(ls -lh "$OUTPUT_DIR/vmlinux" | awk '{print $5}')"

    # 验证 vmlinux 是有效的 ELF 文件
    if file "$OUTPUT_DIR/vmlinux" | grep -q "ELF"; then
        info "  类型: $(file "$OUTPUT_DIR/vmlinux" | cut -d: -f2)"
    else
        warn "  vmlinux 不是有效的 ELF 文件!"
    fi
fi

# ============================================================
# 3. 从 vmlinux 提取 kallsyms
# ============================================================
if [ "$EXTRACT_KALLSYMS" = "true" ]; then
    log "提取 kallsyms 符号表..."

    if [ -n "$VMLINUX" ]; then
        # 使用 nm 工具从 vmlinux 提取符号
        # nm -n = 按地址排序
        # 输出格式: <地址> <类型> <符号名>
        # 类型说明:
        #   T/t = 代码段 (text)
        #   D/d = 已初始化数据 (data)
        #   B/b = 未初始化数据 (bss)
        #   R/r = 只读数据 (rodata)
        #   W/w = 弱符号
        #   A   = 绝对符号
        # 大写 = 全局, 小写 = 局部

        # 优先使用 LLVM 工具链的 llvm-nm (如果存在)
        NM_TOOL="nm"
        if command -v llvm-nm >/dev/null 2>&1; then
            NM_TOOL="llvm-nm"
        elif [ -x "kernel_platform/prebuilts/kernel-build-tools/linux-x86/bin/llvm-nm" ]; then
            NM_TOOL="kernel_platform/prebuilts/kernel-build-tools/linux-x86/bin/llvm-nm"
        fi

        info "  使用工具: $NM_TOOL"
        info "  从 vmlinux 提取符号..."

        "$NM_TOOL" -n "$VMLINUX" 2>/dev/null | \
            awk 'NF>=3 && $1 ~ /^[0-9a-f]+$/ {print $1, $2, $3}' > "$OUTPUT_DIR/kallsyms.txt"

        SYMBOL_COUNT=$(wc -l < "$OUTPUT_DIR/kallsyms.txt")
        info "  kallsyms 符号数: $SYMBOL_COUNT"
        info "  文件大小: $(ls -lh "$OUTPUT_DIR/kallsyms.txt" | awk '{print $5}')"

        if [ "$SYMBOL_COUNT" -gt 0 ]; then
            log "  前 10 个符号示例:"
            head -10 "$OUTPUT_DIR/kallsyms.txt" | sed 's/^/    /'
        else
            warn "  kallsyms 为空! vmlinux 可能已被 strip"
            warn "  尝试使用 objdump..."
            if command -v llvm-objdump >/dev/null 2>&1; then
                llvm-objdump -t "$VMLINUX" 2>/dev/null | \
                    awk 'NF>=4 && $1 ~ /^[0-9a-f]+$/ {print $1, $2, $NF}' > "$OUTPUT_DIR/kallsyms.txt" || true
            fi
        fi
    else
        warn "  vmlinux 不可用, 无法提取 kallsyms"
        warn "  如果你只需要 kallsyms, 可以从已 Root 的设备直接读取 /proc/kallsyms"
    fi
fi

# ============================================================
# 4. 提取 Image (压缩内核镜像)
# ============================================================
log "搜索 Image (压缩内核镜像)..."
IMAGE=""
for candidate in \
    "bazel-bin/kernel_platform/common/Image" \
    "out/msm-kernel-sun-consolidate/dist/Image" \
    "out/msm-kernel-sun-perf/dist/Image"; do
    if [ -f "$candidate" ]; then
        IMAGE="$candidate"
        break
    fi
done

if [ -z "$IMAGE" ]; then
    IMAGE=$(find . -path ./.git -prune -o -name "Image" -type f -print 2>/dev/null | head -1)
fi

if [ -n "$IMAGE" ]; then
    cp -L "$IMAGE" "$OUTPUT_DIR/Image"
    info "  Image: $(ls -lh "$OUTPUT_DIR/Image" | awk '{print $5}')"
else
    warn "  未找到 Image"
fi

# ============================================================
# 5. 提取内核模块 (.ko 文件)
# ============================================================
log "搜索内核模块..."
MODULES_DIR=$(find . -type d -name "dist" 2>/dev/null | head -1)
if [ -n "$MODULES_DIR" ]; then
    KO_COUNT=$(find "$MODULES_DIR" -name "*.ko" 2>/dev/null | wc -l)
    if [ "$KO_COUNT" -gt 0 ]; then
        info "  找到 $KO_COUNT 个内核模块"
        # 打包所有 .ko 文件
        tar -czf "$OUTPUT_DIR/modules.tar.gz" \
            -C "$MODULES_DIR" \
            $(find "$MODULES_DIR" -name "*.ko" -printf "%P\n" 2>/dev/null | head -500) 2>/dev/null || true
        info "  modules.tar.gz: $(ls -lh "$OUTPUT_DIR/modules.tar.gz" | awk '{print $5}')"
    fi
fi

# ============================================================
# 6. 提取内核配置
# ============================================================
log "提取内核配置..."
CONFIG_FILE=""
for candidate in \
    "bazel-bin/kernel_platform/common/.config" \
    "out/msm-kernel-sun-consolidate/dist/.config" \
    "out/msm-kernel-sun-perf/dist/.config"; do
    if [ -f "$candidate" ]; then
        CONFIG_FILE="$candidate"
        break
    fi
done

if [ -n "$CONFIG_FILE" ]; then
    cp "$CONFIG_FILE" "$OUTPUT_DIR/kernel.config"
    info "  kernel.config: $(ls -lh "$OUTPUT_DIR/kernel.config" | awk '{print $5}')"
fi

# ============================================================
# 7. 生成构建信息文件
# ============================================================
log "生成 build_info.txt..."
cat > "$OUTPUT_DIR/build_info.txt" << EOF
============================================
OnePlus Ace 6T (SM8845) Kernel Build Info
============================================

设备: OnePlus Ace 6T
芯片: Qualcomm SM8845 (Snapdragon 8 Gen 5)
Android 版本: 16
内核版本: 6.12.38-android16-5

构建时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
构建主机: $(hostname)
构建目录: $WORKSPACE_DIR

源码仓库:
  - https://github.com/OnePlusOSS/android_kernel_oneplus_sm8845
  - https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8845
  - https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm8845
源码分支: oneplus/sm8845_b_16.0.0_ace_6t

构建环境:
  - OS: $(cat /etc/os-release 2>/dev/null | grep "^PRETTY_NAME" | cut -d= -f2 | tr -d '"' || echo "Linux")
  - CPU: $(nproc) cores
  - 内存: $(free -h | awk '/^Mem:/{print $2}')

产物清单:
$(ls -lh "$OUTPUT_DIR/" 2>/dev/null | tail -n +2 | sed 's/^/  /')

============================================
EOF

# ============================================================
# 8. 汇总
# ============================================================
echo ""
log "============================================"
log "产物提取完成!"
log "============================================"
echo ""
info "输出目录: $OUTPUT_DIR"
info "文件列表:"
ls -lh "$OUTPUT_DIR/" 2>/dev/null | tail -n +2 | while read -r line; do
    info "  $line"
done
echo ""

# 计算总大小
TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" 2>/dev/null | awk '{print $1}')
log "总大小: $TOTAL_SIZE"
