# OnePlus Ace6T 内核构建工具 (vmlinux + kallsyms 提取)

> 基于 **OnePlus 官方开源内核** (OnePlusOSS/kernel_manifest) 构建
> 适用于: 一加 Ace 6 / Ace 6T (SM8750, Android 16, Kernel 6.12.x)

## 📋 项目背景

本工具用于从 OnePlus 官方开源内核项目中编译内核,并提取 **vmlinux** 和 **kallsyms** 符号表。

### 为什么需要这个工具?

- **vmlinux**: 未压缩的 ELF 内核镜像,包含完整符号信息,用于:
  - 内核逆向分析
  - 漏洞研究 / Pwn
  - Frida / eBPF 等动态调试工具的符号解析
  - 调试 panic / oops
- **kallsyms**: 内核符号表 (`/proc/kallsyms` 格式),用于:
  - 查找内核函数地址
  - 配合 root 工具 (如 KernelSU) 使用
  - 编写内核 hook 模块

### 设备信息匹配

| 项目 | 你的设备 | 本工具构建目标 |
|------|---------|---------------|
| 设备 | 一加 Ace6T | OnePlus Ace 6 系列 (共用 SM8750 平台) |
| 系统 | Android 16 | Android 16 (revision: sm8750_b_16.0.0_ace_6) |
| 内核 | 6.12.38 | 6.12.x (GKI) |
| 架构 | aarch64 | arm64 |

> **说明**: OnePlus 官方开源仓库中, Ace 6 和 Ace 6T 共用同一套 SM8750 内核源码 (分支 `oneplus/sm8750`, manifest `oneplus_ace_6.xml`)。Ace 6T 是 Ace 6 的衍生版本, 内核源码完全一致。

---

## 🚀 快速开始

### 方法一: 使用 GitHub Actions (推荐, 免费)

GitHub 免费 Runner 提供 16GB RAM / 4 核 CPU / 14GB 磁盘, 足够完成内核编译。

#### 步骤 1: Fork 仓库

1. 将本项目整个目录上传到你自己的 GitHub 仓库
   (或将 `op_ace6t_kernel_build` 目录内容推送到新仓库)

#### 步骤 2: 启用 Actions

1. 进入你 Fork 的仓库页面
2. 点击 **Actions** 标签
3. 如果有提示, 点击 **I understand my workflows, go ahead and enable them**

#### 步骤 3: 触发构建

1. 在 Actions 页面左侧选择 **Build OnePlus Ace6T Kernel (vmlinux + kallsyms)**
2. 点击 **Run workflow** 按钮
3. 选择参数:
   - `build_variant`: `gki_defconfig` (保持默认)
   - `upload_vmlinux`: ✅ (上传 vmlinux)
   - `upload_kallsyms`: ✅ (上传 kallsyms)
   - `upload_image`: ✅ (上传可刷入的 Image)
4. 点击 **Run workflow** 绿色按钮

#### 步骤 4: 等待构建

- 构建时间: **约 1-2 小时** (首次构建, 无 ccache)
- 二次构建: **约 30-50 分钟** (有 ccache 缓存)
- 构建过程中可以点击任务查看实时日志

#### 步骤 5: 下载产物

构建完成后:
1. 点击完成的 workflow run
2. 在页面底部 **Artifacts** 区域下载:
   - `vmlinux` - 原始 vmlinux ELF 文件 (~500MB)
   - `vmlinux-zst` - vmlinux 的 zstd 压缩版 (~100MB, 推荐下载)
   - `kallsyms` - kallsyms.txt + vmlinux_symbols.txt
   - `Image` - 可刷入的内核镜像
   - `build-info` - 构建信息

---

### 方法二: 本地编译 (需要 Linux 环境)

#### 环境要求

- Ubuntu 22.04+ 或其他 Linux 发行版
- 至少 16GB RAM (vmlinux 链接需要大量内存)
- 至少 30GB 可用磁盘空间
- 4 核以上 CPU (推荐 8 核+)

#### 编译步骤

```bash
# 1. 安装依赖
sudo apt update
sudo apt install -y git repo build-essential libelf-dev libssl-dev \
    bc bison flex python3 ccache dwarves zstd

# 2. 安装 LLVM/Clang (Android 内核要求 LLVM=1)
# 方法 A: 使用系统包
sudo apt install -y llvm clang lld
# 方法 B: 下载 Android 预编译工具链 (推荐, 版本匹配)
# 参考: https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/

# 3. 同步源码
mkdir kernel_workspace && cd kernel_workspace
repo init -u https://github.com/OnePlusOSS/kernel_manifest.git \
    -b oneplus/sm8750 -m oneplus_ace_6.xml --depth=1
repo sync -c -j$(nproc) --no-tags --no-clone-bundle

# 4. 清理 protected exports
rm -f kernel_platform/common/android/abi_gki_protected_exports_*
rm -f kernel_platform/msm-kernel/android/abi_gki_protected_exports_*
sed -i 's/ -dirty//g' kernel_platform/common/scripts/setlocalversion
sed -i 's/ -dirty//g' kernel_platform/msm-kernel/scripts/setlocalversion

# 5. 编译
cd kernel_platform/common
make -j$(nproc) LLVM=1 ARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CC="ccache clang" \
    LD=ld.lld HOSTLD=ld.lld \
    O=out KCFLAGS+=-O2 \
    gki_defconfig all

# 6. 提取 vmlinux 和 kallsyms
# vmlinux 位置: out/vmlinux 或 out/arch/arm64/boot/vmlinux
# Image 位置: out/arch/arm64/boot/Image

# 使用本项目的提取脚本
bash /path/to/scripts/extract-kallsyms.sh out/vmlinux ./output
```

