# MeetingScribe 0.11.4 原生验收、追加修复与本机升级

日期：2026-10-06。继承GitHub固定基线bd80e30和本地e1ddc3f修复，继续在codex/audit-hardening独立工作树完成。累计46项：P0 1 / P1 30 / P2 15。完整清单、Top10及排期见final-review-and-upgrade.md。

## 结论与问题优先级

原生UI实测发现两项此前回归未覆盖的状态反馈问题，按P1、P2顺序修复后再打包安装。保持现有SwiftUI工作台设计，应用UI/UX Pro Max的稳定等待反馈指导。此次没有重设计或新增依赖。

| 优先级 | 问题 | 结果 |
|---|---|---|
| P1 / UX-007 | 准备期已显示录音中、计时和采集承诺 | 已修复；准备/录音分开显示，成功启动后才计时 |
| P2 / UX-008 | 用户取消被当故障并弹配置错误 | 已修复；中性取消反馈，可再次开始；设备和保存失败仍报错 |

## 验收证据

- ui-lifecycle-tests.log：11项生命周期/存储闭环测试通过。
- ui-final-full-tests.log：333项Swift测试、1项真实云端E2E跳过、0失败，warnings-as-errors。
- ui-final/：修复前准备状态、修复后准备/取消截图与完整AX、重开取消AX；两次开始/取消完成。隔离录音器仅延迟启动，不接真实设备、不发云端请求。准备界面实测不等于真实录音验收。
- ui-final-package/signature/runtime-smoke/zip/extracted-audit日志：构建、PM Studio Signing本机证书签名、内置引擎/模型加载与JSON解析、复制/解压后签名及RPATH/依赖/许可审计均通过。引擎烟测只证明可运行，不证明转写准确率。
- 前轮Python38项与合成质量7case通过；本轮仅SwiftUI/状态反馈改动，未重复运行未改动的Python代码。
- 初次载入很快，未捕获独立加载页截图；后台首次加载与新任务门禁已有状态回归，不能写成加载页已完成视觉验收。

## 本机安装与数据完整性

已将/Applications/MeetingScribe.app从0.11.1/build21更新到0.11.4/build24并用CUA启动，返回原文页。安装前从界面确认三场会议完成、播放器暂停、无录音或处理，正常⌘Q退出并检查进程消失。完整数据备份逐文件SHA一致后才复制候选App、验签、移走旧版、替换新版；失败路径保留回滚。

备份目录：/Users/qingmeng/Documents/Codex/MeetingScribe-backups/20261006-131922。包含MeetingScribe-data、data-integrity-manifest.json、MeetingScribe-previous.app。备份目录权限700；包含用户私有会议数据，只留本机，未放入Git、源码包或公开证据。用于回滚的旧数据可能包含历史诊断，不能声称秘密从全部副本清除。此次加载后清单未发生字节重写。

ui-final-install.json仅记录非正文安装验证摘要：24个数据文件、291314048字节；启动前后3个会议ID一致，除诊断字段外JSON完全一致，音频等其他文件逐字节一致。事实上本次三个session.json也均字节未变。没有读/保存真实API Key，没有启动真实录音或云端处理，没有保存真实会议界面截图。

## 回滚与后续验收

如需回滚：先结束任务并正常退出新版，确认无MeetingScribe进程；将当前App移到新的保留位置，再将备份的MeetingScribe-previous.app恢复到/Applications/MeetingScribe.app。升级没有修改当前数据，普通App回滚无需覆盖数据。若之后需要恢复数据，先备份升级后新增会议，再恢复数据副本，避免覆盖新增内容。

仍需真实设备双声源/首包对齐、权限拒绝与设备故障、系统启动/停止超时，VoiceOver完整朗读和键盘全流程、最低macOS15和另一台机器、真实HTTPS/弱网、依赖源码锁定/CVE评估。ARCH-001是渐进改善，剩余主actor小文件写入需按测量继续拆分。当前证书不是Developer ID、没有Apple公证；GitHub未推送、未发布Release。

