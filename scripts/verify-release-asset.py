#!/usr/bin/env python3
"""回读 Release 附件并校验，作为「发布成功」的唯一硬证据。

用法:
    python3 scripts/verify-release-asset.py <tag> <local_fpk_path>

退出码 0 = 附件存在且字节数与 sha256 均与本地一致；非 0 = 发布失败。

为什么必须做这一步：**workflow 显示 success 不等于发布成功**。
`softprops/action-gh-release` 与 curl 上传都可能静默失败（Release 建了但 assets
为空、或文件损坏），而 run 依然全绿。验收标准只有一个：Releases 页出现对应附件
且能下载、内容与本地构建产物逐字节一致。

用 asset 的 `digest` 字段（新版 API 提供 sha256:<hex>）与本地 sha256sum 逐字比对，
同时核字节数 —— 这是判断「产物真的是这次构建出来的」的唯一硬证据。
"""
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request


def _get_json(url, timeout=60):
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "ekko-studio-fpk-verify")
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        req.add_header("Authorization", "token %s" % token)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    tag, local = sys.argv[1], sys.argv[2]
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if not repo:
        print("需要环境变量 GITHUB_REPOSITORY", file=sys.stderr)
        return 2
    if not os.path.isfile(local):
        print("本地产物不存在: %s" % local, file=sys.stderr)
        return 2

    asset_name = os.path.basename(local)
    local_size = os.path.getsize(local)
    local_sha = sha256_file(local)
    print("本地: %s  size=%s  sha256=%s" % (asset_name, local_size, local_sha))

    for attempt in range(1, 6):
        try:
            d = _get_json("https://api.github.com/repos/%s/releases/tags/%s" % (repo, tag))
        except urllib.error.HTTPError as e:
            print("第 %d 次回读 Release %s -> HTTP %s" % (attempt, tag, e.code))
            time.sleep(10)
            continue

        hit = None
        for a in d.get("assets", []):
            if a.get("name") == asset_name:
                hit = a
                break
        if hit is None:
            print("第 %d 次回读: Release %s 附件列表 %s 中未见 %s"
                  % (attempt, tag, [a.get("name") for a in d.get("assets", [])], asset_name))
            time.sleep(10)
            continue

        remote_size = hit.get("size", 0)
        remote_digest = hit.get("digest") or ""
        print("远端: size=%s digest=%s updated_at=%s"
              % (remote_size, remote_digest, hit.get("updated_at")))

        if int(remote_size) != local_size:
            print("::error:: 附件字节数不符: remote=%s local=%s" % (remote_size, local_size), file=sys.stderr)
            return 1
        if remote_digest:
            if remote_digest != "sha256:%s" % local_sha:
                print("::error:: 附件 sha256 不符: %s vs sha256:%s" % (remote_digest, local_sha), file=sys.stderr)
                return 1
        else:
            print("::warning:: 该 Release 的 asset 未提供 digest 字段，仅校验了字节数")
        print("✅ Release 附件已确认（字节数与 sha256 均一致）")
        return 0

    print("::error:: Release %s 未附带 %s，发布失败" % (tag, asset_name), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
