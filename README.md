# ekko-studio-fpk

飞牛 fnOS 上的 **Ekko Studio** 安装包（FPK）。自动跟随上游
[EKKOLearnAI/ekko-studio](https://github.com/EKKOLearnAI/ekko-studio) 构建，下载即装。

## 包信息

| 项 | 值 |
|---|---|
| 包名（appname） | `hermes-studio`（技术标识，勿改，决定数据目录与升级） |
| 显示名 | Ekko Studio（应用中心里看到的） |
| 服务端口 | `8648`（默认；可在「应用设置」中修改） |
| 内置内核 | hermes-agent `v0.22.1`（离线源码包，首启免联网） |
| 上游版本 | hermes-web-ui `0.7.35` |
| 产物文件名 | `fnos-ekko-studio_v<版本>.fpk` |

## 本包改动（相对上游原版）

- **桌面小窗修复**：上游默认禁止 iframe 嵌入，本包三层补丁（构建期预打 + 启动自愈 + 门禁），fnOS 桌面小窗直接可用。
- **零隐私绑定**：白名单只含「本机地址（自动枚举）+ localhost」，不写死任何打包者 IP/域名；自己的域名入口本地补一行配置文件即可。
- **IPv6 / 反代 / 远程可用**：双栈监听 + CORS 注入，WebSocket 不再被拒。
- **离线安装**：内置 Agent 离线源码包与运行依赖（browser tools / TUI / node-pty），弱网也能装、首启不联网编译。
- **可配置**：端口可在应用设置中修改；提供安装向导与配置向导（含微信策略开关）。
- **升级即同步内核**：装新版本 fpk 时按包内锚点把运行内核带到同版本（离线、复用已有 Python 环境、失败自动回滚）；用户自己用 `hermes update` 升到更新版本时绝不回退。
- **远程访问可用**：入口形态与 CLIProxyAPI 一致（单入口 iframe + 固定端口 8648 + `allUsers:true`）；小窗默认**不限制父页面**（`frame-ancestors *`）—— 局域网、飞牛 Connect、自有域名/反代/IPv6 直连都能在桌面窗口内打开（需要收紧时设 `FRAME_ANCESTORS_STRICT=1`）。
- **界面版本如实显示**：装完实测断言「Studio 版本栏显示的内核版本 == 本包内核版本」（探测面与前端逐字一致），显示不出来即判安装失败并回滚 —— 不会出现「装完了界面还写着旧版本 / `0.0.0`」。
- **自动守护**：内核更新通道预置（`hermes update` 可用）；服务崩溃自愈 + 系统级 cron 守护。
- **卸载如实清理**：保留 / 只删运行环境 / 完全删除，三选一。

## 下载与安装

- 下载：见 [Releases](https://github.com/mickeyttsc/ekko-studio-fpk/releases) 页附件（`fnos-ekko-studio_v<版本>.fpk`）
- 安装：飞牛应用中心 → 手动安装 → 选择 fpk。

## 维护

构建链路、目录结构、门禁与历史坑位：[MAINTAINING.md](MAINTAINING.md)

## 许可证

上游 Ekko Studio 为 **BSL 1.1**（个人 / 教育 / 研究可用；商用需授权，2029 转 Apache 2.0）。本仓库仅作 fnOS 打包分发。
