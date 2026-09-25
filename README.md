# ekko-studio-fpk

跟随上游 [EKKOLearnAI/ekko-studio](https://github.com/EKKOLearnAI/ekko-studio) 自动打包飞牛 fnOS 的 **FPK** 安装包。

- **上游**：`EKKOLearnAI/ekko-studio`（原 `EKKOLearnAI/hermes-studio`，同一仓库改名）
- **产物**：`fnos-hermes-studio_v<version>.fpk`
- **appname**：`hermes-studio`（技术标识，数据目录名）
- **display_name**：`Ekko Studio`（应用中心显示名）
- **服务端口**：8648

> `appname` 是给系统认的技术标识（决定 `@apphome/@appconf/@appdata` 三个数据目录名、
> 服务用户名、桌面启动项 ID）。改它等于换应用，当前实例会断且必须迁移数据。
> 用户看到的名字由 `display_name` 控制。

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
curl -X POST -H "Authorization: Bearer $TOK" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/mickeyttsc/ekko-studio-fpk/actions/workflows/build.yml/dispatches \
  -d '{"ref":"main"}'

# 手动触发上游巡检
curl -X POST -H "Authorization: Bearer $TOK" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/mickeyttsc/ekko-studio-fpk/actions/workflows/auto-update.yml/dispatches \
  -d '{"ref":"main"}'

# 查最近运行
curl -s -H "Authorization: Bearer $TOK" \
  "https://api.github.com/repos/mickeyttsc/ekko-studio-fpk/actions/runs?per_page=5"
```

下载最新包：

```bash
# 滚动最新版
curl -fL -o fnos-hermes-studio.fpk \
  https://github.com/mickeyttsc/ekko-studio-fpk/releases/download/latest/fnos-hermes-studio.fpk

# 固定版本
curl -fL -o fnos-hermes-studio_v0.7.24-6.fpk \
  https://github.com/mickeyttsc/ekko-studio-fpk/releases/download/v0.7.24-6/fnos-hermes-studio_v0.7.24-6.fpk
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
# 产物: dist/fnos-hermes-studio_v<version>.fpk
```

构建需要联网（下载上游产物 + Agent 离线源码）。首次构建会下载约 130MB 的
web-ui 预构建产物，并编译/镜像 Agent 的 node 依赖。

**本地手打的包不算 CI 链路可用的证据** —— 只认 Actions 绿跑的 artifact 或 Release 附件。

---

## 验证

```bash
# 双层内容校验（外层条目 + 内层 app.tgz）
bash scripts/verify-fpk-content.sh dist/fnos-hermes-studio_v0.7.24-6.fpk

# 上游探测逻辑（可脱离 CI 单独跑）
export GITHUB_TOKEN=$(cat ~/.config/github/token)
python3 scripts/detect-upstream.py webui
python3 scripts/detect-upstream.py agent
python3 scripts/detect-upstream.py sha256 0.7.24

# 改完 .github/workflows/ 先跑静态体检（不用等 CI 往返）
python3 scripts/validate-gh-workflows.py .github/workflows

# 回读 Release 附件（验收标准：附件存在且能下载，不是 workflow 显示 success）
GITHUB_REPOSITORY=mickeyttsc/ekko-studio-fpk GITHUB_TOKEN=$TOK \
  python3 scripts/verify-release-asset.py v0.7.24-6 dist/fnos-hermes-studio_v0.7.24-6.fpk
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

---

## 升级已装应用

fnOS 没有本地 fpk 升级命令（`appcenter-cli install-fpk` 对已装应用直接拒，
CLI 无 upgrade 子命令）。可行路径 = **应用中心 UI 手动安装新 fpk**，
或在应用中心里选择升级。装完跑一次验收清单。

内核（Hermes Agent）**不会**随 fpk 升级：`install_callback` 检测到
`venv/bin/hermes` 存在即跳过。内核升级走 `hermes update`。

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

---

## 许可证

上游 Ekko Studio 为 **BSL 1.1**（个人 / 教育 / 研究可用；商用需授权，2029 转 Apache 2.0）。
本仓库仅作 fnOS 打包分发，自用无碍，对外分发 / 商用前请确认。
