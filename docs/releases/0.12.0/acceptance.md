# MeetingScribe 0.12.0 发行验收

验收日期：2026-10-07。安装包版本 0.12.0 / build 30，支持 Apple Silicon、macOS 15+；不支持 Intel Mac 和 Windows。

## 发行产物

- 文件：`MeetingScribe-0.12.0-macOS.zip`
- 大小：455,815,509 字节（434.7 MiB）
- SHA-256：`737718dd25a08514daa3b5b45bcf48562b8771afea62fe02c5f6c576ec4ba350`
- 包含应用、首次打开说明、固定版本 whisper-cli、动态库、官方 small 模型及第三方许可。安装者无需 Xcode、Python 或另外下载转写引擎。
- 使用 `REQUIRE_PINNED_RUNTIME=1` 打包；解压到中文目录后，通过分发审计和 `codesign --verify --deep --strict`。见 `extracted-audit.log`。

## 首次使用的隔离验收

使用独立 bundle ID、空会议目录与未配置的偏好设置，不读取既有会议或云端凭据。入口见 `ReleaseAcceptanceHarness.swift`，界面、存储和转写管线使用生产代码；资源来自解压后的发行应用。录音权限使用 granted stub，此次不据此声称真实录音权限验收。

| 项目 | 结果 | 证据 |
|---|---|---|
| 首次启动、空态 | 正常显示录音和导入入口 | 原生 UI 操作 |
| 自动发现引擎、模型 | 无手工配置即可找到包内 whisper-cli 和 small 模型 | `fresh-settings.png` |
| 导入及实际本地 GPU 转写 | 15 秒合成中文音频生成 66 字逐字稿、1 段；状态 ready，错误为空 | `fresh-import-transcript.png` |
| 默认本地整理 | 短材料提示不足，不发往云端 | 原生 UI 操作 |
| 播放、暂停 | 按钮状态切换，播放进度从 0 推进到约 5 秒 | 原生 UI 操作 |
| Markdown 导出 | 原生保存面板成功导出，文件包含本次合成逐字稿 | `fresh-export.md` |
| 包内引擎独立 CPU 运行 | 退出码 0，JSON 可解析，识别安装、会议、左侧、右侧、转写关键词 | `cpu-smoke.json`、`cpu-runtime-smoke.log` |

主应用可执行文件与已构建、已安装验收版本哈希一致。隔离入口不是发行应用本身；它专门验证生产管线使用发行资源、空配置的首次使用条件。

## 已有回归及资料保护

UI 改动的完整 Swift 回归：371 项，1 项真实云端测试跳过，零失败。最终界面补充后 16 项布局、外观和内容规划回归通过。浅色、深色、最小窗口、侧栏收起、长标题与长原文等证据见 [UI 验收](../../reviews/2026-10-07/ui-shell/review.md)。

安装新版后，本机既有 24 个会议文件的哈希与备份一致；真实会议、录音、凭据没有放入发行包或本目录证据。

公开前扫描 Git 可达历史的 857 个文件版本，检查常见密钥格式、私钥、字面凭据与敏感文件路径。候选仅为 `AuditClosureTests.swift` 中的模拟凭据。该扫描未发现真实凭据候选，不代表对所有形式的秘密作绝对保证。

此次没有补做另一台 Mac、三小时录音或真实云端弱网验收。包未做 Apple 公证；安装步骤包含用户已接受的「隐私与安全性 → 仍然打开」。
