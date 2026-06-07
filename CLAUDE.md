# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Layout

This repo contains MQL5 Expert Advisors (trading robots) for MetaTrader 5. Each `ea_*.mq5` file at the root is a **standalone, self-contained EA** — there are no shared MQL5 headers in the repo (only the standard `<Trade\Trade.mqh>` include).

Active development happens on the two most recent EAs; older `.mq5` files are kept as historical reference for the strategy evolution documented in `CHANGELOG.md`:

- `ea_trend_pullback_v5.mq5` — current production strategy (H1 trend + M15 EMA pullback + bounce). Magic `123456`.
- `ea_multi_tf_momentum_v1.mq5` — newer experimental strategy (H4/H1/M15 momentum with RSI-50 cross).
- `ea_trend_and_reveres.mq5`, `ea_trend_and_reveres_version_1.mq5`, `ea_ict_concept.mq5` — earlier iterations (RSI mean reversion, ICT concepts). Don't edit unless explicitly asked; new work goes into the v5/v1 files above.

The v5 and v1 EAs **share the same magic number (`123456`)** intentionally, so v5 can take over and manage positions opened by older versions.

## Build / Test / Run

There is no command-line build system, lint, or test suite. Workflow is entirely inside MetaTrader 5:

1. **Compile**: Open the `.mq5` in MetaEditor → `F7` (or Ctrl+F7). Watch the Errors tab — a non-zero error count means the EA cannot be loaded.
2. **Backtest**: MT5 → Strategy Tester (Ctrl+R) → pick the EA → M15 timeframe → "Every tick" mode. Symbols: AUDUSDc / USDJPYc / USDCADc (historical best performers); XAUUSDc / BTCUSDc are higher-variance.
3. **Demo / live**: Attach EA to an M15 chart. Inputs panel is organized into `input group` sections — change values there, not in code.
4. **Verifying a change**: read the runtime log lines emitted by `OnInit()` (printed at attach time) to confirm new inputs are taking effect, then watch the Experts tab while the EA runs.

There is no way to run the EA from this Windows shell — the user must drive MT5 themselves. When asked to "test" a change, state explicitly that compilation and backtesting must happen in MetaEditor / Strategy Tester.

## Logs (gitignored, but central to debugging)

`Logs/` is in `.gitignore` but is the primary feedback loop. Two log surfaces exist:

