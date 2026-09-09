# MeetingScribe

本地优先的 macOS 会议录音与转写 App。

## 目标

- macOS 15+
- Apple Silicon
- 本地录音 / 本地导入音频
- 本地 `whisper.cpp` 转写
- 逐字稿、速览、决策点、待办、依据、置信度
- 结果只保留在 App 内

## 运行

```bash
swift build
swift run
```

## 打包与安装

生成标准 macOS `.app` 包：

```bash
./Scripts/package_app.sh
```

安装到 `/Applications` 并启动：

```bash
./Scripts/install_app.sh
```

应用包使用标准 `Info.plist`、`.icns` 图标和可调整大小的主窗口，最低支持 macOS 15。

## 默认依赖

- `whisper-cli`：`~/Documents/Codex/易运盈/outputs/crm-mall-flow/whisper.cpp/build/bin/whisper-cli`
- 模型：`~/Documents/Codex/易运盈/outputs/crm-mall-flow/whisper.cpp/models/ggml-small.bin`

可在设置里改成你自己的本地路径。
