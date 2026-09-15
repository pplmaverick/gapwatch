# contracts-stylus

Tier 4 可行性驗證用的最小 scaffold，`cargo stylus new` 產生的預設 Counter
範例，**未經客製化**。

- 已在 Robinhood Chain Testnet 驗證部署成功（詳見
  [`../docs/tier4-stylus-verification.md`](../docs/tier4-stylus-verification.md)）。
- 這裡只是驗證「Stylus 合約能不能在 Robinhood Chain 上部署、啟用、被呼叫」，
  不含任何 Gapwatch 業務邏輯。
- 正式的共識驗證邏輯（`ConsensusVerifier`）會在此 scaffold 基礎上另外開發，
  尚未開始。

原始來源：`~/stylus-rh-test/stylus-hello/`（2026-09-14 建立，未提交 git），
本次搬遷保留原資料夾作為備份，未刪除。
