# Xiaomi 14 (houji) · HyperOS 3 · SukiSU Ultra + KPM + SUSFS 内核

从 **stock OTA 提取内核基线**，自行编译并**持久刷入**一个可用的
`SukiSU Ultra + KPM + SUSFS` 内核的完整记录。

项目面向的是小米 14（`houji` / SM8650）在 HyperOS 3（Android 16 用户空间、
GKI `android14-11` 内核基线）上的定制内核构建。

---

## 结论速览

| 项目 | 结果 |
| --- | --- |
| 设备 | Xiaomi 14 `houji` / 23127PN0CC |
| ROM | `OS3.0.306.0.WNCCNXM`（Android 16 用户空间） |
| 内核基线 | `6.1.138-android14-11-g0c3d559bcd85-ab14529422` |
| 精确 ACK 提交 | `0c3d559bcd85c64dae9c9c9687abbe5347fff3ad` |
| KMI | Android 14 / 6.1，generation 11 |
| 最终内核 | SukiSU Ultra（KPM + SUSFS v2.3.0） |
| 开机验证 | `sys.boot_completed=1`，模块 494，root 可用 |

三个真正的关键点，其它都是弯路：

1. **`CONFIG_MODULE_SIG_PROTECT` 必须关闭** —— 否则内核不信任厂商签名模块，
   34 个 GKI 模块被拒，WiFi/蓝牙链断裂，`vendor.cnd` 崩溃循环，永远开不了机。
2. **SUSFS 的驱动侧要用 SukiSU 的 `builtin` 分支** —— 官方 SUSFS 补丁里的
   `10_enable_susfs_for_ksu.patch` 是给另一套 KernelSU 布局写的，对不上。
3. **刷写要保留原厂 AVB footer** —— 重新生成一张无签名 footer 会被 ABL 拒绝，
   必须像 AnyKernel3 那样就地替换内核负载。

详细分析见 [`docs/01-root-cause.md`](docs/01-root-cause.md)，
踩坑清单见 [`docs/02-pitfalls.md`](docs/02-pitfalls.md)。

---

## 目录

```
.
├── README.md                 本文
├── docs/
│   ├── 01-root-cause.md      根因分析（三个关键点）
│   ├── 02-pitfalls.md        踩坑与错误结论清单
│   ├── 03-build.md           从零构建
│   └── 04-flash.md           刷写、固化与回退
├── scripts/
│   ├── build-kernel.sh       配置改动 + 编译
│   ├── make-stale-boot.py    打包（保留原厂 footer）★
│   ├── repack-boot-v4.py     旧打包方式（会失败，仅作对照）
│   ├── compare-module-abi.py 与 stock 模块逐符号 CRC 校验
│   ├── cfgdiff.py            两份 .config 的语义差异
│   ├── flash-boot.sh         刷入内核
│   └── rollback.sh           回退到原厂
├── patches/
│   ├── 0001-disable-module-sig-protect.md
│   └── 0002-sukisu-susfs-post-execveat-stub.sh
└── configs/
    └── kernel-config-changes.md   与原厂配置的差异
```

---

## 快速开始

### 0. 依赖

```sh
# 构建
apt-get install -y curl                      # ★ SukiSU 版本号计算依赖它
# Android 工具
#   avbtool / magiskboot / fastboot / adb
# Python 辅助脚本
pip install pyelftools                       # compare-module-abi.py 需要
```

### 1. 准备

```sh
# 内核源码（纯 ACK）
git clone --filter=blob:none https://android.googlesource.com/kernel/common
git -C common checkout 0c3d559bcd85c64dae9c9c9687abbe5347fff3ad

# 工具链：官方 prebuilt clang（或系统 clang 亦可，见 docs/03-build.md）
# 关键：确保 curl 存在，否则 SukiSU 版本号会退化为 13000
```

### 2. 打补丁

```sh
# SukiSU 驱动用 builtin 分支（原生带 SUSFS）
git clone --depth 1 -b builtin https://github.com/SukiSU-Ultra/SukiSU-Ultra.git
rm -rf common/drivers/kernelsu
cp -R SukiSU-Ultra/kernel common/drivers/kernelsu
# drivers/Kconfig 增加:  source "drivers/kernelsu/Kconfig"
# drivers/Makefile 增加: obj-$(CONFIG_KSU) += kernelsu/

# 内核侧 SUSFS 补丁
git clone --depth 1 -b gki-android14-6.1 https://github.com/ShirkNeko/susfs4ksu.git
cp susfs4ksu/kernel_patches/fs/*             common/fs/
cp susfs4ksu/kernel_patches/include/linux/*  common/include/linux/
(cd common && patch -p1 -F3 < ../susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch)

# 补一个 fs/exec.c 需要的钩子（见 patches/0002）
```

### 3. 配置

以 stock 内嵌配置为基准，只改这几项（完整差异见
`configs/kernel-config-changes.md`）：

```
# CONFIG_MODULE_SIG_PROTECT is not set     ← 必须
CONFIG_KSU=y
CONFIG_KPM=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
```

### 4. 编译

```sh
make O=out ARCH=arm64 LLVM=1 LOCALVERSION= olddefconfig
make O=out ARCH=arm64 LLVM=1 LOCALVERSION= -j"$(nproc)" Image
```

### 5. 打包（关键）

**不要**用 `avbtool add_hash_footer` 生成新 footer：

```sh
# ✗ 这样刷进去会被 ABL 拒绝并回落到 fastboot
avbtool add_hash_footer --image boot.img --partition_name boot --partition_size 0x6000000
```

**要**保留原厂镜像的 footer，只替换内核负载：

```sh
python3 scripts/make-stale-boot.py \
    --stock stock-boot.img \
    --kernel out/arch/arm64/boot/Image \
    --output houji-sukisu-susfs-boot.img
```

### 6. 刷入

```sh
fastboot flash boot_a houji-sukisu-susfs-boot.img
fastboot set_active a          # 重要：清除可能残留的 unbootable 标记
fastboot reboot
```

`vbmeta` / `vbmeta_system` **保持原厂，不要动**。

---

## 许可与致谢

- [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra)（GPL-2.0）
- [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) / [ShirkNeko fork](https://github.com/ShirkNeko/susfs4ksu)
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3)（保留原厂 footer 的思路来源）
- Android Common Kernel、AOSP `avbtool`

本项目文档与脚本**不包含**任何厂商私有密钥或原厂镜像二进制，
只包含自己编写的脚本、配置差异与复现说明。
发布到 GitHub 前请自行选定许可证（SukiSU / susfs4ksu 均为 GPL-2.0，
若你的脚本衍生自它们，建议同样使用 GPL-2.0）。