---

## 📦 产物说明

### vmlinux
- **格式**: ELF 64-bit LSB executable, ARM aarch64
- **大小**: 约 300-800MB (含调试符号)
- **用途**: 逆向分析、调试、符号解析
- **查看命令**:
  ```bash
  file vmlinux
  readelf -h vmlinux
  nm vmlinux | head
  ```

### vmlinux.zst
- vmlinux 的 zstd 压缩版本, 文件更小便于下载
- 解压: `zstd -d vmlinux.zst -o vmlinux`

### kallsyms.txt
- **格式**: `address type name` (与 `/proc/kallsyms` 一致)
- **示例**:
  ```
  ffffffc000080000 T _text
  ffffffc000080000 T stext
  ffffffc000081000 T do_one_initcall
  ...
  ```
- **type 含义**:
  - `T/t`: 函数 (Text)
  - `D/d`: 已初始化数据 (Data)
  - `B/b`: 未初始化数据 (BSS)
  - `R/r`: 只读数据 (Read-only)
  - `W/w`: 弱符号 (Weak)
  - 大写 = 全局符号, 小写 = 局部符号

### vmlinux_symbols.txt
- 使用 `readelf -s` 提取的完整符号表
- 包含更详细的符号信息 (大小、绑定、可见性等)

### Image
- **格式**: ARM64 Linux kernel image (无压缩或 gzip)
- **用途**: 可通过 AnyKernel3 刷入设备
- **刷入方法**:
  ```bash
  # 使用 AnyKernel3
  git clone https://github.com/osm0sis/AnyKernel3
  cp Image AnyKernel3/
  cd AnyKernel3
  zip -r kernel-flash.zip .
  # 通过 TWRP 或 fastboot 刷入
  ```

---

## ⚠️ 重要注意事项

### 1. 关于 Ace 6T 与 Ace 6
OnePlus 官方开源仓库中, Ace 6T 没有独立的 manifest 文件。Ace 6T 与 Ace 6 共用 SM8750 平台内核, 源码完全一致。本工具使用 `oneplus_ace_6.xml` 构建的内核, 在 Ace 6T 上同样适用。

### 2. 关于内核版本
你设备上的内核版本 `6.12.38-android16-5` 中的 `-5` 是 OnePlus 的构建编号, 不同 OTA 版本可能不同。本工具构建的是当前 `oneplus/sm8750_b_16.0.0_ace_6` 分支的最新源码, 版本号可能与设备上的略有差异, 但 ABI 兼容。

### 3. 关于 GKI
Android 16 使用 GKI (Generic Kernel Image) 架构, 通用内核 (`gki_defconfig`) 适用于所有 SM8750 设备。设备特定的驱动以模块形式加载。

### 4. 刷入风险
- 刷入自编译内核有变砖风险, 请确保有备份
- 建议先在解锁 Bootloader 的设备上测试
- 保留官方 boot.img 以便恢复

### 5. 合规说明
- OnePlus 内核源码遵循 GPLv2 许可证
- 本工具仅用于学习和研究目的
- 请遵守当地法律法规

---

## 🔧 故障排除

### Q: 构建失败, 提示 "protected exports" 错误
A: 工作流已自动处理, 如果本地编译遇到, 执行:
```bash
rm -f kernel_platform/common/android/abi_gki_protected_exports_*
rm -f kernel_platform/msm-kernel/android/abi_gki_protected_exports_*
```

### Q: 构建失败, 提示 clang 版本不对
A: 确保使用 manifest 中指定的预编译工具链:
```bash
export PATH="$PWD/prebuilts/clang/host/linux-x86/clang-r510928/bin:$PATH"
```

### Q: vmlinux 太大无法下载
A: 下载 `vmlinux-zst` 压缩版, 本地用 `zstd -d` 解压。

### Q: kallsyms.txt 是空的
A: 检查 vmlinux 是否包含符号:
```bash
file vmlinux  # 应该是 "not stripped"
nm vmlinux | wc -l  # 应该 > 0
```
如果 vmlinux 被 strip 了, 需要重新编译时不要添加 `strip` 选项。

### Q: GitHub Actions 构建超时
A: GitHub 免费 Runner 有 6 小时时限。首次构建约 1-2 小时, 不会超时。如果超时, 检查网络或减少 `-j` 并行度。

---

## 📚 参考资源

- [OnePlus OSS 内核源码](https://github.com/OnePlusOSS)
- [OnePlus kernel_manifest 仓库](https://github.com/OnePlusOSS/kernel_manifest)
- [Android Generic Kernel Image (GKI) 文档](https://source.android.com/docs/core/architecture/kernel/gki-android-common)
- [AnyKernel3 刷入工具](https://github.com/osm0sis/AnyKernel3)
- [参考构建脚本 (luyanci/op_ace6_kbuild)](https://github.com/luyanci/op_ace6_kbuild)

---

## 📄 许可证

- 构建脚本 (本仓库代码): MIT License
- OnePlus 内核源码: GPLv2 (归 OnePlus 所有)
- 预编译工具链: 遵循各自原始许可证
