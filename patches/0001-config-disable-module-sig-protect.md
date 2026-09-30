# 0001 · 关闭 `CONFIG_MODULE_SIG_PROTECT`

这是整个项目**最关键的一处改动**。没有它，自编译内核能引导 Linux、
能挂载 `/data`、能起 ADB，但永远停在开机动画。

详见 [`../docs/01-root-cause.md`](../docs/01-root-cause.md) 第一节。

---

## 改动

在内核 `.config` 中：

```
# CONFIG_MODULE_SIG_PROTECT is not set
```

（原厂是 `CONFIG_MODULE_SIG_PROTECT=y`。）

## 为什么

原厂所有模块都用厂商私钥签名，原厂内核内置对应公钥，因此
`mod->sig_ok = true`，GKI 的符号保护直接放行。

我们自编译的内核拿不到那把私钥，所有模块都被判定为“未签名”。
此时 `CONFIG_MODULE_SIG_PROTECT=y` 会让内核：

1. 拒绝未签名模块**导出** KMI 符号
   （`kernel/module/main.c`: `exports protected symbol ...` → `-EACCES`）；
2. 拒绝未签名模块从已签名模块**导入**受保护符号。

`system_dlkm` 里 34 个模块因此被整批拒绝，其中包括 `rfkill.ko`。
`rfkill` 缺失导致 `cfg80211` / `btpower` 级联失败，WiFi / 蓝牙 / 网络栈崩塌，
高通连接守护进程 `vendor.cnd` 进入崩溃循环，`system_server` 永远走不完。

关闭该开关后，`kernel/module/internal.h` 会用桩函数把两处检查短路：

```c
#else  /* !CONFIG_MODULE_SIG_PROTECT */
static inline bool gki_is_module_unprotected_symbol(const char *name) { return true; }
static inline bool gki_is_module_protected_export(const char *name) { return false; }
#endif
```

## 等价做法

上游 SUSFS 的文档给了另一种等价表述：

> For gki kernel android14 or above ... it is necessary to delete
> `android/abi_gki_protected_exports_aarch64` ... otherwise some modules
> like WiFi will not work.

即删除“受保护导出”名单，让 `gki_is_module_protected_export()` 永远匹配不到。
两种方式效果一致；本项目选择关配置开关，改动更小、也更容易复核。

## 验证

```
# 模块数应回到 494（修复前是 436）
adb shell su -c lsmod | wc -l

# 内核日志里不应再有：
adb shell su -c dmesg | grep -c 'Unknown symbol'            # 期望 0
adb shell su -c dmesg | grep -c 'exports protected symbol'  # 期望 0

# 且 rfkill 必须有依赖者
adb shell su -c lsmod | grep '^rfkill'                      # 形如 ... 4 btpower,cfg80211,nfc,bluetooth
```
