# MeetingScribe

本地优先的 macOS 会议录音与转写 App。

当前版本：`0.11.1`

## 目标

- macOS 15+
- Apple Silicon
- 本地录音 / 本地导入音频
- 本地 `whisper.cpp` 转写
- 三页各有分工：**速览**＝这场会产出了什么（要点 / 决策 / 待办 / 风险 / 待确认，清单形态）；
  **纪要**＝这场会是怎么定下来的（正文 + 时间导航，叙述形态）；**原文**＝逐字稿，可核对、可举证
- 每条结论都带**依据**与**置信度**，可在原地展开核对
- 点时间锚回放那一段（速览 / 纪要 / 原文三页都能跳）；播放时当前句高亮
- 一键导出 Markdown / 复制全文，**带走之后还能回原文核对**
- 结果只保留在 App 内：不联云、不自动上传；导出与复制都由你手动触发

## 总结模型

逐字稿始终使用本机 `whisper.cpp` 完成。会后整理可以选择本地保守整理、本机 Ollama，或 OpenAI 兼容的云端服务。

使用自定义兼容接口时：

1. 填写服务商 API 根地址，例如 `https://example.com/v1`。
2. 填写 API Key。密钥只保存到 macOS 钥匙串。
3. 点击“保存并测试”。
4. 测试成功后，从服务商返回的模型列表中选择模型。

如果服务商没有提供标准 `/models` 列表，应用会保留手动填写模型 ID 的兜底方式。

## 下载安装

不想编译的话，到 [Releases](https://github.com/a916791360/MeetingScribe/releases/latest)
下载 `MeetingScribe-<版本>-macOS.zip`，解压后把 `MeetingScribe.app` 拖进「应用程序」。
**包内自带转写引擎和模型，不需要另外安装任何东西。**

首次打开会被 macOS Gatekeeper 拦下（本 App 未做 Apple 公证），**这不是文件损坏**——
按下面「分发给别人安装」第 2 条，在「系统设置 → 隐私与安全性 → 安全性」里放行一次即可，
之后不再提示。zip 里附了 `首次打开请看这里.txt`，写的就是这几步。

下载后可自行校验完整性（每个版本的 SHA-256 写在该版本 Release 的说明里）：

```bash
shasum -a 256 MeetingScribe-0.11.1-macOS.zip
```

## 运行

App 界面本身不依赖 `whisper.cpp`，可以直接起：

```bash
swift build
swift run
```

但**转写**需要 `whisper-cli` 和模型文件，见下面「转写引擎与模型」。没有它们 App 能打开、能录音，
逐字稿会报「找不到 whisper-cli」。

## 打包与安装

**先准备好转写引擎与模型**（见下一节），并且让打包脚本能找到它们 —— 默认路径是你自己机器上的，
要用环境变量指过去：

```bash
WHISPER_ROOT=/path/to/whisper.cpp ./Scripts/package_app.sh
```

脚本会把 `whisper-cli`、它依赖的 `*.dylib` 和 `ggml-small.bin` 一起复制进 `Resources/whisper/`，
打出来的 `.app` 因此是**自包含**的（约 483MB，其中模型占 465MB），拷给别人也能用。

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

## 转写引擎与模型

逐字稿由 [whisper.cpp](https://github.com/ggml-org/whisper.cpp) 在本机完成，需要两样东西：
`whisper-cli` 可执行文件，和一个 `ggml-*.bin` 模型。

**1. 装 whisper.cpp**

```bash
git clone https://github.com/ggml-org/whisper.cpp
cd whisper.cpp
cmake -B build && cmake --build build -j --config Release
```

**2. 下载模型**（`small` 约 466MB，中文效果与体积的平衡点）

```bash
./models/download-ggml-model.sh small
```

**3. 让 App 用上**（两种方式，任选）

- **打包时指定**：`WHISPER_ROOT=/path/to/whisper.cpp ./Scripts/package_app.sh`，
  产物自包含，拷给别人也能用。
- **运行时指定**：在 App 的「设置」里分别填 `whisper-cli` 和模型文件的路径。

**换个更强的模型**：把任意 `ggml-*.bin` 放进
`~/Library/Application Support/MeetingScribe/models/`，重启即生效。
优先级 `large-v3-turbo` > `large-v3` > `medium` > `small` > `base` > `tiny`，
用户目录里的模型优先于 App 内置的那个。

> 早期版本把引擎路径写死成开发者本机目录，那只是历史兜底；现在解析顺序是
> **App 内置 → `~/whisper.cpp` → 明确报错**，不再静默失败。

## 分发给别人安装

**包里有什么**：`MeetingScribe.app` 是自包含的（约 483MB）—— 主程序 + `whisper-cli` +
依赖 dylib + `ggml-small.bin`（约 466MB）。对方**不需要另外装 whisper 或下模型**，解压即用。
想换更强的模型，把 `ggml-*.bin` 丢进 `~/Library/Application Support/MeetingScribe/models/`，
重启即生效（优先级见上一节）。

**包里没有什么**：不含任何使用者数据。API Key 存在 **macOS 钥匙串**
（service `MeetingScribe.summary-model`，按服务商分条）；大模型配置（服务商／模型名／端点）
与术语表存在 **UserDefaults**；会议录音与纪要存在
`~/Library/Application Support/MeetingScribe/`。**这三类都是「按用户」落在本机 `~/Library` 下，
物理上不在应用包里** —— 所以拷 `MeetingScribe.app` 给别人，不会带走你的 Key、配置或会议记录。

打包脚本默认用本机自签证书，**没有经过 Apple 公证**。别人下载后 macOS 会拦下来，
弹「Apple 无法验证…」的框，且按钮只有「完成」和「移到废纸篓」。这不是文件坏了，是 Gatekeeper 在起作用。

对方有三条路可走（按推荐程度排）：

1. **自己从源码编译**（最干净）：`swift build && swift run`。
   本机编译出来的产物**不带**隔离标记，不会被拦，也不会弹任何警告。
2. **在系统设置里放行**：先双击一次 `MeetingScribe.app`（会弹出被拦的框），
   然后打开「系统设置 → 隐私与安全性」，向下滚动找到刚被拦的记录，点「仍要打开」。
   之后这个 App 会被记为例外，以后双击即可（Apple 官方文档路径）。
3. **终端去掉隔离标记**：

   ```bash
   xattr -d com.apple.quarantine /Applications/MeetingScribe.app
   ```

**注意**：macOS 15 起 Apple 移除了「按住 Control 点按图标 → 打开」这条老办法，
弹框里也不会再有「打开」按钮，只能走上面第 2 条的设置页。

**要彻底免掉这一步**，需要 Apple Developer Program（99 美元/年）：签 Developer ID → 开硬运行时 →
送 Apple 公证 → 装订票据。仓库里已经备好材料：

```bash
./Scripts/notarize_app.sh --check      # 先体检，看缺什么
./Scripts/notarize_app.sh              # 五步走完（需先存好公证凭据）
```

## 开源协议

本项目使用 MIT License，见 [LICENSE](LICENSE)。
