# `recordVerification()` 人工送出前 Checklist

**適用對象**：目前唯一的送出方式——人工簽章、人工 `cast send`（見 README
Honest Disclosures #13：V2 寫入維持人工、不放 VPS，是刻意的權衡，不是還沒做完
的功能）。

**這份文件涵蓋的風險**：`recordVerification()` 併入
filter-check + multiplier 交叉驗證邏輯之後（原本在 `test/registry-precompile-check`
分支上驗證/稽核，現已併入 `main` 的正式 `GapwatchRegistryV2.sol`），合約會在寫入前用
`isTransactionFiltered(txHash)`／`uiMultiplier()` 即時重查鏈上當下值，
跟你打算提交的 `claimedFiltered`／`claimedMultiplier` 比對——不一致就直接
`revert`（`FilterCheckMismatch`／`MultiplierMismatch`）。`events.db` 裡
`filter_verifier.py`／`reference_model.py` 記錄的值是**查詢當下**的快照，
跟你實際送出交易的時間點之間永遠存在空窗，空窗期間鏈上狀態可能已經變了
（尤其 `uiMultiplier()`——多次連續 multiplier 更新、或 `effectiveAt`
剛好跨過的情況）。沿用舊快照送出，最壞情況就是白燒一筆 gas 換一個
revert。這份 checklist 存在的唯一目的，就是在簽章、送出前，把這個空窗
壓到最短。

**排除事項**：這是操作文件，不是自動化腳本，也不改動任何合約邏輯——
`recordVerification()` 的邏輯本輪稽核已經定案（見稽核報告），這裡只講
人怎麼安全地操作它。

---

## 0. 準備好這幾個值

在開始前，先確認手上有：

- `txHash`（要記錄的事件的原始 tx hash，通常等於 `events.db` 裡的 `tx_hash`）
- `tokenAddress`（該事件對應的股票代幣合約地址）
- 要提交的 `oldMultiplier`／`newMultiplier`／`referenceModelHash`（來自
  `reference_model.py` 的獨立重算結果，非本文件範圍——這幾個目前仍是
  Reference Model 的輸出值，不是本文件重查的對象）
- 目標合約地址（`GapwatchRegistryV2`）跟對應的 `chainId`、RPC URL
- `requiredBond`（讀 `deployment.json` 或直接 `cast call <registry>
  "requiredBond()(uint256)"`）

---

## 1. 前置確認：即時重查鏈上當下值

**這一步的唯一目的：確認你打算提交的 `claimedFiltered`／`claimedMultiplier`，
跟合約在你送出交易那一刻會讀到的 `isTransactionFiltered()`／`uiMultiplier()`
一致。不一致就不要往下走，回到上一步重新確認。**

```bash
# 1a. 查 isTransactionFiltered(txHash) —— 對照 claimedFiltered
cast call 0x0000000000000000000000000000000000000074 \
  "isTransactionFiltered(bytes32)(bool)" \
  <TX_HASH> \
  --rpc-url <RPC_URL>

# 1b. 查 uiMultiplier() on 目標 token —— 對照 claimedMultiplier
cast call <TOKEN_ADDRESS> \
  "uiMultiplier()(uint256)" \
  --rpc-url <RPC_URL>
```

對照表（自己填一次，不要只是看過去）：

| 欄位 | 剛剛查到的鏈上值（actual） | 你打算提交的值（claimed） | 一致？ |
|---|---|---|---|
| filtered | | | ☐ |
| multiplier | | | ☐ |

**兩格都打勾才能進入第 2 步。任何一格對不上，回去確認 `claimedFiltered`／
`claimedMultiplier` 該用什麼值（通常代表 `events.db` 裡的快照已經過期），
不要為了讓它們「看起來一致」去改鏈上查到的東西——鏈上值是唯一的事實來源。**

> 提醒：`isTransactionFiltered()` 的實測結果（見 2026-09-18 那輪調查）
> 在至少 8.3 天到 140.6 天的區間內沒有觀察到查詢窗口限制，所以這一步
> 不會因為 `txHash` 太舊而查不到——真正會漂移的是 `uiMultiplier()`，
> 因為它反映的是股票代幣的當前狀態，可能在你查完到送出之間又更新過。

---

## 2. 簽章步驟

### 2a. 組 digest

`msgHash` 的 `abi.encode` 順序**跟函式參數宣告順序不同**——這是合約內部
自己選的順序，不是自動照函式簽章推導（已在稽核裡確認過，見
`GapwatchRegistryV2.sol` 裡 `recordVerification()` 內文的
`keccak256(abi.encode(...))` 那段）：

```
txHash, tokenAddress, oldMultiplier, newMultiplier, claimedFiltered, claimedMultiplier, referenceModelHash, address(<registry>), chainId
```

用兩個獨立工具各算一次，兩邊一致才繼續（沿用這次驗證過的做法，不要只信一邊）：

```bash
# 工具一：cast
ENC=$(cast abi-encode "f(bytes32,address,uint256,uint256,bool,uint256,bytes32,address,uint256)" \
  <TX_HASH> <TOKEN_ADDRESS> <OLD_MULTIPLIER> <NEW_MULTIPLIER> <CLAIMED_FILTERED> \
  <CLAIMED_MULTIPLIER> <REFERENCE_MODEL_HASH> <REGISTRY_ADDRESS> <CHAIN_ID>)
cast keccak "$ENC"
```

