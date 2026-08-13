# Tokscale 桌面 Token 监控悬浮窗 · 项目进度

> 项目根目录：`D:\token消耗检测网站`
> 组件：Node 后端 + PowerShell WPF 悬浮窗 + 多数据源扫描
> 更新日期：2026-08-11（Deep Code 补充：/history、skill/MCP 展示、文案修复、日志截断）

---

## 一、已完成的功能模块

### 1. 后端 `monitor.mjs`（Node HTTP 服务，端口 8899）
- 读取 `opencode.db`（候选路径见代码，优先 `~/.local/share/opencode/opencode.db`）
- **`GET /stats`**：
  - 今日 token 汇总：输入 / 输出 / 推理 / 缓存读 / 缓存写 / 总量 / 成本 / 消息数
  - 今日各模型用量：`modelsToday`（含 msPer1K、tokensPerSec、占比、成本）
  - 最快模型：`bestModel`（msPer1K 最低、样本>=3、total>=5000 才参与）
  - 最近 60 秒滚动统计：`rolling`
  - 当前活跃会话：`active`
  - 排行榜快照：`leaderboard`
  - 工具扫描状态：`toolsStatus`
- **`GET /tools`**（新增）：近 7 天工具调用统计
  - `skill`：按 skill 名分组（`state.input.name`）
  - `mcp`：按工具名分组（`/mcp/i` 匹配，如 `mcp__xxx`）
  - `byTool`：全部工具名分组
  - `byDay`：按天分桶（7 天）
  - **关键**：同一 callID 有 pending/running/completed 多条，必须按 `tool|callID` 去重
- **`GET /history?days=N`**（新增，默认 30，上限 90）：近 N 天每日 token 汇总
  - 按天聚合 `message` 表 token（input/output/reasoning/cacheRead/cacheWrite/total/cost/messages）
  - `items`：按日期升序，无数据的天保留 0 值占位；`totals`：合计；数据源为 opencode `message` 表
  - **`byTool` 多工具扩展**（2026-08-13）：每个日期含 opencode/claude/codex 分项，`byToolTotals` 为近 N 天各工具合计，`tools` 含 hasUsage 标记
    - claude：全量扫描 `~/.claude/projects/*.jsonl` 的 `message.usage` 按天聚合
    - codex：全量扫描 `~/.codex/sessions` 的 `token_count` 累计值按时间序取差值
    - deepcode/kimi/zcode：jsonl/log **无 tokens 字段**（实测确认）→ 不产生用量行，不编造
- **`GET /leaderboard?refresh=1`**：强制刷新排行榜
- `SIGTERM` 优雅退出

### 2. 多工具扫描 `sources.mjs`
- `scanAll(dayStart, now)` / `toolsStatus()` / `TOOL_LABEL`
- 已支持：claude（`~/.claude/projects`）、codex（`~/.codex/sessions`）、kimi（`~/.kimi-code`）、deepcode（`~/.deepcode`）、zcode（`~/.zcode | %APPDATA%\ZCode`）

### 3. 悬浮窗 `Start-Widget.ps1`（WPF，WindowStyle=None，置顶）
- 今日累计 token（大数字）、输入/输出/缓存/推理明细
- 今日最快模型（标签已从"今日最强模型"改为"今日最快模型"，避免误导）
- 今日使用模型列表（前 6 + 计数）
- **主卡 skill/MCP 简况**（新增）：`ToolsSummary` 一行显示"近7天 工具调用 N 次 · skill N 次(最常用) · MCP 未启用/已启用"，数据复用节流拉取的 `/tools` 缓存
- 模型能力排行榜（前 5 + 源名/时间/缓存标记）
- 最近 60 秒滚动、当前会话、今日成本
- **双击卡片**：切换详情视图（`DetailBlock`，含完整模型明细 + 排行榜 + 近30天每日消耗 + 近7天 skill/MCP 调用）
- **右键菜单**：
  - 刷新间隔 2/3/5/10/30 秒
  - 窗口置顶开关
  - 保存今日明细报表（桌面 txt，notepad 打开）
  - 复制今日摘要（JSON）
  - 刷新排行榜
  - 重启监测后端
  - **停止监测后端**（新增）
  - **退出悬浮窗 / 退出并停止全部**（新增）
