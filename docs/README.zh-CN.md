<div align="center">

<img src="../assets/logo.svg" width="96" height="96" alt="Obsidian Prism Logo" />

# Obsidian Prism · 黑曜棱镜（俄语版分支 / Russian Edition）

**为 Google Antigravity 打造的原生光学界面套件 — 俄语本地化分支**

> 本仓库（[`daimestrike/obsidian-prism`](https://github.com/daimestrike/obsidian-prism)）是基于原作者 [@RMvdesi](https://github.com/RMvdesi) 的 **[Obsidian Prism](https://github.com/RMvdesi/obsidian-prism)**（`GPL-3.0`）维护的**俄语版本分支（Русская версия）**，新增完整俄语（`ru`）一等界面本地化与俄语主文档。

四套深浅配色 · 会呼吸的 512K 上下文试管 · 推理等级滑块 · 像素伙伴 · 自定义动静态壁纸（Beta）· Chat 对话模式（Beta）

[**Русский**](../README.md) · [**English**](../README.en.md) · [**简体中文**](./README.zh-CN.md) · [**更新日志 (CHANGELOG)**](../CHANGELOG.md) · [**问题反馈 (Issues)**](https://github.com/daimestrike/obsidian-prism/issues) · [**上游原仓库 (Upstream)**](https://github.com/RMvdesi/obsidian-prism)

<p>
  <img src="https://img.shields.io/badge/Edition-%D0%A0%D1%83%D1%81%D1%81%D0%BA%D0%B0%D1%8F%20%D0%B2%D0%B5%D1%80%D1%81%D0%B8%D1%8F%20(ru)-2563eb?style=flat-square" alt="Russian Edition" />
  <img src="https://img.shields.io/badge/Version-1.0.8--beta.4-0f172a?style=flat-square" alt="Version 1.0.8-beta.4" />
  <img src="https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20Universal-1e293b?style=flat-square" alt="Platform" />
  <a href="https://github.com/daimestrike/obsidian-prism/actions"><img src="https://img.shields.io/github/actions/workflow/status/daimestrike/obsidian-prism/ci.yml?branch=main&style=flat-square&label=CI" alt="CI Status" /></a>
  <a href="../LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0-2563eb?style=flat-square" alt="License: GPL-3.0" /></a>
  <a href="../NOTICE"><img src="https://img.shields.io/badge/Attribution-Required%20(NOTICE)-8b5cf6?style=flat-square" alt="Attribution Required" /></a>
</p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../assets/screenshots/hero-dark.webp" />
  <source media="(prefers-color-scheme: light)" srcset="../assets/screenshots/hero-light.webp" />
  <img src="../assets/screenshots/hero-dark.webp" width="100%" alt="Obsidian Prism v1.0.8-beta.4 界面演示" />
</picture>

<sub>以上画面由离线渲染舞台直接运行本仓库前端源码逐帧录制，示例工作区与对话内容均为虚构。</sub>

</div>

> **非官方社区项目与商标免责声明 (Non-Affiliation Disclaimer)**
>
> **Obsidian Prism is an independent open-source project and is not affiliated with or endorsed by Google LLC.**
> 本项目为独立的开源社区工程，与 Google LLC 无任何隶属、赞助或官方背书关系；文中提及的 “Antigravity” 与 “Google” 仅作兼容性说明用途。

---

## 亮点

- **完整俄语本地化（`ru`）**：将俄语作为第 10 种一等界面语言内置于外观设置、工作台、Omni 检视台、Chat 模式与思考翻译中。
- **四套配色，一键换装**：深空黑曜、暖炭玄岩两套深色，白昼冷晶、暖白画册两套浅色，可跟随系统亮暗自动切换。
- **看得见的上下文**：输入框旁的小试管实时显示 512K 上下文用量，点开就能看到用量拆分和配额剩余预测。
- **推理等级，一拨就换**：模型菜单里内置星空滑块；选中 Orchestrator 时，滑块会变成一条会折射光线的切工水晶。
- **读得懂的思考过程与标题**：模型的思考内容支持实时转译（沉浸 / 双语对照）与一键诊断，支持手动 HTTP/SOCKS5 代理、可选工具摘要与会话标题自动翻译。
- **自定义动静态背景壁纸（Beta）**：位于设置「Beta 内容」分类，默认关闭零占用，支持纯本机只读加载自定义图片与 MP4/WebM 动态视频背景（实验性功能，交互与表现可能随版本持续调整）。
- **桌面上的像素伙伴**：Clawd、小紫猫和三只迷你蟹会在输入框上方玩叠叠乐，还藏着一个彩虹彩蛋。
- **更顺手的工作台**：内置浏览器和大文件检视台、右键快捷菜单、长代码块折叠、会话大纲快速跳转。
- **Chat 对话模式（Beta）**：在写代码之外，多了一个专门聊天、整理资料的空间，和工程设置互不干扰。
- **轻、快、守规矩**：动画空闲时自动降到 0fps；本地服务只监听本机；设置改动 10 毫秒内生效，随时一键卸载还原。

---

## 界面预览

### 1. 四套配色

<p align="center">
  <img src="../assets/screenshots/palettes.webp" width="100%" alt="四套深浅配色方案" />
</p>

| 主题预设 | 配置键值 | 侧栏底色 | 主画布 | 说明 |
| :--- | :--- | :--- | :--- | :--- |
| **深空黑曜** | `palette: "obsidian"` | `#09090B` | `#0E0E11` | 冷调深灰底色，高对比度代码阅读配色 |
| **暖炭玄岩** | `palette: "warm"` | `#10100F` | `#141413` | 暖炭褐底色，低蓝光夜间配色 |
| **白昼冷晶** | `lightPreset: "crystal"` | `#E8EEF6` | `#F4F7FB` | 冷调浅灰蓝侧栏与高明度工作区 |
| **暖白画册** | `lightPreset: "alabaster"` | `#EBE6DC` | `#F6F4EE` | 暖白纸色背景，柔和对比度浅色配色 |

### 2. 光学细节：上下文试管 · 推理滑块 · 切工水晶

点击底部试管可展开用量浮窗，查看上下文切片、5 小时配额与模型池余量；模型菜单里的推理等级滑块随档位点亮星辰，Orchestrator 则显示为切工水晶条。

<p align="center">
  <img src="../assets/screenshots/optics.webp" width="100%" alt="512K 上下文试管、推理等级滑块与 Orchestrator 切工水晶" />
</p>

### 3. 像素伙伴

输入框上方的像素伙伴可以拖拽、叠成 5 层高塔；满足特定条件时，小紫猫会披上彩虹极光（无操作时自动休眠，可在设置中关闭）。

<p align="center">
  <img src="../assets/screenshots/companions.webp" width="100%" alt="像素伙伴叠叠乐与彩虹彩蛋" />
</p>

### 4. Chat 对话模式（Beta）

默认关闭，可在 **设置 → 外观 → Beta 内容** 中开启。开启后侧栏顶部可在 Code 与 Chat 之间切换，用文件夹整理日常对话，权限按项目隔离，不改动全局工程设置。

<p align="center">
  <img src="../assets/screenshots/chat-mode.webp" width="100%" alt="Chat 对话模式（Beta）" />
</p>

### 5. 更多能力

- **外观设置中心**：集成在 **设置 → 外观**，双栏光学布局、**10 种界面语言**（简中/繁中/英/日/韩/西/法/德/土耳其语/俄语）、**39 项**端到端可校验面板设置（底层配置契约共 **54 项**键，含侧栏导航折叠 `sidebarNavFold`、滚底动效 `scrollBottomMotion` 与「正式版 / Beta 尝鲜版」双更新通道）、三档场景预设（完整光效 / 专注编码 / 静默省电）、配置备份恢复与面板内一键更新。
- **思考转译与标题翻译**：按需加载模块，关闭态默认零注入并支持热插拔；内置免配置机器翻译与本地/兼容模型流式转译，支持 OS 系统代理自动检测与手动 HTTP/SOCKS5 代理、可选工具摘要与会话标题自动翻译、卡片顶部「一键诊断」及源码路径/行号跳转。
- **自定义静态 / 动态视频壁纸（Beta）**：实验性按需加载模块，默认关闭零占用；纯本机只读加载图片（JPG/PNG/WebP/GIF/AVIF）与动态视频（MP4/WebM），支持透明度/模糊/护眼遮罩调节、Browser Hole 自动避让及失焦/隐藏自动 `0fps` 暂停。
- **Omni 检视台与行内 Diff 预览**：裸链接、本地路径一键在侧栏打开，文件变更支持行内 Diff 预览；超大视频、音频、PDF、表格、字体流式预览，右键菜单复制路径、定位文件、插入引用。
- **Smoked Obsidian 切面与工作台增强**：统一烟熏黑曜消息气泡、变更条、Artifact 卡片与石墨键帽；代码块顶栏吸顶、长代码块手动折叠、左侧会话导轨独立大纲入口与悬停大纲、`Alt+↑` / `Alt+↓` 上下轮跳转，以及会话区右键 `/btw` 侧边提问与 `/compact`、`/plan`、`/learn`、`/grill-me` 原生斜杠快捷指令。

---

## 快速安装指南 (Quick Start)

### 方式一：从本俄语版仓库源码部署为 Antigravity 原生插件（推荐）
```bash
git clone https://github.com/daimestrike/obsidian-prism.git
cd obsidian-prism

# 部署至 ~/.gemini/config/plugins/obsidian-prism 并立即连接当前窗口
npm run install:plugin
```
安装完成后打开 **设置 (Settings) → 外观 (Appearance)**，展开 **「Obsidian Prism」** 区域并在语言中选择 **Русский**（或其他 9 种内置语言）。

### 方式二：本地构建独立安装包（Windows `.exe` / macOS `.dmg`）
```bash
npm run build:installer   # Windows 独立安装器 (.exe)
npm run build:macos       # macOS Universal 安装包 (.dmg)
```
> 提示：上游原版预编译安装包位于 [`RMvdesi/obsidian-prism/releases`](https://github.com/RMvdesi/obsidian-prism/releases)，不包含本分支的俄语版本改动；如需俄语版请使用上述源码安装或本地构建。

### AI 助手代装标准流程 & 思考翻译排查清单
如果你使用 AI 助手（Claude Code、Cursor、Antigravity Agent 等）协助从源码安装，请**严格执行以下标准命令**完成部署与验收：
```bash
git clone https://github.com/daimestrike/obsidian-prism.git
cd obsidian-prism

# 1. 必须执行完整本地插件部署（同步全部模块并启动后台常驻守护进程）
npm run install:plugin

# 2. 必须执行安装状态自检，确认后台守护与按需模块均已就绪
node tools/install-plugin.cjs --status
```
- **严禁仅执行 `npm run inject` 替代安装**：`npm run inject` 仅做单次临时前端注入，**不会**将插件部署至 `~/.gemini/config/plugins/obsidian-prism`，也**不会**启动常驻后台守护进程——这会导致思考翻译、本地遥测与动态壁纸等后台服务功能离线，且在窗口刷新、重启或更新后立即失效。
- **核对 `--status` 自检项**：确认返回 JSON 中 `installed: true`、`daemonAlive: true`、`hasThoughtTranslator: true`、`hasWallpaperChannel: true`；若 `bareAntigravityRunning: true`（常见于客户端在线更新后裸启），请关闭 Antigravity 并通过已自动补齐 `--remote-debugging-port=0` 的桌面/开始菜单快捷方式重开一次即可激活。
- **思考过程翻译排查清单**：
  1. **出厂默认关闭**：思考过程翻译默认关闭（`thoughtTranslate: "off"`，零注入），安装后需打开 **设置 (Settings) → 外观 (Appearance) → Obsidian Prism**，手动切换为 **机器翻译（免配置）** 或 **AI 模型流式转译**（按需可同时开启「会话标题自动翻译」）。
  2. **开启后无反应**：点击思考翻译设置卡片顶部的 **「一键诊断」** 按钮，即可一键核验守护桥接在线态、当前模式/模型配置、系统代理与上游网络连通性；也可重新执行 `node tools/install-plugin.cjs --status` 确认 `daemonAlive: true`。
  3. **更新或裸启后样式暂时回退**：若客户端刚完成在线自动更新且当次裸启无调试端口，接受守护进程弹出的温和重开恢复提示，或直接通过桌面/开始菜单快捷方式重启一次 Antigravity 即可恢复。

---

## 开源协议与署名说明

> Built upon [Obsidian Prism](https://github.com/RMvdesi/obsidian-prism) by [@RMvdesi](https://github.com/RMvdesi), licensed under [GPL-3.0](https://www.gnu.org/licenses/gpl-3.0.html). Upstream component notices are preserved in [`NOTICE`](../NOTICE) and [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).

完整许可证、上游开源项目致谢与社区贡献者名单请参见主文档 [**`README.md`（Русский）**](../README.md)、[**`README.en.md`**](../README.en.md)、[**`LICENSE`**](../LICENSE)、[**`NOTICE`**](../NOTICE)、[**`THIRD_PARTY_NOTICES.md`**](../THIRD_PARTY_NOTICES.md) 与 [**`docs/CONTRIBUTORS.md`**](./CONTRIBUTORS.md)。
