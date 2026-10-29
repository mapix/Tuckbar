# MacMenuY 残留问题交接

更新：2026-10-29。本文优先于旧验证文档中的虚拟机计划及过期 checkpoint。

## 1. 交接结论

**应用尚未达到用户要求的“全部 solid 后体验”。我没有完成根因定位和最终运行验收。没有证据证明这些问题是 macOS 无法支持。**

用户报告：收纳栏里重新展示的所有图标，双指右键不能像原菜单栏一样打开下拉选项。后续测试取得了一个真实原生菜单打开样本，但它携带了意外的 Command；另一条无修饰键的后端诊断打开了菜单，却没有执行菜单选项选择。因此不能把这两个样本扩张为“所有图标右键已修好”。

优先解决：

1. 真实收纳栏输入的修饰键是否被错误携带，以及来源。
2. 原菜单能否稳定保持、接受原生选项选择，尤其隐藏后临时移出的图标。
3. 完成修复后，对真实应用与两种原生 fixture 做完整回归，并验证退出恢复。

## 2. 用户最终要求与边界

- 真实菜单栏入口悬浮约 150ms 展开；正式菜单栏下方的整屏横向收纳栏，可换行、滚动和检索。
- 进入入口或收纳栏保持，离开约 200ms 收回；悬浮不夺走正在使用的 App 焦点。
- 默认不透明度 90%，有独立边界和阴影，接近 macOS 原生视觉。
- 不在原菜单栏覆盖黑层。原生可控项折叠，无法控制的系统固定项保留。
- 保留原图标、文字、徽标、左右键及 Option 等修饰键和原菜单交互。
- 真正固定/收回到原菜单栏；独立设置页提供排序规则、样式、图标大小与统一提醒。
- 提醒区分明确未读数和图标活动；读取失败保留上次确认值并标注。
- 方便启用、停用、退出，并恢复临时移动的原项目。

**用户最新明确要求直接在本机验证并关闭虚拟机。VM 与代理已经关闭；不要重启虚拟机。** 用户之前给过的一分钟独占鼠标窗口已结束，不代表当前仍可独占其鼠标。测试原菜单时只对 fixture 执行选项，真实应用菜单只做必要的打开/关闭观察，避免误点退出、账户或业务操作。

## 3. 当前工程与运行状态

工作目录：`/Users/mac/workspaces/MacMenuY`。SwiftUI/AppKit 原生应用，GPL-3.0，基于 Ice/Barkeep 菜单栏引擎，保留来源许可。

| 项目 | 本次交接时核实的值 |
| --- | --- |
| Host | macOS 26.4.1 / 25E253，`hw.model=Mac17,6` |
| 工具链 | Xcode 26.6 / 17F113 |
| 显示 | 刘海屏，1728×1117 逻辑点 |
| Collector | PID **83368**，bundle `io.novarock.MacMenuY` |
| Collector 路径 | `build/Verification/Build/Products/Release/MacMenuY.app` |
| Fixture | PID **80605**，bundle `io.novarock.MacMenuY.Fixture` |
| Fixture 路径 | `build/native-interaction/MenuYFixture.app` |
| 窗口宿主 | PID **746**，`ControlCenter.app` |
| 会话 tap 样本中的 target PID | **710**；本次用 `ps` 核实为 **ChatGPT.app**，不是 SystemUIServer |
| 权限 | Collector 辅助功能、屏幕录制均已确认 true |
| 当前测试菜单 | Fixture `openMenus=[]` |
| VM / VNC | 已停止，没有运行的相关进程 |

PID、窗口 ID、帧会变化，接手后重新核实。上表仅为交接时状态。

Collector 的启动参数：

```text
--verification-host --verification-host-model Mac17,6
--verification-command-file /Users/mac/workspaces/MacMenuY/artifacts/host-native/command.json
--verification-result-dir /Users/mac/workspaces/MacMenuY/artifacts/host-native/results
--verification-fixture-state /Users/mac/workspaces/MacMenuY/artifacts/host-native/fixture-state.json
--diagnostics-path /Users/mac/workspaces/MacMenuY/artifacts/host-native/collector-state.json
--evidence-dir /Users/mac/workspaces/MacMenuY/artifacts/host-native/evidence
```

Git 最后提交为 `f7126ce`，前一个为 `bac72df`。**大量后续修改尚未提交**，包含恢复 journal、Host 验证工具、混合 fixture、修饰键诊断及 UI 修正。不要仅检出 `f7126ce` 就以为拿到了当前实现；不要 reset/clean 工作区。

`build/DerivedData/.../MacMenuY.app` 的正式构建比最后一次 Host 调试修改早，不能当作当前源码的最终已验收包。也不要在应用仍运行时覆盖它的 bundle 或构建到同一路径后继续测试旧进程；磁盘 SHA256 相同不证明已运行进程加载了新代码。