- **右上角 × 按钮**（新增，红显 hover，点击退出并停止后端）
- 启动时自动检测/拉起后端，后端已存在则跳过
- `FindName` 绑定列表已包含全部控件（`ModelsCount`/`ModelsList` 等）

### 4. 排行榜 `leaderboard.mjs`
- **双榜单源**（2026-08-11 新增编程榜）：
  - `aa`（默认）：AA 智能指数，`https://www.datalearner.com/api/leaderboards/external/aa-quality-index`，242 名
  - `code`：编程能力（SWE-bench 等），`https://www.datalearner.com/api/leaderboards/category/code`，225 名，主分 SWE-bench Verified（0 视为无效，1 位小数）
- 字段：`{rank, model, score, org, modelCode, thinkingMode}`，6 小时缓存，失败回退磁盘缓存（`leaderboard.aa.json` / `leaderboard.code.json`）
- `GET /leaderboard?source=aa|code`：切换活跃榜单，`/stats` 的 leaderboard 快照跟随
- `Start-Widget.ps1`：右键菜单新增"排行榜源"子菜单切换；`Get-LbShortName` 归一化显示"AA 智能指数"/"编程能力"
- 踩坑：PowerShell 变量名不区分大小写，菜单变量 `$script:lbSource` 与控件 `$LbSource` 同名冲突（控件被覆盖成字符串导致 `.Text` 报错）→ 改名 `$script:lbSrc`

### 5. 启动器
- `start.bat`：`powershell -STA -WindowStyle Hidden -File Start-Widget.ps1`
- `install.bat`：`npm install tokscale@4.12.0`
- 均用 `%~dp0` 相对路径，移动目录无需改动

### 6. 其他
- `leaderboard.json`：排行榜磁盘缓存
- `.gitignore` / `package.json` / `package-lock.json`
- 日志：`widget.log`（悬浮窗）、`monitor.out.log` / `monitor.err.log`（后端）

---

## 二、未通过的单测 / 已知问题

> 项目暂无自动化测试框架，以下为手工验证结论与待修复项。

### 已修复（历史）
- ✅ 悬浮窗"一直连接中"：`FindName` 列表缺 `ModelsCount`/`ModelsList`，赋 `.Text` 时抛"找不到属性 Text" → 已补入列表
- ✅ 排行榜源与展示不一致：后端曾返回旧 OpenCompass 缓存（后端进程未重启加载新 `leaderboard.mjs`）→ 需杀旧进程重启
- ✅ "今日最强模型"误导标题 → 改为"今日最快模型"（2 处：动态标签 + XAML 初始化）

### 待修复 / 待确认
- [x] **排行榜源切换为 AA 智能指数**（用户指定 `aa-quality-index`）
  - `leaderboard.mjs` 已抓 `https://www.datalearner.com/api/leaderboards/external/aa-quality-index`
  - 返回：`{meta, columns, data, totalCount}`，data[0] = `{rank, modelName, modelCode, score, organization, thinkingMode}`，共 242 条
  - 注意：AA 页面前端用 API 异步拉取，无 `__NEXT_DATA__`；首页 `/leaderboards` 的 `__NEXT_DATA__` 才嵌 `lmarena`
  - 2026-08-11 已验证 `/stats` 返回 AA 榜单（242 名，Claude Opus 5 居首）
- [x] **近 30 天每日 token 消耗** 已实现
  - 后端 `/history?days=30` 已上线，按天聚合 `message` 表 token
  - widget 详情视图已展示"近 30 天每日消耗"（双列 + 合计/日均/成本）
