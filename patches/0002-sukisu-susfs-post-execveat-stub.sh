#!/bin/bash
# 0002 · 给 SUSFS 的内核侧钩子补一个空实现
#
# 内核侧 SUSFS 补丁（50_add_susfs_in_gki-android14-6.1.patch）会在 fs/exec.c
# 里插入：
#
#     #ifdef CONFIG_KSU_SUSFS
#         if (unlikely(is_su_session))
#             (void)ksu_handle_post_execveat_sucompat(&fd, &filename, &argv, &envp, &flags, &retval);
#     #endif
#
# 但 SukiSU 的 builtin 驱动只提供 exec 之前的 ksu_handle_execveat_sucompat，
# 没有 post 版本，直接编译会链接失败：
#
#     ld.lld: error: undefined symbol: ksu_handle_post_execveat_sucompat
#
# SukiSU 已经在 exec 之前处理完 su 路径，因此这里补一个返回 0 的空实现即可。
#
# 用法：
#   ./0002-sukisu-susfs-post-execveat-stub.sh /path/to/common
set -euo pipefail

SRC=${1:?用法: $0 <kernel-tree>}
SUCOMPAT=$SRC/drivers/kernelsu/feature/sucompat.c

[ -f "$SUCOMPAT" ] || { echo "找不到 $SUCOMPAT" >&2; exit 1; }

if grep -q 'ksu_handle_post_execveat_sucompat' "$SUCOMPAT"; then
  echo "已经存在，跳过"
  exit 0
fi

cat >> "$SUCOMPAT" <<'EOF'

#ifdef CONFIG_KSU_SUSFS
/*
 * SUSFS 的内核侧补丁在 fs/exec.c 里引用了这个函数。
 * SukiSU 在 ksu_handle_execveat_sucompat() 中已经完成 exec 前的 su 路径处理，
 * 因此 post 阶段无需额外动作，仅用于满足引用。
 */
int ksu_handle_post_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv,
                                      void *envp, int *flags, int *retval)
{
    return 0;
}
#endif
EOF

echo "已写入 $SUCOMPAT"