## 4. 未解决问题 A：意外 Command

### 实际证据

用户允许一分钟鼠标回归时，CUA 从真实收纳栏的最新 AX 树找到 F32 并执行：

```javascript
await menuY.click(index, { mouseButton: "right" });
```

没有显式传入 `key`。对应 AXIdentifier 为 `menuy.item.4381`。**4381 和当时的数字索引 75 都不是可长期复用的常量。**

原 fixture 收到：

```text
index=32, mode=declarative, button=right
eventType=3, cgEventType=3, buttonNumber=1
modifierFlags=1048576, modifiers=[command]
sourceUserData=50480352896
menuOpened=32 at 1793274639.5581741
```

菜单当时保持 `openMenus=[32]`，后来由测试 `cancel_menu` 关闭。这证明该样本真实进入原应用并打开 `.menu`，不是 transport echo。

证据：

- `artifacts/host-native/right32-actual-before.json`
- `artifacts/host-native/fixture-state.json` 中 `sourceUserData=50480352896` 的事件
- `artifacts/host-native/collector-state.native-click.jsonl` 对应 F32 时间段
- 精简副本：`artifacts/handoff/right32-actual.json`

### 已知与未知

- `click-start` 已经带 Command，因此不是其后的 session tap 才添加。
- `click()` 明确用传入 `modifiers` 覆盖事件 flags；本次 F32 原本可见/固定，没有走本次临时 reveal 拖动。
- `MenuYInputView` 从 `rightMouseUp` 的 `event.modifierFlags` 转发。
- 拖动代码的 down 带 Command，up/fallback 为 `[]`；没有 Command keyboard-down 注入。**这不等于已经证明所有合成状态均被恢复。**
- 后来只读探针测得 HID/combined 都为 0，只证明那个时间点没有 Command，不能倒推之前。
- 未确定是 CUA/真实键盘状态、之前的合成操作，还是输入桥接造成。不要直接过滤 Command，这会破坏用户真正按住 Command/Option 的交互。

建议在输入 down/up、拖动开始/结束、click-start 分别记录原 `NSEvent`、`cgEvent.flags`、source PID/userData、HID/combined flags 与 Command keyState(54/55)。先做同一项直接原菜单栏与收纳栏的对照。

## 5. 未解决问题 B：原菜单选项选择未通过

后端隔离诊断命令：

```json
{"id":"backend-right32-zero-select","op":"native_menu","index":32,"button":"right","modifiers":[],"select":true}
```

结果文件：`artifacts/host-native/results/backend-right32-zero-select.json`。

```text
clientMenuOpened=true
clientSelection=false
transportError=""
menuOpened32=1793275552.585789, rightDown, button1, modifiers=[]
menuClosed32=1793275552.8501859
```

这条诊断调用 `ShelfManager.activate`，**绕过真实收纳栏 InputView，所以不是 UI 交互验收**。它随后向 fixture source PID 发 Down，等 70ms，再发 Return。没有得到 `recordSelection` 回执。

不要把“约 264ms 后关闭”直接解释成菜单自行关闭：中间执行了 Down/Return，尚未排除是选择动作、键盘路由或检测器问题。异步 `menuDidClose` 中的 `NSApp.currentEvent=mouseMoved` 也不能证明关闭由鼠标移动造成。

待分离的变量：

1. 同 F32、无修饰键、`select=false`，观察至少 1 秒；同时用独立 CGWindow 确认真实弹窗。
2. 在稳定的原菜单上，通过真实键盘或鼠标选 `Record selection`，确认源回执。
3. 比较 source PID keyboard 路由与真实菜单窗口/键盘焦点。默认 `.menu` 和 custom-action 都要覆盖。
4. 若确认菜单确实自行关闭，再做下面 A/B，而不是先改生产代码。

| 组 | mouseUp 次数 | 光标返回 |
| --- | ---: | --- |
| 基线 | 2 | 立即 |
| A | 1 | 立即 |
| B | 2 | 延后 800ms，最终必须返回 |
| C | 1 | 延后 800ms，最终必须返回 |

所有实验限定 `MENUY_VERIFY`、明确 Host opt-in、固定 fixture bundle/path/当前 PID/目标项；保持原右键、flags、clickCount、reveal 和最终恢复。不要把右键伪装成左键。

成功 click 路径的 `finishSyntheticPress` 静态分析不会额外再发 Up：session 已记 Up，owner 未记 Down，release plan 两项 false。因此“成功后额外 fallback Up”不是当前已证实根因。

## 6. 验证器已踩过的坑，接手时必须保留修正

