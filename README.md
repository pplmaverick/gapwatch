# Gapwatch

Independent on-chain verification for Robinhood Chain corporate actions.

**Status: work in progress.**

## Overview

Gapwatch monitors the Robinhood Chain sequencer feed in real time, decodes
transactions, and flags candidate corporate-action events (e.g. token
multiplier updates) against a dynamically maintained on-chain token registry.

## Modules

- `src/feed_listener.py` — connects to the sequencer feed websocket, decodes
  frames, and yields decoded transactions.
- `src/filter_engine.py` — checks decoded transactions against the token
  registry and known function selectors to flag candidate events.
- `src/token_registry.py` — builds the dynamic set of token contract
  addresses via `eth_getLogs` on `UIMultiplierUpdated`.

## Development

```bash
uv sync
uv run main.py
```
