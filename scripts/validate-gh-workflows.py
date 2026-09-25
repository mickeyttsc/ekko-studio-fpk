#!/usr/bin/env python3
"""静态体检 .github/workflows/ —— 不用等 CI 跑就能查出 workflow 层错误。

用法:
    python3 validate-gh-workflows.py [WORKFLOWS_DIR]      # 默认 .github/workflows

检查项:
  1. 每个 workflow YAML 能否 yaml.safe_load
  2. 每个 run: 步骤 → bash -n
  3. 每个 github-script 的 script: → node --check（无 node 时跳过）
  4. 门禁错配：workflow 同时可 workflow_dispatch 又有 `if: ...refs/tags/...` 的步骤
     → dispatch 运行的 github.ref 是 refs/heads/<branch>，该步骤被静默跳过
     （典型症状：dispatch 触发的构建永远不建 Release，下游上传资产 404）
  5. 跨 workflow：有步骤用 createWorkflowDispatch 且 ref 非 tag → 下游 tag 门禁不会命中

退出码: 0 = 无硬错误（警告不算）; 1 = 有硬错误; 2 = 用法/依赖问题
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:
    print("需要 pyyaml：uv pip install pyyaml")
    sys.exit(2)

ERRORS = []
WARNS = []


def _run(cmd, body, suffix, label, workdir):
    fd, p = tempfile.mkstemp(suffix=suffix, dir=workdir)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(body)
    try:
        r = subprocess.run(cmd + [p], capture_output=True, text=True)
        if r.returncode != 0:
            first = (r.stderr or r.stdout).strip().splitlines()
            ERRORS.append("{}: {} 失败 -> {}".format(label, cmd[-1], first[:1]))
    finally:
        os.unlink(p)


def check_bash(body, label, workdir):
    _run(["bash", "-n"], body, ".sh", label, workdir)


def check_js(body, label, workdir):
    if not shutil.which("node"):
        return
    _run(["node", "--check"], body, ".js", label, workdir)


def main():
    wdir = sys.argv[1] if len(sys.argv) > 1 else ".github/workflows"
    if not os.path.isdir(wdir):
        print("目录不存在: {}".format(wdir))
        return 2
    files = sorted(f for f in os.listdir(wdir) if f.endswith((".yml", ".yaml")))
    if not files:
        print("{} 下没有 workflow 文件".format(wdir))
        return 2

    tmp = tempfile.mkdtemp()
    dispatchers = {}

    for fn in files:
        raw = open(os.path.join(wdir, fn), encoding="utf-8").read()
        try:
            doc = yaml.safe_load(raw)
        except Exception as e:
            ERRORS.append("{}: YAML 解析失败 -> {}".format(fn, e))
            continue
        if not isinstance(doc, dict):
            ERRORS.append("{}: 顶层不是映射".format(fn))
            continue

        # YAML 1.1 把裸 on: 解析成布尔 True，两种取法都要试
        on = doc.get("on")
        if on is None:
            on = doc.get(True)
        if isinstance(on, dict):
            triggers = {str(k) for k in on}
        elif isinstance(on, list):
            triggers = {str(k) for k in on}
        elif isinstance(on, str):
            triggers = {on}
        else:
            triggers = set()
        lets_dispatch = "workflow_dispatch" in triggers

        for jname, job in (doc.get("jobs") or {}).items():
            for i, step in enumerate((job or {}).get("steps") or []):
                if not isinstance(step, dict):
                    continue
                label = "{} > {} > {}".format(fn, jname, step.get("name") or "step{}".format(i))

                if isinstance(step.get("run"), str):
                    check_bash(step["run"], label, tmp)

                script = step.get("script")
                if isinstance(script, str):
                    check_js(script, label, tmp)
                    if "createWorkflowDispatch" in script:
                        m = re.search(r"ref:\s*['\"]([^'\"]+)['\"]", script)
                        if m and not m.group(1).startswith("refs/tags/"):
                            dispatchers[fn] = m.group(1)

                cond = str(step.get("if") or "")
                if lets_dispatch and "refs/tags/" in cond:
                    WARNS.append(
                        "{}: 该步骤被 tag 门禁（{}）保护，但本 workflow 也能 workflow_dispatch 触发 —— "
                        "dispatch 运行时 github.ref 是 refs/heads/<branch>，此步会被静默跳过"
                        "（症状：dispatch 的构建永远不建 Release）".format(label, cond.strip())
                    )

    for src, ref in dispatchers.items():
        WARNS.append(
            "{}: 用 createWorkflowDispatch 触发下游，ref='{}'（非 tag）—— "
            "下游任何 tag 门禁步骤都不会命中，Release 归属要放在触发方".format(src, ref)
        )

    print("=== 检查了 {} 个 workflow 文件 ===".format(len(files)))
    for w in WARNS:
        print("[warn] " + w)
    for e in ERRORS:
        print("[FAIL] " + e)
    if ERRORS:
        print("\n硬错误 {} 项 —— 先修再推。".format(len(ERRORS)))
        return 1
    print("\n无硬错误。{}".format("警告 {} 项，请人工确认。".format(len(WARNS)) if WARNS else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