- [x] **widget 展示 skill/MCP 近 7 天调用**
  - 后端 `/tools` 接线完成，详情视图展示 skill 列表（次数）、MCP 状态、每日分布
  - 节流：history 60s / tools 30s 拉取一次
- [x] `LbSource` XAML 默认文本已改为"排行榜 · 加载中"（中立文案，不再出现 OpenCompass 旧名）
- [x] `widget.log` 启动时截断（`[System.IO.File]::WriteAllText(...,'')`）
- [x] **推送 GitHub**：`https://github.com/zxx-122/tokscale-monitor`（main 分支）
  - 注：本机 github.com:443 被网络限制、SSH key 未认证 → 改用 GitHub Git Database API 上传本地提交（blob/tree/commit/ref）
  - 2026-08-11 远程 main 已含全部 11 个文件与最新提交 `df22d184`
- [x] **deepcode 扫描器数据污染**（2026-08-11 修复）
  - 原实现把 deepcode jsonl 所有 assistant 消息计为 total=0/messages=1 伪记录 → /stats messages 虚增、modelsToday 出现全 0 假模型
  - deepcode jsonl 实测无 tokens/usage/cost 字段 → parse 改为返回 null，仅保留 toolsStatus 检测
  - 修复后 /stats 与 /history 的 messages/total/cost 完全一致（实测 142 / 15015516 / 0）
- [x] **数据核验**（2026-08-11，与 DB 直查对比全部通过）
  - /stats 今日 token 五字段和 = tokens.total 和；按模型分组与 DB 一致
  - /history 与 /stats 的 total/cost/messages 一致
  - /tools 去重后 941 与原始记录一致；byDay 独立复算一致（08-10:647、08-11:152）
  - 排行榜缓存与 AA API 0 不一致（242 条，versionTime 2026-08-08）
  - claude/codex 扫描器解析与数据格式匹配（codex info=null 时正确跳过）；kimi 无使用记录正确返回空

---

## 三、接下来的具体任务（按优先级）

1. （可选）`/history` 扩展：合并 sources.mjs 各工具扫描的每日数据（当前仅 opencode `message` 表；sources 为内存增量扫描，跨进程无法回溯，需持久化存储才可行）
2. （可选）修复本机 GitHub 443 限制：注册 SSH key 或配置代理后改用 `git push`（当前用 Git Database API 推送可用）

---

## 四、关键踩坑记录

1. **node -e 单行内嵌脚本的引号转义地狱**（Windows PowerShell 下 `\f`、`\"` 常被吞）
   → **一律写临时 `.mjs` 文件再 `node file.mjs` 执行**（`C:\Users\AAA\AppData\Local\Temp\opencode\`）
2. **后台 node 进程阻塞 PowerShell**：`node monitor.mjs` 前台运行会占住 shell 直到超时
   → 用 `Start-Process -WindowStyle Hidden -RedirectStandardError/Output` 启动
3. **端口被旧进程占用**：改了代码后老进程仍监听 8899，返回旧结果
   → 改完代码先杀 `Win32_Process` 中 `CommandLine like '*monitor.mjs*'` 再重启
4. **排行榜数据去重**：`part` 表同一 callID 有 pending/running/completed 三条，统计次数必须按 `tool|callID` 去重
5. **MCP 现状**：当前数据库无任何 `mcp__` 前缀工具调用 → `mcp.detected=false`、total=0，属真实情况，不得编造数据
6. **数据源结构**：opencode 新版 `message.data` 已不含 `parts`，工具调用记录在独立 `part` 表（`type='tool'`，工具名在 `$.tool`，skill 名在 `$.state.input.name`）
7. **robocopy /MOVE**：迁移目录用 `robocopy <src> <dst> /E /MOVE`，exit code 1 表示移动成功（0 无操作，1=成功复制）
8. **AA 页面结构**：`/leaderboards/external/aa-quality-index` 页面是 1MB SSR 但无 `__NEXT_DATA__`，真实数据走 API：`https://www.datalearner.com/api/leaderboards/external/aa-quality-index`
