# ADR-007: 第十语种俄语与预算按实测上调

- **状态 / Status**: Accepted
- **守护铁律**: [`AGENTS.md`](../../AGENTS.md) 10 语种一等公民 · **门禁**: [`bundle-budget.test.mjs`](../../test/gates/bundle-budget.test.mjs)、[`architecture-fitness.test.mjs`](../../test/gates/architecture-fitness.test.mjs)、[`i18n-and-version-sync.test.mjs`](../../test/gates/i18n-and-version-sync.test.mjs)

## 背景 / Context
本分支维护者要求把 `ru` 做成与 `tr` 同级的第 10 种界面语言。俄语用 UTF-8 西里尔字母（多数字符 2 字节），不能再塞进已经贴着 Law 2 棘轮的单体文件，也不能继续把 `pulse-vial-bridge.js` 锁在为 9 语拉丁列标定的 31,000 B。

## 决策 / Decision
1. `ru` 与既有 9 语一样进入 `i18n-core`、schema、宿主词库与各表面；词条放在 sidecar（`i18n-ru-locale.js`、`ru.json`、`swarm-ru.json` 及各 `*-i18n-ru.js`），运行时再挂上，避免把整表写进已棘轮的单体。
2. `pulse-vial-bridge.js` 硬上限由 `< 31,000 B` 调到 `< 31,400 B`：第 10 列西里尔文实测把文件从 30,671 B 增到 31,047 B。只放宽这一处断言，不关闭门禁。
3. 少数必须内联一列俄语的遗留文件，其 `maxBytes` / `maxLines` 只抬到新文件体积（`home-studio-panel.js`、`host-workbench-enhancer.js`、`usage-core.js`、`vendor/effort-slider/upstream-client.js`、`vendor/omni-viewer/workbench-page.mjs`、`vendor/prompt-suggester/suggester-service.mjs`）。新文件仍守 800 行 / 40 KB。
4. Ch1 `< 390,000 B`（实测 `ru = 385,757 B`）与 `configRefresh < 4,096 B`（实测 `3,963 B`）保持不动。
5. 设置通道预算由 `500 KiB` 调到 `530 KiB`：压缩后的俄语 UI 表和表面词条让载荷从约 507 KiB 增到 536,319 B。首页 Studio 通道由 `56 KiB` 调到 `57 KiB`：俄语首页行让载荷增到 57,617 B。
6. `getRuntimeUiSlice` 单语上限由 `4,096 B` 调到 `5,120 B`。九语里最大的日语切片是 3,550 B；俄语切片实测 4,494 B，因为西里尔字母按 2 字节计。这不是 `configRefresh` 的 4,096 B 门禁。
7. 周期表通道的功能测试天花板由 `830,000 B` 调到 `840,000 B`。两份俄语 sidecar 编进通道 8 后载荷为 837,418 B，仍低于注册表预算 `820 KiB`（839,680 B）。注册表预算没有上调。

## 为什么绝不能改回去 / Why Never Revert
删掉 `ru` 或把脉冲桥上限收回到 31,000 B 会让俄语界面无法选择，或让已含第 10 列的桥接文件无法通过门禁。继续把俄语词条内联进贴线单体则会重新撞上体积棘轮。
