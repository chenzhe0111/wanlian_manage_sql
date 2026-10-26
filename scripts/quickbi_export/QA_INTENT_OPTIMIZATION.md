# 飞书 QA 机器人 · 理解力优化说明

**时间**：2026-10-21（本周落地）  
**实现**：`qa_analyze.py` / `qa_bot.py`  
**口径与场景**：见 `QA_ANALYSIS_PLAYBOOK.md`  
**回归**：`qa_intent_cases.json` + `python3 qa_intent_regress.py`

---

## 1. 背景与问题

群内规则问答易出现两类失败：

| 类型 | 典型问法 | 错误表现 |
|---|---|---|
| 答非所问 | 「本周电销新客转化漏斗」 | 被「新客」抢走，答成四举措新客贡献 |
| 暂未识别 | 「说一下电销本周数据情况」 | 直接 unknown，无可操作提示 |

目标：在不接大模型的前提下，用**路由优先级 + 口语归一 + 短上下文 + 回归用例**把高频问法稳住。

---

## 2. 优化点（1～5）

### 2.1 意图冲突优先级

固化路由顺序（高 → 低）：

1. `help` / `empty`
2. `one_liner` / `risk` / `catchup`
3. **分举措深挖** `init_*`（含漏斗 / 转化 / 掉队）— **高于**新客贡献
4. 通用漏斗 stub
5. `new_contrib`（四举措新客；无单举措时）
6. 上下文短跟进（周度切换等，依赖 `prev_intent`）
7. `wow` 周环比
8. `lookup` 查数
9. 专题：`retain` / `structure` / `gtv` / `online_share` / `biz_line` / `overall` / `daily`
10. `online_why` / `why_low`
11. `status`
12. `unknown` → 候选澄清

**效果**：避免「本周 + 新客 + 电销漏斗」被「新客」抢走。

### 2.2 黄金问句回归

| 项 | 内容 |
|---|---|
| 用例 | `qa_intent_cases.json`（约 50+ 条，含冲突句、短跟进、同义词） |
| 脚本 | `python3 qa_intent_regress.py`（退出码 0=全过） |
| 约定 | **改 classify / 同义词 / 优先级后必跑**，防修一处坏三处 |

### 2.3 同义词 / 口语归一

`normalize_query` 先去 `@` 脏文本，再做业务别名映射（先长后短），例如：

| 口语 / 别名 | 标准词 |
|---|---|
| 电销挖潜 | 电销 |
| 端外 / 端外投放 | 投流 |
| 货主招募 | 裂变 |
| 资源合作 | 调度 |
| 这周 / 这一周 / 近一周 | 本周 |
| 按周看 / 周维度 | 周度 |
| 新货主 / 新客户 | 新客 |
| 老货主 / 老客 | 留存 |

### 2.4 同群短跟进上下文

| 项 | 内容 |
|---|---|
| 存储 | `qa_bot.LAST_INTENT`（按群记上一轮意图） |
| 行为 | 「按周度看一下」「漏斗呢」留在上一主题（如电销 `init_tel`），不跳到通用查数 |
| 边界 | 问句已带明确新主题（如换举措漏斗）时，以新主题为准，不盲跟 |

### 2.5 unknown 候选澄清

识别失败时不再只回「暂未识别」：

- 按关键词打分，回 **2～3 条**候选示例问法（`suggest_intents` / `answer_unknown`）
- 群聊：无 `@` 且完全 unknown 时不抢话；有候选澄清时仍可回复（需 `@` 或私聊）

---

## 3. 配套能力

- **分举措周度新客漏斗可答**：问句含本周 / 周度时，电销 / 投流 / 调度 / 裂变走周口径漏斗答案（非仅月度深挖）。
- **Playbook 同步**：`QA_ANALYSIS_PLAYBOOK.md` §R 记录优先级、同义词、短跟进、unknown、回归维护约定。

---

## 4. 维护流程

```
改意图 → 先补 qa_intent_cases.json
      → 改 classify_intent / 同义词
      → python3 qa_intent_regress.py
      → 同步 ~/Library/Application Support/wanlian_qa/
      → launchctl unload/load com.wanlian.qa.bot
```

改口径：先改 Playbook → Skill → `qa_analyze.py` → 同步 runtime 重启 bot。

---

## 5. 一句话

本轮把「答非所问 / 暂未识别」收成可回归的五件套：**优先级 > 用例回归 > 同义词 > 短跟进 > 候选澄清**，并支持分举措周度漏斗问答。
