#!/bin/bash
# ============================================================================
# 本地 kallsyms 提取脚本 (备用)
# 如果你已经在本地编译好内核, 可以用此脚本从 vmlinux 提取 kallsyms
# 用法: ./extract-kallsyms.sh <vmlinux_path> [output_dir]
# ============================================================================

set -e

VMLINUX="${1:-}"
OUTPUT_DIR="${2:-./output}"

if [ -z "$VMLINUX" ] || [ ! -f "$VMLINUX" ]; then
    echo "用法: $0 <vmlinux_path> [output_dir]"
    echo "示例: $0 kernel_platform/common/out/vmlinux ./kallsyms_output"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "=========================================="
echo "  kallsyms 提取工具"
echo "=========================================="
echo "vmlinux: $VMLINUX"
echo "输出目录: $OUTPUT_DIR"
echo ""

# 检查工具
NM=""
for tool in llvm-nm nm aarch64-linux-gnu-nm; do
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

OBJDUMP=""
for tool in llvm-objdump objdump; do
    if command -v $tool >/dev/null 2>&1; then
        OBJDUMP="$tool"
        break
    fi
done

echo "使用工具: NM=$NM, READELF=$READELF, OBJDUMP=$OBJDUMP"
echo ""

# 1. 提取 kallsyms 格式符号表 (address type name)
echo "[1/4] 提取 kallsyms 格式符号表..."
if [ -n "$NM" ]; then
    $NM -n "$VMLINUX" 2>/dev/null | \
        awk 'NF>=2 {
            addr=$1; type=$2; name=$3;
            for(i=4;i<=NF;i++) name=name" "$i;
            printf "%016x %s %s\n", strtonum("0x"addr), type, name
        }' > "$OUTPUT_DIR/kallsyms.txt"
    echo "  ✓ kallsyms.txt ($(wc -l < "$OUTPUT_DIR/kallsyms.txt") 行)"
fi

# 2. 提取完整符号表 (readelf 格式)
echo "[2/4] 提取完整符号表 (readelf)..."
if [ -n "$READELF" ]; then
    $READELF -s "$VMLINUX" 2>/dev/null > "$OUTPUT_DIR/vmlinux_symbols.txt"
    echo "  ✓ vmlinux_symbols.txt ($(wc -l < "$OUTPUT_DIR/vmlinux_symbols.txt") 行)"
fi

# 3. 提取节区信息
echo "[3/4] 提取节区信息..."
if [ -n "$READELF" ]; then
    $READELF -S "$VMLINUX" 2>/dev/null > "$OUTPUT_DIR/vmlinux_sections.txt"
    echo "  ✓ vmlinux_sections.txt"
fi

# 4. 提取内核版本字符串
echo "[4/4] 提取内核版本信息..."
if [ -n "$OBJDUMP" ]; then
    # 从 vmlinux 中搜索 Linux version 字符串
    strings "$VMLINUX" | grep -m1 "Linux version" > "$OUTPUT_DIR/kernel_version.txt" 2>/dev/null || true
    if [ -s "$OUTPUT_DIR/kernel_version.txt" ]; then
        echo "  ✓ kernel_version.txt: $(cat "$OUTPUT_DIR/kernel_version.txt")"
    fi
fi

echo ""
echo "=========================================="
echo "  提取完成!"
echo "=========================================="
echo ""
echo "输出文件:"
ls -lh "$OUTPUT_DIR/"
echo ""
echo "kallsyms.txt 前 10 行预览:"
head -10 "$OUTPUT_DIR/kallsyms.txt" 2>/dev/null
echo ""
echo "kallsyms.txt 后 10 行预览:"
tail -10 "$OUTPUT_DIR/kallsyms.txt" 2>/dev/null
