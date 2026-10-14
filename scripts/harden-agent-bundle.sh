#!/usr/bin/env bash
# 给 Hermes Agent 离线 bundle 预置「更新通道」git 元数据。
#
# 背景（2026-10-14 根因，实测复现）：
#   FPK 离线 bundle 的 .git 只做了 git init + commit，没有 remote / tracking refspec。
#   安装到 NAS 后 `hermes update` 直接失败：
#     ✗ Failed to fetch updates from origin.
#       fatal: 'origin' does not appear to be a git repository
#   内核因此永远无法跟随上游（更新通道在已装实例上是断的）。
#
#   另外两处配套修复（均为实测结论）：
#   - core.filemode=false：fnOS 安装脚本 chmod -R 755 会让 ~1.5 万个文件出现
#     mode 变化、被当成 dirty，每次 update 都要 stash 一大堆假改动；
#   - 分支统一 main + .git/shallow 标记：官方 install.sh 的 clone 形态就是 depth-1
#     shallow（update 走 --depth 1 小增量，实测 84MB），且 update 默认目标是 main
#     分支（停在 master 会被 parked-branch 守卫跳过更新）。不打 shallow 标记时
#     首次 update 要全量 fetch（实测 1GB+，NAS 上 40 分钟都拉不完）。
#
# 幂等：只补缺失项，重复执行无副作用。
#
# 用法: harden-agent-bundle.sh <agent-src-dir>
set -uo pipefail

SRC="${1:?用法: $0 <agent-src-dir>}"
[ -d "$SRC/.git" ] || { echo "WARNING: $SRC/.git 不存在，跳过更新通道预置"; exit 0; }

cd "$SRC" || exit 1

# 1) origin remote + tracking refspec（update 的 fetch 需要写 origin/main；
#    缺 refspec 时 `git fetch origin main` 只写 FETCH_HEAD，update 找不到 origin/main）
git remote get-url origin >/dev/null 2>&1 || \
    git remote add origin "https://github.com/NousResearch/hermes-agent.git"
git config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'

# 2) 忽略 mode 变化（fnOS chmod -R 755 会把全树打成 dirty）
git config core.filemode false

# 3) 分支统一为 main（update 默认目标；master 会触发 parked-branch 守卫跳过）
cur="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
if [ "$cur" = "master" ] && ! git show-ref --verify --quiet refs/heads/main; then
    git branch -m main
fi

# 4) shallow 标记：单提交孤儿 bundle → 与官方 depth-1 clone 同形态
if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" != "true" ]; then
    if [ "$(git rev-list --count HEAD 2>/dev/null || echo 0)" = "1" ]; then
        git rev-parse HEAD > .git/shallow
        echo "已标记 shallow（单提交 bundle）"
    fi
fi

echo "bundle 更新通道就绪: origin=$(git remote get-url origin 2>/dev/null) | refspec=$(git config remote.origin.fetch) | filemode=$(git config core.filemode) | branch=$(git symbolic-ref --short HEAD 2>/dev/null) | shallow=$(git rev-parse --is-shallow-repository)"
