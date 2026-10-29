# Tuckbar

<p align="center">
  <img src="landing/assets/icon-256.png" width="120" height="120" alt="Tuckbar Icon" />
</p>

**Tuckbar** 是一款原生 macOS 二级菜单栏收纳应用（SwiftUI + AppKit）。将顶部菜单栏杂乱的图标收进一个入口，鼠标悬浮即在系统菜单栏正下方丝滑展开二级横向收纳栏；离开后自动收起。

- **官方网站与下载**：[https://tuckbar.novarock.io](https://tuckbar.novarock.io)
- **GitHub 仓库**：[https://github.com/mapix/Tuckbar](https://github.com/mapix/Tuckbar)

## 核心特性

- **二级菜单栏原生左/右键穿透**：在展开的二级收纳栏内，无论是左键、右键还是按住 `Option` 点击，都能直接打开并保持飞书、Chrome、Ollama、Docker 等第三方应用的原生菜单。
- **图钉整理模式自动锁定**：点击二级收纳栏工具栏中的「整理（图钉）」按钮进入编辑状态时，面板自动锁定不隐藏，方便逐个点击图标切换「常驻顶部菜单栏」或「收起」状态；点击「完成整理」后立即恢复自动悬浮收起。
- **可自定义的悬浮与收起时机**：内置防抖动意图识别与边缘缓冲带，支持在设置中自由调节悬浮展开延迟（50–600ms，默认 150ms）与离开自动隐藏延迟（100–1200ms，默认 250ms），且展开/收起全程不抢占当前活跃应用焦点。
- **原生壁纸融合与多尺寸布局**：实时采样系统菜单栏壁纸与明暗色彩，提供「原生菜单栏」「玻璃质感」「紧凑」三种风格及 `16–36pt` 图标尺寸、排序预设和通配优先规则，自动避开 MacBook 刘海区域。
- **智能变化与未读提醒**：顶部唯一入口统一提示收納图标的像素变化或无障碍未读消息数。
- **100% 本地运行 & 退出自动归位**：所有图像捕获与事件路由均在本机完成，无任何远程请求或遥测上传。退出 Tuckbar 时自动将临时展开的图标归位。

## 构建与验证

要求 Xcode 26 / Swift 6 工具链（同时构建 `arm64` 与 `x86_64` Universal Binary）：

```sh
bash scripts/build.sh
bash scripts/verify-core.sh
```

脚本默认使用本机 Developer ID 身份签名；可用 `MENUY_SIGN_IDENTITY` / `MENUY_TEAM` 覆盖。

### 部署分发站点

```sh
bash deploy/deploy.sh
```

## 开源许可与致谢

辅助功能权限用于原生菜单栏图标移动与点击事件路由；屏幕录制权限用于本机镜像图标与菜单栏背景。

底层菜单栏管理引擎源自 [Ice](https://github.com/jordanbaird/Ice) 及 [icey](https://github.com/leonardovida/icey)，遵循 **GPL-3.0** 协议开源，详见 [NOTICE](NOTICE.md) 与 [LICENSE](LICENSE)。
