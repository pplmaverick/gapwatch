# Gapwatch — Detailed Architecture

This is the expanded form of the overview diagram in the [README](../README.md):
the full 8-module off-chain pipeline and the complete Tier 1–4 contract layer,
including the components the overview collapses into a single box.

```mermaid
%%{init: {'flowchart': {'nodeSpacing': 20, 'rankSpacing': 25}}}%%
flowchart TD
    FEED[["Robinhood Chain · raw sequencer feed"]]

    subgraph OFF["OFF-CHAIN PIPELINE — sees candidates before the chain excludes them"]
        direction TB
        M1["1 · feed_listener<br/>decode frames from the feed"]
        M2["2 · filter_engine<br/>match against dynamic token registry"]
        M3["3 · filter_verifier<br/>filter precompile · 0x74"]
        M4["4 · l1_confirmer<br/>confirm UIMultiplierUpdated"]
        M5["5 · reference_model<br/>independent recompute + SHA-256"]
        M6["6 · event_store<br/>SQLite persistence"]
        M7["7 · api<br/>FastAPI · hybrid truth source"]
        M8["8 · frontend<br/>Next.js · Screens A / B / C"]
        M1 --> M2 --> M3 --> M4 --> M5 --> M6 --> M7 --> M8
    end

    GATE{{"2-of-3 node signatures<br/>digest bound to contract + chainid"}}

    subgraph ON["ON-CHAIN CONTRACT LAYER — only a signed consensus result lands here"]
        direction TB
        T3["Tier 3 · GapwatchRegistryV2<br/>consensus-gated writes · mainnet"]
        T4{{"Tier 4 · ConsensusVerifier<br/>Stylus / Rust · ecrecover"}}
        T25["Tier 2.5 · MockLendingPool<br/>downstream consumer demo"]
        T12["Tier 1+2 · GapwatchRegistry<br/>append-only + bond · testnet"]

        T3 -- "every signature check" --> T4
        T3 -- "discrepancy signal" --> T25
        T12 -. "V1 lineage · superseded by" .-> T3
    end

    FEED --> OFF
    OFF -- "verified result + hash" --> GATE
    GATE -- "recordVerification · resolveChallenge<br/>reportDiscrepancy" --> ON

    classDef offchain fill:#e8f1fb,stroke:#4a7fb5,color:#11304d
    classDef onchain fill:#e7f6ec,stroke:#3f9d5d,color:#0f3d22
    classDef gate fill:#f7e3b0,stroke:#b58a2a,color:#3a2b06
    classDef source fill:#ececf2,stroke:#8b8ba0,color:#2a2a3a

    class M1,M2,M3,M4,M5,M6,M7,M8 offchain
    class T3,T25,T12 onchain
    class T4,GATE gate
    class FEED source

    style OFF fill:#f4f9ff,stroke:#4a7fb5,stroke-width:2px,color:#11304d
    style ON fill:#f2fbf5,stroke:#3f9d5d,stroke-width:2px,color:#0f3d22
```

Tier 3 and Tier 4 ship together: `GapwatchRegistryV2` (Solidity) delegates every
signature check to `ConsensusVerifier` (Stylus/Rust) through the
`IConsensusVerifier` interface.