```python
# 工具二：web3.py / eth_abi（獨立跑一次，交叉比對）
from eth_abi import encode
from web3 import Web3
encoded = encode(
    ['bytes32','address','uint256','uint256','bool','uint256','bytes32','address','uint256'],
    [tx_hash_bytes, token_address, old_multiplier, new_multiplier, claimed_filtered,
     claimed_multiplier, reference_model_hash_bytes, registry_address, chain_id]
)
print(Web3.keccak(encoded).hex())
```

两邊算出來的 digest 不一致就停下來，先查出是哪個參數/順序打錯，不要拿任一邊
的結果去簽。

### 2b. node1／node2 手動簽章

**全程手動輸入密碼，不用 `--password-file`**（見第 5 節安全提醒）：

```bash
cast wallet sign --no-hash <DIGEST> \
  --keystore <node1-mainnet-keystore-path>
# 系統會互動式提示輸入密碼

cast wallet sign --no-hash <DIGEST> \
  --keystore <node2-mainnet-keystore-path>
# 系統會互動式提示輸入密碼
```

`--no-hash` 是必須的：不加的話 `cast wallet sign` 會把 digest 當成「訊息」，
自動包一層 EIP-191 前綴重新 hash 過才簽——那樣簽出來的東西
`ecrecover` 不回原本的 node 地址，`verifyConsensus` 判定簽章無效
（不會報錯，是直接被排除在有效票數外，最終落到 `ConsensusNotReached`）。

### 2c. 交叉核對簽章格式

兩把簽出來的東西，逐項確認：

- 長度：`0x` + 130 個 hex 字元（65 bytes：`r`(32) + `s`(32) + `v`(1)）
- `v` 是 `27` 或 `28`（不是 `0`/`1`）
- 兩把簽章**不是同一個 node** 簽的（同一個 node 簽兩次只算一票，湊不到
  2-of-3 門檻）

有把握的話，額外用 `eth_account.Account._recover_hash(digest, signature=sig)`
（或等效工具）在本機把兩把簽章各自 recover 一次，確認回來的地址正好是
`node1`／`node2` 的地址，再送出——上一輪就是靠這一步在送出前抓到潛在的
簽名工具誤用，值得養成習慣。

---

## 3. 送出步驟

```bash
cast send <REGISTRY_ADDRESS> \
  "recordVerification(bytes32,address,bool,uint256,uint256,uint256,bytes32,bytes[])" \
  <TX_HASH> \
  <TOKEN_ADDRESS> \
  <CLAIMED_FILTERED> \
  <CLAIMED_MULTIPLIER> \
  <OLD_MULTIPLIER> \
  <NEW_MULTIPLIER> \
  <REFERENCE_MODEL_HASH> \
  "[<NODE1_SIGNATURE>,<NODE2_SIGNATURE>]" \
  --value <REQUIRED_BOND> \
  --rpc-url <RPC_URL> \
  --account gapwatch-deployer
```

`--account gapwatch-deployer` 不加 `--password-file`，互動輸入密碼。
`cast send` 的參數順序要照函式簽章宣告的順序（`txHash, tokenAddress,
claimedFiltered, claimedMultiplier, oldMultiplier, newMultiplier,
referenceModelHash, signatures[]`）——**跟第 2a 步 digest 的
`abi.encode` 順序不同，兩邊不要混用**（上一輪稽核已經確認過這兩個順序
本來就是分開設計，都各自正確，不代表哪邊錯了）。

送出後，用 tx hash 跑一次 `eth_getTransactionReceipt` 確認 `status: 0x1`，
再視需要用 `getVerification(txHash)` 讀回確認（跟前幾輪做法一致）。

---

## 4. 失敗處理：送出後還是 revert 怎麼辦

`FilterCheckMismatch`／`MultiplierMismatch` 這兩種 revert 代表：從第 1 步
查值到這筆交易真正上鏈執行之間，鏈上狀態又變了（多半是 `uiMultiplier()`
中間又更新了一次）。處理方式：

1. **不要重送同一組舊簽章。** 舊簽章是對「舊的 claimed 值」簽的，鏈上狀態
   既然已經變了，claimed 值也要跟著變，digest 自然就不同——拿舊簽章配新
   digest，`verifyConsensus` 只會判定無效，退回 `ConsensusNotReached`，
   等於又白燒一次 gas。
2. **回到第 1 步，重新查一次 `isTransactionFiltered()`／`uiMultiplier()`。**
   不要假設「應該還是原來那個值」。
3. **回到第 2 步，用新查到的值重新組 digest，請 node1／node2 重新簽。**
4. **回到第 3 步，用新的簽章重新送出。**

`msg.value`（bond）在交易 revert 時會整筆退回（EVM 語義：revert 的交易
不會真的轉移任何 ETH，只有 gas 被消耗），所以失敗不會讓 bond 卡住或遺失，
但每次失敗嘗試都是一筆實打實的 gas 支出，值得為此多花 30 秒重查而不是
賭運氣重送。

---

## 5. 安全提醒

延續整個專案一貫的原則（跟 `.keystores/`／`.keystores-mainnet/` 目前的
使用方式一致）：

- **任何步驟都不把密碼寫進檔案。** 不用 `--password-file`，一律互動輸入。
- **不要把 digest／簽章／密碼貼進任何會被記錄或同步到雲端的地方**
  （聊天記錄、共享文件除外——這份 checklist 本身不含任何真實密鑰或密碼）。
- **node1／node2／`gapwatch-deployer` 的私鑰只留在本機的加密 keystore
  裡**，這份文件全程只示範怎麼「用」它們，不記錄、不匯出任何金鑰內容。
- 送出前用第 2c 步的本機 recover 驗證簽章，是免費、無風險、能在花任何
  gas 之前就抓到簽名工具誤用的最後一道防線，不要跳過。
