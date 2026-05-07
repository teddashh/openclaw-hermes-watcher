# openclaw-hermes-watcher

[English](README.md) | **[繁體中文](README.zh-TW.md)**

> ## 用 OpenClaw 的嚴謹管理機器
> ## 用 Hermes 的積極管理進化
> ### 兩台 Agent 互相幫忙

替已經跑著 [OpenClaw](https://docs.openclaw.ai) 的主機加上一**層 layer** — 我們**不去動** OpenClaw 跟 Hermes 本身,只透過它們的公開 CLI 跟慣用檔案路徑整合。它會裝一個專注研究 OpenClaw 上游的 [Hermes Agent](https://github.com/NousResearch/hermes-agent) profile、一個負責顧好 Hermes 安裝健康度的守護 subagent、一份任何 agent 都改不掉的 `chattr +i` 政策 baseline,以及一套確保「沒跑就會出聲」的決定性 dead-man-switch 心跳互巡機制 — **全都不修改 OpenClaw / Hermes 的已安裝 code。** 因此 `openclaw upgrade` 跟 `hermes update` 完全不會被我們踩到。

Apache-2.0 授權。v0.1.0。39 個檔案。經過三輪雲端 code review。

---

## 目錄

1. [TL;DR — 五行裝完](#1-tldr--五行裝完)
2. [這個 repo 解決的問題](#2-這個-repo-解決的問題)
3. [架構:每一層為什麼這樣設計](#3-架構每一層為什麼這樣設計)
   - 3.1 [四個角色](#31-四個角色)
   - 3.2 [檔案契約(roles 不互聊,只寫檔)](#32-檔案契約roles-不互聊只寫檔)
   - 3.3 [硬性 baseline(chattr +i + sha256 + meta-hash)](#33-硬性-baselinechattr-i--sha256--meta-hash)
   - 3.4 [Watcher(純 bash,不是 LLM)](#34-watcher純-bash不是-llm)
   - 3.5 [Cross-Patrol Heartbeat(Phase 2.5)](#35-cross-patrol-heartbeatphase-25)
   - 3.6 [六個已知難題我們怎麼面對](#36-六個已知難題我們怎麼面對)
4. [實作對照](#4-實作對照)
   - 4.1 [Repo 結構](#41-repo-結構)
   - 4.2 [Phase 1 — 安裝](#42-phase-1--安裝)
   - 4.3 [Phase 1.5 — talk-helpers + maintainer Telegram](#43-phase-15--talk-helpers--maintainer-telegram)
   - 4.4 [Phase 2 — Hermes 自己的 Telegram gateway](#44-phase-2--hermes-自己的-telegram-gateway)
   - 4.5 [Phase 2.5 — daily cron + 心跳互巡](#45-phase-25--daily-cron--心跳互巡)
5. [前置條件](#5-前置條件)
6. [檔案落點(裝完之後長這樣)](#6-檔案落點裝完之後長這樣)
7. [日常營運](#7-日常營運)
8. [長期維護](#8-長期維護)
9. [血淚經驗(都已經寫進 code 結構裡)](#9-血淚經驗都已經寫進-code-結構裡)
10. [已知限制](#10-已知限制)
11. [授權](#11-授權)

---

## 1. TL;DR — 五行裝完

主機上 OpenClaw 已經跑著。你要在它上面加一個長期跑的 Hermes agent + 守護 + dead-man-switch。五個指令:

```bash
git clone https://github.com/<你>/openclaw-hermes-watcher
cd openclaw-hermes-watcher
cp config/machine.env.example config/machine.env
$EDITOR config/machine.env             # 填操作者 + 主機 + bot tokens
bash scripts/all.sh                     # 冪等(idempotent),一氣呵成
```

驗證:`bash scripts/07-smoke-test.sh`。從這一刻起 Hermes 每天醒來、輪換焦點、把發現寫進檔案。Maintainer cron 互相監視 + 監視 Hermes;真的有 cron 漏跑時 Telegram 才會出聲。日常會經歷什麼 → 看 [§7](#7-日常營運)。

如果你想先理解架構為什麼長這樣再決定要不要裝,2 到 4 節是教育性的深度說明。

---

## 2. 這個 repo 解決的問題

你跑著 OpenClaw,router 起來了、workspace bootstrap 過了、project subagents 註冊好了、Telegram bots 配對完成。現在你想要一個**長期駐留的 agent 看著 OpenClaw 上游** — 讀 commits、讀 issues、累積一份「我這台機器在哪裡 fork 過」的模型、有適合 apply 的 release 時起草 upgrade-pack — 但你不想每天看著它,也不想給它足夠繩子讓它把自己說服去做你沒授權的事。

直覺的做法都會以可預測的方式失敗:

### 2.1 「每天 cron 比對上游 + ping Slack」

- 一個月後,你開始無視那些 ping。**Approval fatigue。**
- 三個月後,你已經落後 6 個 minor version。第一個你真的看的 ping 是「23 commits、4 breaking」 — 一次評估太多。
- Cron 不知道你的 local diff;它的 breaking-change 列表是「真正會壞的事」的超集。你不再相信那堆雜訊。

### 2.2 「臨時請 Claude Code(或其他通用 agent)做」

- 每個 session 從零開始。沒有累積的「為什麼三個月前我們改了 X 檔」模型。
- 每個 session 對「值得 apply 什麼」有不同看法。**Taste drift** 在 sessions 之間。
- 你每次都在付重建 context 的錢。成本累積。

### 2.3 「讓 agent 自動更新就好」

- 一直 work,直到不 work 那一天。**沒有 rollback path 的爛 upgrade,單一 shell 救不回來。**
- Agent 沒有保留你 local diff 的動機;agent 的動機是「把 upgrade 弄上去」。
- 一個失準的 agent 第一個學會的就是把那個本來該抓住它的 alert 關掉。

### 2.4 這個 template 怎麼做

- **長期駐留的 agent(Hermes)** 經過數週數月發展成「**這台主機的 OpenClaw 該怎麼演化才能更好地服務 operator 的服務**」的專注專家。它累積的模型放在 `~/.hermes/memories/MEMORY.md` 跟 `~/.hermes/skills/`。它**不會**從零開始。它的食物源有四,按優先順序:服務信號(每個 subagent 的 MACHINE_LOG — 主食,因為服務健康度是唯一 fitness function)、上游 OpenClaw、社群生態系(高星 OpenClaw skill / plugin repos)、自己累積的 MEMORY。
- **守護 subagent(`hermes-maintainer`)** 跑排程性的 Hermes 健康檢查 — `hermes doctor`、weekly insights summary、monthly compress、上游觀測。它**不能**自己 apply 任何東西;只有操作者決定。
- **硬性 baseline(`chattr +i` 政策 YAML 檔)** 編碼 agent **絕不可以**做的事,不管未來提案多有說服力。沒有 LLM 改得掉,因為改它需要 sudo,而 agent 沒 sudo。
- **Watcher(50 行 bash 的 systemd user unit)** 一小時 60 次驗證 baseline。它**不是 LLM** — 是純規則程式。**沒得吵。**
- **Cross-patrol heartbeat** 確保 Telegram 只在「真的有東西壞」(某個 cron 漏跑)時通知你。健康營運是**安靜**的。

結果是一個你可以放著的系統。每月走進來一次,看一眼 `~/.openclaw/workspace/evolution-journal.jsonl`,知道 Hermes 最近在研究什麼,決定有沒有 draft 的 pack 值得 apply。其他時間 — 安靜。

---

## 3. 架構:每一層為什麼這樣設計

**整合邊界優先講。** 這個 template 是個外掛層,透過 OpenClaw 跟 Hermes 的公開 CLI(`openclaw cron / agents / config`、`hermes profile / config / cron / gateway`)跟慣用檔案路徑(`~/.openclaw/workspace/`、`~/.hermes/profiles/<name>/`)整合。**從不**修改它們已安裝的 code:

| 路徑 | 這個 template 動嗎? |
|---|---|
| `/usr/lib/node_modules/openclaw/`(OpenClaw 已安裝 code) | **不動** — 列在 `baseline.policy.yaml:immutable_paths` |
| `~/.hermes/hermes-agent/`(Hermes 已安裝 code) | **不動** — 只能透過 operator 批准的 `hermes update` 管 |
| `~/.openclaw/openclaw.json`(OpenClaw 主 config) | **不直接寫** — 只透過 `openclaw config set` |
| `~/.openclaw/workspace/baseline/`(本 template 的政策檔) | 動 — 部署後 chattr +i,只 operator 編 |
| `~/.hermes/profiles/openclaw-evolution/`(一個 Hermes profile) | 動 — 用 Hermes 文件化的 profile 機制 |
| `~/hermes-maintainer/.openclaw-ws/`(subagent workspace) | 動 — 用 OpenClaw 文件化的 subagent 機制 |

完整檔案清單在 [§6 檔案落點](#6-檔案落點裝完之後長這樣)。實務影響:`openclaw upgrade` 跟 `hermes update`(operator 批准的)完全不會踩到 template 寫到磁碟上的任何東西。

**同樣的 layer-only commitment 也約束 Hermes 能提的東西。** Hermes 產的 evolution-pack 分五種 `pack_kind`(定義在 `baseline.policy.yaml:pack_kinds`)。最安全的兩種 — `install_skill` 跟 `install_plugin` — 落到 OpenClaw 文件化的擴充點(`~/.openclaw/skills/` 跟 plugin 系統),**結構上不可能修改 OpenClaw 本體**。這就是為什麼 Hermes 的四個食物源裡有「社群生態系」(高星 skill / plugin repos 像 `VoltAgent/awesome-openclaw-skills`):採用解決服務痛點的社群 skill 是 Hermes 能做出最架構對齊的動作。較高風險的 pack kind(`config_change`、`synthesize_custom`)需要 operator review。

下面每一層都得交代 — 它做什麼、為什麼需要它、它對應哪個失敗模式。整個架構針對「長駐有認知能力的 agent 在生產主機上要面對的六個已知難題」採取明確立場(看 [§3.6](#36-六個已知難題我們怎麼面對))。

### 3.1 四個角色

四個 agent 角色 + 一個人:

```
                        Operator(人,Principal)
                         │
                         │  CLI · SSH · Telegram bots
                         ▼
              ┌────────────────────────┐
              │  OpenClaw main agent   │  router + side-effect outlet
              │  ~/.openclaw/workspace │
              └─┬──────────────────────┘
                │ spawns + governs
                ▼
   ┌─────────────────────────────────────────────────────┐
   │ OpenClaw workspace subagents                         │
   │ ─────────────────────────────────────────────────── │
   │ <你的 project subagents — 不在此 repo 範圍>            │
   │ hermes-maintainer (~/hermes-maintainer/.openclaw-ws/) │
   └────────────────────┬────────────────────────────────┘
                        │ "hermes-maintainer" 讀 / 跑:
                        ▼
              ┌────────────────────────┐
              │  Hermes Agent          │  演化 OpenClaw
              │  profile:              │
              │  openclaw-evolution    │
              │  ~/.hermes/            │
              └────────────────────────┘
```

**經驗法則:從目錄列表看不出每個角色在做什麼,代表部署出錯了。** 每個角色的足跡都在 plain markdown / JSONL / YAML 裡 — 人能讀、未來 Claude Code rescue 能讀、其他 agent 也能讀。沒有專有狀態、沒有不透明的 SQLite blob 要解讀。

#### 3.1.1 Operator(Principal)

人類。終極權威。**架構的存在是為了讓你「不需要」每天看著它**;它保留你冷啟動進來理解狀態的能力,但不要求。

你跟 agents 溝通透過:
- CLI(`talk-main`、`talk-hermes` 等 — Phase 1.5+)
- Telegram bots(per-agent,Phase 1.5/Phase 2 opt-in)
- SSH + 直接編輯檔案(永遠可用)

你擁有 agents 沒有的權威:
- `sudo chattr -i` — 只有你能 unfreeze baseline(透過 `scripts/edit-baseline.sh`)
- `hermes update` — 只有你決定何時升級 Hermes(maintainer 標記 release,你動)
- Pack apply — main 在驗證後 apply,但只有在 pack 進 inbox 且你決定後

#### 3.1.2 OpenClaw main agent

**工作:** 路由請求。處理主機層級事務(Caddy、Docker、systemd、ports、SSL、backups)。在驗證後 apply Hermes 產出的 upgrade-pack。寫 evolution journal。治理 subagents。

**不能:** 改 `baseline.policy.yaml` `immutable_paths` 裡的檔。改 watcher unit 或它的 policy(`chattr +i` 強制)。改 Hermes 的 source 安裝(`~/.hermes/hermes-agent/`)除非透過 documented `hermes update` flow + operator 批准。

**足跡:** `~/.openclaw/workspace/MACHINE_LOG.md`、`evolution-journal.jsonl`、`DEVIATIONS.md`。

#### 3.1.3 hermes-maintainer subagent

唯一工作:讓本機 Hermes Agent 安裝**保持健康、跟得上、跟它應該做的事對齊**。**Hermes 的醫生兼史官,不是它的老闆。**

**可以:**
- 跑 `hermes doctor`、`hermes status`、`hermes -p openclaw-evolution insights --days N`
- 讀 `~/.hermes/sessions/`、memories、skills(read-only)
- 讀上游 Hermes repo 觀察 release
- 寫 study notes 到 `~/hermes-maintainer/.openclaw-ws/study-notes/`
- 透過 journal 通知 main agent 有什麼需要關注

**不能:**
- 編輯 Hermes 的 SOUL.md / USER.md / MEMORY.md(那是 Hermes 自己的狀態)
- 改 `~/.hermes/.env`(API keys — operator only)
- Apply Hermes 產出的 upgrade-pack(只有 main 可以,而且要驗證後)
- 改 baseline 或 watcher
- 自己跑 `hermes update` — 在 `forbidden_autonomous`;轉成 journal event 給 operator

**為什麼跟 main 分開:** Maintainer 的 daily/weekly 節奏專注於 Hermes 相關信號。它不跟 main 的主機管理工作搶資源。它的 bootstrap 檔(`AGENTS.md`、`IDENTITY.md`)把它錨在窄的角色上,即使 operator 數週沒進來。

#### 3.1.4 Hermes Agent(`openclaw-evolution` profile)

**工作:** 主動演化這台主機上的 OpenClaw,使它**更好地服務 operator 的服務**。讀每個服務的 MACHINE_LOG 找痛點;對照上游 OpenClaw、社群生態系(高星 skill / plugin repos)、自己累積的 MEMORY;產出針對特定服務改善的 evolution-pack。透過自我改進迴路在這**一份**工作上越做越好。成功指標:**服務健康度**(穩定性、延遲、錯誤率、復原時間、升級難度) — 不是上游一致性。

**可以:**
- 讀 `~/.openclaw/`(read-only) — 包含每個服務的 MACHINE_LOG、evolution-journal、study-notes
- 透過 `gh` CLI 或 REST fallback 讀上游 OpenClaw repo
- 讀社群生態系:curator list 像 `VoltAgent/awesome-openclaw-skills`、`gh search` `topic:openclaw-skill` / `topic:openclaw-plugin`
- 寫到自己的 `~/.hermes/` profile dir(sessions、memories、skills、SOUL)
- 在 `~/.openclaw/workspace/upgrade-packs/inbox/` 產出 evolution-pack 工件。Pack `kind` 是五種之一:`install_skill`、`install_plugin`、`apply_upstream_patch`、`synthesize_custom`、`config_change`(定義在 `baseline.policy.yaml:pack_kinds`)。前兩種結構上不修改任何東西(只是擴充點),優先採用。
- 透過 CLI 或 Telegram(Phase 2,可選)跟 operator 講話

**不能:**
- 直接寫 `~/.openclaw/`,只能透過 upgrade-pack inbox
- Apply 自己產出的 upgrade-pack
- 改 `~/.hermes/.env`
- 改 watcher 或 baseline policy
- 在自己 sandbox 外起 shell process(Hermes shell tool 是 chroot-jailed — 詳見 [§9 血淚經驗](#9-血淚經驗都已經寫進-code-結構裡))

### 3.2 檔案契約(roles 不互聊,只寫檔)

> **角色之間「不」互相聊。它們透過寫結構化檔案讓對方讀來溝通。**

這是整個系統最重要的單一架構規則。**沒有 agent-to-agent 的 prompt 傳遞、沒有 live RPC、沒有協商。** 每個角色把資料寫到磁碟上,格式是其他人(以及救火時的 Claude Code)能讀的。

| From → To | 通道 | 格式 |
|---|---|---|
| Hermes → main | Upgrade-pack drop dir | `manifest.yaml` + diffs |
| main → Hermes | Evolution journal entries | append-only JSONL |
| hermes-maintainer → main | Study notes + journal events | markdown + JSONL |
| 任何 subagent → main | `MACHINE_LOG.md` updates | markdown |
| Operator → 任何角色 | CLI / Telegram / SSH | conversational |

**為什麼用檔案,不用 RPC:**

1. **可審計。** 一個 pack proposal 是你 `cat` 得到的檔。一個 journal event 是你 `jq` 得出的 JSONL 行。沒有 transient 狀態、沒有「agents 昨天聊了什麼」這種問題。如果發生了,就在磁碟上。
2. **可救火。** 出事 cold-SSH 進來時,plain markdown / JSONL / YAML 是現存最 rescue-friendly 的格式。沒有 daemon 要 inspect、沒有網路 endpoint 要查,只有檔案。
3. **預設非同步。** Agents 不需要同時上線。Hermes 週一 06:00 UTC 起草 pack;main 週三 04:30 EDT 在它的排程跑時讀。各自步調。
4. **沒有 agent-to-agent 說服。** Hermes 想要 main apply 一個 pack 時,寫個 `hermes_proposed` event 帶 pack ID。它**不**寫散文說服 main。Main 讀 manifest.yaml 自己決定。
5. **跟 rescue agent 對稱。** 你(或 Claude Code)走進來調查「這台機器發生什麼事」時,**讀的是跟 agents 一樣的檔**。沒有要還原的隱藏 inter-agent 狀態。

### 3.3 硬性 baseline(chattr +i + sha256 + meta-hash)

`~/.openclaw/workspace/baseline/` 含四個政策檔加兩個完整性 hash:

```
baseline/
├── baseline.policy.yaml         # forbidden_actions, immutable_paths, allow_write_for_main, change_budget, require_approval
├── hermes-permissions.yaml      # Hermes 可 / 不可做
├── machine-mission.md           # 這台主機是做什麼的
├── watcher.sh                   # 定期 sentinel
├── .expected-hashes             # 上面四檔的 sha256
└── .expected-hashes.sha256      # meta-hash,.expected-hashes 自己的 sha256
```

部署完六個全部 `chattr +i`(immutable)。

**為什麼用 chattr +i**(而不是只靠檔案權限):
- Linux 檔案權限可以被檔案 owner 改。`ubuntu` user(agents 跑的身份)擁有 baseline 檔案;沒 chattr 的話,任何 agent 都能 `chmod` 然後改寫。
- `chattr +i` 在 kernel 層讓檔案真正 immutable。寫入需要先 `chattr -i`,而那需要 `sudo`。**Agents 沒 sudo。Operator 有。**
- 這是系統裡**最承重的單一安全屬性**。沒有它,其他每一層都是裝飾 — 一個決定 policy「過時了」的 LLM 直接改寫就好。

**為什麼有 `.expected-hashes` 檔**(而不是只信任 chattr):
- chattr +i 阻止寫入但理論上夠聰明的攻擊者能繞過 filesystem 層竄改資料(原始 block device write 之類)。Defense in depth 說:也驗 hash。
- 更實際的是:operator 透過 `scripts/edit-baseline.sh` 編輯後可能忘記 re-freeze。Watcher 抓到這個會 emit `baseline_immutability_lost` event。

**為什麼有 meta-hash**(`.expected-hashes.sha256`):
- 這是 chicken-and-egg 修補。如果 `.expected-hashes` 自己可竄改,攻擊者可以**同步**改寫某 baseline 檔 + `.expected-hashes` 裡那行,雙改下 hash 檢查就破了。
- Meta-hash 是 `.expected-hashes` 自己的 sha256,放在另一個檔。Watcher 在信任 `.expected-hashes` 之前先驗 meta-hash。要破這個,攻擊者要**同步改三個檔** — 而其中任何一個是 chattr +i 就斷鏈了。

**編輯 baseline** 是 operator-only,透過 `scripts/edit-baseline.sh`。那個腳本:
1. `sudo chattr -i` 目標檔 + 兩個 hash 檔
2. 開 `$EDITOR`
3. 重生 `.expected-hashes` 跟 `.expected-hashes.sha256`
4. `sudo chattr +i` 全部
5. Emit `operator_edited_baseline` journal event,`actor=operator`

如果你忘了步驟 4(re-freeze),watcher 60 秒內會發現並 emit `baseline_immutability_lost`。**沒有辦法靜默讓 baseline 維持可變。**

### 3.4 Watcher(純 bash,不是 LLM)

純 bash 的 systemd user unit,在 `~/.config/systemd/user/openclaw-watcher.service`,每 60 秒觸發一次。它跑 `~/.openclaw/workspace/baseline/watcher.sh`(本身也是 chattr +i)。

每個 tick 它:
- 驗證所有 baseline 檔還是 `chattr +i`
- 驗證所有 sha256 hash 跟 `.expected-hashes` 對得上
- 驗證 `.expected-hashes` 自己的 hash 跟 `.expected-hashes.sha256` 對得上
- 驗證 `openclaw-gateway` process 在跑
- 每小時 emit 一次 `watcher_heartbeat` event,讓你知道 watcher 自己還活著

異常 emit JSONL events 到 `~/.openclaw/workspace/evolution-journal.jsonl`。**Watcher 不對異常採取行動 — 只記錄。** Main agent(或 operator 下次進來)讀了再決定。

**為什麼純 bash 不是 LLM:**
- LLM watcher 可以被吵贏。「這個檔案改變沒問題,因為 X。」純規則 watcher**沒得吵**。它算一個 hash、跟 fingerprint 比、不對就 emit 一個 JSONL event。**沒得協商。**
- 核心原則:**會思考的 watcher 可以被說服去允許事情;只是一個寫保護檔的 watcher 不可妥協。**

**為什麼用 systemd user unit 而不是 system unit:**
- User unit 不需要 root。Watcher 跟 gateway 跑同一個 `ubuntu` user。
- User unit 比較容易裝(`~/.config/systemd/user/`),不用改 `/etc/systemd/system/`。
- 取捨:user unit 沒法 drop 需要 CAP_SYS_ADMIN 的 capabilities(`LockPersonality`、`MemoryDenyWriteExecute` 等)。Defense in depth 在這裡靠 policy + filesystem 層(`chattr +i`、sudo 限制),不是 kernel-namespace 層。Unit 檔有註記。

**為什麼 watcher 的檢查是極簡的:**
- 每加一個檢查就多一個東西要維護。上面四個檢查是承重的。
- 擴 watcher 是重決定,因為 watcher 自己 `chattr +i`。透過 `scripts/edit-baseline.sh` 編輯。

### 3.5 Cross-Patrol Heartbeat(Phase 2.5)

**決定性的 dead-man-switch:把「壞了會出聲的警報」換成「沒人用新心跳 dismiss 的警報才會出聲」**。

五個排程工作定期跑:

| Job | 預設排程 | 擁有者 |
|---|---|---|
| `hermes_daily_doctor` | 04:30 local 每天 | hermes-maintainer (OpenClaw cron) |
| `hermes_upstream_watch` | 05:00 local 每天 | hermes-maintainer (OpenClaw cron) |
| `hermes_weekly_review` | Mon 05:00 local | hermes-maintainer (OpenClaw cron) |
| `hermes_monthly_compress` | 1st 05:30 local | hermes-maintainer (OpenClaw cron) |
| `openclaw-daily-study` | 10:00 UTC 每天 | Hermes Agent (Hermes cron) |

每個在**成功時**寫一個 heartbeat 檔含當下 timestamp + interval + grace。然後巡邏其他四個 heartbeats;任何一個太久沒寫超過 `interval + grace`,就透過設定的 bot 發 Telegram alert。

**為什麼 cron prompt 把 heartbeat 排在「第一」**(不是最後):

我們**慘痛地**學到這個。當 patrol 呼叫是 prompt 的**後綴**時,agent 會在呼叫 patrol script 之前就把 summary(「Done. ... I did not run hermes update.」)寫成最後回覆。OpenClaw cron framework 把第一個文字 summary 當成 run 完成,所以後綴永遠不會 fire — heartbeat 永遠不會落地。把 `STEP 1: heartbeat-patrol` 放在 prompt 開頭保證 heartbeat 在 agent 產出 summary 之前先寫、先巡 peers,即使下游任務 turn-limit 用完或 classifier short-circuit。看 `scripts/06-cron-setup.sh:heartbeat_prefix_for`。

**為什麼用獨立的 alerter script**(`heartbeat-patrol`):

Patrol 邏輯**必須是決定性的**。如果 patrol 自己是 LLM 呼叫,它會跟被巡邏的 agent 有同樣的對齊失敗模式。所以 `heartbeat-patrol` 是 150 行 bash — 它寫一個 heartbeat、讀 peers、算 (now − last_timestamp)、跟 (interval + grace) 比、stale 時 curl Telegram。**Alert 路徑沒有 LLM。**

**為什麼是「default broken alert,被 fresh heartbeat dismiss」而不是「壞了再警報」:**

如果警報是「壞了再 fire」,警報路徑本身就變成 single point of failure。Alerter 掛了你就一片寂靜。改用「heartbeat = dismissal」的 pattern,**沒動作這件事**觸發警報,所以警報路徑不需要在跑就能告訴你 — 下一個還活著的 peer 巡邏時會抓到 stale-peer 然後 fire。

**為什麼每個 agent 用自己的 bot 發 alert**(而不是共用一個 bot):

不同 bot = Telegram client 裡不同的「聲音」。`@*_watchbot` 通知你時是 maintainer 抓到 staleness。`@*_hermesbot` 回覆時是 Hermes 自己。如果某個 agent 出問題,**另一個 agent 的 bot 還是能發出 alert**。

**Hermes-side 的 cron 比較特別** — 用 Hermes 自己的 cron scheduler,不是 OpenClaw cron,因為:
- OpenClaw cron 配 `--session isolated --agent X` 跑的是 OpenClaw subagent 身份,不是 Hermes。
- Hermes 的 daily-study task 要寫 Hermes 自己的狀態(sessions、memories、skills)— 只有 Hermes 自己有那邊乾淨的寫入權。
- Hermes 的 shell tool 是 chroot-jailed(§9 詳述),所以 daily-study cron 的 prompt 指示 Hermes 用它**原生**的 `filesystem_write` 工具加**絕對路徑**,而不是住在 jail 外面的 patrol script。

### 3.6 六個已知難題我們怎麼面對

長駐有認知能力的 agent 在生產主機上有六個已知難題,任何設計都得對它們採取立場。這個 template 不假裝完全解決,但對每個有明確的立場。

| 問題 | 立場 | Code 在哪 |
|---|---|---|
| **Cold start** — 第一週行為跟穩態時質性不同 | Maintainer 的 daily-doctor cron 從第 1 天開始跑,所以 observability 不依賴 agent 已經值得信任 | `scripts/06-cron-setup.sh` 在裝完後立刻註冊 cron |
| **Recursive upgrade** — agent 自己升自己 | `hermes update` 在 `forbidden_autonomous`;只有 operator | `templates/baseline.policy.yaml.tmpl:forbidden_actions[id=...]` |
| **Taste drift** — agent 偏好跟 operator 分歧 | SOUL.md 跨 re-run 保留;maintainer 的週審查浮出 drift 信號 | `scripts/04-configure-hermes.sh` 只在 SOUL 缺檔時寫 |
| **Approval fatigue** — operator 不再仔細看提案 | Drafts 進 inbox;不主動 push Telegram;operator 想看再拉 | `templates/SOUL.md.tmpl` 「Output 走檔案,不走 Telegram push」 |
| **Token cost** — agent 自己思考很貴 | Daily 焦點輪換限制每天燃料;idempotency check 跳過已做工作 | `templates/hermes-daily-study-prompt.txt.tmpl` 「skip if already done today」 |
| **Fleet sharing** — 跨機器協調 | 明確不在範圍內;一台機器一份 config | 完全沒 fleet 邏輯 |

---

## 4. 實作對照

每個架構決定都對應到一段 code。這節按裝的順序走一遍,指出實現每一層的檔案。

### 4.1 Repo 結構

```
openclaw-hermes-watcher/
├── README.md                          ← 你正在讀(英文)
├── README.zh-TW.md                    ← 繁體中文(這頁)
├── ARCHITECTURE.md                    ← 架構深入(精簡;這個 README 才是長篇版)
├── CHANGELOG.md
├── LICENSE                            ← Apache-2.0
├── .gitignore                         ← machine.env + heartbeat-patrol.env + .pii-patterns.local
│
├── config/
│   └── machine.env.example            ← per-machine config 模板(operator 複製 + 編)
│
├── lib/                               ← 通用 shell,直接搬,不渲染
│   ├── heartbeat-patrol.sh            ← 決定性 dead-man-switch alerter(150 行)
│   └── watcher.sh                     ← baseline sentinel(200 行,每 60 秒跑)
│
├── templates/                         ← .tmpl 檔,經 envsubst-with-allowlist 渲染
│   ├── machine-mission.md.tmpl        ← 這台主機是做什麼的(部署後 chattr +i)
│   ├── baseline.policy.yaml.tmpl      ← 硬底線:forbidden_actions、immutable_paths、...
│   ├── hermes-permissions.yaml.tmpl   ← Hermes 可 / 不可
│   ├── SOUL.md.tmpl                   ← Hermes 的身份(初次裝後跨 re-run 保留)
│   ├── USER.md.tmpl                   ← Hermes 對 operator 的認知
│   ├── MEMORY.md.tmpl                 ← Hermes 累積知識的 bootstrap
│   ├── hermes-daily-study-prompt.txt.tmpl  ← 每日 cron prompt(heartbeat-FIRST)
│   ├── hermes-maintainer-AGENTS.md.tmpl    ← maintainer subagent 角色說明
│   ├── hermes-maintainer-IDENTITY.md.tmpl  ← maintainer 簡短身份
│   └── openclaw-watcher.service.tmpl       ← systemd user unit
│
├── scripts/                           ← 安裝腳本,按編號順序跑
│   ├── 00-prereqs.sh                  ← 檢 OpenClaw、gh、jq、systemd、machine.env
│   ├── 01-render.sh                   ← templates/ → .render-cache/ via envsubst
│   ├── 02-deploy-baseline.sh          ← chattr +i baseline,裝 + 啟 watcher
│   ├── 03-install-hermes.sh           ← curl | bash 上游 installer (--skip-setup)
│   ├── 04-configure-hermes.sh         ← 建 profile、寫 SOUL/USER/MEMORY
│   ├── 05-register-maintainer.sh      ← 註冊 hermes-maintainer OpenClaw subagent
│   ├── 06-cron-setup.sh               ← 裝 heartbeat-patrol + 5 個 cron jobs
│   ├── 07-smoke-test.sh               ← 端到端驗證
│   ├── 08-finalize.sh                 ← summary + 後續步驟
│   ├── 09-talk-helpers.sh             ← Phase 1.5:talk-* ACP shortcut wrappers
│   ├── 10-tg-maintainer.sh            ← Phase 1.5:maintainer 的 Telegram bot
│   ├── 11-tg-hermes.sh                ← Phase 2:Hermes 自己的 Telegram gateway
│   ├── all.sh                         ← orchestrator(冪等跑 00-11)
│   ├── edit-baseline.sh               ← operator-only:安全編輯 chattr +i 檔
│   └── lib/
│       ├── common.sh                  ← shared helpers(load_config、emit_journal_event)
│       └── render-template.sh         ← envsubst 配明確 allowlist
│
├── docs/
│   ├── INSTALL.md                     ← 逐步走法
│   ├── PHASE-2-TELEGRAM.md            ← Phase 2 的 @BotFather flow
│   └── ROLLBACK.md                    ← 解除安裝步驟
│
└── tests/
    ├── check-no-pii.sh                ← CI 守衛:committed 檔不含 operator literals
    ├── .pii-patterns.local.example    ← operator-specific pattern 模板(複製為 gitignored 版)
    └── (.pii-patterns.local — gitignored)
```

### 4.2 Phase 1 — 安裝

裝的核心。順序重要,靠檔名(`00-` 到 `08-`)強制。

**`00-prereqs.sh`** 驗主機就緒:
- bash 4+、jq、curl、envsubst、sha256sum、lsattr/chattr、systemd --user、gh CLI 已認證
- OpenClaw 已裝且 `openclaw status` 正常
- `~/.openclaw/workspace/` 存在(main agent bootstrap 過)
- `loginctl enable-linger` 設好(user systemd 登出後不死)
- `config/machine.env` 存在且最低欄位填過

快速失敗,給 actionable 錯誤訊息。**不改任何狀態。**

**`01-render.sh`** 渲染 templates:
- 透過 `scripts/lib/common.sh` 的 `load_config` 載入 `config/machine.env`
- 從已裝二進位自動偵測 `KNOWN_GOOD_*_VERSION`(若還沒裝就 fallback `unknown` — 步驟 03 會修)
- 呼叫 `render_template`(在 `scripts/lib/render-template.sh`),裡面包 `envsubst` 加**明確 allowlist** 的變數名單
- 輸出到 `.render-cache/`(gitignored)

**為什麼 envsubst 配 allowlist**(而不是裸 envsubst):裸 envsubst 把輸入裡的任何 `$VAR` 都換掉。Templates 合法地含 `$()` shell snippet 跟應該保留為 literal 的 `$VAR` 引用。Allowlist 讓我們明確說「只換這些」,其他保留 literal。

**`02-deploy-baseline.sh`** 上 chattr +i 那層:
1. 讀 `.render-cache/`
2. 偵測既有 baseline + 內容不同就解凍(`sudo chattr -R -i`)
3. 把渲染檔 copy 到 `~/.openclaw/workspace/baseline/`
4. 重生 `.expected-hashes`(所有 `*.yaml`/`*.md`/`watcher.sh` 的 sha256sum)和 `.expected-hashes.sha256`(meta-hash)
5. 在 `~/.config/systemd/user/openclaw-watcher.service` 裝 systemd user unit(`__HOME__` 已展開)
6. **`sudo chattr +i`** baseline 檔 + 兩個 hash 檔
7. `systemctl --user enable + start openclaw-watcher`
8. Bootstrap `~/.openclaw/workspace/upgrade-packs/inbox/`、`heartbeats/`,stub `openclaw-local-diff.md`

如果 watcher 起不來,部署中止 — 留一個沒 enforce 的 baseline 比沒 baseline 更糟。

**`03-install-hermes.sh`** 跑上游 Hermes installer:
- 檢查 hermes 是否已裝(冪等跳過)
- 跑 `curl -fsSL .../install.sh | bash -s -- --skip-setup`(--skip-setup 讓 wizard 不自動把 OpenClaw state 遷移進 Hermes)
- 裝完後**重跑 `01-render.sh` 跟 `02-deploy-baseline.sh --force`** 修掉 hermes 還沒在 PATH 時烙進的「unknown」hermes_version(這是 ultrareview 抓到的教訓之一)

**`04-configure-hermes.sh`** 建 Hermes profile:
- `hermes profile create openclaw-evolution`
- 把 SOUL.md 寫到 profile dir(per-profile)
  - **只在缺檔或跟 template 完全相同時寫** — 跨 re-run 保留 Hermes 自我修正過的 SOUL(週四 rotation 讓 Hermes 修剪過時條目)
- 把 USER.md 跟 MEMORY.md 寫到 `~/.hermes/memories/`(global,跨 profiles 共享,根據 Hermes docs)
  - MEMORY.md 若含 `version at install: unknown` 會刷新(早期 botched 安裝的痕跡)
- 設 profile config 預設(Phase 1 gateway off)

**`05-register-maintainer.sh`** 註冊 OpenClaw subagent:
- 預先放 `~/hermes-maintainer/.openclaw-ws/{AGENTS,IDENTITY,USER,MACHINE_LOG}.md` 到位(從渲染 templates)
- `openclaw agents add hermes-maintainer --workspace ~/hermes-maintainer/.openclaw-ws/`
- 更新 `agents.defaults.subagents.allowAgents` 加入 `hermes-maintainer`(保留你已有的 project subagents)
- 重啟 `openclaw-gateway` 讓新 subagent 可達

**`06-cron-setup.sh`** 是最內容多的腳本:
1. 從 `lib/heartbeat-patrol.sh` 裝 `~/.local/bin/heartbeat-patrol`(chmod 755)
2. 從 `machine.env` 值寫 `~/.config/heartbeat-patrol.env`(chmod 600)
3. 種子 heartbeat 檔配當下 timestamp(避免首次 patrol false-positive)
4. 透過 `openclaw cron add` 註冊四個 maintainer cron jobs,每個帶:
   - **Heartbeat-FIRST 前綴**(`STEP 1`)在實際工作之前呼叫 `heartbeat-patrol --self <jobname>`
   - 原本工作當 `STEP 2`
   - `SUMMARY_TAIL` 指示 agent summary 只列 positive actions(workaround OpenClaw cron classifier 的「did not」denial-token 假警報)
5. 透過 `hermes -p openclaw-evolution cron create` 註冊 Hermes-side daily-study cron
   - 把 `templates/hermes-daily-study-prompt.txt.tmpl` 渲染成真 prompt
   - 排在 `0 10 * * *` UTC(06:00 EDT,maintainer crons 跑完之後)
   - 冪等:有重複先 loop 移除再加

**`07-smoke-test.sh`** 驗 39+ 個 invariants 並計算 pass/fail。任一 FAIL 就非零退出。

**`08-finalize.sh`** 印 summary + 「下一步」指向 Phase 1.5/Phase 2。

### 4.3 Phase 1.5 — talk-helpers + maintainer Telegram

**`09-talk-helpers.sh`** 在 `~/.local/bin/` 產 wrapper script:
- `talk-main` — `openclaw acp --session "agent:main:main"`
- `talk-maintainer` — `openclaw acp --session "agent:hermes-maintainer:main"`
- `talk-<你的 project subagent>` — 從 `openclaw agents list --json` 自動發現
- `talk-hermes` — `hermes -p openclaw-evolution`(不同二進位;不走 OpenClaw ACP)

冪等 symlink。隨時 re-run 都會刷新。

**`10-tg-maintainer.sh`** 替 `hermes-maintainer` 註冊 Telegram bot:
- 從 `machine.env` 讀 `TG_BOT_HERMES_MAINTAINER_TOKEN`。空就整個跳過。
- 透過 `openclaw gateway telegram add`(或 `openclaw config set` fallback)加 bot
- 重啟 `openclaw-gateway`
- 印下一步手動指示:傳訊息給 bot 收 pairing code、回傳碼授權

配對後可以透過 Telegram 跟 `hermes-maintainer` 聊天。Maintainer 也用這個 bot 做 cross-patrol alert(Phase 2.5)— 看 [§3.5](#35-cross-patrol-heartbeatphase-25)。

### 4.4 Phase 2 — Hermes 自己的 Telegram gateway

**`11-tg-hermes.sh`** 啟用 Hermes 自己的 gateway:
- 從 `machine.env` 讀 `TG_BOT_HERMES_AGENT_TOKEN`。空就跳過。
- 在 Hermes profile config 設 `messaging.telegram.enabled true` + bot_token + allowed_user_id
- `hermes -p openclaw-evolution gateway install --force` 建 profile-scoped systemd unit `hermes-gateway-openclaw-evolution.service`
- **`systemctl --user restart`**(不是 `start`)— 這樣 token rotation 在 re-run 時才會生效

之後可以直接傳訊給 Hermes。根據它 SOUL contract,它**不主動 push** — 只回應你的訊息。

### 4.5 Phase 2.5 — daily cron + 心跳互巡

這個 phase 沒有獨立 script — 在 Phase 1 的 `06-cron-setup.sh` 裡就啟用。Hermes daily 的 cron 註冊跟 heartbeat-patrol 安裝都在那。

**Hermes daily-study prompt**(`templates/hermes-daily-study-prompt.txt.tmpl`)有四步:

1. **STEP 0** — 透過 `date -u +%A` 確定今天 UTC 是星期幾(template 不能用 `$(date)`,因為 envsubst 不展開 `$()`,且 Hermes prompt 是 text-not-shell)
2. **STEP 1** — heartbeat **先**寫。用 `filesystem_write`(**不**用 shell — Hermes shell 是 chroot-jailed,會寫到 sandbox 內的 `home/.hermes/heartbeats/`,不是真正 `/home/<user>/.hermes/heartbeats/`)
3. **STEP 2** — 巡邏四個 maintainer heartbeat;有 stale 透過 Telegram alert
4. **STEP 3** — 今天的 rotation 任務(Mon: commits、Tue: subsystem 深讀、Wed: issues themes、Thu: self-correct、Fri: pack-readiness、Sat: Hermes self、Sun: rest)。`MEMORY.md` 已有今日 heading 就 skip。
5. **STEP 4** — 簡短回報

輪換給寬廣覆蓋而不每天重活。平均每天 ~10–30k tokens。Token cost 在 [§3.6](#36-六個已知難題我們怎麼面對) 討論。

---

## 5. 前置條件

主機要先有:

1. **OpenClaw** 裝好且跑著(`openclaw status` 正常;gateway 在跑)
2. **OpenClaw main agent workspace** 在 `~/.openclaw/workspace/`
3. **gh CLI** 已認證為你的 GitHub user(`gh auth status` 綠燈)
4. **bash 4+**、`jq`、`curl`、`envsubst`(來自 `gettext`)、`sha256sum`、`lsattr`/`chattr`、`systemd --user` 加 linger enabled
5. **Phase 1.5 / Phase 2 可選**:Telegram 帳號 + 透過 `@BotFather` 拿到的 bot token

這個 template **不會**裝 OpenClaw 本身 — 那是你的事,OpenClaw 有自己的 installer。

---

## 6. 檔案落點(裝完之後長這樣)

| Path | 擁有者 | 用途 |
|---|---|---|
| `~/.openclaw/workspace/baseline/` | operator (chattr +i) | 硬政策:`baseline.policy.yaml`、`hermes-permissions.yaml`、`machine-mission.md`、`watcher.sh`、sha256 fingerprints |
| `~/.openclaw/workspace/heartbeats/` | maintainer crons | 每個 maintainer cron job 一個 `*.last` |
| `~/.openclaw/workspace/upgrade-packs/inbox/` | Hermes(寫)/ main(讀) | Hermes 提案的 draft packs |
| `~/.openclaw/workspace/openclaw-local-diff.md` | operator | local diff 對上游的活文件 |
| `~/.openclaw/workspace/evolution-journal.jsonl` | OpenClaw main | append-only event log |
| `~/.hermes/profiles/openclaw-evolution/` | Hermes | profile 狀態:SOUL.md、sessions、skills、gateway |
| `~/.hermes/heartbeats/` | Hermes daily-study cron | `hermes_daily_study.last` |
| `~/.hermes/memories/` | Hermes | 全域 MEMORY.md、USER.md(跨 profile 共享) |
| `~/hermes-maintainer/.openclaw-ws/` | maintainer subagent | bootstrap 檔 + study-notes |
| `~/.local/bin/heartbeat-patrol` | scripts/06 | dead-man-switch alerter |
| `~/.config/heartbeat-patrol.env` | operator (chmod 600) | bot token + chat ID |
| `~/.config/systemd/user/openclaw-watcher.service` | scripts/02 | systemd unit |

---

## 7. 日常營運

每天會發生什麼:

- **04:30 local** — `hermes_daily_doctor` cron fire。Maintainer 跑 `hermes doctor`、寫一行到 `MACHINE_LOG.md`、健康就不通知。Heartbeat 寫入。
- **05:00 local** — `hermes_upstream_watch` fire。Maintainer 掃 `NousResearch/hermes-agent` 看新 tag。有 release 就寫 study-note + journal event `hermes_release_review_pending` 等你 review。
- **05:00 local Mon** — `hermes_weekly_review` fire。Maintainer 跑 `hermes -p openclaw-evolution insights --days 7` 寫週摘要到 `~/hermes-maintainer/.openclaw-ws/study-notes/`。
- **05:30 local 1st of month** — `hermes_monthly_compress` fire。Maintainer 跑 `/compress` 壓縮 Hermes session memory。
- **10:00 UTC 每天** — `openclaw-daily-study` fire。Hermes 自己醒來、按星期幾輪換焦點、寫到 `MEMORY.md` / `skills/` / `upgrade-packs/inbox/`。

**真的有東西壞才會收到 Telegram。健康營運是安靜的。**

要 check in:
```bash
# 最近 journal events
tail -50 ~/.openclaw/workspace/evolution-journal.jsonl | jq -c '{ts,event,actor}'

# Watcher + gateway 還活著
systemctl --user status openclaw-watcher openclaw-gateway

# Hermes profile 健康
hermes -p openclaw-evolution config show
hermes doctor

# Cron job 狀態
openclaw cron list
hermes -p openclaw-evolution cron list

# Heartbeat 新鮮度
ls -la ~/.openclaw/workspace/heartbeats/ ~/.hermes/heartbeats/

# Patrol alerts(若有)
tail ~/.openclaw/workspace/heartbeats/_alerts.log
```

要跟 agents 對話:
```bash
talk-main           # OpenClaw main router
talk-maintainer     # hermes-maintainer subagent
talk-hermes         # Hermes Agent (openclaw-evolution profile)
```

---

## 8. 長期維護

- **每週**:看一眼 journal `tail ~/.openclaw/workspace/evolution-journal.jsonl | jq -c .`,看 `~/hermes-maintainer/.openclaw-ws/study-notes/` 最新週審查。
- **每月**:讀累積的 study notes;考慮 `~/.openclaw/workspace/openclaw-local-diff.md` 是否要更新你新加的 local 客製。
- **OpenClaw 上游 release 時**:Hermes 把 pack draft 到 `upgrade-packs/inbox/<tag>/`。Maintainer 透過 journal `hermes_proposed` 標記。你 review、決定後讓 main apply(或拒絕)。
- **Hermes 自身 release 時**:maintainer 透過 `hermes_release_review_pending` 標記。你決定要不要跑 `hermes update`(它在 `forbidden_autonomous`)。

更新這個 template 自身:`git pull upstream main`(設好 upstream remote 之後,看 `docs/INSTALL.md`),然後重跑 `bash scripts/all.sh`。冪等。

---

## 9. 血淚經驗(都已經寫進 code 結構裡)

下面每一條都是生產部署或三輪 `/ultrareview` 雲端 code review 抓到的真實 bug,以及現在已經結構化進這個 template 的修法。

| # | 教訓 | 落點 |
|---|---|---|
| 1 | **Cron prompt heartbeat 排「第一」不是「最後」**。後綴模式時,agent 在呼叫 patrol 之前就先寫 summary 當 final response — heartbeat 永遠不落地。 | `scripts/06-cron-setup.sh:heartbeat_prefix_for` |
| 2 | **Hermes shell tool 是 chroot-jailed**。呼叫 `~/.local/bin/heartbeat-patrol` 會把 heartbeat 靜默地寫到 sandbox 內 `home/.hermes/heartbeats/` 而不是真實路徑。 | `templates/hermes-daily-study-prompt.txt.tmpl` STEP 1 用 `filesystem_write` 不用 shell |
| 3 | **OpenClaw cron classifier 把「did not」denial token 標 error**。Agent 確認句如「I did not run hermes update」會讓成功 run 顯示 status=error。 | `scripts/06-cron-setup.sh:SUMMARY_TAIL` 指示 agent summary 只列 positive actions |
| 4 | **Watcher 在 journal 不可寫時要 `continue` 不要 fall-through**。否則接下來的 immutability/hash/gateway 檢查會靜默 no-op 對死 journal。 | `lib/watcher.sh` main loop 有 `if ! check_journal_writable; then sleep + continue` |
| 5 | **Heartbeat-patrol 必須驗證 write 真的落地**。沒有 `set -euo pipefail` 加 read-back check,失敗的 redirect(chattr +i、ENOSPC、RO remount)會 log 到 stderr 但仍印 OK。Dead-man-switch 會說謊。 | `lib/heartbeat-patrol.sh` 有 `set -euo pipefail` + `grep -qxF` 寫後驗證 |
| 6 | **`KNOWN_GOOD_HERMES_VERSION="unknown"`** 會在 `01-render.sh` 跑於 `03-install-hermes.sh` 之前時被烙進 chattr +i baseline。一旦凍結,要 sudo 才修得了。 | `03-install-hermes.sh` 在 hermes 進 PATH 後重跑 `01-render` + `02-deploy-baseline --force` |
| 7 | **`SOUL.md` 跨 re-run 必須保留**。無條件 `cp` 會毀掉週週累積的 Hermes 自我修正(週四 rotation 修剪過時項)。 | `04-configure-hermes.sh` 只在缺檔或完全相同時寫 |
| 8 | **`systemctl --user restart` 不要 `start`** for credential rotation。已 active 時 `start` 是 no-op;daemon 拿著舊 token。 | `11-tg-hermes.sh` 用 `restart`(對應 `10-tg-maintainer.sh`) |
| 9 | **`edit-baseline.sh` 必須先 `load_config`** 才引用 `$OPERATOR_HANDLE` — 沒有的話,在檔案已經 re-frozen 後 post-edit journal call 會 set -u crash。 | `scripts/edit-baseline.sh` 在 source `common.sh` 後呼叫 `load_config` |
| 10 | **Hermes daily-study `$(date +%A)` 不會展開**,因為 envsubst 只處理 `${VAR}`。Template 必須讓 Hermes 在 runtime 自己決定。 | `templates/hermes-daily-study-prompt.txt.tmpl` STEP 0 跑 `date -u +%A` |
| 11 | **空 Telegram chat ID** 會插值成 `chat  via your gateway`(literal 雙空格),把 Hermes 搞混。Prompt 現在明確檢查 chat ID 不為空。 | `templates/hermes-daily-study-prompt.txt.tmpl:STEP 2` 有 empty-string fallback |
| 12 | **PII allowlist 必須 per-match,不是 per-line**。早期版本比對整個 grep 行;含一個公網 IP 跟一個 RFC1918 IP 的同一行會被誤放,因為該行含 allowlist 的 RFC1918 prefix。 | `tests/check-no-pii.sh:run_check` 用 `grep -oE` 做 per-match 比對 |
| 13 | **PII allowlist 對 IP-shape 必須 prefix-anchor**。Substring containment 讓公網 IP 漏網,只要它們十進位形式裡某段含 allowlist 的 RFC1918 prefix(例如某個公網 IP 第二段剛好是 `10`,就會 match `10.` allowlist 條目)。現在用 `[[ $match == $allowed* ]]` 對 IP。 | `tests/check-no-pii.sh:is_allowlisted` 拆 IP_PREFIX_ALLOWLIST vs SUBSTRING_ALLOWLIST |
| 14 | **`tests/check-no-pii.sh` 自己不能含 operator literals**。早期版本把私人識別字串硬編成 regex literal;script 自我排除所以 check 綠燈而 literals 躺在 committed 檔。 | `tests/check-no-pii.sh` 只有 generic 結構 patterns;literals 在 gitignored `.pii-patterns.local` |
| 15 | **`heartbeat-patrol --self`(沒值)不能 set -u crash**。用 `${2:-}` 加 friendly usage 路徑。 | `lib/heartbeat-patrol.sh` 引數解析 |
| 16 | **`while read` 必須救援沒結尾換行的檔案**。`\|\| [ -n "$line" ]` 救 operator 沒帶 closing `\n` 加的最後一行(通常是最近加的)。 | `tests/check-no-pii.sh` 讀 patterns 檔的 loop |
| 17 | **`emit_journal_event` 預設 actor=`installer`,不是 `main`**。Install scripts 把動作標 "main" 會誤導 rescue triage。`edit-baseline.sh` 明確傳 `actor="operator"`。 | `scripts/lib/common.sh:emit_journal_event` |

這些教訓的價值來自於**真的在生產環境跑一段時間 + 把結果送 code review**。它們現在是結構性的 — template 不會 regress。

---

## 10. 已知限制

- **Watcher 偵測不到自己被停**。停掉的 process 不 emit event。在 `baseline.policy.yaml` `forbidden_actions[id=disable_watcher]` 標 `todo_implement: cross_unit_liveness_check`。緩解:cross-patrol heartbeat 抓 missed runs;若 watcher 跟 patrol 雙死,系統會靜默 drift。
- **Hermes installer 透過 `curl | bash`** 從可設定的 git ref 抓。預設 `main` 跟著上游;在 `machine.env` 用 `HERMES_INSTALL_REF` pin 到 tag 才能 reproducible install。我們**還沒**驗證 install.sh 內容的 sha256。
- **還沒 CI workflow**。PR 要手動 syntax check(`bash -n scripts/*.sh`)跟跑 `tests/check-no-pii.sh`。
- **Examples 目錄是空的**。`examples/solo-dev.env`、`examples/shared-server.env` 等應該在 v0.2 ship。

---

## 11. 授權

Apache-2.0。看 [LICENSE](LICENSE)。

## 相關專案

- [OpenClaw](https://docs.openclaw.ai) — agent kernel。本 template 透過它的公開 CLI(`openclaw cron`、`openclaw agents`、`openclaw config`)整合;**從不**修改 OpenClaw 已安裝的 code。`openclaw upgrade` 不會被我們踩到。
- [Hermes Agent](https://github.com/NousResearch/hermes-agent) — 長駐 agent runtime。我們用 Hermes 上游 installer 裝它,然後透過 Hermes 公開 CLI 配置**一個** profile(`openclaw-evolution`)。**從不**修改 Hermes 本身;`hermes update`(operator 批准的)會乾乾淨淨地走過。
