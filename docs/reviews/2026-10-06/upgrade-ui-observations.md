# 升级后的原生界面验收

日期：2026-10-06；当前修改源码独立编译，唯一bundle ID local.codex.MeetingScribeReview.upgrade。只用四份合成会议，未读取真实会议、使用云端或保存真实Key。最终UI的工具栏补丁再次编译后实测。

| 场景 | 实测结果 | 证据 |
|---|---|---|
| 待办负责人 | 速览可见负责人：审查甲 | upgrade-ui-overview.png / overview-ax.txt |
| 编辑输入框名称 | Description包含校正逐字稿、我方、00:00 | cua_repl本次原始工具输出 |
| 草稿切页 | 周一改周二，切纪要再回原文，未保存草稿仍在 | cua_repl本次原始工具输出 |
| 过期提示 | 保存后速览与纪要均标明旧结果，未冒充已更新 | upgrade-ui-overview.png / minutes-ax.txt |
| 旧版全文 | 正文可见并提示没有分段时间锚 | upgrade-ui-legacy.png / legacy-ax.txt |
| 1000段首屏 | AX可读1–19句 | upgrade-ui-long-top-ax.txt |
| 1000段末尾 | AXScrollToBottom后可读981–1000句 | upgrade-ui-long-bottom.png / bottom-ax.txt |
| 工具栏 | 最终标签为开始录音/导入音频/设置 | upgrade-ui-toolbar-ax.txt |
| 空结果 | 显示未识别到发言，提供查看原文 | upgrade-ui-empty-ax.txt |
| 键盘设置 | Cmd+,打开设置；点击关闭后返回会议 | cua_repl本次原始工具输出 |
| 浅/深色 | 原生浅色速览、深色空态均检查了截图 | upgrade-ui-overview.png / upgrade-ui-dark.png |

未用VoiceOver、未测屏幕阅读器完整导航、未测色彩对比度仪器值或FPS。AX长文观察改善，不能等同于VoiceOver验收通过。实际录音授权与声音来源、设备切换、macOS15运行仍需实机验证。退出夹具后，只保留隔离目录与合成证据；未替换/退出/改动真实安装App。
