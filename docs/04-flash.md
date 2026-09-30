# 刷写、固化与回退

前提：bootloader 已解锁（`ro.boot.verifiedbootstate=orange`）。

---

## 0. 先备份

至少保存这几张原厂镜像，回退时要用：

```
boot.img
init_boot.img
vbmeta.img
vbmeta_system.img
```

来源就是 OTA 包，无需从设备里读。

分区大小（本机实测，用 `fastboot getvar partition-size:xxx` 可复核）：

```
boot        0x6000000  (100663296)
init_boot   0x800000   (8388608)
vbmeta      0x20000    (131072)
vbmeta_system 0x20000  (131072)
```

---

## 1. 打包：保留原厂 footer

### 错误做法

```sh
avbtool add_hash_footer --image boot.img --partition_name boot \
        --partition_size 0x6000000
```

生成的是 `Algorithm: NONE` 的 footer。因为原厂 `vbmeta` 里有一条
**指向 `boot` 的 Chain Partition 描述符**，要求 boot 的 vbmeta 由厂商公钥签名，
所以这张镜像**刷进分区后会被 ABL 拒绝**，设备回落 fastboot。
（`fastboot boot` 因为绕过链式校验，反而能启动，特别容易误导。）

对齐 `Rollback Index` 也没用，问题在签名。

### 正确做法

**不动 footer，只替换内核负载**：

```sh
python3 scripts/make-stale-boot.py \
    --stock  stock-boot.img \
    --kernel out/arch/arm64/boot/Image \
    --output houji-sukisu-susfs-boot.img
```

脚本做的事：

1. 读入原厂 `boot.img`（已含 footer）；
2. 把 header 偏移 8 处的 `kernel_size` 改成新内核长度；
3. 从偏移 4096 起就地写入新内核；
4. 原封不动写回，**保留原厂 footer 与填充**。

原厂 footer 的哈希此时已过期，但**签名仍是厂商的**，
所以能通过链式校验——这正是 AnyKernel3 之类的刷机包能工作的原因。

---

## 2. 刷入

```sh
adb reboot bootloader

fastboot flash boot_a houji-sukisu-susfs-boot.img
fastboot set_active a        # ★ 见下节
fastboot reboot
```

A/B 设备上刷 `boot_a` 只影响当前槽；建议保留另一槽不动，多一层退路。

### ★ 为什么一定要 `set_active`

只要有一次启动失败，ABL 就会把该槽标记为不可启动：

```
(bootloader) slot-unbootable:a:yes
(bootloader) slot-successful:a:no
```

之后所有启动尝试都会**直接进 fastboot**，不再真正尝试启动。
这会让后续每一次测试都“看起来失败”，得出完全错误的结论。

```sh
fastboot getvar slot-unbootable:a   # 检查
fastboot set_active a               # 清除（retry 计数也会重置）
```

**每次失败重启后，先清标记，再判断结果。**

---

## 3. 验证

```sh
adb shell getprop sys.boot_completed      # 期望 1
adb shell uname -a                        # 应是你的编译时间
adb shell su -c id                        # uid=0(root) context=u:r:ksu:s0
adb shell su -c lsmod | wc -l             # 本机约 494
adb shell su -c dmesg | grep -i 'susfs is initialized'
```

本机实测输出：

```
Linux ... #4 SMP PREEMPT Thu Oct  1 04:44:26 CST 2026
uid=0(root) gid=0(root) groups=0(root) context=u:r:ksu:s0
494
susfs:[0][1][susfs_init] susfs is initialized! version: v2.3.0
KernelSU: load_allow_uid, name: com.sukisu.ultra, uid: 10533, allow: 1
```

---

## 4. 关于 `vbmeta` / `init_boot`

### `vbmeta`：不要动

本项目最终方案**不需要修改 `vbmeta`**。

以下做法在本设备上都被证实有害，不要用：

| 做法 | 结果 |
| --- | --- |
| 手工改 `vbmeta` flags 字段 | 破坏其签名，**连原厂内核都起不来** |
| `fastboot --disable-verification ... flash vbmeta` | 同上，原厂内核也起不来 |
| `fastboot --disable-verity ... flash vbmeta` | 单独用是安全的，但**不解决问题** |

（若确实需要，务必先备份 `vbmeta` / `vbmeta_system`，出事立刻刷回。）

### `init_boot`：可选

`init_boot` 不是必须改的。两种典型做法：

- **原厂 `init_boot`**：内核里已集成 SukiSU，root 由内核提供，最干净。
- **KernelSU/Magisk 修补版 `init_boot`**：提供 LKM 形式的 root，
  方便在内核出问题时仍能拿到 root 和 `dmesg`。

两者可以共存：内核内已集成 KernelSU 时，`init_boot` 里的 `ksuinit`
会检测并跳过（日志会打印 `KernelSU may be already loaded in kernel, skip!`）。

> 注意 `init_boot` 本身**没有**链式校验（原厂 `vbmeta` 只对
> `boot`/`recovery`/`vbmeta_system` 建了链），所以修补后可以直接刷入。

---

## 5. 回退到原厂

```sh
adb reboot bootloader

fastboot flash boot_a        stock-boot.img
fastboot flash init_boot_a   stock-init_boot.img
fastboot flash vbmeta        stock-vbmeta.img          # 如果你动过
fastboot flash vbmeta_system stock-vbmeta-system.img   # 如果你动过

fastboot set_active a
fastboot reboot
```

日常只回退内核的话，第一行加最后两行就够了。

---

## 6. 常见现象速查

| 现象 | 多半是 |
| --- | --- |
| `fastboot boot` 能进系统，刷入后掉 fastboot | 用了重新生成的 AVB footer |
| 改完 vbmeta 后连原厂内核都起不来 | 破坏了 vbmeta 签名 |
| 反复刷、反复“失败”，但现象一模一样 | 槽被标记 `unbootable`，没 `set_active` |
| 能开机但卡在开机动画（`boot_completed` 空） | `CONFIG_MODULE_SIG_PROTECT` 没关 |
| 模块数明显少于原厂（如 436 vs 494） | 同上，模块被策略拒绝 |
| 版本号显示 13000 | 构建机缺 `curl` 且浅克隆 |
