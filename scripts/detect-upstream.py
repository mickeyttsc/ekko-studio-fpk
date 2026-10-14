#!/usr/bin/env python3
"""判定上游「可打包版本」并输出校验值。

用法:
    python3 scripts/detect-upstream.py webui   # 打印最新可打包的 hermes-web-ui 版本号
    python3 scripts/detect-upstream.py agent   # 打印 hermes-agent 最新 release 标签
    python3 scripts/detect-upstream.py sha256 <version>   # 打印该版本资产的 sha256
    python3 scripts/detect-upstream.py selftest           # 无网络回归自检（标签过滤器行为契约）

设计依据（都是踩过的坑）：
  1. 上游 release 线被官方显式标记为非 latest，不能取 releases/latest，
     必须自行过滤版本标签（^v\\d+\\.\\d+\\.\\d+$）并按 published_at 取最新。
  2. 同一仓库还会发手机端 release（如 v1.0.4 只含 .apk）—— 必须按
     「是否带 hermes-web-ui-<ver>.tar.gz 资产」过滤，否则手机端版本会抢先
     入选、再因缺少预构建产物校验失败而中止整天更新。
  3. 「可打包版本」必须同时存在产物与 <asset>.sha256 sidecar；只发产物不发
     sha256 的版本不作为自动更新目标 —— 否则构建会回退 npm，或静默放过一个
     未校验的包。
  4. 所有 api.github.com 调用必须带 Authorization：Actions runner 出口 IP 为
     GitHub 全平台共享，未鉴权走 60 次/小时的 IP 级配额，常被其它仓库耗尽 →
     403 → JSON 解析失败 → 「同步上游」静默失效。
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

WEBUI_REPO = "EKKOLearnAI/ekko-studio"
AGENT_REPO = "NousResearch/hermes-agent"
API = "https://api.github.com"


def _get(url, raw=False, timeout=60):
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/vnd.github.raw" if raw else "application/vnd.github+json")
    req.add_header("User-Agent", "ekko-studio-fpk-detect")
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        req.add_header("Authorization", "token %s" % token)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def latest_webui_version():
    """返回最新「带 hermes-web-ui-<ver>.tar.gz 资产」的版本号（无 v 前缀）。"""
    data = json.loads(_get("%s/repos/%s/releases?per_page=100" % (API, WEBUI_REPO)))
    cands = []
    for r in data:
        if r.get("prerelease") or r.get("draft"):
            continue
        tag = r.get("tag_name", "")
        if not re.match(r"^v\d+\.\d+\.\d+$", tag):
            continue
        ver = tag.lstrip("v")
        names = {a.get("name", "") for a in r.get("assets", [])}
        # 产物 + sha256 sidecar 必须同时存在，才算「可打包版本」
        if ("hermes-web-ui-%s.tar.gz" % ver) in names and (
            "hermes-web-ui-%s.tar.gz.sha256" % ver
        ) in names:
            cands.append((r.get("published_at") or "", ver))
    if not cands:
        return ""
    cands.sort(reverse=True)
    return cands[0][1]


# ⚠️ 只接「语义化正式标签」，必须挡掉日期式（v2026.9.24）与 +canary 预发布。
# 日期式 tag 的特征是 major 为【4 位年份】，故限 major 最多 3 位：
# 既精准排掉 v2026.x.y，又不会误伤上游将来真走到 v100.x.y 的情况
# （若写成 ^v\d+\.\d+\.\d+$ 会连日期式一起放行 —— 曾经的真实缺陷；
#   若限成 1~2 位则会在 v100 上假失败。两种都由 selftest 钉住）。
# `main` 是锚点的人工兜底值，不属于标签选取，故不在此列（由 build.yml 门禁单独放行）。
AGENT_SEMVER_RE = re.compile(r"^v\d{1,3}\.\d+\.\d+$")


def latest_agent_tag():
    """返回最新【正式语义化】release 标签。

    不能用 releases/latest：
      1. 上游同一仓库既发语义化（v0.22.0）也发历史日期式（v2026.9.24）tag，
         latest 指针可能落在任一类型上；我们只跟语义化（与 fpk 锚点注释一致）。
      2. 上游还会发 `vX.Y.Z+canary.<ts>` 预发布，不能入选。
    故拉 releases 列表，过滤 prerelease/draft + AGENT_SEMVER_RE（拒绝日期式），
    按 published_at 取最新。
    """
    data = json.loads(_get("%s/repos/%s/releases?per_page=100" % (API, AGENT_REPO)))
    cands = []
    for r in data:
        if r.get("prerelease") or r.get("draft"):
            continue
        tag = r.get("tag_name", "")
        if not AGENT_SEMVER_RE.match(tag):
            continue
        cands.append((r.get("published_at") or "", tag))
    if not cands:
        return ""
    cands.sort(reverse=True)
    return cands[0][1]


def asset_sha256(version):
    """取 sidecar 里的 sha256；失败返回空串（调用方应视为硬失败）。"""
    asset = "hermes-web-ui-%s.tar.gz" % version
    url = "https://github.com/%s/releases/download/v%s/%s.sha256" % (WEBUI_REPO, version, asset)
    try:
        txt = _get(url, raw=True)
    except urllib.error.HTTPError as e:
        print("sidecar 下载失败: HTTP %s" % e.code, file=sys.stderr)
        return ""
    m = re.search(r"\b([0-9a-f]{64})\b", txt)
    return m.group(1) if m else ""


def agent_tag_exists(tag):
    try:
        _get("%s/repos/%s/git/refs/tags/%s" % (API, AGENT_REPO, tag))
        return True
    except urllib.error.HTTPError:
        return False


# ── 回归自检：标签过滤器必须真的做到注释声明的事 ────────────────────────────
# 历史教训：AGENT_SEMVER_RE 曾写成 ^v\d+\.\d+\.\d+$，注释说「拒绝日期式」但
# v2026.9.24 照样匹配 —— 声明与实现脱节，靠上游恰好只发语义化 tag 才没出事。
# 下面这组用例把「接受/拒绝」钉成可执行契约，CI 与本机都跑（scripts/selftest）。
SELFTEST_AGENT_TAGS = [
    # (tag, 应入选, 说明)
    ("v0.22.0", True, "当前语义化正式版"),
    ("v0.9.13", True, "个位 major"),
    ("v1.0.0", True, "跨 major"),
    ("v12.3.4", True, "两位 major"),
    ("v100.0.0", True, "三位 major —— 上游将来真升 big version 不能被误拒"),
    ("v2026.9.24", False, "日期式（4 位年份 major）—— 必须拒"),
    ("v2026.10.15", False, "日期式 —— 必须拒"),
    ("v0.22.0+canary.1728000000", False, "canary 预发布"),
    ("v0.22", False, "缺 patch 段"),
    ("0.22.0", False, "缺 v 前缀"),
    ("main", False, "分支名不是 release 标签"),
    ("", False, "空值"),
]


def selftest():
    """无网络自检：校验标签过滤器行为与声明一致。全部通过返回 0。"""
    fails = []
    for tag, want, why in SELFTEST_AGENT_TAGS:
        got = bool(AGENT_SEMVER_RE.match(tag))
        if got != want:
            fails.append("agent 过滤器 %s: tag=%r 期望 accept=%s 实得=%s (%s)"
                         % ("误放行" if got else "误拒绝", tag, want, got, why))
    # 锚点人工兜底值 main 必须由 CI 门禁放行（与 build.yml 的 ^(…|main)$ 对齐）
    if AGENT_SEMVER_RE.match("main"):
        fails.append("main 不应被标签过滤器接受（它由 build.yml 锚点门禁单独放行）")

    if fails:
        for f in fails:
            print("FAIL: %s" % f, file=sys.stderr)
        print("SELFTEST FAILED (%d)" % len(fails), file=sys.stderr)
        return 1
    print("SELFTEST OK (%d 用例)" % len(SELFTEST_AGENT_TAGS))
    return 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    if cmd == "webui":
        v = latest_webui_version()
        if not v:
            print("未能解析出可打包的 hermes-web-ui 版本", file=sys.stderr)
            return 1
        print(v)
    elif cmd == "agent":
        t = latest_agent_tag()
        if not t:
            print("未能解析 hermes-agent 最新 release 标签", file=sys.stderr)
            return 1
        print(t)
    elif cmd == "sha256":
        if len(sys.argv) < 3:
            print("用法: detect-upstream.py sha256 <version>", file=sys.stderr)
            return 2
        s = asset_sha256(sys.argv[2])
        if not s:
            print("未能获取 sha256", file=sys.stderr)
            return 1
        print(s)
    elif cmd == "agent-tag-exists":
        if len(sys.argv) < 3:
            return 2
        return 0 if agent_tag_exists(sys.argv[2]) else 1
    elif cmd == "selftest":
        return selftest()
    else:
        print("未知子命令: %s" % cmd, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
