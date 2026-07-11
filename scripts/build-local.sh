#!/bin/bash
# ============================================================================
# OnePlus Ace6T 内核本地构建脚本
# 适用于: GitHub Codespaces / 本地 Linux / WSL2
# 
# 用法:
#   chmod +x scripts/build-local.sh
#   ./scripts/build-local.sh
#
# 环境要求:
#   - Ubuntu 22.04+ (Codespaces 默认满足)
#   - 至少 16GB 磁盘空间
#   - 至少 8GB 内存 (推荐 16GB)
# ============================================================================

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $1"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $1"; }
info() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }

# 配置
MANIFEST_URL="https://github.com/OnePlusOSS/kernel_manifest.git"
MANIFEST_BRANCH="oneplus/sm8845"
MANIFEST_NAME="oneplus_ace_6t.xml"
KERNEL_REPO_PATH="kernel_platform/common"
WORKSPACE="$PWD/kernel_workspace"
OUTPUT_DIR="$PWD/output"

# 检查环境
log "=========================================="
log "  OnePlus Ace6T 内核构建脚本"
log "=========================================="
echo ""
info "Manifest: $MANIFEST_URL"
info "Branch:   $MANIFEST_BRANCH"
info "XML:      $MANIFEST_NAME"
info "Workspace: $WORKSPACE"
info "Output:    $OUTPUT_DIR"
echo ""

# 检查磁盘空间
AVAILABLE_GB=$(df -BG . | awk 'NR==2{print $4}' | tr -d 'G')
log "可用磁盘空间: ${AVAILABLE_GB}GB"
if [ "$AVAILABLE_GB" -lt 20 ]; then
    warn "磁盘空间不足 20GB (当前 ${AVAILABLE_GB}GB), 构建可能失败"
    warn "建议在 GitHub Codespaces (32GB) 或本地大磁盘环境运行"
fi

# 检查内存
MEM_GB=$(free -g | awk '/Mem/{print $2}')
log "内存总量: ${MEM_GB}GB"
if [ "$MEM_GB" -lt 8 ]; then
    warn "内存不足 8GB (当前 ${MEM_GB}GB), vmlinux 链接阶段可能 OOM"
fi

echo ""
log "=========================================="
log "  步骤 1/7: 安装依赖"
log "=========================================="
sudo apt-get update -qq
sudo apt-get install -y -qq \
    git repo build-essential libelf-dev libssl-dev \
    bc bison flex python3 python3-pip ccache \
    dwarves zstd curl wget lld llvm clang 2>&1 | tail -5

# 配置 git
git config --global user.name "kernel-builder" 2>/dev/null || true
git config --global user.email "builder@local" 2>/dev/null || true

echo ""
log "=========================================="
log "  步骤 2/7: 同步 OnePlus 官方内核源码"
log "=========================================="
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

if [ ! -d ".repo" ]; then
    log "初始化 repo..."
    repo init -u "$MANIFEST_URL" \
        -b "$MANIFEST_BRANCH" \
        -m "$MANIFEST_NAME" \
        --depth=1
else
    info "已存在 .repo, 跳过 init"
fi

log "开始同步源码 (这一步可能需要 10-30 分钟)..."
repo sync -c -j$(nproc --all) --no-tags --no-clone-bundle --force-sync 2>&1 | tail -10

