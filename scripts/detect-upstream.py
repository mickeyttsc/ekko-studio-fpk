#!/usr/bin/env python3
"""判定上游「可打包版本」并输出校验值。

用法:
    python3 scripts/detect-upstream.py webui   # 打印最新可打包的 hermes-web-ui 版本号
    python3 scripts/detect-upstream.py agent   # 打印 hermes-agent 最新 release 标签
    python3 scripts/detect-upstream.py sha256 <version>   # 打印该版本资产的 sha256

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


def latest_agent_tag():
    d = json.loads(_get("%s/repos/%s/releases/latest" % (API, AGENT_REPO)))
    return d.get("tag_name", "")


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
    else:
        print("未知子命令: %s" % cmd, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