### 6.1 两种 fixture 必须分开

旧 fixture 全部是 `button.sendAction(left/rightUp) → status.popUpMenu(menu)`，成功不能证明默认原生 `.menu` 路径。

当前 `Tests/MenuFixture.swift`：1–16 为 custom-action，17–32 为直接赋值 `NSStatusItem.menu`。源事件的 `mode`、真实 down/up/button/modifier 和真实 `selection` 都有记录。

### 6.2 AX 遍历会制造“菜单打开”假阳性

遍历 Fixture 的 `AXExtrasMenuBar/AXMenu` 会 lazy 触发 17–32 的 `menuWillOpen/menuDidClose`，常见 `eventType=5(mouseMoved)`、`sourceUserData=0`，并没有真实点击或持续可见弹窗。

当前 Host observer **完全跳过 Fixture AX**；Collector 只遍历窗口/普通子节点，避开菜单树。验收必须同时要求正确 mouse down/up、按钮、精确 modifiers、新鲜回执和独立可见菜单窗口。只看到 `menuOpened` 不够。

### 6.3 privateState 全局查询会阻塞

新增 `CGEventSource.flagsState(.privateState)` 后，Host 只读工具曾挂住至 55 秒超时。移除后探针 0.696 秒完成。`privateState` 没有可用的全局状态查询；如需要 private event source，应用实例并限定实验。

已修证据：`artifacts/host-native/fast-window-readonly-audit-summary.json`；事件数 201→201，验证了只读探针没有制造 fixture 菜单回执。

### 6.4 代理窗口不是实际菜单栏窗口

Tahoe status 窗口宿主是 Control Center。fixture `NSWindow.windowNumber` 可为 137438953472 等超 UInt32 的代理值；代理/按钮 frame 也可能陈旧或只是内部视图。不能强制转 UInt32，不能按这些 frame 猜实际窗口。

当前 HostHarness 使用 fixture 的 `(autosaveName, index, SourcePID)` 清单，与独立 CGS 菜单 ID 成员、layer25、精确唯一 `Fixture-N` 标题匹配，获取实际 CGID/frame。重复、缺失或错误标题拒绝。真实收纳栏 AXIdentifier=`menuy.item.<CGID>`，不按重复的应用名称定位。

### 6.5 tap 日志与 CUA 超时的含义

- session `.listenOnly` tap 后修改 targetPID 的日志不证明最终客户端收到事件；Icey 也有相同模式，静态疑点不能直接当回归原因。
- 本样本的 rewrite 前 targetPID=710，交接时核实为 ChatGPT；hostPID=746，sourcePID=80605。原因尚未定位，不要沿用旧 checkpoint 的 SystemUIServer 猜测。
- 收纳栏关闭后，CUA `getAXState/getApp` 可能超时。有些失败发生在点击前，另一些发生在点击后；检查代码是否已找到目标、源事件和 lastNativeAction，不能把 planned click 当完成，也不能把 timeout 当没有菜单。
- 同时操作会关闭面板或改变菜单状态，先协调短时间鼠标操作窗口，再做紧凑的 checkpoint→真实点击→源证据读取。

## 7. 代码入口

| 文件 | 重点 |
| --- | --- |
| `Ice/UI/IceBar/MenuYHorizontalShelf.swift` | `MenuYInputView.rightMouseDown/rightMouseUp/click`，输入 flags，真实 AXIdentifier |
| `Ice/UI/IceBar/ShelfManager.swift` | `activate`，关闭收纳栏、revealAndClick、错误反馈 |
| `Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift` | `postClickEventWithBarrier`、`click`、Up×2、光标 lease、临时显示/归位及 termination |
| `Ice/MenuBar/MenuBarItems/MenuBarSourceResolver.swift` | 实际 source 与 Control Center window host 的身份解析 |
| `Ice/UI/IceBar/MenuYVerificationCommands.swift` | test-only `native_menu` 与 source-PID Down/Return；诊断不能替代真实 UI 点击 |
| `Ice/MenuBar/MenuBarItems/NativeRestorationVerification.swift` | Guest/明确 Host opt-in 的 test-only fault guard |
| `Tests/MenuFixture.swift` | 两种原菜单、真实回执、原生窗口观测 |
| `Tests/HostNativeObserver.swift` | 独立窗口、光标、flags，跳过 Fixture AX |
| `scripts/host-harness.py` | mark-menu、verify-open/selection、原位置比较、面板门槛 |
| `docs/NATIVE_RESTORATION_JOURNAL.md` | 恢复 journal 的机制，真实 fault/restart 仍待验收 |

源码行号会变化，按函数名检索。

## 8. 接手操作

### 8.1 先只读核实，不覆盖当前运行包

