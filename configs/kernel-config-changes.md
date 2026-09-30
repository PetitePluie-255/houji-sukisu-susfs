# 与原厂内核配置的差异

基准：从 OTA 的 `boot.img` 中提取的内嵌配置（IKCONFIG）。
对比对象：最终可工作的 `out/.config`。

比对方式（语义比对，忽略“符号在某棵树里不存在”造成的噪声）：

```sh
python3 scripts/cfgdiff.py stock-kernel.config out/.config
```

---

## 汇总

```
common symbols = 6001    differing = 8
only in stock  = 1
only in ours   = 15
```

也就是说，**真正需要改的只有一项**：`CONFIG_MODULE_SIG_PROTECT`。
其余全部是编译器版本字符串、内核版本字符串，以及新增的 KernelSU/SUSFS 选项。

---

## 一、取值不同（8 项）

```
CONFIG_CC_VERSION_TEXT
    stock = "Android (10087095, +pgo, +bolt, +lto, -mlgo, based on r487747c) clang version 17.0.2 ..."
    ours  = "Ubuntu clang version 18.1.3 (1ubuntu1)"
CONFIG_CLANG_VERSION       stock = 170002   ours = 180103
CONFIG_AS_VERSION          stock = 170002   ours = 180103
CONFIG_LLD_VERSION         stock = 170002   ours = 180103
CONFIG_PAHOLE_VERSION      stock = 123      ours = 125

CONFIG_LOCALVERSION        stock = ""       ours = "-android14-11-g0c3d559bcd85-ab14529422"
CONFIG_LOCALVERSION_AUTO   stock = y        ours = n

CONFIG_MODULE_SIG_PROTECT  stock = y        ours = n      ← ★ 成败关键
```

说明：

- 四个编译器版本项是必然差异，与启动无关（本项目验证过 clang 17/18/20，
  在 `MODULE_SIG_PROTECT` 修复后都能正常工作）。
- `LOCALVERSION` 是刻意固定的：为了和原厂模块的 vermagic 完全一致。
  原厂是 `LOCALVERSION=""` + `LOCALVERSION_AUTO=y`，靠 git 描述得到
  `...-g0c3d559bcd85`，再由 Android 构建系统追加 `-ab14529422`。
  我们直接写死整串。

---

## 二、仅存在于原厂配置（1 项）

```
CONFIG_MODULE_SCMVERSION=y
```

它 `depends on LOCALVERSION_AUTO`，被上面那条改动连带关掉。
它只影响模块的 `scmversion` 信息字段（`modinfo` / `/sys/modules/*/scmversion`），
**与启动和 ABI 无关**。

---

## 三、仅存在于我们配置（15 项）

```
CONFIG_KSU=y
CONFIG_KSU_DEBUG=n
CONFIG_KSU_FEATURE_ADBROOT=y
CONFIG_KPM=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_PAHOLE_HAS_LANG_EXCLUDE=y
```

这些符号在原厂 GKI 内核的 Kconfig 里根本不存在，所以是“仅存在于 B”。
其中 KernelSU/SUSFS 相关项由 `builtin` 分支驱动与内核侧 SUSFS 补丁引入。

> `CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT`、
> `CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT`、
> `CONFIG_KSU_SUSFS_TRY_UMOUNT`、
> `CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT`
> 为默认开启项，未出现在 diff 中。

---

## 四、保持不变的关键项（供核对）

以下项曾一度被怀疑，实测与原厂一致，无需改动：

```
CONFIG_CFI_CLANG=y
CONFIG_SHADOW_CALL_STACK=y
CONFIG_LTO_NONE=y            # 原厂也没用 LTO
CONFIG_MODULE_SIG=y
# CONFIG_MODULE_SIG_FORCE is not set
CONFIG_DEBUG_INFO_BTF=y
CONFIG_TRIM_UNUSED_KSYMS=y
CONFIG_UNUSED_KSYMS_WHITELIST="abi_symbollist.raw"
CONFIG_ARM64_4K_PAGES=y
CONFIG_ARM64_VA_BITS=39
CONFIG_GUNYAH=y
CONFIG_GUNYAH_PLATFORM_HOOKS=y
# CONFIG_GUNYAH_QCOM_PLATFORM is not set
CONFIG_KPROBES=y
CONFIG_EXT4_FS=y
```
