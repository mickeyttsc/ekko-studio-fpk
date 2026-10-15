# ekko-studio-fpk · 维护文档

> 面向维护者（构建链路 / 门禁 / 历史坑位）。用户向说明见 [README.md](README.md)。

## 标识与命名（先读）

- **appname** `hermes-studio`：技术标识，决定 `@apphome/@appconf/@appdata` 数据目录名、服务用户名、桌面启动项 ID。**故意不改**——改它等于换应用，当前实例会断且必须迁移数据。
- **display_name** `Ekko Studio`：用户看到的名字由它控制。
- 产物文件名已从 `fnos-hermes-studio_*` 改为 `fnos-ekko-studio_*`（2026-09-25）。纯文件名，与 appname 无关，不影响安装与升级；v0.7.24-6 及更早的包仍是旧名。

---

## 自动出包链路

```
auto-update.yml                          build.yml
（schedule 每 2h + dispatch）       →    （push / dispatch / workflow_run 接力）
  检测上游「可打包版本」                    拉官方产物（sha256 校验）
  有变化 → bump 版本号 + 固定 sha256   →    组内层 app.tgz + 外层 FPK
  提交到 main                              跑硬门禁 → 发 Release（latest + 稳定 tag）
                                           回读 Release 附件确认可下载
```

**发布职责归属**：`build.yml` 是 Release 的**唯一**归属方。
`auto-update.yml` 只做检测 + bump + 提交，不建 Release、不传资产 ——
两处都写「建 Release」会导致一边空转、整条链路每轮都红且永不产出。

### 触发方式

```bash
TOK=$(cat ~/.config/github/token)

# 手动触发构建（version 留空则用 manifest 里的版本号）
curl -X POST -H "Authorization: Bearer ***" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/mickeyttsc/ekko-studio-fpk/actions/workflows/build.yml/dispatches \
  -d '{"ref":"main"}'

# 手动触发上游巡检
curl -X POST -H "Authorization: Bearer ***" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/mickeyttsc/ekko-studio-fpk/actions/workflows/auto-update.yml/dispatches \
  -d '{"ref":"main"}'

# 查最近运行
curl -s -H "Authorization: Bearer ***" \
  "https://api.github.com/repos/mickeyttsc/ekko-studio-fpk/actions/runs?per_page=5"
```

下载最新包：

```bash
# 滚动最新版
curl -fL -o fnos-ekko-studio.fpk \
  https://github.com/mickeyttsc/ekko-studio-fpk/releases/download/latest/fnos-ekko-studio.fpk

# 固定版本
curl -fL -o fnos-ekko-studio_v0.7.35-1.fpk \
  https://github.com/mickeyttsc/ekko-studio-fpk/releases/download/v0.7.35-1/fnos-ekko-studio_v0.7.35-1.fpk
```

---

## 目录结构

```
manifest                     appname / version / 依赖 / 桌面启动名 / checksum（勿手填）
ICON.PNG / ICON_256.PNG      应用图标（512 / 256）
cmd/                         生命周期：main / install_init / install_callback /
                             upgrade_init / upgrade_callback / config_init /
                             config_callback / uninstall_init / uninstall_callback
config/
  ├── privilege              运行用户（package）
  ├── resource               共享目录 + CLI 链接
  ├── bootstrap/             版本锚点（回调期读，必须在【外层】）
  └── upstream/              上游产物固定 sha256（入库，供应链校验锚点）
wizard/                      install（安装向导）、uninstall（卸载向导）
app/                         ← 进入内层 app.tgz 的内容
  ├── bin/hermes-web-ui      CLI 包装脚本（usr-local-linker 链到 /usr/local/bin）
  ├── ui/config + images/    桌面入口（.url 格式，port=8648）
  └── config/bootstrap/      版本锚点（内层副本）
scripts/
  ├── build-fpk.sh           拉产物 → sha256 校验 → 组内层 → 组外层 → 后处理
  ├── detect-upstream.py     判定「可打包版本」并取 sha256（可本机直跑）
  ├── verify-fpk-content.sh  双层内容校验（外层 + 内层 app.tgz）
  ├── verify-release-asset.py 回读 Release 附件校验字节数与 sha256
  └── validate-gh-workflows.py 改 workflow 后先跑的静态体检
```

**内层 `app.tgz` 不得带 `app/` 前缀，也不得带 `./` 前缀。**
官方 `fnpack` 把 `app/` 的**内容**打在归档根（`bin/ config/ node/ ui/`）。
带前缀时装完是 `@appcenter/<app>/app/node/...`，而脚本找 `@appcenter/<app>/node/...`
—— 四个关键路径全错，安装必失败。正确写法：