```sh
git status --short
pgrep -fl 'MacMenuY.app/Contents/MacOS/MacMenuY|MenuYFixture.app/Contents/MacOS/MenuYFixture'
python3 scripts/host-harness.py snapshot --verification-host --expected-model Mac17,6 --fast-window-only --trace-phases > artifacts/host-native/takeover-fast.json
```

大快照重定向文件，避免把整个 AX 树打印到聊天。观察器不发送指针/键盘输入，`quit` 是显式正常终止操作。

### 8.2 构建

当前工具 binary 在 `artifacts/host-tools/`。如源码改动，重新编译 helper；它们有固定 Host 型号、bundle 和路径 guard。

```sh
swiftc Tests/HostNativeObserver.swift -o artifacts/host-tools/HostNativeObserver
# 仅在 fixture 已正常退出后替换其 bundle 中 executable，然后重新签名。
swiftc Tests/MenuFixture.swift -o artifacts/host-tools/MenuYFixture-next
# Collector 也应先正常退出，再构建/启动，不能覆盖运行中的 bundle。
MENUY_DERIVED_DATA=build/Verification MENUY_SWIFT_FLAGS=MENUY_VERIFY bash scripts/build.sh
bash scripts/verify-core.sh
```

正式构建用 `bash scripts/build.sh`，必须重新核实签名及无测试命令/故障开关。当前 Host 控制须同时显式 `--verification-host --verification-host-model Mac17,6`，普通生产编译没有该接口。

### 8.3 真实 UI 回归与诊断分开

收纳栏可通过 test-only `preview` 固定显示，但实际点击必须走真实 InputView。下例写 command file 时用新 id，结果在 `results/<id>.json`。

```json
{"id":"unique-preview-id","op":"preview"}
```

在 CUA 中读取完整最新 AX 树，按真实 `menuy.item.<当前CGID>` 定位；不要复用数字索引。

```sh
python3 scripts/host-harness.py mark-menu --verification-host --expected-model Mac17,6 --index 32 --button right --checkpoint artifacts/host-native/new-checkpoint.json > artifacts/host-native/new-mark.json
# 人或 CUA 真实点击收纳栏对应图标
python3 scripts/host-harness.py verify-open --verification-host --expected-model Mac17,6 --index 32 --button right --checkpoint artifacts/host-native/new-checkpoint.json > artifacts/host-native/new-open.json
# 真实选 Record selection，然后 verify-selection
```

检查退出码与 JSON，不能仅看文件生成。无修饰键应精确 `[]`，不能用 subset 匹配。

`native_menu` 是用来分离 backend/keyboard routing 的诊断；不要用它宣布 InputView/双指点击已验收。先 `select=false`，确认稳定打开再测选择。

## 9. 已有验证与仍缺失的验收

已有：签名 universal build；完整 pure regression/typecheck；历史真实 hover/leave、原生 pin/unpin、custom-action 左右菜单、未读3及设置；最新 Host 51项/32张原图、整屏宽与 opacity .9、一个真实 `.menu` 右键打开样本。具体历史样本不证明最新代码整体验收完成。

仍需完成：

- 两种菜单的 **真实原菜单栏 baseline vs 收纳栏** 左/右/Option，精确 flags 与实际菜单选择。
- 已隐藏、真实临时移出的 `.menu` 项；目前关键 F32 样本是已经可见/固定的项。
- 用户真实应用右键兼容，不能只凭 fixture 宣告全部兼容。
- 最新代码 hover/焦点/离开、真实固定/收回及进程重启持久性，动态增删、badge3→0、设置/排序规则/样式与大小。
- 最新真实 active-menu quit 无残留；实际部分移动失败→保存 journal→下一次启动恢复。这些目前只有源码/纯测试门，未完成完整运行门。
- 最新正式无调试构建的真实 UI、签名、debug 排除与打包交付。

测试结束清理 fixture、fixture pins/排序规则等人工数据。用户设置备份在 `artifacts/host-native/preferences-before.plist`，但测试期间用户可能继续修改；不要整份覆盖回去，按测试造成的变化处理。

## 10. 交付物与交接限制

- 可复制任务说明：[NEXT_AGENT_PROMPT.md](NEXT_AGENT_PROMPT.md)。
- 精简证据包：`artifacts/handoff/residual-evidence.zip`，只包含本问题必要的 fixture/trace/探针摘要和本文，不含 VM 登录材料或完整用户设置。
- 原始证据在同工作区 `artifacts/host-native/`，通常被 Git 忽略。换机器/工作区时需要另行携带，不能假设只拿 Git 提交就有证据或当前未提交源码。
- Collector/fixture 当前仍运行，菜单已关闭；为了保留复现现场，本次文档交接没有启动、重启或操作它们。
