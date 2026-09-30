# 踩坑清单

按“错误结论 → 为什么错”的形式记录。这部分和根因分析同样重要：
本次大部分时间花在验证并推翻这些假设上，写下来可以避免后来者重走。

---

## 一、被证伪的技术假设

### 1. `drivers/misc/hwid` 源码缺失导致无法启动

**假设**：小米开源包里 `drivers/misc/Kconfig` 引用了 `drivers/misc/hwid/Kconfig`，
但目录没发布，所以编出来的内核缺东西。

**实际**：`hwid` 是 **vendor 侧模块**（`hwid.ko`，存在于 vendor 镜像里），
在我们的内核上加载正常，`lsmod` 里能看到它被 9 个模块依赖：

```
hwid  24576  9  qca_cld3_kiwi_v2,msm_eva,icss2,cnss2,...,ufs_qcom
```

原厂 GKI 启动内核的配置里**根本没有 `CONFIG_MI_HARDWARE_ID`**。
缺失的开源源码不影响启动。（简单说：`source` 一个不存在的 Kconfig 是空操作，
那份 `Makefile` 里的 `obj-$(CONFIG_MI_HARDWARE_ID)` 也不会展开。）

### 2. KVM / pKVM 回退补丁导致启动失败

**假设**：merge 进树的后期 KVM/pKVM 改动与 stock 行为不一致。

**实际**：专门做了一版“回退 KVM 改动”的控制内核（`nokvm`），
结果与普通版**完全一样**地卡在开机动画。
反证：社区 AngelBeats 用 6.1.158（更新的内核、包含全部 KVM 特性）能完整开机。

### 3. 编译器版本不对（原厂 clang 17.0.2 vs 我们的 18/20）

**假设**：GKI 内核必须用原厂那套 Android clang 构建。

**实际**：最终**可开机、可用**的成就是用 **Ubuntu clang 18.1.3** 编出来的。
而且 v17/v18/v20 三种版本此前都失败过——因为它们**都带着
`CONFIG_MODULE_SIG_PROTECT=y`**。

顺带一提：Google 的 prebuilt clang 是 **x86_64** 的，在 ARM64 的
Linux 虚拟机里根本跑不起来（`Exec format error`），这条路本身也不通。

### 4. ACK + MiCode 合并树 / 纯 ACK 树的选择

中间试过把 MiCode 的 `shennong-u-oss` 树与 ACK 6.1.138 做 merge 再构建，
也试过纯 ACK。两者表现一致——都不是根因。
最终确定：**纯 ACK + stock 配置 + 三处改动** 即可，不需要合并厂商树。

### 5. 打包流程有问题

**假设**：我们的 `boot.img` 打包（header/AVB）不对。

**实际**：把**原厂内核**放进我们的打包流程，`fastboot boot` 完整开机、
494 个模块全加载，说明打包本身没问题。
真正的问题只在“重新生成 AVB footer”这一步（见 `01-root-cause.md` 第三节）。

---

## 二、AVB / 刷写相关的坑（最容易反复踩）

### 1. 改原厂 vbmeta 的 flags 字段

想用“把 flags 改成 2（关闭校验）”来绕过 boot 的链式校验。
`avbtool info_image` 读出来确实是 `Flags: 2`，看起来成功了，但：

- 改 flags 会**破坏 vbmeta 自身的小米签名**；
- 带 key 却验签失败的 vbmeta 会被直接拒绝——
  **连原厂 boot 都起不来**，一样掉 fastboot。

> 另外 AVB 头部字段是**大端**。我第一次按小端写了 u32，
> 结果 `2` 落到了高位字节变成 `0x02000000`，
> `avbtool` 读出来是 `Flags: 33554432`——等于啥也没关。
> 验证 offsets 的可靠办法：用 `avbtool make_vbmeta_image --flags 0/2`
> 生成两张对照图，直接 diff 找差异字节。

### 2. `--disable-verity` 和 `--disable-verification` 不是一回事

```sh
fastboot --disable-verity flash vbmeta vbmeta.img                 # 只关 dm-verity(hashtree)
fastboot --disable-verity --disable-verification flash vbmeta …   # 再关 vbmeta 签名校验
```

在这台机器上：

- **只加 `--disable-verity`**：原厂内核仍能正常开机（安全）。
- **两个一起加**：**原厂内核也起不来**，直接掉 fastboot。

所以这个选项组合在本设备上不可用。最终方案完全不需要动 vbmeta。

### 3. 槽被标记 `unbootable` 会污染所有后续测试