## 追加问题详情

### UX-007：录音尚在准备时界面已宣称采集开始

| 字段 | 内容 |
|---|---|
| ID | UX-007 |
| 类型 | UX / Bug |
| 严重级别 | P1 严重 |
| 置信度 | 高：隔离原生界面实测与状态代码 |
| 位置 | WorkbenchView.swift:2702，WorkbenchProcessingState；MeetingStore.swift:334；窗口副标题和侧边栏状态 |
| 问题描述 | start尚未返回成功，isPreparingRecording=true、isRecording=false，但草稿status=recording驱动红点、录音计时、正在采集和实时写入文案；准备耗时也算入计时。 |
| 证据 | ui-final/initial-ax.txt、preparing-ax.txt和preparing.png记录准备按钮与00:15、录音中、正在采集同时出现；注入录音器start睡30秒，此时尚未确认启动成功。修复前版本为本地e1ddc3f。 |
| 影响 | 用户可能在尚未确认采集成功时开始会议发言；计时与成功启动后的3小时限制不一致。这里确认的是误导反馈，不声称已经实测真实音频丢失。 |
| 复现步骤 | 1. 使用独立bundle ID、合成数据和延迟start录音器。2. 点击开始录音。3. start返回前查看标题、正文、页脚和计时。 |
| 建议修复 | 已显示独立准备页面、等待指示和取消入口；准备时不显示计时/电平/红点/实时写入承诺。recordingStartedAt只在start成功且未取消后设置，计时与上限提示用同一起点。 |
| 验证方式 | preparing-fixed-ax.txt与PNG中全部状态为正在准备录音，且无录音计时或采集承诺；生命周期测试确认准备时起点nil，成功后时间不早于确认启动；真实采集首包时钟另需设备测试。 |
| 是否 AI 生成典型问题 | 是：将草稿状态当成设备成功状态；作者来源不确定 |
| 当前状态与验收 | 已修复 / 原生合成UI、状态回归 |

### UX-008：主动取消录音准备被当成失败

| 字段 | 内容 |
|---|---|
| ID | UX-008 |
| 类型 | UX / Bug |
| 严重级别 | P2 一般 |
| 置信度 | 高：原生操作与取消分支代码 |
| 位置 | MeetingStore.swift:349、1442，录音启动catch和failSession；SafeDiagnostics.swift:6、54；WorkbenchView.swift:602 |
| 问题描述 | 用户点击取消录音准备，统一catch仍执行失败弹窗，提示检查权限、磁盘和模型；重新处理空录音的入口也不适合恢复取消动作。 |
| 证据 | 修复前CUA观察到发生问题弹窗；e1ddc3f的启动catch无取消区分，调用failSession(error.localizedDescription)。修复后cancelled-fixed-ax.txt、cancelled-reopened-ax.txt与PNG记录无弹窗的取消页和恢复的开始录音按钮。 |
| 影响 | 正常取消被解释成系统故障，用户可能无谓修改配置或重试并不存在的录音；不会帮助恢复实际任务。 |
| 复现步骤 | 1. 在延迟启动夹具点击开始录音。2. 在设备确认前取消准备。3. 观察是否弹配置错误及恢复入口。4. 重开检查取消文案。 |
| 建议修复 | 已只把任务取消且未收到设备故障的路径视为用户取消；关闭错误弹窗、持久化固定取消文案、显示中性取消状态与开始录音指引。复用failed存储状态保持旧格式兼容，但界面明确显示取消；故障和保存失败仍告警。 |
| 验证方式 | 原生两次开始/取消和重开均通过；11项AuditClosureTests验证取消后晚返回不进入录音、取消文案持久化、设备故障仍报错、取消保存失败仍显示未能保存。 |
| 是否 AI 生成典型问题 | 是：将所有异常统一等同于用户可见故障；作者来源不确定 |
| 当前状态与验收 | 已修复 / 原生合成UI、故障回归 |
