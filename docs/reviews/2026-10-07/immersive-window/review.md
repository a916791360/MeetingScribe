# 沉浸式窗口调整 · 2026-10-07

本机版本：0.12.1（31）。GitHub 已发布版本仍为 0.12.0，本轮尚未发布新 Release 或移动既有 tag。

## 改动

- 使用原生隐藏标题栏，内容延伸至窗口顶部，取消标题栏分隔线。
- 顶部与侧栏使用同一窗口底色；浅色下右侧保留白色内容卡片。
- 顶部结构留白 28 pt，加内容卡片上边距 12 pt，卡片起点距窗口顶部 40 pt。
- 顶部拖动视图覆盖 40 pt 灰色区域，正文和功能按钮不在其命中范围内；使用 AppKit `performDrag(with:)`，支持后台窗口首次点击。
- 保留原生关闭、最小化、缩放/全屏按钮；全屏时不执行普通窗口尺寸钳制。

## 已验证

| 项目 | 结果 / 证据 |
|---|---|
| 最终 Release 构建 | `swift build --configuration release --disable-sandbox -Xswiftc -warnings-as-errors` 成功 |
| 相关现有测试 | LayoutTokenTests、AppearancePaletteTests、WorkbenchContentPlanTests、AppAppearanceTests：16 项通过，0 失败 |
| 浅色展开侧栏 | `light-expanded.png`：无独立白条，底色连续，卡片顶部间距 40 pt |
| 浅色收起侧栏 | `light-collapsed.png`：卡片扩展，顶部及左右边距保留 |
| 最小内容尺寸布局 | `minimum-light.png`、`minimum-dark.png`；本机实际窗口 1060×692 pt（内容最小值 1060×660，系统安全区参与外框测量），标题与按钮未遮挡 |
| 原生窗口属性 | `drag-metrics.json`：fullSizeContentView、取消分隔线、三个原生按钮存在且启用 |
| 原生缩放 | 操作绿色按钮的缩放辅助动作后，窗口由 1360×820 变为 1470×842 pt |
| 设置与外观切换 | 合成夹具中打开/关闭设置，浅色与深色切换成功 |
| 真实鼠标拖动 | 用户在已安装 0.12.1 上操作后确认「可以正常移动」；通过 |
| 安装包检查 | 运行时来源与哈希、许可、签名、动态库依赖、开发路径与凭据扫描通过 |
| 本机更新 | 使用与旧版相同的 PM Studio Signing 身份及 designated requirement；正式应用成功启动 |
| 真实数据完整性 | 更新前完整备份核对通过，更新前后 24 个资料文件 SHA-256 一致，共 291314048 字节；未开始录音或云端请求 |

所有截图均来自隔离的合成会议夹具，未截取真实会议内容。截图左上角紫色图标为 macOS 截屏共享指示器，非应用新增控件。

## 待验证

自动化已送达鼠标事件，但窗口位置未出现可确认的变化，因此 `drag-metrics.json` 仅记录自动化结果。真实鼠标拖动已由用户确认通过。原生全屏进入/退出未在本轮实测。

本轮仅验证窗口结构调整；不代表重做此前所有音频、云端、设备及长时运行验收。

## 复现方式

`ReviewImmersiveHarness.swift` 与仓库根目录 Swift 源文件一起编译，排除 `Package.swift` 和 `MeetingScribeApp.swift`；独立 bundle identifier 隔离偏好，独立目录承载合成会议。bundle identifier 包含 `minimum` 时默认最小窗口，后缀 `.empty` 时使用空夹具。

备份与本机安装结果见 `install.json`；真实资料逐文件完整性清单仅保存在私人备份内，不进仓库。
