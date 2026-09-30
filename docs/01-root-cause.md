# 根因分析

整个项目遇到三类互不相关的问题。它们的表象都是“开不了机 / 起不来”，
但成因完全不同，必须分开看。

---

## 一、内核能启动却永远进不了系统 —— `CONFIG_MODULE_SIG_PROTECT`

### 现象

自编译内核能引导 Linux、ADB 可用、`/data` 正常挂载、大部分 vendor 模块能加载，
但开机动画永不结束，`sys.boot_completed` 一直为空。
对照测试：同一个 `boot.img` 用 `fastboot boot` 临时启动也一样；
而原厂内核放进同样的打包流程则完整开机。
模块数量始终是 **436**，而原厂是 **494**。

### 定位

拿到内核日志后（见下节“如何取日志”），关键两行是：

```
rfkill: exports protected symbol rfkill_alloc
modprobe: Failed to insmod '.../rfkill.ko' with args '': Permission denied
```

`EACCES`。顺着符号名找到实现：

```
kernel/module/gki_module.c
kernel/module/main.c:1283   pr_err("%s: exports protected symbol %s\n", ...)
kernel/module/Kconfig:134   config MODULE_SIG_PROTECT
```

机制是这样的：

- 厂商用私钥给所有模块签名，原厂内核内置对应公钥，因此 `mod->sig_ok = true`，
  这些检查直接放行。
- 我们自编译的内核拿不到厂商私钥，所有模块在它眼里都是“未签名”。
- 当 `CONFIG_MODULE_SIG_PROTECT=y` 时，内核禁止**未签名模块导出 KMI 符号**，
  也禁止未签名模块从已签名模块导入受保护符号。

于是 `system_dlkm` 里这批需要导出 KMI 符号的模块被整批拒绝：

```
rfkill  btqca  hci_uart  rfcomm  hidp  usbnet  r8152  ax88179_178a
usbserial  cdc_eem  ppp_generic  ppp_mppe  ppp_deflate  pptp  slhc
tipc  can  can-gw  can-dev  vcan  slcan  wwan  mii  libarc4
mac802154  ieee802154  ieee802154_6lowpan  ieee802154_socket
6lowpan  nhc_ipv6  nhc_mobility  nhc_udp  l2tp_core  l2tp_ppp
```

`rfkill` 缺失后，`cfg80211` 与 `btpower` 报 `Unknown symbol` 级联失败，
WiFi / 蓝牙 / 网络栈整片倒下，依赖它们的高通连接守护进程开始崩溃循环：

```
init: Service 'vendor.cnd' (pid 8137) received signal 6
init: process with updatable components 'vendor.cnd' exited 4 times before boot completed
```

再加上传感器等 HAL 起不来，`system_server` 始终走不完，于是永远停在开机动画。
34 个被拒模块 + 各自下游，正好对上少掉的 58 个。

### 修复

`CONFIG_MODULE_SIG_PROTECT` 是可选开关（`depends on MODULE_SIG && !MODULE_SIG_FORCE`）。
关闭后 `kernel/module/internal.h` 会用桩函数把两处检查短路：

```c
static inline bool gki_is_module_unprotected_symbol(const char *name) { return true; }
static inline bool gki_is_module_protected_export(const char *name) { return false; }
```

```
# CONFIG_MODULE_SIG_PROTECT is not set
```

改完重编，模块数回到 494，`Unknown symbol` 计数归零，完整开机。

> 上游 SUSFS 文档里其实也写了这一条（只是表述成“删除
> `android/abi_gki_protected_exports_aarch64`，否则 WiFi 之类模块不工作”），
> 两者是同一个机制的两面。
>
> 注意 `CONFIG_MODULE_SIG_PROTECT` 还依赖 `LOCALVERSION_AUTO`：
> 如果你为了固定内核版本字符串而关掉 `LOCALVERSION_AUTO`，
> `CONFIG_MODULE_SCMVERSION` 也会被连带关掉（它只影响 `scmversion` 信息字段，
> 与启动无关）。

### 如何取日志（在 user 版上）

user 版默认取不到 `dmesg`，`/proc/kallsyms` 也不可读。可用的办法：

1. 用 KernelSU/Magisk 修补 `init_boot`，得到 root；
2. root 下 `su -c dmesg` 就能拿到完整内核日志。

本项目正是靠这条通道拿到那 13k 行日志、进而定位到 `rfkill` 的。

内核**已经集成 KernelSU** 时，`init_boot` 里那个 LKM 版加载器
（`ksuinit`）会自动检测并跳过（日志里会打印
`KernelSU may be already loaded in kernel, skip!`），不会冲突。

---

## 二、SUSFS 驱动侧装不上 —— 用错分支

### 现象

内核侧 SUSFS 补丁（`50_add_susfs_in_gki-android14-6.1.patch`）对纯 ACK 树是
**干净应用**的；但驱动侧补丁 `10_enable_susfs_for_ksu.patch` 满屏 `.rej`，
手工修完又冒出成片编译错误：

```
sucompat.c: error: redefinition of 'su_path'
sucompat.c: error: use of undeclared identifier 'ksu_syscall_table'
syscall_event_bridge.c: error: invalid argument type 'struct static_key_true' to unary expression
core/init.c: error: call to undeclared function 'ksu_syscall_hook_manager_init'
```

### 定位

官方 SUSFS 补丁说明里写着：“所有 susfs 补丁主要基于**官方 KernelSU**”。
核对文件路径后确认：`10_enable_susfs_for_ksu.patch` 改的是
`kernel/core/`、`kernel/feature/`、`kernel/supercall/` 这套布局，
但内容是**老式 syscall table + kprobe** 架构，而 SukiSU Ultra 的 `main`
已经换成新的 inline hook 框架，所以结构性对不上。