```bash
APP_ENTRIES="$(cd app && ls -A)"
tar -czf app.tgz -C app ${APP_ENTRIES}   # ✅ 首条是 bin/，无 app/ 也无 ./
tar -czf app.tgz -C app .                # ⚠️ 无 app/ 但带 ./ 开头，与官方格式不一致
tar -czf app.tgz app                     # ❌ 多一层 app/，装完路径全错位
```

---

## 本地构建

```bash
export PATH="/var/apps/nodejs_v24/target/bin:$PATH"
bash scripts/build-fpk.sh dist
# 产物: dist/fnos-ekko-studio_v<version>.fpk
```

构建需要联网（下载上游产物 + Agent 离线源码）。首次构建会下载约 130MB 的
web-ui 预构建产物，并编译/镜像 Agent 的 node 依赖。

**本地手打的包不算 CI 链路可用的证据** —— 只认 Actions 绿跑的 artifact 或 Release 附件。

---

## 验证

```bash
# 双层内容校验（外层条目 + 内层 app.tgz）
bash scripts/verify-fpk-content.sh dist/fnos-ekko-studio_v0.7.35-1.fpk

# 上游探测逻辑（可脱离 CI 单独跑）
export GITHUB_TOKEN=$(cat ~/.config/github/token)
python3 scripts/detect-upstream.py webui
python3 scripts/detect-upstream.py agent
python3 scripts/detect-upstream.py sha256 0.7.35

# 改完 .github/workflows/ 先跑静态体检（不用等 CI 往返）
python3 scripts/validate-gh-workflows.py .github/workflows

# 回读 Release 附件（验收标准：附件存在且能下载，不是 workflow 显示 success）
GITHUB_REPOSITORY=mickeyttsc/ekko-studio-fpk GITHUB_TOKEN=$TOK \
  python3 scripts/verify-release-asset.py v0.7.35-1 dist/fnos-ekko-studio_v0.7.35-1.fpk
```

### 验收清单

- [ ] fpk 存在且大小合理
- [ ] 外层条目含 `manifest`、`manifest.checksum`、`cmd/`、`config/`、`wizard/`、`app.tgz`
- [ ] `manifest.checksum` == 包内 `app.tgz` 的 md5
- [ ] **解开内层 `app.tgz` 再查一遍**（禁携带 `skills/`、bundled 运行时/原生模块是否真的在里面）
- [ ] 内层归档根无 `app/` 与 `./` 前缀
- [ ] `cmd/*` 全部可执行（755）
- [ ] Release 已创建并附带 fpk；**从 Release 下载该附件再做一次同样的双层校验**
- [ ] 产物来源已确认（Actions 绿跑的 artifact / Release 附件，不是本地手打的包）
- [ ] 仓库不携带用户私有数据（内网 IP / 密钥 / token / 账号 UID）

> 隐私自查：每次推送前对【全历史文件内容 + 提交信息】各做一次私密串扫描（具体口令见本地运维备忘，勿入库）。

---

## 升级已装应用

fnOS 没有本地 fpk 升级命令（`appcenter-cli install-fpk` 对已装应用直接拒，
CLI 无 upgrade 子命令）。可行路径 = **应用中心 UI 手动安装新 fpk**，
或在应用中心里选择升级。装完跑一次验收清单。

内核（Hermes Agent）**会**随 fpk 升级：`install_callback`/`upgrade_callback` 都过
`config/bootstrap/ensure-kernel.sh` 版本闸门，包内内核较新时原地对齐（备份 + 复用
venv + 失败回滚），见坑表 #36。用户自己 `hermes update` 到更新版本时闸门判 skip，
绝不降级。

**装完必须确认界面版本**：Studio 版本栏读的是 `hermes_cli.__version__`，它只认内核
树里的 `install-stamp.json`（不回退 git）——stamp 缺失/损坏时界面显示 `0.0.0`。
故装后由 `hermes-agent-postinstall.sh --expect-version <本包锚点>` 实测断言
「界面会显示的值 == 包内锚点」，不符即回滚（见坑表 #37）。

---

## 已固化的坑（改代码前先读）

这些是本项目踩过并已修复/加门禁的问题，改动时不要回退：