- **MT5 Experts tab** (live): each EA's `PrintLog()` wrapper calls `Print()` and writes to a daily text file.
- **File logs** under `<MT5 Common>\Files\EA_Logs\` (path printed by `OnInit` when `InpEnableFileLogging = true`):
  - `EA_v5_FullLog_YYYY.MM.DD_<symbol>.txt` — all events
  - `EA_v5_YYYY.MM.DD_<symbol>.csv` — trade open/close records
  - `EA_v5_SIGNAL_YYYY.MM.DD_<symbol>.csv` — one row per M15 bar evaluation (this is what you grep to understand *why* a bar didn't trade)

`Logs/phase-*/` directories store historical log captures grouped by EA version era (phase-1 through phase-5 = strategy versions). `Logs/parse_weekly_report.ps1` aggregates `.log` files into `weekly_symbol_report.csv` with per-symbol P&L and max-drawdown:

```powershell
.\Logs\parse_weekly_report.ps1 -LogsRoot .\Logs -OutputCsv .\Logs\weekly_symbol_report.csv
```

## Architecture That Spans Files

Although each EA is one file, they all follow the same skeleton — once you know it, jumping between EAs is fast:

1. **Inputs** (`input group "=== ... ==="`) — strategy params, risk caps, symbol filter toggles, session filter, debug flags. Grouped logically; preserve grouping when adding inputs.
2. **Globals** — indicator handles (`g_handle*`), per-day/per-week equity baselines for circuit breakers, per-ticket SL-update throttle arrays, closed-position tracking arrays.
3. **Helpers** — `GetPipValue()`, `CountOpenPositions()`, `CountTotalPositionsAllSymbols()`, `IsUSDBiasCapHit()`, daily/weekly loss limits.
4. **Logging block** — `PrintLog()`, `_WriteLogLine()`, `DebugLogCSV()`, `LogTradeEvent()`, `LogSignalEvent()`, `LogClosedPosition()`.
5. **Lifecycle** — `OnInit` (handles + summary print), `OnDeinit` (`IndicatorRelease`), `OnTick` (manage positions every tick, evaluate signal on new M15 bar only).
6. **Signal pipeline** — `GetIndicatorValues()` → `CheckTradingConditions()` (filters that block entry) → `AnalyzeAndTrade()` (signal + entry decision) → `OpenPosition()` → `ManageOpenPositions()` (breakeven, trailing).

### Cross-cutting concepts to know before changing risk/position logic

- **`GetPipValue()` is non-trivial.** Pip definitions are symbol-specific: Gold = 0.10, BTC = 10.0, JPY pairs = 0.01 (2/3-digit) or `point*10` (5-digit), indices (US30/NI225) = 1.0, generic forex = `point*10` for 5-digit. **Never hardcode pip values** — always call `GetPipValue()`. The same function shape appears in `Logs/parse_weekly_report.ps1` for offline analysis.
- **Broker stop-level buffer.** `BROKER_STOP_BUFFER = 1.1` — when SL/TP is closer than `SYMBOL_TRADE_STOPS_LEVEL`, multiply by this buffer before sending. Don't remove.
- **Bar-once execution.** Signals evaluate only on a new M15 bar (`iTime(_Symbol, PERIOD_M15, 0)` change). `ManageOpenPositions()` runs every tick for responsive trailing/breakeven.
- **Array ordering.** All indicator buffers use `ArraySetAsSeries(arr, true)` — index 0 = current bar, index 1 = previous closed bar. Crossover checks always use `[1]` vs `[2]` (closed bars), never `[0]` (forming bar).
- **Portfolio-wide caps.** `InpMaxTotalPositions` counts across **all symbols** with the same magic — not per-symbol — because correlated USD pairs moving together caused single-day cascades (see CHANGELOG v5.1 / Apr 30 incident). `IsUSDBiasCapHit()` further limits same-direction USD exposure.
- **Daily / weekly circuit breakers.** `g_dailyStartEquity` / `g_weeklyStartEquity` are captured at the first tick of each UTC day/week. Once drawdown ≥ `InpMaxDailyLossPercent` / `InpMaxWeeklyLossPercent`, new entries are blocked but existing positions are NOT closed.
- **Breakeven locks profit.** Moving SL to `entry + InpBreakevenLockPips` (default 15), not raw entry — this is a deliberate v5.1 fix after $0-close breakeven-trap incidents (CHANGELOG v5.1).
- **SL-update throttle.** `g_slUpdateTickets[]` / `g_slUpdateTimes[]` enforce `InpMinSecondsBetweenSLUpdates` and `InpMinSLUpdatePips` per ticket to reduce broker server load.

## Conventions When Modifying an EA

- Adding an indicator: declare `g_handleXxx`, create in `OnInit()` with `INVALID_HANDLE` check, release in `OnDeinit()`, fetch into a `&buf[]` parameter inside `GetIndicatorValues()`, then use in `AnalyzeAndTrade()`.
- Adding a filter: insert in `CheckTradingConditions()` (blocks all entries) or inside `AnalyzeAndTrade()` (signal-specific). Always log the rejection reason via `PrintLog("BLOCKED: ...")` so it shows up in signal CSV / Experts tab.
- Adding an input: place inside the right `input group` block, mirror the comment style (units, default rationale), and update the `OnInit()` summary `Print(...)` so the value is visible at attach time.
- Normalize prices with `NormalizeDouble(price, _Digits)` before passing to `trade.Buy()/Sell()/PositionModify()`.
- Keep the existing magic number on v5 (`123456`) so legacy positions remain manageable.

## CHANGELOG is Load-Bearing

`CHANGELOG.md` is structured as a strategy post-mortem ledger (each version explains the problem, the fix, and expected impact with real $ figures from prior logs). When asked "why does the EA do X?", check CHANGELOG first — many counter-intuitive choices (e.g., disabling EURUSD on Trend, locking +15 pips at breakeven, capping total positions across symbols) are documented there with the originating incident.

## Notes on README.md Drift

`README.md` describes the v3/v4 era (`ea_trend_and_reveres`, RSI mean reversion with Conservative/Aggressive `.set` profiles). The actual current strategy is `ea_trend_pullback_v5.mq5` (EMA pullback, no RSI, no `.set` profile system). When in doubt, trust the `.mq5` source and CHANGELOG over the README.