真正的答案在 SukiSU Ultra 自己的构建流水线里：

```sh
curl -LSs https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh | bash -s builtin
```

传的是 **`builtin` 分支**。该分支的驱动**原生带 SUSFS**：

| 分支 | `kernel/Kconfig` 里 `KSU_SUSFS` | `supercall/dispatch.c` 中 susfs 引用 |
| --- | --- | --- |
| `builtin` | 19 处 | 53 处 |
| `main` | 0 | 0 |
| `susfs_new` | 0 | 0 |

所以正确做法是：**驱动直接换成 `builtin` 分支的 `kernel/`**，
内核侧 SUSFS 补丁照常打，**不要再打 `10_enable_susfs_for_ksu.patch`**。

### 还需要一个小补丁

`fs/exec.c` 被内核侧补丁插入了这样一段：

```c
#ifdef CONFIG_KSU_SUSFS
	if (unlikely(is_su_session))
		(void)ksu_handle_post_execveat_sucompat(&fd, &filename, &argv, &envp, &flags, &retval);
#endif
```

`builtin` 驱动提供的是 `ksu_handle_execveat_sucompat`（exec 前），没有 post 版本。
SukiSU 已经在 exec 前处理完 su 路径，因此补一个空实现即可，
见 [`../patches/0002-sukisu-susfs-post-execveat-stub.sh`](../patches/0002-sukisu-susfs-post-execveat-stub.sh)。

---

## 三、刷进去就掉 fastboot —— 不要重新生成 AVB footer

### 现象

- 同一个镜像用 `fastboot boot` **每次都能完整开机**；
- `fastboot flash boot_a` 之后从分区启动 → 直接回到 fastboot。

### 定位

对比两张镜像的 AVB 尾部：

```
原厂 boot.img : Algorithm SHA256_RSA2048, Rollback Index 1785542400
我们的 boot.img: Algorithm NONE,          Rollback Index 0
```

原厂 `vbmeta` 是 `Flags: 0`（校验开启），其中有一条 **Chain Partition 描述符
指向 `boot`**，要求 boot 的 vbmeta 由厂商公钥（sha1 `b2a02f1e…`）签名。
我们没有厂商私钥，只能生成 `Algorithm: NONE` 的 footer。

`fastboot boot` 是把镜像载入内存直接启动，**绕过链式校验**；
从分区启动则要过 ABL 的校验，没有有效签名的 boot 被拒 → 回落 fastboot。

排除了几种猜测：

- **回滚索引**：对齐成 `1785542400` 后照样失败，不是它。
- **AVB 整体关闭**：把原厂 vbmeta 的 flags 改成 2 —— 会**破坏它的签名**，
  设备连原厂内核都拒绝启动；用 `fastboot --disable-verity --disable-verification`
  同样会让原厂内核起不来。这两种做法在本题上都是错的。
- **compiler / 打包流程 / `hwid` / KVM 回退**：全部排除（见 pitfalls）。

### 修复

社区（AnyKernel3 那一套）的做法是：**不动 footer，只换内核负载**。
原厂 footer 的哈希虽然已经过期，但**签名仍然是厂商的**，因此能过链式校验。

```python
data = bytearray(open(stock_boot, "rb").read())
data[8:12] = len(kernel).to_bytes(4, "little")   # 更新 header 里的 kernel_size
data[4096:4096 + len(kernel)] = kernel           # 就地替换内核
open(out, "wb").write(bytes(data))
```

完整脚本见 [`../scripts/make-stale-boot.py`](../scripts/make-stale-boot.py)。

### 另一个必须知道的坑：槽会被标记 unbootable

一次启动失败后，ABL 会把该槽标记为不可启动：

```
(bootloader) slot-unbootable:a:yes
(bootloader) slot-successful:a:no
```

此后**所有刷写测试都不再尝试启动**，直接进 fastboot，
会让人误以为各种改动都无效。必须清除：

```sh
fastboot set_active a     # slot-unbootable 变 no，retry 计数重置
```

本项目中间有数轮“仍然失败”的结论，就是被这个标记污染的。

---

## 附：关于版本号 40900 / 40940 / 13000

SukiSU 的版本号不是常量，而是**算出来的**：

```make
VERSION_BASE   := 40000
VERSION_OFFSET := 2815
GITHUB_COMMITS := $(shell curl -sI ".../commits?sha=$(REPO_BRANCH)&per_page=1" | ...last page...)
LOCAL_COUNT    := $(if $(GITHUB_COMMITS),$(GITHUB_COMMITS),$(git_commit_count))
KSU_VERSION    := $(if $(LOCAL_COUNT),$(expr $(VERSION_BASE) + $(LOCAL_COUNT) - $(VERSION_OFFSET)),13000)
```

即 `40000 + main 分支提交数 - 2815`。

- 构建机没有 `curl`、又是浅克隆 → `LOCAL_COUNT` 为空 → **退化成兜底值 13000**。
  装个 `curl` 即可，会得到 40940。
- 发布的管理器 APK 是 `v4.2.0_40900`，40940 只比它多 40 个提交，属同一版本线。

更重要的是：**管理器判兼容看的是 UAPI，不是这个数字**。

| 来源 | `KERNEL_SU_UAPI_VERSION` |
| --- | --- |
| `builtin` 驱动 | 2 |
| 管理器 v4.2.0（40900） | 2 |
| `main`（40940，未发布） | 4 |

所以配 v4.2.0 管理器要用 `builtin` 驱动；反过来若用 `main`，反而会提示
“管理器版本过低”。
