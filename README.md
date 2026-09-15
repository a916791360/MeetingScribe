# MeetingScribe

本地优先的 macOS 会议录音与转写 App。

当前版本：`0.10.0`

## 目标

- macOS 15+
- Apple Silicon
- 本地录音 / 本地导入音频
- 本地 `whisper.cpp` 转写
- 逐字稿、速览、决策点、待办、依据、置信度
- 结果只保留在 App 内

## 总结模型

逐字稿始终使用本机 `whisper.cpp` 完成。会后整理可以选择本地保守整理、本机 Ollama，或 OpenAI 兼容的云端服务。

使用自定义兼容接口时：

1. 填写服务商 API 根地址，例如 `https://example.com/v1`。
2. 填写 API Key。密钥只保存到 macOS 钥匙串。
3. 点击“保存并测试”。
4. 测试成功后，从服务商返回的模型列表中选择模型。

如果服务商没有提供标准 `/models` 列表，应用会保留手动填写模型 ID 的兜底方式。

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

## 质量指标

改完转写/摘要相关代码，想知道「产出到底变好了没有」，跑一条命令：

```bash
Scripts/quality_report.sh --check      # 免密、免网络；CI 每次改动也跑这一条
Scripts/quality_report.sh --run --diff # 真实语料跑一遍模型，再与基线对比（需要 MS_E2E_KEY）
Scripts/quality_report.sh --judge --repeat 3   # 换异厂模型当裁判；要用分数当依据就必须 --repeat 3
Scripts/probe_owner_gap.py             # 「待办没写谁负责」是材料没写还是没抽出来？（决定要不要上双声道）
```

口径、评测集与「哪些指标算不了」见 [docs/verification/quality/README.md](docs/verification/quality/README.md)。

## 默认依赖

- `whisper-cli`：`~/Documents/Codex/易运盈/outputs/crm-mall-flow/whisper.cpp/build/bin/whisper-cli`
- 模型：`~/Documents/Codex/易运盈/outputs/crm-mall-flow/whisper.cpp/models/ggml-small.bin`

可在设置里改成你自己的本地路径。

## 开源协议

本项目使用 MIT License，见 [LICENSE](LICENSE)。
