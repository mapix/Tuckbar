# MacMenuY

原生 macOS 菜单栏收纳应用，SwiftUI + AppKit。悬浮真实收纳入口，在正式菜单栏下方展开整屏横向收纳栏；鼠标离开入口和收纳栏后自动收起。

## 交互

- 原菜单栏使用原生分隔项折叠，不覆盖原菜单栏。无法控制的系统项目保持原样。
- 收纳栏保留原图标、文字、徽标，支持检索、自动换行与滚动。
- 普通点击打开原应用菜单；右键、Option 等修饰键按原方式传递。
- 图钉整理模式或「项目管理」页将可控项目真实移回原菜单栏，再点一次收回。
- 独立原生设置页提供样式、16–36pt 图标、排序预设和通配优先规则。
- 默认不透明度 90%。悬浮展示不主动夺走工作 App 的焦点。
- 原生入口统一提示图标变化；仅当应用明确提供未读数时显示未读数。查询暂时失败会保留上次确认值，避免将未知当成 0。
- 入口右键、收纳栏和设置页均可启用/停用或退出。

## 构建

要求 Xcode 26 / Swift 6 工具链。本机验证目标为 macOS 26.4.1、Apple Silicon；Release 同时构建 arm64 与 x86_64。

```sh
bash scripts/build.sh
bash scripts/verify-core.sh
```

脚本默认使用本机已有 Developer ID 身份；可用 `MENUY_SIGN_IDENTITY` / `MENUY_TEAM` 覆盖。无需服务器、账户或上传数据。

### 原生调试验收

```sh
MENUY_DERIVED_DATA=build/Verification MENUY_SWIFT_FLAGS=MENUY_VERIFY bash scripts/build.sh
```

仅该编译条件启用原生验收面板和固定展开等调试功能。正式构建没有调试面板。真实客户端 fixture、命令文件和证据字段见 [原菜单交互验收](docs/NATIVE_INTERACTION.md)。当前运行验收范围与结果见 [验证记录](docs/VERIFICATION.md)。

## 权限与来源

辅助功能用于原生移动/菜单交互；屏幕录制用于本机镜像图标和菜单栏背景。原图标由原应用拥有，App 不改动原应用源码、包或系统安全设置。

源自 Ice 菜单栏引擎，包含 Tahoe 兼容修正。GPL-3.0，保留原作者版权和依赖许可，见 [NOTICE](NOTICE.md) 与 [LICENSE](LICENSE)。
