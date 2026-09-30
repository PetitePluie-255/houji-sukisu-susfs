# 从零构建

以下命令在 **ARM64 Linux** 上验证通过（Ubuntu 24.04 ARM64 虚拟机，
系统 clang 18.1.3）。宿主架构不影响结论，但注意 Google 的 prebuilt clang
是 x86_64 的，在 ARM64 上无法直接执行。

---

## 0. 取得内核基线信息

从设备的 OTA 包里拿 `boot.img` 与 `vendor_boot.img`，然后：

```sh
# 内核版本字符串 / KMI / 编译器
strings boot-kernel | grep -m1 'Linux version'

# 启动头（本机为 v4，页大小 4096，boot 内 ramdisk 为空）
python3 - <<'PY'
import struct
head = open("boot.img","rb").read(4096)
print("magic      ", head[:8])
print("kernel_size", struct.unpack_from("<I", head, 8)[0])
print("ramdisk_sz ", struct.unpack_from("<I", head, 12)[0])
print("header_ver ", struct.unpack_from("<I", head, 40)[0])
PY

# 内嵌的完整内核配置（IKCONFIG）
python3 scripts/extract-ikconfig.py boot-kernel > stock-kernel.config
```

本项目得到：

```
6.1.138-android14-11-g0c3d559bcd85-ab14529422
```

即 ACK `android14-6.1` 的 `0c3d559bcd85c64dae9c9c9687abbe5347fff3ad`，
KMI generation 11。

---

## 1. 源码

```sh
git clone --filter=blob:none https://android.googlesource.com/kernel/common.git
git -C common checkout 0c3d559bcd85c64dae9c9c9687abbe5347fff3ad
```

**用纯 ACK 即可**，不需要合并厂商树。

---

## 2. SukiSU 驱动（用 `builtin` 分支）

```sh
git clone --depth 1 -b builtin https://github.com/SukiSU-Ultra/SukiSU-Ultra.git

rm -rf common/drivers/kernelsu
cp -R SukiSU-Ultra/kernel common/drivers/kernelsu

grep -q 'drivers/kernelsu/Kconfig' common/drivers/Kconfig || \
  printf '\nsource "drivers/kernelsu/Kconfig"\n' >> common/drivers/Kconfig

grep -q 'kernelsu' common/drivers/Makefile || \
  printf 'obj-$(CONFIG_KSU) += kernelsu/\n' >> common/drivers/Makefile
```

> `builtin` 分支的 `kernel/Kconfig` 里已经带有 19 个 `KSU_SUSFS` 选项，
> 以及 `KPM`。这是它和 `main` 的关键区别。

---

## 3. 内核侧 SUSFS 补丁

```sh
git clone --depth 1 -b gki-android14-6.1 https://github.com/ShirkNeko/susfs4ksu.git

cp susfs4ksu/kernel_patches/fs/*            common/fs/
cp susfs4ksu/kernel_patches/include/linux/* common/include/linux/

( cd common && patch -p1 -F3 < \
    ../susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch )
```

这个补丁对**纯 ACK 树**是干净应用的（改动 `fs/`、`selinux/`、`mm/`、
`kernel/`、`drivers/input/` 等）。

**不要**再打 `kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch`。

### 3.1 补一个空实现

`fs/exec.c` 会引用 `ksu_handle_post_execveat_sucompat`，
`builtin` 驱动没有它（SukiSU 在 exec 前就处理完了 su 路径）。
在 `common/drivers/kernelsu/feature/sucompat.c` 末尾追加：

```c
#ifdef CONFIG_KSU_SUSFS
int ksu_handle_post_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv,
                                      void *envp, int *flags, int *retval)
{
    return 0;
}
#endif
```

---

## 4. 配置

以 stock 内嵌配置为基准，只改这几项：

```
# CONFIG_MODULE_SIG_PROTECT is not set
CONFIG_KSU=y
CONFIG_KPM=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
```

`CONFIG_MODULE_SIG_PROTECT` 是**成败关键**，原因见 `01-root-cause.md`。

---

## 5. 编译

```sh
cp stock-kernel.config out/.config
make O=out ARCH=arm64 LLVM=1 LOCALVERSION= olddefconfig

# 确认改动生效
grep -E '^CONFIG_(KSU|KPM|KSU_SUSFS)=' out/.config
grep -E '^# CONFIG_MODULE_SIG_PROTECT' out/.config

make O=out ARCH=arm64 LLVM=1 LOCALVERSION= -j"$(nproc)" Image
strings out/arch/arm64/boot/Image | grep -m1 'Linux version'
```

### 两个容易被忽略的前置条件

**a) 装上 `curl`。** SukiSU 的 `kernel/Makefile` 通过 GitHub API 计算版本号，
没有 `curl` 且没有 git 历史时会退化成 `13000`：

```sh
apt-get install -y curl
# 构建日志里应看到:  -- SukiSU-Ultra version: 40940 [v4.2.0-...]
```

**b) `LOCALVERSION`。** 为保证模块 vermagic 与原厂一致，
用 `LOCALVERSION=` 传空值，并在配置里把内核版本字符串固定为原厂那串：

```
CONFIG_LOCALVERSION="-android14-11-g0c3d559bcd85-ab14529422"
# CONFIG_LOCALVERSION_AUTO is not set
```

> 副作用：`CONFIG_MODULE_SCMVERSION` 依赖 `LOCALVERSION_AUTO`，
> 会被连带关掉。它只影响 `scmversion` 信息字段，与启动无关。

---

## 6. 编译后校验（强烈建议）

把新内核的导出符号 CRC 与 `vendor_boot` / `vendor_dlkm` / `system_dlkm`
里所有模块逐一比对：

```sh
python3 scripts/compare-module-abi.py out/Module.symvers <modules-dir>
```

期望结果：

```json
{ "module_count": 340, "mismatched_symbol_count": 0, "unresolved_symbol_count": 0 }
```

这一步只能证明 **ABI 层面**兼容，不能证明运行期行为正确——
`rfkill` 那次就是 ABI 全过但运行期被策略拒绝的典型例子。

配置层面的比对用 `scripts/cfgdiff.py`（语义比对，忽略缺失符号造成的噪声）：

```sh
python3 scripts/cfgdiff.py stock-kernel.config out/.config
```

---

## 7. 打包

见 `04-flash.md`。一句话：**保留原厂 footer，只换内核负载**。