| # | 坑 | 现状 |
|---|---|---|
| 1 | **宽泛 pkill 误杀 Docker 容器** —— `pkill -f "bin/hermes-web-ui"` / `"dist/server/index.js"` 会杀掉同机 Docker 版官方容器，导致「装一个、坏一个」 | 所有生命周期脚本统一锚定到本应用专属路径；CI 门禁拦复发 |
| 2 | **空 `TRIM_*` 注入 sed 写坏 `cmd/main`** —— fnOS 偶尔不传 `TRIM_APPDEST`，空值注入把 `/vol2/@appcenter/...` 换成 `/bin/...` | sed 前一律 `[ -n "$VAR" ]` 校验；所有脚本自带 `_resolve_trim_paths` |
| 3 | **不 hardcode 卷号** —— 写死 `/vol1` 让日志写进不存在的目录，升级失败零诊断信息 | 从 `/var/apps/<app>` symlink 反推 + `/tmp` 兜底 |
| 4 | **外部产物必须校验 sha256** —— 供应链入口，不是性能问题 | 优先读入库的 `config/upstream/<asset>.env`；没有才退回 sidecar；两者都缺 = 构建失败 |
| 5 | **只做「现拉 sidecar 现比」等于没校验** —— 上游事后替换同版本资产时 sidecar 会跟着变 | 固定 sha256 进版本控制，由 `auto-update.yml` 随 bump 更新 |
| 6 | **内层 `app.tgz` 带 `app/` 或 `./` 前缀** → 装完路径全错位，安装必失败 | 显式列条目 + 构建期自检 + CI 门禁 |
| 7 | **外层 `config/` 必须含 `bootstrap/`** —— 回调期要读，只放内层会导致读不到而降级成 `unknown` | 内外都放；CI 门禁查外层 |
| 8 | **`cmd/*` 权限 644** → `uninstall_init` 的 `[ -x ]` 判断失败，卸载/升级静默跳过 stop，残留进程占端口 | 打包前统一 `chmod 755` + CI 门禁 |
| 9 | **必需组件缺失只打 warning** —— 构建「绿」了但包里没有内核，装机时超时或卡在连不上 GitHub | 一律 `exit 1` + CI 门禁查必需件存在性 |
| 10 | **CI 里未鉴权的 `api.github.com` 调用被 IP 级限流** —— runner 出口 IP 全平台共享，未鉴权走 60 次/小时配额，常被其它仓库耗尽 → 403 → JSON 解析失败 → 「同步上游」静默失效 | 所有 API 调用带 `Authorization`；探测逻辑集中在 `detect-upstream.py`（可本机直跑验证） |
| 11 | **Release 归属与触发 ref 不匹配** —— 发布步骤写 `if: startsWith(github.ref, 'refs/tags/')`，而 dispatch/workflow_run 的 ref 是 `refs/heads/main`，发布被静默跳过：run 全绿但仓库里永远没有 Release | 发布步骤**不带 ref 门禁**；发布职责由 `build.yml` 独占 |
| 12 | **`GITHUB_TOKEN` 推送不触发 `push` 事件**（GitHub 防递归策略） | bump 后靠 `workflow_run` 接力，`build.yml` 的 `on.workflow_run` 已配对 |
| 13 | **`workflow_dispatch` 传 `version: "latest"`** → 产物文件名无版本号，fnOS 应用中心**永远装不上** | 版本号格式门禁（必须形如 `0.7.24-6`） |
| 14 | **`manifest.checksum` 与 `app.tgz` 实际 md5 失配** | 后处理重算 + CI 门禁逐字比对 |
| 15 | **推送 workflow 后不校验 YAML 缩进** —— 缩进丢失会让步骤被静默跳过 | 改完先跑 `scripts/validate-gh-workflows.py` |
| 16 | **远端没落地就宣布推送成功** —— 本地 commit 成功 ≠ 远端有该提交 | `auto-update.yml` 结尾回读 `git ls-remote` 比对 SHA |
| 17 | **workflow 显示 success ≠ 发布成功** —— 上传可能静默失败（Release 建了但 assets 为空） | 回读 Release 附件，比对字节数与 `digest` 的 sha256 |
| 18 | **编码 Agent（DSH 等）装完找不到** —— WebUI 走裸 `npm install -g`，落点由 `.npmrc` 的 prefix 决定，而反查用 `findCommandPaths(name, PATH)`，PATH 里没该目录就永远 503 | 对齐上游环境约定：`NPM_CONFIG_PREFIX` 指向固定目录 + 同源 `<该目录>/bin` 进 PATH（`cmd/main`、`app/bin/*`、两个 callback 四处一致） |
| 19 | **DSH 凭据被 `chmod -R` 放宽** —— DSH 对 `data/.dsh/.credentials.yaml` 做 owner-only 硬校验，权限变宽则 plugin tree 加载失败（「DSH 模式」下拉框无限转圈） | 三处入口（install/upgrade/main）在 `chmod -R` **之后**无条件 `chmod 600`；CI 门禁查三处 |
| 20 | **官方 CLI start 会强杀端口占用者** —— `hermes-web-ui.mjs` 的 `startDaemon()` 发现端口被占直接 `killListeningPids()`，新旧应用同端口共存时会无声杀掉老应用 | `cmd/main` 启动前 `check_port_owner()`：自己的旧进程放行，别人的拒启 |
| 21 | **包内携带 `skills/`** → 安装/升级时覆盖用户技能库 | 不内置任何技能；CI 门禁查内外两层 |
| 22 | **构建机绝对路径污染** —— `/home/runner/...` 被带进包导致 `install_callback` 找不到 `node_modules` 而回退 npm | 相对路径镜像 + CI 门禁 |
| 23 | **`cp -a` 遇上 git gc 竞态会 stat 失败中断打包** | 源码复制用 `tar` 管道并排除 `.git` |
| 24 | **`echo "$大字符串" \| grep -q` 在 `pipefail` 下产生假阴性** —— 内层清单 3 万多行（400KB+）超过管道缓冲区，`grep -q` 命中即早退 → `echo` 收 SIGPIPE(141) → `if ! echo "$L" \| grep -q X` 被判成「未命中」，**安全检查静默通过**；`echo "$L" \| head -1` 则直接 rc=141 判失败（曾实际挂掉 CI） | 清单一律先写文件再 `grep`/`sed`；门禁集中在 `scripts/verify-fpk-gates.sh`，并带「反自检」断言 grep 通路是活的 |
| 25 | **Python 3.11 不支持 `tarfile.extract(filter=)`** —— 该参数是 3.12+ 才有，3.11 直接 `TypeError` 中断打包 | try/except 兼容两者 |
| 26 | **门禁只查结构不查必需内容** —— 构建「绿」了但包里没有内核/原生模块 | 逐条断言必需件存在；CI 与本机共用 `verify-fpk-gates.sh`（单一份逻辑，避免漂移） |
| 27 | **卸载向导承诺「完全删除」，回调只删 `data/`** —— 用户真正的数据目录 `hermes-home/`（会话、记忆、技能、cron、AGENTS.md/SOUL.md、含 API Key 与渠道 token 的 `.env`）与内核 `hermes-agent/` **从来没被删过**，密钥留在盘上而界面说已清干净 | 卸载向导改三选一（保留 / 只删运行环境 / 完全删除）并在 `uninstall_callback` 按语义如实删除；破坏性删除前做路径白名单校验（只允许 `/vol<N>/@app{home,data,...}/hermes-studio`）；CI 门禁核对「向导每个选项都有对应处理分支」 |
| 28 | **微信策略写到内核读不到的路径** —— 写的是 `${DATA_DIR}/.hermes/.env`，而内核按 `HERMES_HOME` 读 `${TRIM_PKGHOME}/hermes-home/.env`。用户在安装向导勾「允许所有微信用户」完全不生效且无报错 | 落点改为 `hermes-home/.env`；写入后回读校验；CI 门禁拦死旧路径 |
| 29 | **只写不清的开关** —— 用户把「允许所有微信用户」关掉后，`.env` 里的 `WEIXIN_ALLOW_ALL_USERS=true` 仍在，策略实际没关 | `config_callback` 关闭时显式改回 `allowlist` / `false` |
| 30 | **端口写死，应用设置改不动** —— 桌面入口 `ui/config` 里 `port` 硬编码 8648，用户在应用设置里改端口后入口变了、服务还在老端口 | 向导新增 `wizard_port`，`ui/config` 用 `${wizard_port}`（fnOS 会替换；已装应用 `cleanfnos` 实证该机制存在），`cmd/main` 读取并做数字/范围校验，`config_callback` 改完端口主动重启 |
| 31 | **上游 `fnpack --version` 校验本身是坏的** —— `fnpack` 没有 `--version` 子命令（exit 1），上游 CI 里 `curl && chmod && mv && command -v && fnpack --version` 因此**永远失败**，加上 `continue-on-error` 就静默降级到 tar 兜底 | 新仓库改用 `command -v fnpack` 判断，fnpack 真正生效（实测走官方打包路径） |
| 32 | **向导文案与实现不符** —— 上游写「首次安装会自动下载 Node.js 运行时并全局安装 hermes-web-ui，请耐心等待」，实际是内置 bundled 运行时离线复制，几秒完成 | 文案按真实行为改写（内置依赖、安装很快、首启后台装内核） |
| 33 | **配置向导缺失** —— 上游没有 `wizard/config`，装完无法在应用设置里调整端口/微信策略 | 新增 `wizard/config` + `config_callback` 真正落地变更 |
| 34 | **上游在 `install_callback` 里注入 `trim-cli` 技能** —— `rm -rf` 用户技能目录后覆盖，会打回旧版 | 不内置任何技能；CI 门禁查内外两层 |
| 35 | **口径手抄多份 + 自检自证范围造假** —— 「只跟语义化 tag、拒绝日期式」这条规则同时抄在 `detect-upstream.py`、`build.yml`、`verify-fpk-gates.sh` 三处，且都写成 `v[0-9]+`/`\d+` 宽松形：注释与报错文本声明拒绝日期式，实现却放行上游的 `v2026.9.24`（major 是 4 位年份；上游 39 个 release 里 **36 个是日期式**）。当时没出事只因语义式恰好发布更晚。更糟的是第一版修复只收紧了两处、漏了第三处，而 selftest 只测自己的 Python 常量 —— 把 build.yml 改回宽松写法后 selftest 仍全绿，注释里「两侧由 selftest 钉住」是假的。另有空锚点静默兜底 `main`（与同文件「main 只允许显式写入」矛盾）、`published_at` 最新≠版本最高导致的锚点倒退、上游改回日期式后静默冻结 | **口径收敛为单一真源**：`detect-upstream.py` 的 `AGENT_TAG_PATTERN`/`ANCHOR_ERE`，限 major 最多 3 位（排 4 位年份又不误伤将来的 `v100.x.y`）；shell 侧一律调 `anchor-ok`/`gate-regex`，不再自带正则。**selftest 升级为四项契约**：① 标签串逐样本（含尾部换行脏值用 `fullmatch`）② 选取逻辑用构造 release 样本（prerelease/draft 过滤、`published_at` 排序、日期式让位）③ `ANCHOR_ERE` 与 Python 口径逐样本等价（且必须接受 `main`、拒绝空值）④ **全仓禁止宽松字面副本 + 消费方必须引用真源**。空锚点改为硬失败；tick 增加**倒退守卫**；两处静默失败路径打 `::error::`/`::warning::` 注解（埋在 6 小时长驻日志里等于没有）|
| 36 | **升级 fpk 不更新内核（用户实测暴露）** —— `install_callback` 见 `venv/bin/hermes` 存在就 `return 0`，`upgrade_callback` 又只比 hermes-web-ui 版本；两版 fpk 的 web-ui 都是 `0.7.35`，于是「版本匹配，无需重装」，内核路径根本走不到。**包内新内核只对全新机器生效**，老装机界面里的内核版本纹丝不动（用户原话：「我更新了 APK 之后系统内显示的内核还是 0.22.0」），只能手动 `hermes update`。另一个坑：`install.sh` 只在 `USE_VENV=true` 时导出 `VIRTUAL_ENV`，对齐时若用 `--no-venv` 复用环境却不自己导出它，依赖会被装到系统解释器上（污染系统且内核仍缺依赖） | **版本闸门 + 原地对齐**：单一真源 `app/config/bootstrap/ensure-kernel.sh`（`decide/installed/bundled`；已装版本优先 `hermes --version` 以识别用户自升级，回退 `.fpk-kernel-version` → `.bundled-agent-ref`；判不出/更旧一律 skip，绝不猜不降级）；`upgrade_callback` 与 `install_callback` 都过该闸门；对齐 = 旧内核**移到备份**（不是 `rm -rf`）→ 复制包内源码 → **把 venv 搬回复用**（`--no-venv` + 显式导出 `VIRTUAL_ENV`，避免重下 Python 3.14 与全部依赖）→ 官方 installer 同步依赖 → postinstall 硬校验 → 失败**回滚**并写 `marker=rolled-back`（不能写 `failed`：`cmd/main` 见 failed 会 `rm -rf` 内核重装，会把刚恢复的可用内核又删掉）；成功后写 `.fpk-kernel-version`。CI 门禁 fail-closed：内层必含闸门脚本 + `install_callback` 必含 `prealign/rolled-back/--no-venv/rollback_or_fail` + `upgrade_callback` 必含 `decide` 接线 + `build.yml` 跑 `ensure-kernel-selftest.sh`（17 用例：10 判定 + 7 界面版本） |
| 37 | **装完 fpk 界面版本显示无人验证（用户明确要求「更新后界面必须显示正常的当前版本」）** —— Studio 版本栏读的是 `hermes_cli.__version__`，它**只认内核树里的 `install-stamp.json` 的 `baseVersion`，不回退 git**：stamp 缺失/损坏 → 界面显示 `0.0.0`（而 `hermes --version` 同时还能显示 `git.<sha>`，两处不一致，极易误判成「内核坏了」）。旧 postinstall 的 stamp 写入是**软行为**（锚点解析不出/写失败只打 WARNING 就 `exit 0`），且「已有可用 stamp 就不动」——内嵌源码若自带 stamp 就会被留下，界面显示的不是本包版本。实测取证：把包内源码原样铺成内核树后跑 Studio 的探测命令 → `0.0.0`（`hermes --version` 显示 `git.35ce5d9`） | **显示版本硬门禁**：`ensure-kernel.sh` 新增 `displayed`（逐字执行 Studio 前端的探测命令 `python -c "...print(hermes_cli.__version__)"`）与 `assert-displayed`（第 1 行 `OK/MISMATCH/SKIP`，`v` 前缀走 `norm_ver` 归一化）；`install_callback` 在对齐/新装复制源码后先 `rm -f install-stamp.json`，再把本包锚点作 `--expect-version` 传给 postinstall；postinstall 在硬门禁模式下**强制按锚点重写** stamp（不符即重写）并断言界面显示值 == 锚点，不符则 `exit 1` → 对齐路径回滚旧内核。CI 门禁 fail-closed：内层必含 `ensure-kernel.sh` 的 `displayed/assert-displayed` 与**与前端一致的探测面**（`hermes_cli.__version__` + `find_spec('hermes_cli.main')`）、postinstall 必含 `--expect-version` + `assert-displayed` 调用、install_callback 必含两要素、包内锚点 == 内嵌源码 `.bundled-agent-ref` |
| 38 | **门禁的 grep 把 `--no-venv` 当选项解析（run#7 构建红）** —— `printf '%s' "$IC" \| grep -qF "$need"`，`$need` 是以 `-` 开头的字面量时 grep 报 `unrecognized option '--no-venv'` → 断言恒判「缺失」→ 构建必红；同时 `printf \| grep -q` 命中即早退还有 SIGPIPE 假阴性风险 | 清单先写文件再 `grep -qF -- "$need" <file>`（`--` 终止选项解析）；本机干跑脚本对每条断言做变异验证（删掉要素必须判红，且不能只靠注释命中） |
| 39 | **fnOS Connect（远程访问）小窗打不开：manifest 缺 `service_port` + 多写了 `micro_app=true`（用户实测暴露）** —— 现象=在 Connect 模式下点桌面图标，浏览器报 `hermes-studio.mickeytt.fnos.net 拒绝连接`（ERR_CONNECTION_REFUSED），本地直连/其他应用都正常。取证：① 桌面前端拼 URL 的规则是 `de && e.fnDomain && e.port → https://<fnDomain>.<host><path>`，否则退回 `host:port`；② 全机对比——能走 Connect 的端口型应用**都**在 manifest 里声明了 `service_port`（cliproxyapi 8317 / wildwork 7863 / lemon-music 7983 / cleanfnos 47939），进程 env 里 `TRIM_SERVICE_PORT` 非空；而本应用进程 env 是 **`TRIM_SERVICE_PORT=`（空）**，manifest 里没有该字段（官方打包文档 §8.3：`TRIM_SERVICE_PORT` 的来源就是 manifest 的 `service_port`）；③ 另一个差异=`micro_app = true`（继承自上游 veenyi 的 fpk）——该标记属于「经统一网关按路径服务」的微应用形态（fygo-browser：`service_port=0` + `gatewaySocket/gatewayPrefix` + `url=/app/<name>`），我们是端口型入口，带它会让桌面按微应用路由访问，而本应用没有网关 socket 上游 | ① manifest 声明 `service_port = 8648`；② 删掉 `micro_app = true`；③ `cmd/main` 端口改三级优先级（`wizard_port` → `TRIM_SERVICE_PORT` → 默认 8648，与官方文档 §8.3 同序）；④ 构建期 fail-closed 门禁两处（build.yml 的 manifest 校验 + `verify-fpk-gates.sh` 对产物 manifest）：**缺 `service_port` 或声明 `micro_app=true` 即中止构建**。⚠️ 副作用须知：`service_port` 打包时固定，用户在应用设置里改端口后该值不会跟着变（官方文档已记载），Connect 上游仍指向旧端口 —— 需要改端口时同步改 manifest 重新出包 |
| 41 | **远程访问最终定案：必须与 CLIProxyAPI 同形（用户拍板「cliproxyapi 最合理」）** —— #40 的「统一网关路径型 + socket 桥」方案实测同样打不开：按该形态重装 0.7.35-7 后 `trim_sac.entry` 已注册 `gateway_socket=/var/apps/hermes-studio/target/app.sock`、`gateway_prefix=/app/hermes-studio`、桥进程与 `app.sock` 都在，但 Connect 下点图标仍失败。逐字段对比 CLIProxyAPI（用户实测可远程）后，剩下的实质差异只有三处：① `allUsers`：我们 `false` → 系统把入口标成 **admin-only**（`trim_sac.entry.is_admin=true`），而全机可远程的第三方 iframe 应用（cliproxyapi/cleanfnos/wildwork）全是 `allUsers:true`/`is_admin=false` —— 远程那条报错正是「暂无权限访问该服务」（权限面）；② ui/config 端口写的是模板 `${wizard_port}` 而非字面量（cliproxyapi 写死 8317）；③ 我们多了个「直连」入口 + `control` 块（cliproxyapi 单入口、无 control）。CLIProxyAPI 的形态还包含：**没有 wizard**（无端口字段）、manifest `service_port=8317` 与入口端口一致 | **照抄 CLIProxyAPI**：`app/ui/config` 收敛为**单入口** `type:iframe` + `protocol:http` + **字面量 `port:8648`** + `url:"/"` + **`allUsers:true`**（去掉 gateway 键、去掉第二个入口、去掉 control）；`wizard/install` 与 `wizard/config` **删除端口字段**（端口固定 8648，与入口/manifest 三者一致，改端口需重新出包）；`cmd/main` 端口链去掉 `wizard_port`（`TRIM_SERVICE_PORT`→8648），并**移除网关桥全部代码与随包脚本**；门禁相应改为 fail-closed：**ui/config 入口端口 == manifest `service_port`**、**所有入口必须 `allUsers:true`**、带 port 入口必须 iframe、protocol=http。⚠️ 代价：端口不再能在应用设置里改（与 CLIProxyAPI 一致）；历史 #30 的「端口可配」特性随本次收敛回退。 |
| 37 | **装完 fpk 界面版本显示无人验证（用户明确要求「更新后界面必须显示正常的当前版本」）** —— Studio 版本栏读的是 `hermes_cli.__version__`，它**只认内核树里的 `install-stamp.json` 的 `baseVersion`，不回退 git**：stamp 缺失/损坏 → 界面显示 `0.0.0`（而 `hermes --version` 同时还能显示 `git.<sha>`，两处不一致，极易误判成「内核坏了」）。旧 postinstall 的 stamp 写入是**软行为**（锚点解析不出/写失败只打 WARNING 就 `exit 0`），且「已有可用 stamp 就不动」——内嵌源码若自带 stamp 就会被留下，界面显示的不是本包版本。实测取证：把包内源码原样铺成内核树后跑 Studio 的探测命令 → `0.0.0`（`hermes --version` 显示 `git.35ce5d9`） | **显示版本硬门禁**：`ensure-kernel.sh` 新增 `displayed`（逐字执行 Studio 前端的探测命令 `python -c "...print(hermes_cli.__version__)"`）与 `assert-displayed`（第 1 行 `OK/MISMATCH/SKIP`，`v` 前缀走 `norm_ver` 归一化）；`install_callback` 在对齐/新装复制源码后先 `rm -f install-stamp.json`，再把本包锚点作 `--expect-version` 传给 postinstall；postinstall 在硬门禁模式下**强制按锚点重写** stamp（不符即重写）并断言界面显示值 == 锚点，不符则 `exit 1` → 对齐路径回滚旧内核。CI 门禁 fail-closed：内层必含 `ensure-kernel.sh` 的 `displayed/assert-displayed` 与**与前端一致的探测面**（`hermes_cli.__version__` + `find_spec('hermes_cli.main')`）、postinstall 必含 `--expect-version` + `assert-displayed` 调用、install_callback 必含两要素、包内锚点 == 内嵌源码 `.bundled-agent-ref` |
| 38 | **门禁的 grep 把 `--no-venv` 当选项解析（run#7 构建红）** —— `printf '%s' "$IC" \| grep -qF "$need"`，`$need` 是以 `-` 开头的字面量时 grep 报 `unrecognized option '--no-venv'` → 断言恒判「缺失」→ 构建必红；同时 `printf \| grep -q` 命中即早退还有 SIGPIPE 假阴性风险 | 清单先写文件再 `grep -qF -- "$need" <file>`（`--` 终止选项解析）；本机干跑脚本对每条断言做变异验证（删掉要素必须判红，且不能只靠注释命中） |
| 39 | **fnOS Connect（远程访问）小窗打不开：manifest 缺 `service_port` + 多写了 `micro_app=true`（用户实测暴露）** —— 现象=在 Connect 模式下点桌面图标，浏览器报 `hermes-studio.mickeytt.fnos.net 拒绝连接`（ERR_CONNECTION_REFUSED），本地直连/其他应用都正常。取证：① 桌面前端拼 URL 的规则是 `de && e.fnDomain && e.port → https://<fnDomain>.<host><path>`，否则退回 `host:port`；② 全机对比——能走 Connect 的端口型应用**都**在 manifest 里声明了 `service_port`（cliproxyapi 8317 / wildwork 7863 / lemon-music 7983 / cleanfnos 47939），进程 env 里 `TRIM_SERVICE_PORT` 非空；而本应用进程 env 是 **`TRIM_SERVICE_PORT=`（空）**，manifest 里没有该字段（官方打包文档 §8.3：`TRIM_SERVICE_PORT` 的来源就是 manifest 的 `service_port`）；③ 另一个差异=`micro_app = true`（继承自上游 veenyi 的 fpk）——该标记属于「经统一网关按路径服务」的微应用形态（fygo-browser：`service_port=0` + `gatewaySocket/gatewayPrefix` + `url=/app/<name>`），我们是端口型入口，带它会让桌面按微应用路由访问，而本应用没有网关 socket 上游 | ① manifest 声明 `service_port = 8648`；② 删掉 `micro_app = true`；③ `cmd/main` 端口改三级优先级（`wizard_port` → `TRIM_SERVICE_PORT` → 默认 8648，与官方文档 §8.3 同序）；④ 构建期 fail-closed 门禁两处（build.yml 的 manifest 校验 + `verify-fpk-gates.sh` 对产物 manifest）：**缺 `service_port` 或声明 `micro_app=true` 即中止构建**。⚠️ 副作用须知：`service_port` 打包时固定，用户在应用设置里改端口后该值不会跟着变（官方文档已记载），Connect 上游仍指向旧端口 —— 需要改端口时同步改 manifest 重新出包 |
| 40 | **fnOS Connect（远程访问）小窗仍打不开：端口型入口走的是应用子域路由（承接 #39，实测推翻「只补 service_port 就够」）** —— 补上 `service_port` 后重装（0.7.35-5），`appcenter.app.service_url` 已从空变成 `://${host}:8648/`（与 cliproxyapi 同形），但用户实测 Connect 下点图标**依旧**报 `hermes-studio.mickeytt.fnos.net 拒绝连接`。取证：桌面前端拼 URL 的规则是「远程模式 + `fnDomain` + `port` → `https://<fnDomain>.<当前域><path>`」——端口型入口在远程下必然走**应用子域**；而该子域在 relay 侧一律返回「FN Connect 暂无权限访问该服务」（连不存在的子域也一样，未登录无区分度），子域→本地端口的映射无法从本机验证/修复。**反例即正解**：`wild-work-fpk` 的主入口用的是**统一网关路径型**（`gatewaySocket: "app.sock"` + `gatewayPrefix: "/app/wildwork"`，不带 port），其安装向导明写「主入口走统一网关，局域网和飞牛远程都能打开」，并且随包带 `bridge/`（Go 版 `wwbridge`：unix socket → 127.0.0.1:7863，含前缀剥离、裸前缀 301 补斜杠、Host/Origin 同源对齐与 `Sec-Fetch-*` 注入以防 CSRF 误拦） | **改用与 wild-work 同款的「统一网关 + 路径型入口 + 本地 socket 桥」**：① `app/ui/config` 主入口改 `protocol:""` + `gatewaySocket:"app.sock"` + `gatewayPrefix:"/app/hermes-studio"` + `url:"/app/hermes-studio"`（不再带 port），另增 `hermes-studio.direct` 端口直连入口（协议显式 `http`，保留端口可改）；② 新增随包桥 `app/bin/gw-bridge.mjs`（Node 实现，无 Go 依赖）：前缀剥离 / 裸前缀 301 / 无前缀透传 / **WebSocket 透传（Socket.IO 必需）** / Host-Origin 对齐 / 残留 socket 探测接管 / `SIGTERM` 清 socket；③ `cmd/main` 增 `start_gateway_bridge`/`stop_gateway_bridge`（定义+调用，启动后等 socket 可连；清理函数一并杀桥进程与死 socket）；④ 门禁 fail-closed：产物 ui/config 必须「主入口 = 网关路径型且不带 port」+「至少一个带 port 的直连入口」、内层必含 `bin/gw-bridge.mjs`、`cmd/main` 的网关桥函数必须**定义+调用各 ≥1 次**（只查字符串存在会漏拦：`foo() {` 定义行本身也算命中，干跑变异实测）。本机实测桥行为 7 项全过（前缀剥离/301/首页/静态/无前缀/同源注入/WS 透传）。⚠️ service_port 保留（直连入口与系统端口检查仍需），但它不是远程访问的充分条件 |

---

## 许可证

上游 Ekko Studio 为 **BSL 1.1**（个人 / 教育 / 研究可用；商用需授权，2029 转 Apache 2.0）。
本仓库仅作 fnOS 打包分发，自用无碍，对外分发 / 商用前请确认。
