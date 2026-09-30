# openclaw-hermes-watcher

[![test](https://github.com/teddashh/openclaw-hermes-watcher/actions/workflows/test.yml/badge.svg)](https://github.com/teddashh/openclaw-hermes-watcher/actions/workflows/test.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/tag/teddashh/openclaw-hermes-watcher?label=release&sort=semver)](https://github.com/teddashh/openclaw-hermes-watcher/releases)

[English](README.md) · **繁體中文**

替既有的 OpenClaw 主機加上一層：Hermes 研究 agent、守護用的 subagent、`chattr +i` 政策基線與交叉巡邏心跳，而且不修改 OpenClaw 或 Hermes 的程式碼。

**專案介紹頁：** https://teddashh.github.io/openclaw-hermes-watcher/?lang=zh-TW

> ## 用 OpenClaw 的嚴謹管理機器
> ## 用 Hermes 的積極管理演化
> ### 兩個 agent，互相幫忙

這個 repo 是疊在既有 [OpenClaw](https://docs.openclaw.ai) 主機上的一**層**。它會加上一個專門研究「這台主機上的 OpenClaw 該怎麼演化」的 [Hermes Agent](https://github.com/NousResearch/hermes-agent) profile、一個照顧 Hermes 安裝狀態的守護 subagent、一份沒有 sudo 就改不動的 `chattr +i` 政策基線，以及一套確定性的交叉巡邏心跳，把 agent 自己不會回報的漏跑工作抓出來。**它不修改 OpenClaw 與 Hermes 已安裝的程式碼**。整合只透過兩者的公開 CLI 和慣用的檔案位置，所以 `openclaw upgrade` 和 `hermes update` 都不受影響。

Apache-2.0 授權。最新版本：v0.1.7（2026-05-07）。之後 `main` 就沒有新的 commit；安裝前請先看 [§10 已知限制](#10-已知限制)，尤其是 OpenClaw 2026.5.20 以後的版本。

---

## 目錄

1. [快速開始](#1-快速開始)
2. [這個專案要解決的問題](#2-這個專案要解決的問題)
3. [架構：每一層為什麼存在](#3-架構每一層為什麼存在)
   - 3.1 [四個角色](#31-四個角色)
   - 3.2 [檔案契約](#32-檔案契約)
   - 3.3 [硬性基線](#33-硬性基線chattr-i--sha256--meta-hash)
   - 3.4 [Watcher](#34-watcher確定性的-bash不是-llm)
   - 3.5 [交叉巡邏心跳](#35-交叉巡邏心跳phase-25)
   - 3.6 [六個已知難題的立場](#36-六個已知難題的立場)
4. [實作導覽](#4-實作導覽)
   - 4.1 [Repo 結構](#41-repo-結構)
   - 4.2 [Phase 1：安裝](#42-phase-1安裝-hermesmaintainer基線與-watcher)
   - 4.3 [Phase 1.5：talk-helpers 與 maintainer 的 Telegram](#43-phase-15talk-helpers-與-maintainer-的-telegram)
   - 4.4 [Phase 2：Hermes 的 Telegram gateway](#44-phase-2hermes-的-telegram-gateway)
   - 4.5 [Phase 2.5：每日排程與心跳](#45-phase-25每日排程與交叉巡邏心跳)
5. [前置條件](#5-前置條件)
6. [安裝後的檔案位置](#6-安裝後的檔案位置)
7. [日常運作](#7-日常運作)
8. [長期維護](#8-長期維護)
9. [學到的教訓](#9-學到的教訓)
10. [已知限制](#10-已知限制)
11. [授權](#11-授權)

---

## 1. 快速開始

OpenClaw 已經在跑了，你想在上面加一個長期運作的 Hermes agent、一個守護者和一個 dead-man's switch。五個指令：

```bash
git clone https://github.com/teddashh/openclaw-hermes-watcher   # 或你的 fork，見 docs/INSTALL.md
cd openclaw-hermes-watcher
cp config/machine.env.example config/machine.env
$EDITOR config/machine.env             # 管理者、主機、服務、排程（這裡不放機密）
bash scripts/all.sh                    # 可重複執行的完整安裝
```

Bot token 是選用的，放在另一個不進 git 的檔案：`cp config/machine.env.secrets.example config/machine.env.secrets`，只填你要用的 bot。沒有 token 的話，Telegram 相關階段會自動跳過。

`all.sh` 會要求 sudo（用來設定 `chattr +i`），第一次安裝 Hermes 大約要 10 到 20 分鐘。第 07 步會跑冒煙測試（`bash scripts/07-smoke-test.sh`），之後隨時可以再跑。從此 Hermes 每天醒來，依星期幾挑一個研究主題，把發現寫進檔案。四個 maintainer 工作和 Hermes 的工作會互相檢查心跳，只有某個工作錯過時段才會發警報。平常的一天是什麼樣子，請看 [§7 日常運作](#7-日常運作)。

如果你想先弄懂架構為什麼長這樣再決定要不要裝，就繼續往下讀。第 2 到 4 節是完整說明。

---

## 2. 這個專案要解決的問題

你在跑 OpenClaw：router 起來了，workspace 也 bootstrap 好了，專案用的 subagent 都註冊了，Telegram bot 也配對完成，一切順利。現在你想要一個長期運作的 agent 盯著 OpenClaw 上游（讀 commit 和 issue、記住你在本機改過哪些地方、遇到值得套用的版本就起草 upgrade-pack），但你不想每天盯著它，也不想給它太多空間，讓它說服自己去做你沒授權的事。

直覺的做法，會用可預期的方式失敗：

### 2.1 「每天跑個 cron 比對上游，再 ping 我的 Slack 就好。」

- 一個月後，你開始忽略那些通知。**審批疲勞（approval fatigue）。**
- 三個月後，你已經落後六個 minor 版本。你真正點開的第一則通知寫著「23 個 commit、4 個 breaking」，多到沒辦法一次評估。
- cron 不知道你在本機改過什麼，它列出的 breaking change 比真正會在這台機器上壞掉的東西多得多。久了你就不再相信這些雜訊。

### 2.2 「有需要時再叫 Claude Code（或其他通用 agent）處理。」

- 每個 session 都從零開始，沒有累積下來的脈絡，例如「三個月前為什麼改了 X 檔？」
- 每個 session 對「什麼值得套用」看法都不同，session 之間會出現**品味漂移（taste drift）**。
- 每次都要花錢重建脈絡，成本會一直累積。

### 2.3 「讓 agent 自己更新，不用人管。」

- 一直都沒事，直到出事的那天。沒有 rollback 路徑的壞升級，光靠一個 shell 很難救回來。
- agent 沒有保留你本機修改的動機，它的動機是把升級做完。
- 一個偏離目標的 agent，第一個學會的事就是把原本會抓到它的警報關掉。

### 2.4 這個範本的做法

- **長期運作的 agent**（Hermes）會在幾週、幾個月之間，成長為專精「**這台主機的 OpenClaw 該怎麼演化，才能把管理者的服務顧得更好**」的專家。累積的知識放在 `~/.hermes/memories/MEMORY.md` 和 `~/.hermes/skills/`，所以不會每次從零開始。它依優先順序從四個來源取材：服務訊號（每個 subagent 的 MACHINE_LOG，這是主食，因為服務健康度是唯一的評量標準）、上游 OpenClaw、社群生態系（高星數的 OpenClaw skill 和 plugin repo），以及自己累積的記憶。
- **守護用的 subagent**（`hermes-maintainer`）定期檢查 Hermes 本身：`hermes doctor`、每週 insights 回顧、每月壓縮，以及追蹤上游版本。它不能套用 pack，也不能執行 `hermes update`；它負責提醒，由管理者決定。
- **硬性基線**（`chattr +i` 政策檔）寫明 agent 絕對不能做的事，不管將來的提案多有說服力。要改寫它得先執行 `sudo chattr -i`，而 agent 照理不該有 sudo（請看 [§3.3](#33-硬性基線chattr-i--sha256--meta-hash) 的但書）。
- **Watcher**（約 200 行 bash，跑在 systemd user unit 裡）每 60 秒檢查一次基線。它是規則式的程式，不是 LLM，沒有討價還價的空間。
- **交叉巡邏心跳**讓 Telegram 只在排程工作錯過時段時才通知你。運作正常時完全安靜。

結果是一個大致可以放著不管的系統。你每個月進來看一次，瀏覽 `~/.openclaw/workspace/evolution-journal.jsonl`，看看 Hermes 最近在研究什麼，再審核需要你決定的 pack。其他時候，一片安靜。

---

## 3. 架構：每一層為什麼存在

**先講整合邊界**。這個範本是一層外掛，透過 OpenClaw 和 Hermes 的公開 CLI（`openclaw cron / agents / config`、`hermes profile / config / cron / gateway`）以及慣用的檔案位置（`~/.openclaw/workspace/`、`~/.hermes/profiles/<name>/`）整合，**從不修改**它們已安裝的程式碼：

| 路徑 | 這個範本會動嗎？ |
|---|---|
| `/usr/lib/node_modules/openclaw/`（OpenClaw 已安裝的程式） | **不會**。列在 `baseline.policy.yaml` 的 `immutable_paths` |
| `~/.hermes/hermes-agent/`（Hermes 已安裝的程式） | **不會**。只由管理者執行的 `hermes update` 更動 |
| `~/.openclaw/openclaw.json`（OpenClaw 主設定檔） | **不直接寫入**。變更都透過 `openclaw` CLI（例如 `openclaw config set`） |
| `~/.openclaw/workspace/baseline/`（本範本的政策檔） | 會。部署後設為 `chattr +i`，只有管理者能編輯 |
| `~/.hermes/profiles/openclaw-evolution/`（一個 Hermes profile） | 會。使用 Hermes 文件記載的 profile 機制 |
| `~/hermes-maintainer/.openclaw-ws/`（subagent workspace） | 會。使用 OpenClaw 文件記載的 subagent 機制 |

完整的檔案清單在 [§6 安裝後的檔案位置](#6-安裝後的檔案位置)。實際的效果是：`openclaw upgrade` 和管理者執行的 `hermes update`，都不會碰到這個範本放在磁碟上的任何東西。

**同樣的「只做外掛層」原則，也限制了 Hermes 能提什麼**。Hermes 的 evolution-pack 分成五種 `pack_kind`，定義在 `baseline.policy.yaml` 的 `pack_kinds`。最安全的兩種是 `install_skill` 和 `install_plugin`，它們放進 OpenClaw 文件記載的擴充點（`~/.openclaw/skills/` 和 plugin 系統），**在結構上不可能修改 OpenClaw 本身**。這也是 Hermes 的四個取材來源裡有社群生態系的原因（像 `VoltAgent/awesome-openclaw-skills` 這類高星數的 skill 與 plugin repo）：採用能解決服務痛點的社群 skill，是 Hermes 最符合外掛層原則的做法。政策允許 main 在驗證後，於維護時段內、每週變更額度之內套用這兩種 pack 和 `apply_upstream_patch`；`synthesize_custom` 和 `config_change` 一律等管理者審核。

下面每一層都要交代清楚：它做什麼、為什麼需要、對應哪一種失敗模式。任何「長期運作的 agent 跑在正式主機上」的設計，都得回答六個已知難題，這個架構對每一題都表明了立場（見 [§3.6](#36-六個已知難題的立場)）。

### 3.1 四個角色

架構裡有四個 agent 角色，加上一個人：

```
                        Operator（人，Principal）
                         │
                         │  CLI · SSH · Telegram bots
                         ▼
              ┌────────────────────────┐
              │  OpenClaw main agent   │  router + side-effect outlet
              │  ~/.openclaw/workspace │
              └─┬──────────────────────┘
                │ spawns + governs
                ▼
   ┌───────────────────────────────────────────────────────┐
   │ OpenClaw workspace subagents                          │
   │ ───────────────────────────────────────────────────── │
   │ <your project subagents: out of scope for this repo>  │
   │ hermes-maintainer (~/hermes-maintainer/.openclaw-ws/) │
   └────────────────────┬──────────────────────────────────┘
                        │ "hermes-maintainer" 讀取 / 執行：
                        ▼
              ┌────────────────────────┐
              │  Hermes Agent          │  演化 OpenClaw
              │  profile:              │
              │  openclaw-evolution    │
              │  ~/.hermes/            │
              └────────────────────────┘
```

**經驗法則：如果從目錄列表看不出每個角色在做什麼，部署就出問題了**。角色之間用來協調的東西全是純文字的 markdown、JSONL 或 YAML，人看得懂，之後來救援的 Claude Code session 看得懂，其他 agent 也看得懂。Hermes 自己的 session 紀錄存在它的 SQLite 裡，但協調流程完全不依賴它。

**關於強制力**。所有 agent 都以執行安裝程式的那個 Linux 帳號身分執行。真正硬性的保證只有 `chattr +i` 的檔案（要 root 才能改）和 Hermes 自己的 shell sandbox。下面各角色「不能」的清單，其餘都是政策：寫在 `baseline.policy.yaml` 和 `hermes-permissions.yaml`，由 agent 讀取，並由 main 在套用 pack 前檢查。

#### 3.1.1 Operator（管理者，Principal）

就是人，也是最終的決定者。這個架構的設計讓你不必一直盯著；你隨時可以冷啟動進來看懂目前狀態，但不需要天天這麼做。

你和 agent 溝通的方式：
- CLI（`talk-main`、`talk-maintainer`、`talk-hermes`，Phase 1.5 起）
- Telegram bot（每個 agent 各一個，Phase 1.5 和 Phase 2 自行選擇是否啟用）
- SSH 加上直接編輯檔案（隨時可用）

只有你有、agent 沒有的權限：
- `sudo chattr -i`：只有你能解凍基線（透過 `scripts/edit-baseline.sh`）
- `hermes update`：只有你決定何時升級 Hermes（maintainer 提醒有新版本，由你動手）
- 高風險 pack：`synthesize_custom`、`config_change` 以及所有 `high_risk` 等級的 pack，都要等你核准。低風險和中風險的 pack，main 驗證後可以在 `hermes-permissions.yaml` 的變更額度內、`machine-mission.md` 規定的維護時段內套用（`machine.env` 裡 `TZ_NAME` 時區的 04:00 到 06:00；低風險 pack 在時段外也可以套用）。

#### 3.1.2 OpenClaw main agent

**工作**：轉送請求。處理主機層級的事（Caddy、Docker、systemd、連接埠、SSL、備份）。驗證 Hermes 產出的 pack，套用政策允許的那些。寫入 evolution journal。管理 subagent。

**不能**：修改 `baseline.policy.yaml` 裡 `immutable_paths` 列出的檔案。修改 watcher 腳本或政策檔（都是 `chattr +i`）。停掉或修改 watcher 的 unit（這只是政策，`disable_watcher` 目前還沒有偵測機制，見 [§10](#10-已知限制)）。修改 Hermes 的原始安裝（`~/.hermes/hermes-agent/`）；升級一律透過管理者執行的 `hermes update`。

**足跡**：`~/.openclaw/workspace/MACHINE_LOG.md`、`evolution-journal.jsonl`、`DEVIATIONS.md`。

#### 3.1.3 hermes-maintainer subagent

一個 workspace subagent，唯一的工作是讓本機的 Hermes Agent 保持健康、版本跟得上，而且不偏離任務。**它是 Hermes 的醫生兼檔案管理員，不是它的上司。**

**可以：**
- 執行 `hermes doctor`、`hermes status`、`hermes -p openclaw-evolution insights --days N`
- 讀取 `~/.hermes/sessions/`、memories 和 skills（唯讀）
- 讀取上游 Hermes repo，追蹤新版本
- 把研究筆記寫到 `~/hermes-maintainer/.openclaw-ws/study-notes/`
- 寫 journal 事件給 main 和管理者（例如 `hermes_proposed`、`hermes_release_review_pending`）

**不能：**
- 編輯 Hermes 的 SOUL.md、USER.md 或 MEMORY.md（那是 Hermes 自己的狀態）
- 修改 `~/.hermes/.env`（API 金鑰，只有管理者能動）
- 套用 Hermes 產出的 pack（只有 main 可以，而且要先驗證）
- 修改基線或 watcher
- 自行執行 `hermes update`。它列在 `hermes-permissions.yaml` 的 `forbidden_autonomous`；maintainer 只寫一筆 journal 事件，由管理者決定。

**為什麼要跟 main 分開**：它每天、每週的節奏只處理和 Hermes 有關的訊號，不會和 main 的主機管理工作搶資源。它的 bootstrap 檔（`AGENTS.md`、`IDENTITY.md`）讓它守在這個範圍很窄的角色裡，即使管理者好幾週沒進來也一樣。

#### 3.1.4 Hermes Agent（`openclaw-evolution` profile）

**工作**：演化這台主機上的 OpenClaw，讓它把管理者的服務顧得更好。讀每個服務的 MACHINE_LOG 找出痛點，對照上游 OpenClaw、社群生態系（高星數的 skill 與 plugin repo）和累積的 MEMORY，起草針對特定服務改善的 evolution-pack。它的自我改進迴路只對準這**一件**工作。成功指標是服務健康度（穩定性、延遲、錯誤率、復原時間、升級難易度），不是跟上游有多一致。

**可以：**
- 讀取 `~/.openclaw/`（唯讀），包括每個服務的 MACHINE_LOG、evolution journal 和研究筆記
- 透過 `gh` CLI 讀取上游 OpenClaw repo，不行時改用 REST API
- 讀取社群生態系：像 `VoltAgent/awesome-openclaw-skills` 這類整理清單，以及 `gh search repos --topic openclaw-skill` / `--topic openclaw-plugin`
- 寫入自己的 `~/.hermes/` 空間（sessions、memories、skills、SOUL、heartbeats）
- 在 `~/.openclaw/workspace/upgrade-packs/inbox/` 起草 evolution-pack。Pack 的 `kind` 是 `install_skill`、`install_plugin`、`apply_upstream_patch`、`synthesize_custom`、`config_change` 其中之一，定義在 `baseline.policy.yaml` 的 `pack_kinds`。前兩種只用到擴充點，優先採用。
- 透過 CLI 回覆管理者；啟用 Phase 2 的話也可以用 Telegram

**不能：**
- 直接寫入 `~/.openclaw/`，upgrade-pack inbox 除外
- 套用自己產出的 pack
- 修改 `~/.hermes/.env`
- 修改 watcher 或基線政策
- 在 sandbox 外執行 shell 指令（Hermes 的 shell 工具被 chroot 關在 sandbox 裡，見 [§9 學到的教訓](#9-學到的教訓)）

### 3.2 檔案契約

> **角色之間「不」互相聊天。它們把結構化的檔案寫到磁碟上，讓其他角色去讀。**

這是整個系統最重要的一條架構規則。沒有 agent 之間互傳 prompt，沒有即時 RPC，也沒有協商。每個角色都用其他角色（以及救援時的 Claude Code）讀得懂的格式寫到磁碟上。

| 從 → 到 | 管道 | 格式 |
|---|---|---|
| Hermes → main | upgrade-pack inbox | `manifest.yaml`、`summary.md`、`rollback-plan.md` |
| main → Hermes | evolution journal 條目 | 只能附加的 JSONL |
| hermes-maintainer → main | 研究筆記 + journal 條目 | markdown + JSONL |
| watcher → main、管理者 | evolution journal 條目 | 只能附加的 JSONL |
| 任何 subagent → main | 更新 `MACHINE_LOG.md` | markdown |
| 管理者 → 任何角色 | CLI / Telegram / SSH | 對話 |

**為什麼用檔案，不用 RPC：**

1. **可稽核**。一份 pack 提案就是一個可以 `cat` 的檔案，一筆 journal 事件就是一行可以 `jq` 的 JSONL。沒有暫存狀態，也不會有「agent 昨天彼此說了什麼」這種問題。發生過的事，都在磁碟上。
2. **好救援**。出事時你冷啟動 SSH 進來，純文字的 markdown、JSONL、YAML 幾乎是最好救援的格式。不用檢查 daemon，不用查網路端點，只有檔案。
3. **預設非同步**。agent 不必同時在線。Hermes 在週四 10:00 UTC 那次執行起草 pack，週五寫好 `summary.md`；maintainer 和 main 依自己的排程接手。每個角色照自己的步調走。
4. **agent 之間不互相遊說**。pack 準備好時，maintainer 寫一筆帶 pack ID 的 `hermes_proposed` journal 事件。沒有人寫一段文字去說服 main。main 讀 `manifest.yaml`，自己決定。
5. **和救援者看到的一樣**。你（或 Claude Code）進來調查「這台主機怎麼了」時，讀的就是 agent 讀的同一批檔案，沒有隱藏的 agent 之間狀態需要還原。

### 3.3 硬性基線（chattr +i + sha256 + meta-hash）

`~/.openclaw/workspace/baseline/` 裡有三個政策檔、watcher 腳本，以及兩個完整性雜湊：

```
baseline/
├── baseline.policy.yaml         # immutable_paths, allow_write_for_main, forbidden_actions, require_approval, pack_kinds, known_good, managed_paths
├── hermes-permissions.yaml      # hermes_may, hermes_may_not, change_budget
├── machine-mission.md           # 這台主機的用途、變更額度摘要、維護時段
├── watcher.sh                   # 哨兵腳本
├── .expected-hashes             # 上面四個檔案的 sha256
└── .expected-hashes.sha256      # meta-hash：.expected-hashes 本身的 sha256
```

部署後這六個檔案都是 `chattr +i`。watcher 的 systemd unit 檔不是（見 [§3.4](#34-watcher確定性的-bash不是-llm)）。

**為什麼用 chattr +i**（而不是一般檔案權限）：
- 檔案權限可以由檔案擁有者修改。agent 和擁有基線檔案的是同一個 Linux 帳號，沒有 `chattr +i` 的話，任何 agent 都能 `chmod` 之後改寫。
- `chattr +i` 在核心層讓檔案不能變更。要寫入必須先 `chattr -i`，而這需要 root。
- 這是整個系統最關鍵的安全性質。少了它，其他每一層都只是裝飾：一個認定政策「過時了」的 LLM 可以直接改寫它。
- **sudo 的但書**。安裝程式不會設定 sudo。只有在 agent 使用的 Linux 帳號執行 sudo 需要密碼時，`chattr +i` 才擋得住 agent。如果這個帳號有免密碼 sudo（很多雲端映像檔會替預設帳號這樣設定），任何能用 shell 的 agent 都可以自己執行 `sudo chattr -i`，基線就從一道鎖變成只是政策。依賴它之前，先檢查 `/etc/sudoers` 和 `/etc/sudoers.d/` 裡有沒有 `NOPASSWD`。

**為什麼還要 `.expected-hashes`**（而不是只相信 chattr）：
- chattr +i 在設定期間會擋住寫入，但理論上有心的攻擊者可以在檔案系統層之下改資料（例如直接寫入 block device）。縱深防禦的原則是：雜湊也要驗。
- 更實際的情況是：如果某個檔案失去了 `+i`（編輯被中斷，或有人手動 `chattr -i` 後忘了還原），watcher 會回報 `baseline_immutability_lost`，任何內容變動也會以 `baseline_hash_mismatch` 出現。

**為什麼還要 meta-hash**（`.expected-hashes.sha256`）：
- 這是在解決雞生蛋的問題。如果 `.expected-hashes` 本身可以被竄改，攻擊者就能同時改寫某個基線檔案和它在 `.expected-hashes` 裡的那一行，讓雜湊檢查失效。
- meta-hash 是 `.expected-hashes` 的 sha256，存在另一個檔案。watcher 先驗證 meta-hash，才信任 `.expected-hashes`。要突破它，攻擊者得同時改三個檔案，而只要其中任何一個還是 `chattr +i`，這條路就斷了。

**編輯基線**只能由管理者透過 `scripts/edit-baseline.sh <檔名>` 進行。這個腳本會：
1. 對目標檔和兩個雜湊檔執行 `sudo chattr -i`
2. 用 `$EDITOR` 開啟檔案
3. 重新產生 `.expected-hashes` 和 `.expected-hashes.sha256`
4. 對目標檔和兩個雜湊檔執行 `sudo chattr +i`
5. 附加一筆 `actor=operator` 的 `operator_edited_baseline` journal 事件

只要有檔案處於可寫狀態，watcher 下一輪就會記下 `baseline_immutability_lost`，並且每分鐘重複，直到旗標恢復為止。前提是 watcher 還在跑（見 [§10](#10-已知限制)）。

注意：重跑 `scripts/all.sh` 會用 `templates/` 和 `config/machine.env` 重新產生基線，並覆蓋所有內容不同的已部署檔案。要長期保留的基線修改，請改在你 fork 的範本或設定裡，不要只改部署出去的那一份。

### 3.4 Watcher（確定性的 bash，不是 LLM）

`~/.config/systemd/user/openclaw-watcher.service` 這個 systemd user unit 會執行 `~/.openclaw/workspace/baseline/watcher.sh`（本身也是 `chattr +i`）。它是一個常駐迴圈，每輪之間休息 60 秒（`INTERVAL_SEC=60`）；失敗時 systemd 會在 30 秒後重新啟動它。

每一輪，watcher 會：
- 確認基線目錄裡每個 `*.yaml`、`*.md`、`*.sh` 檔，以及兩個雜湊檔，都還有 `chattr +i`
- 用 `.expected-hashes.sha256` 驗證 `.expected-hashes` 的 meta-hash
- 逐一驗證 `.expected-hashes` 裡的 sha256
- 確認 OpenClaw gateway 程序還在執行
- 每小時寫一筆 `watcher_heartbeat` 事件，讓你知道 watcher 本身還活著

發現異常時，它會把 JSONL 事件寫進 `~/.openclaw/workspace/evolution-journal.jsonl`。watcher 不會處理異常，也不會發 Telegram 訊息，只負責記錄。由 main，或下次進來的管理者，讀了再決定。

**為什麼用純 bash，不用 LLM：**
- LLM 做的 watcher 可以被說服：「這個檔案改動沒問題，因為 X。」規則式的 watcher 不行。它算雜湊、比對指紋，不符就寫一筆 JSONL 事件，沒有可以談判的地方。
- 原則是：**需要思考的 watcher 可能被說服去放行；只是一支防寫腳本的 watcher 不會。**

**為什麼用 systemd user unit，不用 system unit：**
- user unit 不需要 root，watcher 和 gateway 用同一個帳號執行。
- user unit 裝在 `~/.config/systemd/user/`，不必動到 `/etc/systemd/system/`。
- 取捨：有幾個強化選項只能用在 system unit，在 user 模式下會失敗（`LockPersonality`、`MemoryDenyWriteExecute`、`ProtectKernelTunables` 等），所以 unit 只保留 `ProtectSystem=strict`、`ReadOnlyPaths`/`ReadWritePaths`、`NoNewPrivileges`、`PrivateTmp` 和 `RestrictAddressFamilies`。而且這個 unit 屬於 agent 所用的帳號，這個帳號不用 sudo 就能把它停掉。停掉 watcher 是政策禁止（`disable_watcher`），不是技術上做不到。

**為什麼 watcher 的檢查這麼少：**
- 每多一項檢查，就多一樣要維護的東西。上面四項是真正撐住系統的檢查。
- 修改 watcher 本來就該是件慎重的事，因為 `watcher.sh` 是 `chattr +i`。要永久修改，請改你 fork 裡的 `lib/watcher.sh`，再重跑 `scripts/all.sh`。

### 3.5 交叉巡邏心跳（Phase 2.5）

確定性的 dead-man's switch。它不是「出事時響警報」，而是「**除非有新的心跳解除警報，否則就響**」。

五個排程工作定期執行：

| 工作（心跳名稱） | 預設排程 | 擁有者 | 逾時門檻 |
|---|---|---|---|
| `hermes_daily_doctor` | 每天 04:30（本地） | hermes-maintainer（OpenClaw cron） | 24h + 6h |
| `hermes_upstream_watch` | 每天 05:00（本地） | hermes-maintainer（OpenClaw cron） | 24h + 6h |
| `hermes_weekly_review` | 每週一 05:00（本地） | hermes-maintainer（OpenClaw cron） | 168h + 24h |
| `hermes_monthly_compress` | 每月 1 日 05:30（本地） | hermes-maintainer（OpenClaw cron） | 720h + 72h |
| `hermes_daily_study`（Hermes 工作名稱 `openclaw-daily-study`） | 每天 10:00 UTC | Hermes Agent（Hermes cron） | 24h + 6h |

「本地」指的是 `machine.env` 裡的 `TZ_NAME`（預設 `America/New_York`）。五個排程都是 cron 表示式，可以在那裡修改。Hermes 的排程器用主機的時鐘，所以只有主機時鐘設為 UTC（雲端主機常見的預設）時，每日研究才會在 10:00 UTC 執行。

每個工作的**第一步**都是寫心跳檔（時間戳記、週期、寬限）。接著巡邏另外四個心跳；只要有一個超過「週期加寬限」沒更新，就發出警報。心跳只證明工作有被觸發，不代表工作內容成功。

四個 maintainer 工作會呼叫 `~/.local/bin/heartbeat-patrol --self <工作名稱>`。發現逾時的同伴時，腳本會附加一行到 `~/.openclaw/workspace/heartbeats/_alerts.log`；如果 `~/.config/heartbeat-patrol.env` 同時有 bot token 和 chat ID，就透過設定的 proxy 發 Telegram 訊息。Hermes 的工作用自己的檔案工具巡邏，透過它的 Telegram gateway 發警報；沒有設定 chat ID 時，改為附加到 `~/.hermes/heartbeats/_alerts.log`。警報不會去除重複：每個看到同一個逾時同伴的工作，都會再發一次。

**為什麼 cron prompt 要先寫心跳**（而不是最後才寫）：

這是吃過虧才學到的。巡邏指令原本放在 prompt 最後面，agent 會在呼叫巡邏腳本*之前*，就先把摘要（「Done. ... I did not run hermes update.」）當成最後回覆寫出來。OpenClaw 的 cron 框架把第一段文字摘要當成執行完成，於是後面的指令從來沒執行，心跳也就沒寫進去。把 `STEP 1: heartbeat-patrol` 放在 prompt 最前面，就能確保 agent 在產出最終摘要之前，已經寫好心跳、巡邏過同伴，即使後面的任務用完輪數，或分類器提早結束也一樣。見 `scripts/06-cron-setup.sh` 的 `heartbeat_prefix_for`。

**為什麼要獨立的警報腳本**（`heartbeat-patrol`）：

巡邏邏輯必須是確定性的。如果巡邏本身是 LLM 呼叫，它就會和被巡邏的 agent 有同樣的偏差問題。所以 `heartbeat-patrol` 是約 170 行的 bash：寫心跳、讀同伴、把「現在減去上次時間」和「週期加寬限」比較，逾時就用 curl 呼叫 Telegram。maintainer 這邊的警報路徑裡沒有 LLM。

**為什麼是「新心跳解除警報」，而不是「失敗時發警報」：**

如果警報是在失敗時才發，警報路徑本身就成了單一故障點。警報程式當掉，你就什麼都收不到。改成用心跳來解除警報，觸發警報的是「*沒有*動作」這件事，所以出問題的工作不必還活著也能讓你知道：下一個還活著的同伴巡邏時，就會發現那個過期的心跳。

**為什麼每個 agent 用自己的 bot 發警報**（而不是共用一個）：

不同的 bot，在你的 Telegram 裡就是不同的「聲音」。maintainer 的 bot 通知你，代表某個 maintainer 工作發現了逾時；Hermes 的 bot 發訊息，就是 Hermes 本人。某個 agent 出問題時，另一個 agent 的 bot 發的警報還是送得到。

**Hermes 這邊的工作比較特別**。它用 Hermes 自己的 cron 排程器，而不是 OpenClaw cron，原因是：
- OpenClaw cron 搭配 `--session isolated --agent X` 時，是以 OpenClaw subagent 的身分執行，不是 Hermes。
- 每日研究要寫入 Hermes 自己的狀態（sessions、memories、skills），只有 Hermes 本身能乾淨地寫到那裡。
- Hermes 的 shell 工具被 chroot 關在 sandbox 裡（§9 有更多說明），所以每日研究的 prompt 要求 Hermes 用原生的檔案工具，並使用**絕對路徑**，而不是呼叫放在 sandbox 外面的巡邏腳本。

### 3.6 六個已知難題的立場

長期運作的 agent 跑在正式主機上，一定得對六個已知難題表態。這個範本不宣稱解決了它們，但對每一個都有明確的立場。

| 問題 | 立場 | 程式在哪裡 |
|---|---|---|
| **冷啟動**：第一週的行為和穩定後本質上不同 | maintainer 的 daily-doctor 工作從第一天就開始跑，所以可觀測性不必等 agent 先建立信任 | `scripts/06-cron-setup.sh` 在安裝後立刻註冊排程 |
| **遞迴升級**：agent 自己更新自己 | `hermes update` 屬於 `forbidden_autonomous`，由管理者執行 | `templates/hermes-permissions.yaml.tmpl` 的 `change_budget.tier_examples.forbidden_autonomous`、`templates/hermes-maintainer-AGENTS.md.tmpl` |
| **品味漂移**：agent 的偏好和管理者越差越遠 | SOUL.md 在重跑安裝時保留；maintainer 的每週回顧會浮現漂移的訊號 | `scripts/04-configure-hermes.sh` 只在 SOUL.md 不存在，或仍是 Hermes 安裝程式的預設內容時寫入 |
| **審批疲勞**：管理者不再仔細看提案 | 草稿放進 inbox，不主動推 Telegram；低風險 pack 在額度內套用；管理者有空再來看 | `templates/SOUL.md.tmpl` 的「Output goes to FILES, not Telegram pushes」 |
| **Token 成本**：agent 自己思考很花錢 | 依星期輪替，每天只做一件事；當天做過就跳過；prompt 限制每次 30 分鐘或 30 輪（只是指示，沒有強制） | `templates/hermes-daily-study-prompt.txt.tmpl` 的 STEP 3 |
| **多機共用**：跨機器協調 | 明確不在範圍內：一台主機、一份設定 | 沒有任何多機邏輯 |

---

## 4. 實作導覽

每個架構決定都有對應的程式碼。這一節照安裝順序走一遍，指出實作每一層的檔案。

### 4.1 Repo 結構

```
openclaw-hermes-watcher/
├── README.md                          ← 英文說明
├── README.zh-TW.md                    ← 你正在看的繁體中文版
├── ARCHITECTURE.md                    ← 較短的架構文件（完整版在這份 README）
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
├── LICENSE                            ← Apache-2.0
├── .gitignore                         ← machine.env、machine.env.secrets、heartbeat-patrol.env、.pii-patterns.local、.render-cache/
│
├── .github/
│   ├── workflows/test.yml             ← CI：bash -n、PII 檢查、範本產生的冒煙測試
│   ├── workflows/pages.yml            ← 把 site/ 發布到 GitHub Pages
│   ├── ISSUE_TEMPLATE/                ← bug 回報、功能建議
│   └── PULL_REQUEST_TEMPLATE.md
│
├── config/
│   ├── machine.env.example            ← 每台主機的設定，不含機密（管理者複製後編輯）
│   └── machine.env.secrets.example    ← bot token（實際檔案不進 git）
│
├── examples/
│   ├── README.md
│   ├── solo-dev.env                   ← 一個開發者、一台機器，不含 Phase 2
│   └── shared-server.env              ← 多服務主機，含 Phase 1.5 和 Phase 2
│
├── lib/                               ← 通用 shell，原樣使用，不經範本處理
│   ├── heartbeat-patrol.sh            ← 確定性的 dead-man's switch 警報程式（約 170 行）
│   └── watcher.sh                     ← 基線哨兵（約 200 行，60 秒一輪）
│
├── templates/                         ← .tmpl 檔，用加白名單的 envsubst 產生
│   ├── machine-mission.md.tmpl        ← 這台主機的用途（部署後 chattr +i）
│   ├── baseline.policy.yaml.tmpl      ← 硬性底線：immutable_paths、forbidden_actions、pack_kinds……
│   ├── hermes-permissions.yaml.tmpl   ← Hermes 可以與不可以做的事、變更額度
│   ├── SOUL.md.tmpl                   ← Hermes 的身分（第一次安裝後重跑會保留）
│   ├── USER.md.tmpl                   ← Hermes 眼中的管理者
│   ├── MEMORY.md.tmpl                 ← Hermes 累積知識的起點
│   ├── hermes-daily-study-prompt.txt.tmpl  ← 每日排程的 prompt（先寫心跳）
│   ├── hermes-maintainer-AGENTS.md.tmpl    ← maintainer subagent 的角色說明
│   ├── hermes-maintainer-IDENTITY.md.tmpl  ← maintainer 的簡短身分
│   └── openclaw-watcher.service.tmpl       ← systemd user unit
│
├── scripts/                           ← 安裝腳本，依編號順序執行
│   ├── 00-prereqs.sh                  ← 檢查工具、OpenClaw、gh 登入、workspace、machine.env
│   ├── 01-render.sh                   ← templates/ → .render-cache/（envsubst）
│   ├── 02-deploy-baseline.sh          ← 基線設為 chattr +i，安裝並啟動 watcher
│   ├── 03-install-hermes.sh           ← curl | bash 上游安裝程式（--skip-setup）
│   ├── 04-configure-hermes.sh         ← 建立 profile，寫入 SOUL/USER/MEMORY
│   ├── 05-register-maintainer.sh      ← 註冊 hermes-maintainer OpenClaw subagent
│   ├── 06-cron-setup.sh               ← 安裝 heartbeat-patrol 和 5 個排程工作
│   ├── 07-smoke-test.sh               ← 端到端驗證（41 項檢查）
│   ├── 08-finalize.sh                 ← 摘要與下一步
│   ├── 09-talk-helpers.sh             ← Phase 1.5：talk-* ACP 捷徑
│   ├── 10-tg-maintainer.sh            ← Phase 1.5：maintainer 的 Telegram bot
│   ├── 11-tg-hermes.sh                ← Phase 2：Hermes 自己的 Telegram gateway
│   ├── all.sh                         ← 總控腳本（依序執行 00 到 11）
│   ├── edit-baseline.sh               ← 只給管理者：安全地編輯 chattr +i 檔案
│   └── lib/
│       ├── common.sh                  ← 共用函式（load_config、emit_journal_event）
│       └── render-template.sh         ← 加上明確白名單的 envsubst
│
├── docs/
│   ├── INSTALL.md                     ← 逐步安裝說明
│   ├── PHASE-2-TELEGRAM.md            ← Phase 2 的 @BotFather 流程
│   └── ROLLBACK.md                    ← 移除步驟
│
├── site/                              ← 專案介紹頁（由 site/page.json 產生）
│
└── tests/
    ├── check-no-pii.sh                ← CI 防護：commit 的檔案裡不能有管理者的實際資料
    ├── .pii-patterns.local.example    ← 管理者自用比對規則的範本（複製出的檔案不進 git）
    └── （.pii-patterns.local，不進 git）
```

### 4.2 Phase 1：安裝 Hermes、maintainer、基線與 watcher

整個安裝的核心。順序很重要，由檔名（`00-` 到 `08-`）決定。

**`00-prereqs.sh`** 檢查主機是否就緒：
- bash 4+、jq、curl、envsubst、git、sha256sum、lsattr/chattr、`systemctl --user`
- OpenClaw 已安裝，且 `openclaw status` 正常
- gh CLI 已登入
- `~/.openclaw/workspace/` 存在（main agent 已 bootstrap）
- `config/machine.env` 存在
- 已啟用 `loginctl` linger，登出後 user service 才會繼續跑（沒啟用只會警告，不算失敗）

有問題就立刻停下，並給出可以照做的錯誤訊息，不會改動任何狀態。

**`01-render.sh`** 產生範本：
- 透過 `scripts/lib/common.sh` 的 `load_config` 載入 `config/machine.env`（有 `config/machine.env.secrets` 的話也一起載入）
- 從已安裝的程式自動偵測 `KNOWN_GOOD_*_VERSION`（還沒安裝的會是 `unknown`，第 03 步會修正）
- 呼叫 `scripts/lib/render-template.sh` 裡的 `render_template`，用明確的變數白名單包住 `envsubst`
- `lib/watcher.sh` 原樣複製，unit 檔裡的 `__HOME__` 和 `__MACHINE_NAME__` 用 `sed` 填入
- 全部輸出到 `.render-cache/`（不進 git）

**為什麼 envsubst 要搭配白名單**（而不是直接用 envsubst）：直接用 envsubst 會替換輸入裡所有的 `$VAR`。但範本裡本來就有 `$()` shell 片段，以及應該保持原樣的 `$VAR`。白名單明確指定哪些變數要替換，其餘保持原文。

**`02-deploy-baseline.sh`** 部署 `chattr +i` 這一層：
1. 確認 `.render-cache/` 裡五個產生好的檔案都在
2. 如果已部署的基線是凍結狀態，而且內容和新產生的不同，就先解凍（`sudo chattr -R -i`）
3. 把有變動的檔案複製到 `~/.openclaw/workspace/baseline/`
4. 雜湊對不上時，重新產生 `.expected-hashes`（所有 `*.yaml`、`*.md` 和 `watcher.sh` 的 sha256）以及 meta-hash `.expected-hashes.sha256`
5. 安裝並啟用 `~/.config/systemd/user/openclaw-watcher.service`
6. 對四個基線檔和兩個雜湊檔執行 **`sudo chattr +i`**
7. 啟動 `openclaw-watcher`
8. 建立 `~/.openclaw/workspace/upgrade-packs/inbox/` 和 `heartbeats/`；`openclaw-local-diff.md` 不存在時建立空白範本

watcher 起不來的話，部署會中止：沒人執行的基線，比沒有基線更糟。

**`03-install-hermes.sh`** 執行上游的 Hermes 安裝程式：
- 已經裝過 `hermes` 的話，回報版本後直接結束（可重複執行）
- 否則執行 `curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_INSTALL_REF}/scripts/install.sh | bash -s -- --skip-setup`。加 `--skip-setup` 是因為第 04 步會自己設定 profile；腳本也從不執行 `hermes claw migrate`，那會把 OpenClaw 的 SOUL、記憶、skills 和金鑰搬進 Hermes。
- `HERMES_INSTALL_REF` 是 `main`（會變動的分支）時發出警告；出現 `openclaw-imports` skills 目錄（代表還是跑了遷移）時也會警告
- 全新安裝後，**重跑 `01-render.sh` 和 `02-deploy-baseline.sh --force`**，把 Hermes 還不在 PATH 時寫進基線的 `unknown` 換成實際版本（§9 第 6 條）

**`04-configure-hermes.sh`** 建立 Hermes profile：
- `hermes profile create openclaw-evolution --no-alias`，已存在就沿用
- 把 SOUL.md 寫進 profile 目錄
  - **只在檔案不存在，或仍是 Hermes 安裝程式的預設內容時寫入**。和範本不同的 SOUL.md 會保留，因為那可能是 Hermes 在週六輪替時自我修正過的，也可能是你手動改的。
- USER.md 和 MEMORY.md 不存在時，寫到 `~/.hermes/memories/`（全域，依 Hermes 文件由所有 profile 共用）
  - MEMORY.md 如果還有 `version at install: unknown` 或 `Bootstrapped at TBD`（先前安裝失敗留下的痕跡），就重新寫入
- 把 `messaging.telegram/discord/slack.enabled` 設為 `false`（Phase 1 沒有 Hermes gateway）

**`05-register-maintainer.sh`** 註冊 OpenClaw subagent：
- 在 `~/hermes-maintainer/.openclaw-ws/` 用產生好的範本寫入 `AGENTS.md`、`IDENTITY.md`，並在不存在時建立 `USER.md`、`MACHINE_LOG.md` 和 `study-notes/README.md`
- `openclaw agents add hermes-maintainer --non-interactive --workspace ~/hermes-maintainer/.openclaw-ws/`（已註冊就跳過）
- 把 `hermes-maintainer` 加進 `agents.defaults.subagents.allowAgents`，保留原本已有的專案 subagent
- 重新啟動 `openclaw-gateway`，讓新的 subagent 可以使用

**`06-cron-setup.sh`** 是最複雜的腳本。它會：
1. 從 `lib/heartbeat-patrol.sh` 安裝 `~/.local/bin/heartbeat-patrol`（權限 755）
2. 同時知道巡邏用的 bot token 和 chat ID 時，寫入 `~/.config/heartbeat-patrol.env`（權限 600）。token 預設用 maintainer bot 的（沒有的話用 main bot 的），chat ID 預設用 `OPERATOR_TELEGRAM_USER_ID`。兩者缺一時，巡邏只會寫進 `_alerts.log`。
3. 五個心跳檔不存在時先建立，避免第一次巡邏誤報
4. 用 `openclaw cron add --session isolated --agent hermes-maintainer --no-deliver --light-context` 註冊四個 maintainer 工作（遇到不支援 `--light-context` 的版本，會拿掉後重試）。每個 prompt 都包含：
   - **心跳優先的前綴**（`STEP 1`），在做任何事之前先執行 `heartbeat-patrol --self <工作名稱>`
   - 真正的任務，放在 `STEP 2`
   - `SUMMARY_TAIL`，要求 agent 的摘要只列出做了哪些事（避開 OpenClaw cron 分類器把「did not」判成錯誤的問題）
   同名的既有工作會先用迴圈全部移除，重複的工作不會越積越多。
5. 用 `hermes -p openclaw-evolution cron create` 註冊 Hermes 這邊的工作
   - prompt 是產生好的 `templates/hermes-daily-study-prompt.txt.tmpl`
   - 預設排程 `0 10 * * *`，本意是 10:00 UTC（紐約夏令時間 06:00，maintainer 的工作都跑完之後）
   - 可重複執行：重新加入前，先用迴圈移除同名的既有工作

**`07-smoke-test.sh`** 執行 41 項檢查：工具、基線檔案、`chattr +i` 旗標、雜湊、watcher unit、心跳檔、Hermes profile、五個排程工作和 subagent。最後三項（巡邏試跑、`openclaw status`、`hermes doctor`）只會警告。只要有任何一項 FAIL，就以非零狀態結束，`all.sh` 也會跟著停下。

**`08-finalize.sh`** 寫一筆 `deploy_finalized` journal 事件，並印出摘要，以及 Phase 1.5 和 Phase 2 的下一步。

### 4.3 Phase 1.5：talk-helpers 與 maintainer 的 Telegram

**`09-talk-helpers.sh`** 在 `~/.local/share/openclaw-talk-helpers/` 產生包裝腳本，並在 `~/.local/bin/` 建立指向它們的 symlink：
- `talk-main`：`openclaw acp --session "agent:main:main"`
- `talk-maintainer`：`openclaw acp --session "agent:hermes-maintainer:main"`
- `talk-<agent>`：`openclaw agents list --json` 找到的其他 agent 各一個
- `talk-hermes`：`hermes -p openclaw-evolution`（不同的執行檔，不走 OpenClaw ACP）

隨時可以重跑，包裝腳本會重新產生。OpenClaw 2026.5.20 以後，agent 清單會以扁平的 JSON 陣列回傳，`main` 上的腳本解析不了，只會退回建立 `talk-main` 和 `talk-maintainer`。尚未合併的 PR #1 修正了這個問題。

**`10-tg-maintainer.sh`** 替 `hermes-maintainer` 接上 Telegram bot：
- 從 `config/machine.env.secrets` 讀取 `TG_BOT_HERMES_MAINTAINER_TOKEN`，是空的就跳過這個階段。
- 用 `openclaw config set` 設定 `channels.telegram.accounts.hermes-maintainer.botToken`（token 相同就不動，不同就更新）。第一次設定時，也會把這個帳號的 `proxy` 設為 `HEARTBEAT_PATROL_PROXY`。
- 重新啟動 `openclaw-gateway`
- 印出手動配對步驟：傳訊息給 bot，收到配對碼後回傳給它完成授權

配對完成後，就能在 Telegram 上和 `hermes-maintainer` 對話。四個 maintainer 工作的巡邏警報由 `heartbeat-patrol` 發送，預設用的就是這個 bot 的 token（見 [§3.5](#35-交叉巡邏心跳phase-25)）。

### 4.4 Phase 2：Hermes 的 Telegram gateway

**`11-tg-hermes.sh`** 啟用 Hermes 自己的 gateway：
- 從 `config/machine.env.secrets` 讀取 `TG_BOT_HERMES_AGENT_TOKEN`，是空的就跳過。
- 在 profile 設定中設定 `messaging.telegram.enabled true`、`messaging.telegram.bot_token`，以及（有 `OPERATOR_TELEGRAM_USER_ID` 時）`messaging.telegram.allowed_user_id`
- `hermes -p openclaw-evolution gateway install --force` 建立 profile 專屬的 user unit `hermes-gateway-openclaw-evolution.service`
- 用 **`systemctl --user restart`**（不是 `start`），重跑時換過的 token 才會生效

之後你就能直接傳訊息給 Hermes。依照它的 SOUL，它不會主動推播，只會回覆你。唯一的例外是 [§3.5](#35-交叉巡邏心跳phase-25) 提到的每日研究巡邏警報。

### 4.5 Phase 2.5：每日排程與交叉巡邏心跳

這個階段沒有專屬腳本；Phase 1 的 `06-cron-setup.sh` 會安裝巡邏腳本，並註冊全部五個工作。

**Hermes 每日研究的 prompt**（`templates/hermes-daily-study-prompt.txt.tmpl`）開頭是 PATH CONVENTIONS 區塊，接著是五個步驟：

- **PATH CONVENTIONS**：Hermes 的檔案工具會把 `~` 解析到 sandbox 裡，所以 prompt 要求它使用 `/home/ubuntu/...` 的絕對路徑。這也是 agent 用其他帳號執行時需要修改範本的原因（見 [§10](#10-已知限制)）。
- **STEP 0**：用 `date -u` 取得今天的 UTC 星期、日期和 ISO 週數。範本本身不能用 `$(date)`，因為 envsubst 不會展開 `$()`。
- **STEP 1**：先寫心跳，而且用檔案工具，不用 shell。shell 被 chroot 關住，會寫到 sandbox 裡的 `home/.hermes/heartbeats/` 副本，而不是真正的目錄。
- **STEP 2**：讀取四個 maintainer 心跳，有逾時就發警報（設定了 chat ID 就透過 gateway 發 Telegram，否則在 `~/.hermes/heartbeats/_alerts.log` 加一行）。
- **STEP 3**：今天的任務；如果 `MEMORY.md` 已經有今天日期的標題就跳過：
  - 週一：服務訊號（挑一個過去 7 天沒讀過的服務，讀它的 MACHINE_LOG）
  - 週二：上游 OpenClaw 過去 7 天的 commit 和未關閉的 issue
  - 週三：社群生態系，依 ISO 週數除以 4 的餘數挑來源（整理清單、`openclaw-skill` topic、`openclaw-plugin` topic、官方範例與 fork）
  - 週四：綜合整理，在 inbox 起草 `manifest.yaml`
  - 週五：檢查 pack 是否就緒，替通過的草稿寫 `summary.md` 和 `rollback-plan.md`
  - 週六：自我修正（整理 MEMORY、把反覆出現的模式升級成 skill），並查看 Hermes 的新版本
  - 週日：休息
- **STEP 4**：簡短的摘要回覆。

輪替讓涵蓋面夠廣，又不必每天做重工作。prompt 要求 Hermes 在 30 分鐘或 30 輪內完成 STEP 3；這只是指示，沒有強制，repo 裡也沒有實測的 token 成本數字。

---

## 5. 前置條件

主機上必須已經有：

1. **有 systemd user service 的 Linux**，並啟用 linger（`sudo loginctl enable-linger $USER`），登出後服務才會繼續跑
2. **OpenClaw**，已安裝並在執行（`openclaw status` 正常，gateway 在跑）
3. **OpenClaw main agent 的 workspace**，位於 `~/.openclaw/workspace/`
4. **gh CLI**，已用你的 GitHub 帳號登入（`gh auth status` 顯示正常）
5. **bash 4+**、`git`、`jq`、`curl`、`envsubst`（來自 `gettext`）、`sha256sum`、`lsattr`/`chattr`
6. 安裝用的帳號要有 **sudo**，用來執行 `chattr`（請看 [§3.3](#33-硬性基線chattr-i--sha256--meta-hash) 的但書）
7. **選用**，Phase 1.5 和 Phase 2 才需要：Telegram 帳號，以及從 `@BotFather` 取得的 bot token

這個範本**不會**安裝 OpenClaw；OpenClaw 有自己的安裝程式。

---

## 6. 安裝後的檔案位置

| 路徑 | 擁有者 | 用途 |
|---|---|---|
| `~/.openclaw/workspace/baseline/` | 管理者（`chattr +i`） | 硬性政策：`baseline.policy.yaml`、`hermes-permissions.yaml`、`machine-mission.md`、`watcher.sh`、sha256 指紋 |
| `~/.openclaw/workspace/heartbeats/` | maintainer 的工作 | 每個 maintainer 工作一個 `*.last` 檔，以及 `_alerts.log` |
| `~/.openclaw/workspace/upgrade-packs/inbox/` | Hermes（寫）/ main（讀） | Hermes 起草的 pack，以及 `_questions-for-operator.md` |
| `~/.openclaw/workspace/openclaw-local-diff.md` | 管理者 | 記錄本機相對上游修改的活文件 |
| `~/.openclaw/workspace/evolution-journal.jsonl` | watcher、安裝程式、maintainer、main | 只能附加的事件紀錄 |
| `~/.hermes/profiles/openclaw-evolution/` | Hermes | profile 目錄：SOUL.md、設定 |
| `~/.hermes/sessions/`、`~/.hermes/skills/` | Hermes | session 紀錄、產生的 skill |
| `~/.hermes/heartbeats/` | Hermes 每日研究工作 | `hermes_daily_study.last`；沒設定 chat ID 時還有 `_alerts.log` |
| `~/.hermes/memories/` | Hermes | 全域的 MEMORY.md、USER.md（所有 profile 共用） |
| `~/hermes-maintainer/.openclaw-ws/` | maintainer subagent | bootstrap 檔、MACHINE_LOG.md、研究筆記 |
| `~/.local/bin/heartbeat-patrol` | scripts/06 | dead-man's switch 警報程式 |
| `~/.config/heartbeat-patrol.env` | scripts/06（權限 600） | 巡邏用的 bot token、chat ID、proxy |
| `~/.local/bin/talk-*` | scripts/09 | 指向 `~/.local/share/openclaw-talk-helpers/` 包裝腳本的 symlink |
| `~/.config/systemd/user/openclaw-watcher.service` | scripts/02 | watcher 的 unit |
| `hermes-gateway-openclaw-evolution.service` | `hermes gateway install`（Phase 2） | Hermes 的 Telegram gateway（user unit） |

---

## 7. 日常運作

平常的一天：

- **本地 04:30**：`hermes_daily_doctor`。maintainer 執行 `hermes doctor`，在自己的 `MACHINE_LOG.md` 加一行，並寫一筆 `hermes_doctor_report` journal 事件（有問題時另外寫一份研究筆記）。
- **本地 05:00**：`hermes_upstream_watch`。maintainer 用 `gh release list --repo NousResearch/hermes-agent --limit 5` 對照基線裡的 `known_good.hermes_version`。有較新的版本時，寫一份研究筆記和一筆 `hermes_release_review_pending` 事件給你。
- **每週一本地 05:00**：`hermes_weekly_review`。maintainer 執行 `hermes -p openclaw-evolution insights --days 7`，把每週回顧寫到 `~/hermes-maintainer/.openclaw-ws/study-notes/`，並重新產生 Hermes 會讀的三份摘要。
- **每月 1 日本地 05:30**：`hermes_monthly_compress`。maintainer 對 Hermes 的 session 記憶執行 `/compress`，並記下壓縮前後的大小。
- **每天 10:00 UTC**：`openclaw-daily-study`。Hermes 醒來，挑當天的任務，把發現寫進 `MEMORY.md`、`skills/` 或 `upgrade-packs/inbox/`。

除非有工作錯過時段，或你主動傳訊息給 bot，Telegram 都會保持安靜。watcher 的發現（`+i` 旗標不見、雜湊不符、gateway 停了）只會寫進 evolution journal，所以進來看的時候記得查它。

要檢查狀況：
```bash
# 最近的 journal 事件
tail -50 ~/.openclaw/workspace/evolution-journal.jsonl | jq -c '{ts,event,actor}'

# watcher 的發現（不含每小時的心跳）
jq -c 'select(.actor == "watcher" and .event != "watcher_heartbeat")' ~/.openclaw/workspace/evolution-journal.jsonl | tail

# watcher 和 gateway 是否還活著
systemctl --user status openclaw-watcher openclaw-gateway

# Hermes profile 狀態
hermes -p openclaw-evolution config show
hermes doctor

# 排程工作
openclaw cron list
hermes -p openclaw-evolution cron list

# 心跳新不新
ls -la ~/.openclaw/workspace/heartbeats/ ~/.hermes/heartbeats/

# 巡邏警報（如果有）
tail ~/.openclaw/workspace/heartbeats/_alerts.log ~/.hermes/heartbeats/_alerts.log
```

要和 agent 對話：
```bash
talk-main           # OpenClaw main router
talk-maintainer     # hermes-maintainer subagent
talk-hermes         # Hermes Agent（openclaw-evolution profile）
```

---

## 8. 長期維護

- **每週**：看一下 journal（`tail ~/.openclaw/workspace/evolution-journal.jsonl | jq -c .`），再讀 `~/hermes-maintainer/.openclaw-ws/study-notes/` 裡最新的每週回顧。
- **每月**：讀累積的研究筆記；如果你在本機做了新的客製，更新 `~/.openclaw/workspace/openclaw-local-diff.md`。
- **Hermes 完成一個 pack 時**：maintainer 會寫一筆 `hermes_proposed` journal 事件。main 驗證後，低風險和中風險的 pack 可以在變更額度和維護時段內套用，其他的等你決定。你也可以透過平常的管道，請 main 套用或退回某個 pack。
- **上游 Hermes 發布新版時**：maintainer 會寫一筆 `hermes_release_review_pending`。要不要執行 `hermes update` 由你決定（agent 不行，它屬於 `forbidden_autonomous`）。

更新這個範本本身：先依 `docs/INSTALL.md` 加上 upstream remote，再 `git pull upstream main`，然後重跑 `bash scripts/all.sh`。它可以重複執行，但會重新產生並取代已部署的基線（見 [§3.3](#33-硬性基線chattr-i--sha256--meta-hash)）。

---

## 9. 學到的教訓

下面每一條都是真實的 bug，來自這個範本所抽取的正式部署，或是第一次發布前的 `/ultrareview` 程式碼審查，以及現在已經內建在範本結構裡的修正。

| # | 教訓 | 現在的位置 |
|---|---|---|
| 1 | **cron prompt 要先寫心跳，不是最後才寫**。巡邏指令放在最後時，agent 會在呼叫巡邏之前就把摘要當成最後回覆寫出來，心跳從沒寫進去。 | `scripts/06-cron-setup.sh` 的 `heartbeat_prefix_for` |
| 2 | **Hermes 的 shell 工具被 chroot 關住**。呼叫 `~/.local/bin/heartbeat-patrol` 會默默把心跳寫進 sandbox 內部的 `home/.hermes/heartbeats/`，而不是真正的路徑。 | `templates/hermes-daily-study-prompt.txt.tmpl` 的 STEP 1 用檔案工具，不用 shell |
| 3 | **OpenClaw cron 分類器會把「did not」這類否定句判成錯誤**。像「I did not run hermes update」這樣的確認句，會讓成功的執行顯示 status=error。 | `scripts/06-cron-setup.sh` 的 `SUMMARY_TAIL` 要求 agent 只列出做了哪些事 |
| 4 | **journal 壞掉時，watcher 必須 `continue`，不能繼續往下跑**。否則 journal 無法寫入時，不可變旗標、雜湊和 gateway 的檢查結果都會默默消失。 | `lib/watcher.sh` 主迴圈：`if ! check_journal_writable; then sleep + continue` |
| 5 | **heartbeat-patrol 必須確認真的寫進去了**。沒有 `set -euo pipefail` 加上回讀檢查，寫入失敗（chattr +i、ENOSPC、唯讀重新掛載）只會在 stderr 留一行，卻照樣印出「OK」。dead-man's switch 會說謊。 | `lib/heartbeat-patrol.sh` 有 `set -euo pipefail`，寫入後再用 `grep -qxF` 確認 |
| 6 | **`KNOWN_GOOD_HERMES_VERSION="unknown"`** 會在 `01-render.sh` 早於 `03-install-hermes.sh` 執行時，被寫進 `chattr +i` 的基線。一旦凍結，要 sudo 才能修。 | `03-install-hermes.sh` 安裝後重跑 `01-render` 和 `02-deploy-baseline --force` |
| 7 | **`SOUL.md` 必須在重跑時保留**。無條件 `cp` 會毀掉 Hermes 好幾週的自我修正（週六的輪替會整理過時的內容）。 | `04-configure-hermes.sh` 只在檔案不存在，或仍是 Hermes 安裝程式的預設內容時寫入 |
| 8 | **換 token 要用 `systemctl --user restart`，不是 `start`**。unit 已在執行時 `start` 不會有動作，daemon 會繼續用舊 token。 | `11-tg-hermes.sh` 用 `restart`（和 `10-tg-maintainer.sh` 重啟 gateway 的做法一致） |
| 9 | **`edit-baseline.sh` 必須先呼叫 `load_config`**，才能用 `$OPERATOR_HANDLE`。少了它，編輯後寫 journal 的那一步會在 `set -u` 下崩潰，而且是在檔案已經重新凍結之後。 | `scripts/edit-baseline.sh` 在 source `common.sh` 之後呼叫 `load_config` |
| 10 | **每日研究範本裡的 `$(date +%A)` 不會展開**，因為 envsubst 只處理 `${VAR}`。範本必須讓 Hermes 在執行時自己判斷今天星期幾。 | `templates/hermes-daily-study-prompt.txt.tmpl` 的 STEP 0 執行 `date -u +%A` |
| 11 | **Telegram chat ID 是空的**時，會被代換成 `chat  via your gateway`（中間兩個空格），讓 Hermes 搞混。prompt 現在會明確檢查 chat ID 不是空的。 | `templates/hermes-daily-study-prompt.txt.tmpl` 的 STEP 2 有空字串的替代做法 |
| 12 | **PII 白名單必須逐一比對抓到的字串，不能整行比對**。早期版本比對整行 grep 結果，同一行同時有公網 IP 和 RFC1918 IP 時，只因為行內某處有白名單裡的 RFC1918 前綴，就整行放過。 | `tests/check-no-pii.sh` 的 `run_check` 對 `grep -oE` 抓到的每個字串分別比對 |
| 13 | **PII 白名單對 IP 格式必須從開頭比對前綴**。用「包含子字串」比對時，只要公網 IP 的文字裡剛好有白名單的 RFC1918 前綴就會漏掉（第二段是 `10` 的公網 IP 會符合 `10.` 這一條）。IP 現在改用 `[[ $match == $allowed* ]]`。 | `tests/check-no-pii.sh` 的 `is_allowlisted` 分開 IP_PREFIX_ALLOWLIST 和 SUBSTRING_ALLOWLIST |
| 14 | **`tests/check-no-pii.sh` 本身不能含有管理者的實際資料**。早期版本把私人識別字串直接寫成 regex；腳本會排除自己，所以檢查通過了，那些字串卻留在 commit 進去的檔案裡。 | `tests/check-no-pii.sh` 只放通用的結構比對；實際字串放在不進 git 的 `.pii-patterns.local` |
| 15 | **`heartbeat-patrol --self`（沒給值）不能在 `set -u` 下崩潰**。用 `${2:-}`，並顯示友善的用法說明。 | `lib/heartbeat-patrol.sh` 的參數解析 |
| 16 | **`while read` 必須救回結尾沒有換行的最後一行**。`\|\| [ -n "$line" ]` 會保留管理者加上去、但沒有以 `\n` 結尾的最後一行。 | `tests/check-no-pii.sh` 讀取 patterns 檔的迴圈 |
| 17 | **`emit_journal_event` 預設的 actor 是 `installer`，不是 `main`**。安裝腳本把動作記成「main」做的，會誤導救援時的判斷。`edit-baseline.sh` 會明確傳入 `actor="operator"`。 | `scripts/lib/common.sh` 的 `emit_journal_event` |

這些教訓來自實際在正式環境跑一段時間，再把結果拿去做程式碼審查。它們現在是結構的一部分，範本不會在這些地方悄悄退步。

---

## 10. 已知限制

- **基線有多強，取決於 sudo 的設定**。安裝程式不會設定 sudo。如果 agent 使用的 Linux 帳號有免密碼 sudo，能用 shell 的 agent 就可以自己執行 `sudo chattr -i`（見 [§3.3](#33-硬性基線chattr-i--sha256--meta-hash)）。
- **watcher 沒有保護自己**。它的 unit 屬於 agent 所用的帳號，不用 sudo 就能停掉。正常停止時會寫一筆 `watcher_stopped` 事件，之後就沒有任何東西注意到它不見了。watcher 每小時會寫一筆 `watcher_heartbeat`，但目前沒有工作去檢查它。`baseline.policy.yaml` 裡的 `disable_watcher` 標著 `todo_implement: cross_unit_liveness_check`。交叉巡邏心跳抓得到漏跑的工作，但 watcher 一旦停了，它的檢查也就跟著停了。
- **大部分禁止行為是政策，不是程式**。11 項 `forbidden_actions` 中有 8 項標為 `todo_implement`。`remove_baseline` 和 `chattr_minus_i` 有 `chattr +i` 和 watcher 撐著；其餘靠 main agent 在套用 pack 前自己檢查政策。變更額度也是由 main agent 計算，不是 repo 裡的程式。
- **每日研究的 prompt 寫死了 `/home/ubuntu`**。PATH CONVENTIONS 區塊直接寫出 `/home/ubuntu/...` 給 Hermes 的檔案工具用。agent 用其他帳號執行的話，安裝前要先改 `templates/hermes-daily-study-prompt.txt.tmpl`。
- **OpenClaw 2026.5.20 以後的版本**。設定路徑是以 OpenClaw v2026.5.x 驗證的。在 2026.5.20 以後，`main` 上的 `09-talk-helpers.sh` 只會建立 `talk-main` 和 `talk-maintainer`；修正在尚未合併的 PR #1。
- **巡邏警報預設經過 proxy**。`heartbeat-patrol` 透過 `HEARTBEAT_PATROL_PROXY`（預設 `http://127.0.0.1:8118`）發送 Telegram 訊息。把它設成空字串也不會取消 proxy，因為 `load_config` 會把預設值填回去。主機上沒有這個 proxy 的話，警報只會寫進 `_alerts.log`。
- **預算只是指示**。每日研究 30 分鐘、30 輪的預算是 prompt 裡的指示，沒有強制，也沒有實測的 token 成本數字。
- **Hermes 安裝程式用 `curl | bash` 取得**，來源是可設定的 git ref。預設的 `main` 會跟著上游變動；要能重現安裝，請在 `machine.env` 用 `HERMES_INSTALL_REF` 指定 tag。安裝腳本的 checksum 沒有驗證。
- **活動狀況**。`main` 最後一次 commit 是 2026-05-07（v0.1.7），PR #1 從 2026-05-23 開著至今。

---

## 11. 授權

Apache-2.0。見 [LICENSE](LICENSE)。

## 相關專案

- [OpenClaw](https://docs.openclaw.ai)：agent 核心。本範本透過它的公開 CLI（`openclaw cron`、`openclaw agents`、`openclaw config`）整合，**從不修改** OpenClaw 已安裝的程式碼，所以 `openclaw upgrade` 不會受到本範本放在磁碟上的任何東西影響。
- [Hermes Agent](https://github.com/NousResearch/hermes-agent)：長期運作的 agent 執行環境。本範本用 Hermes 的上游安裝程式安裝它，再透過 Hermes 的公開 CLI 設定**一個** profile（`openclaw-evolution`）。它**從不修改** Hermes 本身；管理者執行的 `hermes update` 可以順利完成。
