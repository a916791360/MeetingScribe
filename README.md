# MeetingScribe

本地优先的 macOS 会议录音与转写 App。

当前开发版本：`0.11.7`（本轮审查升级，本地构建；尚未发布到 GitHub）

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
- 录音和逐字稿在本机保存；选择云端整理时，逐字稿会发送到你配置的服务商，选择本地整理则不发送。导出与复制由你手动触发

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
shasum -a 256 MeetingScribe-0.11.7-macOS.zip
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

打对外分发的 zip（App + `首次打开请看这里.txt`，并打印 SHA-256）：

```bash
./Scripts/make_release_zip.sh   # → ../dist/MeetingScribe-<版本>-macOS.zip
```

这个脚本会在压缩前**再跑一次分发审计**（扫的是最终要发出去的那一份），
并且要求签名在复制后依然完好 —— 任何一项不过就直接不出包。

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

内置运行时包含 whisper.cpp、ggml 与 OpenAI Whisper 模型，第三方许可随 App 放在
`Contents/Resources/Licenses/`，来源见 [ThirdPartyLicenses](Packaging/ThirdPartyLicenses/SOURCES.md)。
自定义转写运行时若含其他组件，打包者需补齐其许可与版本来源。

本地审查版 0.11.7 使用 [runtime-lock.json](Packaging/runtime-lock.json) 固定的
whisper.cpp v1.9.4 提交和官方 small 模型 SHA-256。使用已有模型构建，不修改已安装 App：

```bash
python3 Scripts/build_pinned_runtime.py --model /path/to/ggml-small.bin --cmake /path/to/cmake
WHISPER_ROOT="$PWD/.build/pinned-whisper" REQUIRE_PINNED_RUNTIME=1 Scripts/package_app.sh
REQUIRE_PINNED_RUNTIME=1 Scripts/make_release_zip.sh
```

构建限定 Apple Silicon、macOS 15+，需要 Xcode 命令行工具和 CMake。
App 内 `Contents/Resources/RuntimeProvenance.plist` 记录源码、模型、构建配置及打包后的文件哈希；
发行审计校验锁定来源、模型和实际文件。自签证书及来源记录不等同于 Apple 公证。



### 0.11.7 后台人工保存

人工校正和重命名在后台原子保存；保存成功才关闭编辑，失败保留草稿。
保存中显示明确状态，阻止重复提交与冲突操作；正常退出会提示等待保存完成。
录音/处理故障收尾只更新最新记录的终态字段，保留已保存的新名称。

验收与回滚见 [0.11.7追加报告](docs/reviews/2026-10-06/editing/review-and-upgrade.md)。

### 0.11.6 后续修复

取消重新整理会等待当前任务实际退出，再恢复开始/导入入口；删除同样等待收尾。
后台事务及导入保留人工命名，晚到的结果不会覆盖界面新名称。整理和删除在后台执行；
整理配置及术语以点击时为准，模型失败才计算本地兜底。单路/双路各自保存可校验的恢复检查点。

完整审查、回归结果与验收边界见 [总报告](docs/reviews/2026-10-06/final-review-and-upgrade.md)
及 [0.11.6追加报告](docs/reviews/2026-10-06/lifecycle/review-and-upgrade.md)。
本轮未公开发版，正式分发仍需Developer ID和Apple公证。

### 0.11.3 审查收尾

历史错误、录音警告与部分结果提示只展示可信诊断；加载旧记录时原子清理这些字段，会议正文不做脱敏替换。
清理写入失败会提示，旧文件仍保留；已有导出文件、系统备份与其他副本不会被自动清除。
录音启动期可以取消，中断及重复回调有任务归属保护；停止采集先于读取会议文件，磁盘故障不会跳过录音器清理。
转写检查点写入失败会停止任务并报告；无法保存终态时明确提示先检查磁盘或导出可见内容。
启动读取与历史修补、大音频副本移到后台；导入先完成临时副本，再替换目标文件。

追加验收见 `docs/reviews/2026-10-06/closure-review-and-upgrade.md`。

### 0.11.2 审查修复

重新处理保留已有逐字稿、人工校正和纪要，失败或取消不会用空结果覆盖它们。
双路录音按样本时间戳补齐静音间隔，失败轨道退回混合原件；清洗保留说话人、否定意见和分块尾句。
原文修改后提示速览和纪要待更新，编辑草稿在切页期间保留；旧版全文可阅读和导出。
云端请求限制跨来源跳转，错误体不进入可分享资料；流式中断明确标记部分结果，普通 JSON 回包不会重复生成。

发行包会在签名前移除外部引擎的开发机 RPATH，并审计所有运行时 Mach-O 文件。
正式公证分发可设置 `REQUIRE_NOTARIZATION=1` 运行 `Scripts/make_release_zip.sh`；本机自签包仍按上面的首次打开说明处理。
评测工具更换地址时必须使用该地址匹配的凭据，不再从其他提供商自动补 key。

完整修复验收与剩余实机验证见 `docs/reviews/2026-10-06/final-review-and-upgrade.md`。
