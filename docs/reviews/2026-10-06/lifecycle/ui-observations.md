# 0.11.6 原生合成界面与性能观察

日期：2026-10-06。使用独立bundle `com.qingmeng.meetingscribe.review.lifecycle`，4条合成会议、假录音器、延迟摘要分析器。没有真实会议、API Key、录音或云端请求。源码与构建方式为同目录的ReviewLifecycleUIHarness.swift和build-lifecycle-harnesses.py。

## 界面结论

- 负责人“审查甲”可见。点击重新整理后，顶部出现停止处理，导入禁用，整理按钮显示忙碌。
- 点击停止后，假分析器完成取消收尾，旧纪要仍在，开始和导入入口恢复。假收尾延迟2秒；AX抓取用时超过该窗口，未捕获正在等待的中间状态。持续忙碌及禁止重复整理/删除的时序由SummaryLifecycleTests的continuation门禁验证，不能用最终AX替代时序证据。
- 1000段原文首部AX包含第1句，不包含第1000句；列表的AXScrollToBottom让末句可达且首句退出当前AX，AX文本长度5380；AXScrollToTop恢复首句且末句退出当前AX，长度5358。证明本次惰性列表首尾可达，不等同于VoiceOver实际朗读。
- 验收后正常退出隔离App。真实应用只检查任务按钮状态并用于安装数据完整性核对，不保存真实正文或截图。

## 主线程调度基准

ReviewPersistenceBenchmark.swift使用临时合成数据根，分别同步执行3次事务及通过repository后台执行3次事务；5ms tick记录MainActor调度。没有初始化真实Store或读取真实库。

| 原文段数 | JSON字节 | 同步平均事务ms | 同步最大tick间隔ms | 后台平均事务ms | 后台最大tick间隔ms |
|---|---|---|---|---|---|
| 1000 | 410228 | 4.485 | 20.881 | 4.396 | 7.541 |
| 10000 | 4136229 | 41.036 | 130.532 | 44.976 | 8.397 |
| 50000 | 20856229 | 203.244 | 617.176 | 202.430 | 7.564 |

事务总耗时相近，后台执行让主线程能继续调度。617ms是连续3次同步事务的最大调度间隔，不能说成单次保存耗时或界面帧率。完整数字见persistence-benchmark.json；不代表所有手动编辑已后台化。

## Instruments本机采样

xctrace Time Profiler附着合成进程MSLifecycleReview，录制20.700796秒，期间打开1000段原文并首尾跳转。potential-hangs导出0条；阈值250ms。仅说明这次采样没有记录达到阈值的卡顿，不能保证其他规模/负载无卡顿或稳定60fps。CUA的AX访问参与采样，会增加辅助功能处理开销。录制后单点RSS为178016 KiB，不是峰值，也不足以判断内存泄漏。

公开证据为ui-profile.log、脱敏ui-profile-toc.xml、ui-hangs.xml。原始trace、TOC和时间样本含启动环境及设备标识，只留本机ignored的.review-dist，禁止加入Git或交付。没有采集真实进程的正文、环境或音频。

## 仍需验收

VoiceOver朗读/焦点、真实声源与设备故障、另机macOS15、长录音、真实HTTPS与弱网、公证仍待具备相应条件后完成。本轮不会把AX、合成回归或本机采样替代这些验收。
