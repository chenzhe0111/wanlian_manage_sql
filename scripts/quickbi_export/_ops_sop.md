本文说明「线上目标」日常自动化全链路：定时从 Quick BI 拉数 → 回写目标飞书表 → 群内推送达成简报 → 群内规则问答。整条链路跑在本机 macOS LaunchAgent 上，**不依赖 Cursor / AI 在线**。

## 一、总览

每天固定节奏（本机已 load）：

| 时间 | 任务 | 作用 |
|---|---|---|
| 10:00 | Quick BI 导出 + 整合表月实际回写 | 把 T-1 实际写入目标表，并更新统计截止日 O1 |
| 10:02 | 新老货主回写 | 第七部分等新老明细 |
| 10:04 | 注册司机回写 | 司机车辆 sheet |
| 10:06 | 周度回写 | 周度详细数据 + 本地 `quickbi_weekly_latest.csv` |
| 10:08 | 漏斗回写 | 月/周漏斗 sheet + 本地 funnel CSV |
| 10:20 | 达成简报推送 | 校验 O1=昨天后，图文发到飞书群 |
| 常驻 | 规则问答机器人 | 群内 @ 提问，按固化思路自动答 |

目标工作簿：[目标管理0930_线上3w版本](https://wanlianyida.feishu.cn/sheets/L91EsEtAohwjhStD4y6cYLCGnVe)（整合表 sheet=`1074dd`）。

简报与问答群：**线上目标达成日简报**（`FEISHU_DIGEST_CHAT_ID`）。

## 二、定时拉数并回写目标文档

### 2.1 口径

- 业务日：**昨天（T-1）**，与 Quick BI `pt=yesterday`、表头「统计截止日」O1 一致。
- 脚本目录：`~/Desktop/wanlian_manage_sql/scripts/quickbi_export/`
- 配置：同目录 `.env`（AK/SK、ApiId、飞书表 token 等），**勿提交 git**。

### 2.2 LaunchAgent 清单

安装位置：`~/Library/LaunchAgents/`；源文件在 `scripts/quickbi_export/com.wanlian.*.plist`。

| Label | 脚本 |
|---|---|
| `com.wanlian.quickbi.export` | `run.sh --pt yesterday`（可选本地 CSV） |
| `com.wanlian.sheet.actuals` | `refresh_sheet_actuals.py` → 整合表月实际 + O1 |
| `com.wanlian.sheet.newold` | `refresh_sheet_newold.py` |
| `com.wanlian.sheet.driver` | `refresh_sheet_driver.py` |
| `com.wanlian.sheet.weekly` | `refresh_sheet_weekly.py` |
| `com.wanlian.sheet.funnel` | `refresh_sheet_funnel.py` |

### 2.3 手动补跑

```bash
launchctl start com.wanlian.sheet.actuals
launchctl start com.wanlian.sheet.newold
launchctl start com.wanlian.sheet.driver
launchctl start com.wanlian.sheet.weekly
launchctl start com.wanlian.sheet.funnel
```

或进入脚本目录用 `.venv/bin/python refresh_sheet_*.py`。日志：`scripts/quickbi_export/logs/sheet_*.log`。

### 2.4 成功怎么验

打开整合表，确认 **O1 统计截止日 = 昨天**，当月实际列（如 10 月为 N 列）有数，且表内达成率/时间进度公式已重算。

## 三、发送群日报（达成简报）

### 3.1 任务

- Label：`com.wanlian.daily.digest`，每天 **10:20**
- 入口：`./run_daily_digest.sh`（内部 `daily_target_digest.py`）
- 运行身份：飞书**机器人**发到群 `FEISHU_DIGEST_CHAT_ID`

### 3.2 新鲜度门槛（必过才发）

1. O1 == 昨天  
2. 当月「整体-月运单」实际格有数  

不满足则日志打印 `SKIP:` 并退出 0，**不发旧数**。紧急强推：`./run_daily_digest.sh --force`。

### 3.3 推送内容

- 模板文案：整体/线上/四举措达成 vs 时间进度（规则填数，非 AI 撰写）  
- 附图：四举措达成率 vs 时间进度柱状图  
- 产物：`out/digest_latest.png`、`out/digest_latest.md`

### 3.4 手动推送

```bash
cd ~/Desktop/wanlian_manage_sql/scripts/quickbi_export
./run_daily_digest.sh --dry-run   # 只出图文
./run_daily_digest.sh             # 正式发群
launchctl start com.wanlian.daily.digest
```

日志：`logs/daily_digest.out.log` / `daily_digest.err.log`。

## 四、群内如何提问与自动解答

### 4.1 常驻服务

- Label：`com.wanlian.qa.bot`（KeepAlive）  
- 运行目录（避开 Desktop 权限）：`~/Library/Application Support/wanlian_qa/`  
- 监听事件：`im.message.receive_v1`  
- 默认只响应简报群；群里请 **@机器人** 再提问  

前提：开放平台已订阅该事件；提问人在群内即可（不必每人单独加应用可用性）。

### 4.2 已固化问法（规则分析，不经过 AI）

完整清单见仓库 `QA_ANALYSIS_PLAYBOOK.md`，常用包括：

- 进度为什么慢 / 谁拖累（先点名举措，再点名运单类型）  
- 线上进度为什么慢  
- 新客贡献有没有提升（日均 + 新客占比，忌未完月硬比）  
- 大盘 / 追赶还差多少  
- 线上占比、业务线、分举措深挖（调度/投流/电销/裂变）  
- 周环比、留存、红灯、结构偏移、GTV、一句话汇报  

本地试答（不发飞书）：

```bash
cd ~/Desktop/wanlian_manage_sql/scripts/quickbi_export
/Users/chenzhe/bin/python3 qa_analyze.py "进度为什么这么慢"
```

### 4.3 改代码后如何生效

问答进程读的是 Application Support 副本，改完源码需同步并重启：

```bash
RUNTIME="$HOME/Library/Application Support/wanlian_qa"
SRC="$HOME/Desktop/wanlian_manage_sql/scripts/quickbi_export"
cp "$SRC"/qa_analyze.py "$SRC"/qa_playbooks.py "$SRC"/daily_target_digest.py "$RUNTIME/"
cp -f "$SRC"/out/quickbi_weekly_latest.csv "$RUNTIME/out/" 2>/dev/null
launchctl unload ~/Library/LaunchAgents/com.wanlian.qa.bot.plist
launchctl load ~/Library/LaunchAgents/com.wanlian.qa.bot.plist
```

## 五、和「找 AI 聊」的边界

| 场景 | 是否需要 Cursor/AI 在线 |
|---|---|
| 每天定时回写 + 10:20 简报 | 否 |
| 群内规则问答 | 否 |
| 在 Cursor 里追问、改口径、加新分析思路 | 是 |
| 改 PLAYBOOK / Skill / 脚本后上线 | 需人改代码并同步 runtime |

分析思路正式文档：仓库内 `scripts/quickbi_export/QA_ANALYSIS_PLAYBOOK.md`；Cursor skill：`.cursor/skills/wanlian-online-data-analysis/SKILL.md`。

## 六、排障速查

| 现象 | 处理 |
|---|---|
| 简报 SKIP、未发群 | 先看 O1 是否昨天；先跑 `sheet.actuals` |
| launchctl 报 Operation not permitted | Desktop TCC；问答已迁 Application Support；回写任务用仓库内 plist 的 python 路径 |
| 机器人对某人私聊 230013 | 应用可用性未覆盖；优先用群推送 |
| 问答无响应 | 是否 @ 机器人；是否在简报群；看 `Application Support/wanlian_qa/logs/qa_bot.*.log` |
| sheet 任务 exit 78 | 查对应 `logs/sheet_*.err.log`（常见缺 env / Quick BI 失败） |

Quick BI 失败即停，不要静默重试把自己卡死；恢复后显式 `launchctl start` 再跑。

## 七、相关链接与路径

- 目标表：https://wanlianyida.feishu.cn/sheets/L91EsEtAohwjhStD4y6cYLCGnVe?sheet=1074dd  
- 脚本根目录：`~/Desktop/wanlian_manage_sql/scripts/quickbi_export/`  
- 问答 runtime：`~/Library/Application Support/wanlian_qa/`  
- LaunchAgents：`~/Library/LaunchAgents/com.wanlian.*`  
