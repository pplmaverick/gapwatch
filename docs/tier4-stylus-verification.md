# Tier 4 — Stylus 可行性驗證紀錄

**數據來源**：2026-09-14 開發 session 原始 RPC/交易輸出，經使用者核對提供。
下列所有數值均為 `eth_call`/`eth_getCode`/交易 receipt 的實際回傳內容，非估算或推測。

**狀態**：可行性已驗證，尚未整合進正式邏輯。這裡只證明「Stylus 合約能在
Robinhood Chain 上部署、啟用、被呼叫」，不含任何 Gapwatch 業務邏輯。正式的
共識驗證邏輯（`ConsensusVerifier`）尚未開始，會在 `contracts-stylus/` scaffold
基礎上另外開發。

---

## ⚠️ 地址混淆警告（必讀）

本文件記錄的地址 **`0xef33b95c009ca3c7021c294567237ce08679c0f1`**，因
CREATE nonce 巧合，**同時也是另一個完全不相關專案（SpaceFinance，部署在
Creditcoin CC3 Testnet）的合約地址**。這是同一個部署錢包在不同鏈上、相同
nonce 下產生的地址碰撞，屬已知現象（CREATE 地址只取決於部署者 + nonce，
與鏈無關）。

**本文件記錄的地址部署於 Robinhood Chain Testnet（chain id 46630），不適用於
Robinhood Chain Mainnet（chain id 4663）。任何引用這個地址時都必須明確標註
鏈別（Robinhood Chain Testnet, 46630），不可與 SpaceFinance / Creditcoin CC3
的紀錄混用或混淆。**

---

## Step A — ArbWasm precompile 驗證（主網，`eth_call` 真實查詢）

| 查詢 | 結果 |
|---|---|
| `eth_chainId` | `0x1237`（= 4663，確認打的是 Robinhood Chain 主網） |
| `eth_getCode(ArbWasm, 0x...0071)` | `0xfe`（precompile 標記，非空） |
| `eth_getCode(ArbOwnerPublic, 0x...006b)` | `0xfe`（precompile 標記，非空） |
| `ArbWasm.stylusVersion()`（selector `0xa996e0c2`） | `0x...0003` → 解碼 = **3** |
| `ArbWasm.inkPrice()`（selector `0xd1c17abc`） | `0x...2710` → 解碼 = **10000** |
| `ArbWasm.maxStackDepth()`（selector `0x8ccfaa70`） | `0x...55f0` → 解碼 = **22000** |

> 澄清：先前交接文件中「推測」二字指的是「ArbOS 61 Elara 升級是造成第三方
> 工具說法過時的原因」這個推論，**不是**指 `stylusVersion()=3` 這個數值本身
> ——這個數值是真實 `eth_call` 打出來的，不是猜的。

## Step B — 測試網部署（實際交易）

- 合約地址：`0xef33b95c009ca3c7021c294567237ce08679c0f1`（Robinhood Chain Testnet）
- deployment tx：`0xf0825144391d02e1ab4f87ff8fcea305e64b3cebe14f21395f5d2ae21d592a8f`（status: `0x1`）
- activation tx：`0x6364aacac97f1249f4ae6dd0a5b4922be331f593ade35ce4daacdcb7d4ecc406`（status: `0x1`）
- 呼叫 `number()` view function → 正確回傳 `0`

## Step C — 估算 vs 實際花費對照

| 項目 | 估算 | 實際 |
|---|---|---|
| wasm data fee | 0.000071 ETH（含 20% buffer，原始估算 0.000059 ETH） | 0.0000594 ETH（從 activation tx 的 ArbWasm log 解出） |
| 部署 tx gas | 1,534,667（`cargo-stylus 0.10.0` 估算） | 1,503,349 |
| 啟用 tx gas | — | 3,240,627 |
| 兩筆 tx 總花費 | — | 0.0000474 ETH（gas price 0.01 gwei） |

## Step D — `cargo-stylus 0.10.9` gas 估算 bug 的 A/B 對照證據

排除「Robinhood Chain 特有問題」的可能性，用官方 Arbitrum Sepolia 做對照組：

| 項目 | Robinhood Chain Testnet | Arbitrum Sepolia（官方） |
|---|---|---|
| wasm data fee | 0.000071 ETH | 0.000071 ETH |
| deployment tx gas | 71,252,741,796,780 | 71,252,741,514,972 |
| gas price | 0.01 gwei | 0.271648 gwei |
| deployment tx 總花費 | 712.527417967800000000 ETH | 19355.664727059113856000 ETH |

兩邊 `deployment tx gas` 幾乎一模一樣，只有市場 gas price 不同——**證明異常
出在 `cargo-stylus 0.10.9` 本身的 gas 估算邏輯，不是 Robinhood Chain 特有
問題**。已定位並鎖定使用 `cargo-stylus 0.10.0`（本機已安裝並確認為此版本，
`cargo stylus -V` → `stylus 0.10.0`）。

## 重要提醒（避免期待值過高）

查證發現「Arbitrum Tech Stack Integration」不是真實評分項目（誤傳），且同
系列黑客松已有隊伍（YieldMind）用 Stylus 做真正的核心計算（策略運算，
10 倍 gas 節省）。Tier 4 若只做示範性小合約會顯得單薄——**要做就挑真正有
計算量的邏輯**，不要為了用到 Stylus 而硬湊。