```
(bootloader) slot-unbootable:a:yes
(bootloader) slot-successful:a:no
```

一次启动失败后，ABL 就不再尝试启动该槽，**直接进 fastboot**。
此时无论你改什么、刷什么，现象都是“还是 fastboot”，
会让人得出完全错误的结论。

**每次启动失败后都要执行**：

```sh
fastboot set_active a
```

### 4. 回滚索引（Rollback Index）不是原因

把 footer 的 `Rollback Index` 对齐成原厂 `1785542400` 后，
从分区启动**依旧失败**。真正的问题是签名，不是回滚。

---

## 三、SUSFS 集成相关的坑

### 1. 直接用 `10_enable_susfs_for_ksu.patch`

该补丁面向官方 KernelSU（老式 syscall table + kprobe 架构），
对 SukiSU Ultra 的 `main` 分支结构性不兼容，会产生成片 `.rej` 和编译错误。
**正确做法是换用 SukiSU 的 `builtin` 分支驱动**，不要再打这个补丁。

### 2. 追 `.rej` 陷阱

`patch` 在“已应用/反向应用”时会写 `.rej`，这些 `.rej` 并不一定代表真的失败。
更坑的是：如果重复应用同一补丁，第二次会把“已应用”的 hunk 全部记成 `.rej`，
看起来像大面积失败。判断真实状态要看**源码里的集成点**（例如 Kconfig 是否有
`KSU_SUSFS`、函数是否被调用），而不是数 `.rej` 个数。

### 3. `git checkout <sha> -- <dir>` 可能什么都没做

如果目标目录**不在那个提交里**（例如被 `.gitignore` 忽略、从未 `git add` 成功），
`git checkout` 不会恢复任何东西，但你可能以为已回滚。
本项目因此一度在“已回滚”的错觉上排查了很久。

### 4. 版本号变成 13000

见 `01-root-cause.md` 附录。原因是构建机缺 `curl` + 浅克隆，
导致 `KSU_VERSION` 走了兜底值。装 `curl` 即可。

---

## 四、环境与工具链上的坑

### 1. Android user 版拿不到内核日志

- `adb shell dmesg` → `klogctl: Permission denied`
- `/proc/kallsyms` → `Permission denied`
- `/proc/config.gz` 不存在
- logd 也没开 `ro.logd.kernel`

解决办法是用 KernelSU/Magisk 修补 `init_boot` 拿到 root，再 `su -c dmesg`。

### 2. `pstore` / ramoops 可以作为兜底

设备启动了 `ramoops`（`pstore: Registered ramoops as persistent store backend`），
崩溃/异常重启的内核日志可能留在 `/sys/fs/pstore/console-ramoops-*`，
root 下可读。是排查“启动失败（内核根本没跑起来）时的最后现场”的手段。

### 3. 用 `prlctl exec` 操作 Parallels 虚拟机

- **参数会被拼成一行**交给 guest shell，引号会被吞。
  正确姿势是把整条命令作为**单个参数**传入。
- **命令长度有上限**：脚本稍大（约 4KB 以上）就会报
  `PrlJob_GetResult: Invalid argument`。工程做法：本地把脚本 `base64`，
  用一条短命令解码落盘再执行。
- 虚拟机上跑 **x86_64 的 Google prebuilt clang** 会 `Exec format error`。

### 4. 虚拟机没有 `curl`

影响两处：SukiSU 版本号计算（见上），以及很多构建脚本假设 `curl` 存在。
`apt-get install -y curl` 解决。

### 5. 共享目录看不到某些 Mac 路径

Parallels 的共享目录对 `~/Documents` 等受保护路径可能不可见，
读不到工作目录里的文件。传文件用「Mac 起 HTTP 服务、虚拟机 `urllib` 拉取」
最稳；反向则让虚拟机起 HTTP 服务。

---

## 五、判断问题归属的通用顺序

本项目最后收敛出的排查顺序，供参考：

1. **先确认打包链路**：把原厂内核塞进自己的打包流程，能开机就说明打包没问题。
2. **再确认源码与配置**：配置做**语义比对**（不是文本 diff），
   只保留真正取值不同的项。
3. **拿日志**：user 版上先想办法拿到 `dmesg`，否则一切推断都是猜。
4. **区分“从内存启动”与“从分区启动”**：
   `fastboot boot` 成功 ≠ 刷入后能启动。
5. **区分“内核起不来”与“ABL 拒绝启动”**：
   看 `fastboot getvar slot-unbootable:*`。
