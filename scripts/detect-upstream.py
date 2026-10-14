#!/usr/bin/env python3
"""判定上游「可打包版本」并输出校验值。

用法:
    python3 scripts/detect-upstream.py webui   # 打印最新可打包的 hermes-web-ui 版本号
    python3 scripts/detect-upstream.py agent   # 打印 hermes-agent 最新 release 标签
    python3 scripts/detect-upstream.py sha256 <version>   # 打印该版本资产的 sha256
    python3 scripts/detect-upstream.py selftest           # 无网络回归自检（标签过滤器行为契约）

设计依据（都是踩过的坑）：
  1. 上游 release 线被官方显式标记为非 latest，不能取 releases/latest，
     必须自行过滤版本标签（见 AGENT_TAG_PATTERN / WEBUI_TAG_PATTERN：major 最多 3 位，
     以排除上游的历史日期式 tag v2026.x.y）并按 published_at 取最新。
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


# webui 侧标签判据：与 agent 侧同用「major 最多 3 位」口径，排除 4 位年份日期式。
# 实测上游 EKKOLearnAI/ekko-studio 现网 release 无 4 位 major（多为 v0.7.x 与手机端
# v1.0.x），收紧不改变现有选取；统一口径是为了上游哪天改用日期式也不会误入选。
WEBUI_TAG_PATTERN = r"v\d{1,3}\.\d+\.\d+"
WEBUI_TAG_RE = re.compile(r"^" + WEBUI_TAG_PATTERN + r"$")


def latest_webui_version():
    """返回最新「带 hermes-web-ui-<ver>.tar.gz 资产」的版本号（无 v 前缀）。"""
    data = json.loads(_get("%s/repos/%s/releases?per_page=100" % (API, WEBUI_REPO)))
    cands = []
    for r in data:
        if r.get("prerelease") or r.get("draft"):
            continue
        tag = r.get("tag_name", "")
        if not WEBUI_TAG_RE.fullmatch(tag):
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


# ── 口径唯一真源 ─────────────────────────────────────────────────────────────
# ⚠️ 只接「语义化正式标签」，必须挡掉日期式（v2026.9.24）与 +canary 预发布。
# 日期式 tag 的特征是 major 为【4 位年份】，故限 major 最多 3 位：既精准排掉
# v2026.x.y，又不会误伤上游将来真走到 v100.x.y（写成 ^v\d+\.\d+\.\d+$ 会连日期式
# 一起放行 —— 2026-10-15 实测的真实缺陷；限成 1~2 位则会在 v100 上假失败）。
#
# 这条规则曾被【手抄三份】（本文件 + build.yml + verify-fpk-gates.sh），结果
# 一处收紧、另两处漏改，且收紧的那处注释还宣称「两侧由 selftest 钉住」——
# 实际 selftest 只测自己。现在改为：shell 侧一律调 `gate-regex` 取串，
# 而 selftest 会扫描仓库、禁止任何位置再出现宽松的字面副本。
AGENT_TAG_PATTERN = r"v\d{1,3}\.\d+\.\d+"
AGENT_SEMVER_RE = re.compile(r"^" + AGENT_TAG_PATTERN + r"$")

# POSIX ERE 版（供 shell 门禁 `grep -qE` 直接消费；含人工兜底值 main）。
# main 不属于 release 标签选取，只作为显式锚点值合法存在。
ANCHOR_ERE = r"^(v[0-9]{1,3}\.[0-9]+\.[0-9]+|main)$"


def pick_agent_tag(releases):
    """从 release 字典列表里挑最新【正式语义化】标签；无可选项时返回空串。

    纯函数（不联网），便于 selftest 用构造样本验证「选谁」的真实逻辑
    —— 只测正则串会漏掉 prerelease/draft 过滤与排序键这两类回归。
    """
    cands = []
    for r in releases:
        if r.get("prerelease") or r.get("draft"):
            continue
        tag = r.get("tag_name", "")
        if not AGENT_SEMVER_RE.fullmatch(tag):
            continue
        cands.append((r.get("published_at") or "", tag))
    if not cands:
        return ""
    cands.sort(reverse=True)
    return cands[0][1]


def latest_agent_tag():
    """返回最新【正式语义化】release 标签。

    不能用 releases/latest：
      1. 上游同一仓库既发语义化（v0.22.0）也发历史日期式（v2026.9.24）tag，
         latest 指针可能落在任一类型上；我们只跟语义化（与 fpk 锚点注释一致）。
      2. 上游还会发 `vX.Y.Z+canary.<ts>` 预发布，不能入选。
    故拉 releases 列表交给 pick_agent_tag（过滤 prerelease/draft + 语义化标签，
    按 published_at 取最新）。
    """
    data = json.loads(_get("%s/repos/%s/releases?per_page=100" % (API, AGENT_REPO)))
    return pick_agent_tag(data)


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


# ── 回归自检：标签选取契约（无网络，CI 前置与本机都跑）────────────────────
# 历史教训两层：
#  ① 口径与声明脱节 —— 过滤器曾写成「major 任意位数」，注释说「拒绝日期式」，
#     而 v2026.9.24 照样匹配；上游 39 个 release 里 36 个是日期式，一旦它再发
#     日期式就会赢过语义化版本被写进锚点。
#  ② 自检自证范围造假 —— 旧 selftest 只测本文件的正则串，shell 侧（build.yml /
#     verify-fpk-gates.sh）的正则是手抄副本，改回宽松写法后 selftest 仍全绿。
# 因此本自检做四件事：正则串行为、标签选取逻辑（纯函数）、shell 口径与 Python
# 口径逐样本等价、以及「禁止再出现宽松的字面副本 / 消费方必须走 gate-regex」。
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
    ("v0.22.0\n", False, "尾部换行（脏值）—— fullmatch 必须拒"),
]

# 选取逻辑样本：验证 prerelease/draft 过滤与 published_at 排序真的在起作用。
# 只测正则串挡不住「删掉 prerelease 过滤」或「排序键改成 tag_name」这类回归。
SELFTEST_PICKS = [
    (
        "日期式即使更新也要让位给语义式",
        [
            {"tag_name": "v2026.10.15", "published_at": "2026-10-15T00:00:00Z"},
            {"tag_name": "v0.22.0", "published_at": "2026-10-14T03:21:46Z"},
        ],
        "v0.22.0",
    ),
    (
        "prerelease 必须被剔除",
        [
            {"tag_name": "v0.23.0", "published_at": "2026-10-15T00:00:00Z", "prerelease": True},
            {"tag_name": "v0.22.0", "published_at": "2026-10-14T00:00:00Z"},
        ],
        "v0.22.0",
    ),
    (
        "draft 必须被剔除",
        [
            {"tag_name": "v0.24.0", "published_at": "2026-10-16T00:00:00Z", "draft": True},
            {"tag_name": "v0.22.0", "published_at": "2026-10-14T00:00:00Z"},
        ],
        "v0.22.0",
    ),
    (
        "同批里按 published_at 取最新语义式",
        [
            {"tag_name": "v0.21.7", "published_at": "2026-10-12T05:53:41Z"},
            {"tag_name": "v0.22.0", "published_at": "2026-10-14T03:21:46Z"},
            {"tag_name": "v0.21.6", "published_at": "2026-10-08T11:51:57Z"},
        ],
        "v0.22.0",
    ),
    (
        "排序键必须是 published_at 而不是 tag 字典序",
        # 字典序倒排会把 v0.9.13 排在 v0.22.0 前面（'9' > '2'），
        # 而上游实际后发布的是 v0.22.0 —— 少了这条 fixture，
        # 「排序键被改成 tag_name」这类回归测不出来（实测漏网过）。
        [
            {"tag_name": "v0.9.13", "published_at": "2026-10-10T00:00:00Z"},
            {"tag_name": "v0.22.0", "published_at": "2026-10-14T00:00:00Z"},
        ],
        "v0.22.0",
    ),
    (
        "全被过滤时返回空串（调用方须跳过本轮，不得写垃圾锚点）",
        [{"tag_name": "v2026.9.24", "published_at": "2026-09-24T10:09:38Z"}],
        "",
    ),
    ("空列表返回空串", [], ""),
]


def selftest():
    """无网络自检：标签选取契约 + 多口径一致性。全部通过返回 0。"""
    fails = []

    # 1) 标签正则串行为
    for tag, want, why in SELFTEST_AGENT_TAGS:
        got = bool(AGENT_SEMVER_RE.fullmatch(tag))
        if got != want:
            fails.append("标签过滤器 %s: tag=%r 期望 accept=%s 实得=%s (%s)"
                         % ("误放行" if got else "误拒绝", tag, want, got, why))

    # 2) 标签选取逻辑（过滤 + 排序）
    for why, releases, want in SELFTEST_PICKS:
        got = pick_agent_tag(releases)
        if got != want:
            fails.append("选取逻辑错误: %s —— 期望 %r 实得 %r" % (why, want, got))

    # 3) shell 口径（ANCHOR_ERE）必须与 Python 口径逐样本等价 —— 但 main 是
    #    【刻意不对称】项：标签选取必须拒它，锚点校验必须收它（人工显式兜底值）。
    #    所以 main 不进等价比对，改由下方两条专项断言各自钉住。
    #    本口径的 ERE 语法子集与 Python 一致，故可直接用 re 断言。
    ere = re.compile(ANCHOR_ERE)
    for tag, want, why in SELFTEST_AGENT_TAGS:
        if not tag or tag == "main":
            continue
        got = bool(ere.fullmatch(tag))
        if got != want:
            fails.append("ANCHOR_ERE 与 Python 口径不一致: tag=%r 期望=%s 实得=%s (%s)"
                         % (tag, want, got, why))
    if bool(AGENT_SEMVER_RE.fullmatch("main")):
        fails.append("标签过滤器必须拒绝 main（main 不是 release 标签）")
    if not ere.fullmatch("main"):
        fails.append("ANCHOR_ERE 必须接受人工兜底值 main")
    if ere.fullmatch(""):
        fails.append("ANCHOR_ERE 必须拒绝空锚点（空值不得被当成 main）")

    # 4) 反「手抄副本」：shell 消费方必须从 gate-regex/anchor-ok 取口径，
    #    且全仓不得再出现宽松口径的字面正则（注释里描述历史缺陷除外）。
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    consumers = [
        ".github/workflows/build.yml",
        ".github/workflows/auto-update.yml",
        "scripts/verify-fpk-gates.sh",
        "scripts/build-fpk.sh",
        "scripts/auto-update-tick.sh",
        "cmd/main",                                    # 装机运行时（无扩展名，曾漏在扫描外）
        "app/config/bootstrap/hermes-agent-postinstall.sh",
    ]
    # 行级禁令：任何消费方**逐行**都不许自带版本正则（宽松或严格都不行）。
    # 早前是文件级豁免 —— 文件里出现过 anchor-ok 就整份放行，于是「再手抄一份
    # 严格口径」这种漂移抓不到（本仓正是因为手抄才漏改第三处门禁的）。
    hardcoded = re.compile(r"grep\s+-[A-Za-z]*E\s+.*v(\[0-9\]|\\d)")
    for rel in consumers:
        fp = os.path.join(root, rel)
        if not os.path.exists(fp):
            continue
        text = open(fp, encoding="utf-8", errors="replace").read()
        for i, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            if hardcoded.search(line):
                fails.append("%s:%d 自带版本正则（应改用 detect-upstream.py 的 anchor-ok/gate-regex）: %s"
                             % (rel, i, line.strip()[:100]))

    # 宽松口径的「字面量指纹」：直接子串匹配源码，避免用正则去匹配正则。
    # 收紧后的写法（v\d{1,3}\. / v[0-9]{1,3}\.）不含这两个指纹，故不会误报。
    loose_markers = ("v\\d+\\.\\d+", "v[0-9]+\\.")
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if d not in (".git", "node_modules", "hermes-agent-src", "dist")]
        for fn in filenames:
            # 额外纳入无扩展名的运行时脚本（cmd/main 曾被 .py/.sh/.yml 过滤器漏掉）
            if not (fn.endswith((".py", ".sh", ".yml")) or fn == "main"):
                continue
            fp = os.path.join(dirpath, fn)
            try:
                text = open(fp, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for i, line in enumerate(text.splitlines(), 1):
                if line.lstrip().startswith("#"):
                    continue
                if any(m in line for m in loose_markers):
                    fails.append("宽松口径字面副本: %s:%d  %s"
                                 % (os.path.relpath(fp, root), i, line.strip()[:110]))

    if fails:
        for f in fails:
            print("FAIL: %s" % f, file=sys.stderr)
        print("SELFTEST FAILED (%d 项)" % len(fails), file=sys.stderr)
        return 1
    print("SELFTEST OK (%d 标签用例 + %d 选取用例 + ERE 等价 + 口径唯一性)"
          % (len(SELFTEST_AGENT_TAGS), len(SELFTEST_PICKS)))
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
    elif cmd == "gate-regex":
        # 口径唯一出口：shell 侧门禁一律 $(python3 scripts/detect-upstream.py gate-regex)
        print(ANCHOR_ERE)
    elif cmd == "anchor-ok":
        if len(sys.argv) < 3:
            print("用法: detect-upstream.py anchor-ok <锚点值>", file=sys.stderr)
            return 2
        val = sys.argv[2]
        if not re.fullmatch(ANCHOR_ERE, val):
            print("锚点非法: %r（要求 %s；拒绝日期式 v2026.x.y 与 +canary）" % (val, ANCHOR_ERE),
                  file=sys.stderr)
            return 1
        return 0
    else:
        print("未知子命令: %s" % cmd, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