log "源码同步完成"
du -sh kernel_platform/* 2>/dev/null | head -10

echo ""
log "=========================================="
log "  步骤 3/7: 清理 protected exports"
log "=========================================="
cd "$WORKSPACE"
rm -f kernel_platform/common/android/abi_gki_protected_exports_* 2>/dev/null || true
rm -f kernel_platform/msm-kernel/android/abi_gki_protected_exports_* 2>/dev/null || true

for f in kernel_platform/common/scripts/setlocalversion \
         kernel_platform/msm-kernel/scripts/setlocalversion \
         kernel_platform/external/dtc/scripts/setlocalversion; do
    if [ -f "$f" ]; then
        sed -i 's/ -dirty//g' "$f"
        sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' "$f"
        log "已清理: $f"
    fi
done

echo ""
log "=========================================="
log "  步骤 4/7: 编译内核 (这一步最耗时)"
log "=========================================="
cd "$WORKSPACE/$KERNEL_REPO_PATH"

# 工具链路径
CLANG_PATH="$WORKSPACE/kernel_platform/prebuilts/clang/host/linux-x86/clang-r510928/bin"
if [ ! -d "$CLANG_PATH" ]; then
    # 查找实际存在的 clang 版本
    CLANG_DIR=$(find "$WORKSPACE/kernel_platform/prebuilts/clang/host/linux-x86/" -maxdepth 1 -type d -name "clang-r*" 2>/dev/null | head -1)
    if [ -n "$CLANG_DIR" ]; then
        CLANG_PATH="$CLANG_DIR/bin"
    else
        warn "未找到预编译 clang, 使用系统 clang"
        CLANG_PATH=""
    fi
fi

if [ -n "$CLANG_PATH" ]; then
    export PATH="/usr/lib/ccache:$CLANG_PATH:$PATH"
    log "使用预编译 clang: $CLANG_PATH"
else
    export PATH="/usr/lib/ccache:$PATH"
    warn "使用系统 clang: $(which clang)"
fi

log "开始编译 (预计 1-3 小时, 取决于 CPU)..."
log "CPU 核心数: $(nproc)"
echo ""

make -j$(nproc) \
    LLVM=1 \
    ARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CC="ccache clang" \
    RUSTC=../../prebuilts/rust/linux-x86/1.73.0b/bin/rustc \
    PAHOLE=../../prebuilts/kernel-build-tools/linux-x86/bin/pahole \
    LD=ld.lld \
    HOSTLD=ld.lld \
    O=out \
    KCFLAGS+=-O2 \
    gki_defconfig all 2>&1 | tail -30

echo ""
log "编译完成!"
log "构建产物:"
ls -lh out/arch/arm64/boot/Image 2>/dev/null && echo "  ✓ Image"
ls -lh out/vmlinux 2>/dev/null && echo "  ✓ vmlinux (root)"
ls -lh out/arch/arm64/boot/vmlinux 2>/dev/null && echo "  ✓ vmlinux (boot)"

echo ""
log "=========================================="
log "  步骤 5/7: 提取 vmlinux"
log "=========================================="
mkdir -p "$OUTPUT_DIR"

VMLINUX=""
for p in out/vmlinux out/arch/arm64/boot/vmlinux; do
    if [ -f "$p" ]; then
        VMLINUX="$p"
        break
    fi
done

if [ -z "$VMLINUX" ]; then
    err "未找到 vmlinux!"
    exit 1
fi

log "找到 vmlinux: $VMLINUX"
ls -lh "$VMLINUX"
file "$VMLINUX"

cp "$VMLINUX" "$OUTPUT_DIR/vmlinux"
log "压缩 vmlinux (zstd)..."
zstd -19 -T0 "$VMLINUX" -o "$OUTPUT_DIR/vmlinux.zst" 2>&1 | tail -3
ls -lh "$OUTPUT_DIR/"

echo ""
log "=========================================="
log "  步骤 6/7: 提取 kallsyms"
log "=========================================="

# 查找 nm 工具
NM=""
for tool in llvm-nm nm; do
    if command -v $tool >/dev/null 2>&1; then
        NM="$tool"
        break
    fi
done

READELF=""
for tool in llvm-readelf readelf; do
    if command -v $tool >/dev/null 2>&1; then
        READELF="$tool"
        break
    fi
done

log "使用工具: NM=$NM, READELF=$READELF"

# 提取 kallsyms 格式
if [ -n "$NM" ]; then
    log "提取 kallsyms.txt..."
    $NM -n "$VMLINUX" 2>/dev/null | \
        awk 'NF>=2 {
            addr=$1; type=$2; name=$3;
            for(i=4;i<=NF;i++) name=name" "$i;
            printf "%016x %s %s\n", strtonum("0x"addr), type, name
        }' > "$OUTPUT_DIR/kallsyms.txt"
    log "kallsyms.txt: $(wc -l < "$OUTPUT_DIR/kallsyms.txt") 行"
fi

# 提取完整符号表
if [ -n "$READELF" ]; then
    log "提取 vmlinux_symbols.txt..."
    $READELF -s "$VMLINUX" 2>/dev/null > "$OUTPUT_DIR/vmlinux_symbols.txt"
    log "vmlinux_symbols.txt: $(wc -l < "$OUTPUT_DIR/vmlinux_symbols.txt") 行"
    
    log "提取 vmlinux_sections.txt..."
    $READELF -S "$VMLINUX" 2>/dev/null > "$OUTPUT_DIR/vmlinux_sections.txt"
fi

# 提取内核版本
strings "$VMLINUX" | grep -m1 "Linux version" > "$OUTPUT_DIR/kernel_version.txt" 2>/dev/null || true
if [ -s "$OUTPUT_DIR/kernel_version.txt" ]; then
    log "内核版本: $(cat "$OUTPUT_DIR/kernel_version.txt")"
fi

echo ""
log "=========================================="
log "  步骤 7/7: 复制 Image 并生成构建信息"
log "=========================================="

if [ -f out/arch/arm64/boot/Image ]; then
    cp out/arch/arm64/boot/Image "$OUTPUT_DIR/Image"
    log "已复制 Image"
fi

cat > "$OUTPUT_DIR/build_info.txt" << EOF
===========================================
OnePlus Ace6T Kernel Build Info
===========================================
Build Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Builder: $(whoami)@$(hostname)

Source:
  Manifest: $MANIFEST_URL
  Branch:   $MANIFEST_BRANCH
  XML:      $MANIFEST_NAME
  Revision: oneplus/sm8845_b_16.0.0_ace_6t

Device Target:
  SoC: Qualcomm SM8750 (Snapdragon 8 Elite Gen 5)
  Device: OnePlus Ace 6 / Ace 6T
  Android: 16
  Kernel: 6.12.x

Build Config:
  Defconfig: gki_defconfig
  Compiler: clang (LLVM=1)
  ARCH: arm64
  CPU cores: $(nproc)

Artifacts:
  - vmlinux: ELF 内核镜像 (含完整符号, 用于调试/逆向)
  - vmlinux.zst: vmlinux 的 zstd 压缩版
  - kallsyms.txt: 内核符号表 (/proc/kallsyms 格式)
  - vmlinux_symbols.txt: readelf 提取的完整符号表
  - vmlinux_sections.txt: 节区信息
  - Image: 可刷入的内核镜像 (用于 AnyKernel3 等)
  - kernel_version.txt: 内核版本字符串
EOF

if [ -f out/include/config/kernel.release ]; then
    echo "" >> "$OUTPUT_DIR/build_info.txt"
    echo "Kernel Release: $(cat out/include/config/kernel.release)" >> "$OUTPUT_DIR/build_info.txt"
fi

cat "$OUTPUT_DIR/build_info.txt"

echo ""
log "=========================================="
log "  构建全部完成!"
log "=========================================="
echo ""
info "输出目录: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR/"
echo ""
log "kallsyms.txt 前 10 行预览:"
head -10 "$OUTPUT_DIR/kallsyms.txt" 2>/dev/null
echo ""
log "kallsyms.txt 后 10 行预览:"
tail -10 "$OUTPUT_DIR/kallsyms.txt" 2>/dev/null
