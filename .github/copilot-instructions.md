# MT5 Expert Advisor - Development Guide

## Project Overview
This is an MQL5 Expert Advisor (EA) for MetaTrader 5 that implements a dual-mode trading strategy: trend-following using RSI mean reversion and sideways range trading. Designed for BTC and Gold (XAU) instruments on M15 timeframe.

## Architecture & Core Components

### Market State Engine
- **Market Classification**: Three states tracked via `ENUM_MARKET_STATE`: `MARKET_UPTREND`, `MARKET_DOWNTREND`, `MARKET_SIDEWAYS`
- **State Detection**: Uses EMA34/EMA89 crossover + ADX >= 20 for trends; sideways when ADX < threshold
- **Dual Strategy**: Trending mode (RSI oversold/overbought) vs Sideways mode (RSI range 35-65)

### Indicator Pipeline
All indicators initialized in `OnInit()` with handles stored globally:
```mql5
g_handleRSI = iRSI(_Symbol, PERIOD_M15, InpRSIPeriod, PRICE_CLOSE);
g_handleEMAFast = iMA(_Symbol, PERIOD_M15, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
```
Always release handles in `OnDeinit()` to prevent memory leaks.

### Execution Flow
1. `OnTick()` → Bar detection (only trade on new M15 bar)
2. `GetIndicatorValues()` → Fetch all indicators in arrays
3. `CheckTradingConditions()` → Validate filters (time, cooldown, max positions)
4. `AnalyzeAndTrade()` → Market state + signal generation
5. `OpenPosition()` → Calculate lot size, SL/TP, execute trade
6. `ManageOpenPositions()` → Breakeven logic on profitable trades

## Symbol-Specific Pip Calculations

**Critical**: Pip values vary by instrument in `GetPipValue()`:
- **Gold (XAU)**: 1 pip = 0.10 (10 pips = 1 gia/$1)
- **Bitcoin (BTC)**: 1 pip = 10.0 (100 pips = $1000)
- **JPY pairs**: 1 pip = 0.01 (2-3 digit brokers) or point * 10 (5-digit)
- **Other forex**: point * 10 for 5-digit brokers, else point

When coding SL/TP logic, always use `GetPipValue()` multiplier, never hardcode points.

## Risk Management Pattern

**Fixed-Pip System**: All SL/TP in pips, converted via `CalculateSLTP_FixedPips()`:
```mql5
double slDistance = slPips * GetPipValue();
sl = isBuy ? (entryPrice - slDistance) : (entryPrice + slDistance);
```

**Position Sizing**: Percent-based with auto-scaling:
```mql5
positionValueUSD = balance * (InpPositionSizePercent / 100.0)
lotSize = positionValueUSD / (contractSize * entryPrice)
```

**Broker Compliance**: Always check `SYMBOL_TRADE_STOPS_LEVEL` and adjust SL/TP if below minimum distance (multiply by 1.1 buffer).

## Trading Rules & Filters

### Multi-Layer Validation
Checks executed in `CheckTradingConditions()`:
1. Terminal/EA permissions
2. Time filter (default 8:00-20:00 London/NY session)
3. Cooldown (2 hours between trades via `g_lastTradeTime`)
4. Max positions (auto-adjusts by balance: $200=3, $500=4, $1000=5, else 7)

### Signal Filters in `AnalyzeAndTrade()`
- **Volume**: Current > 1.2x average (20-period)
- **Volatility**: ATR > 0.8x average (20-period) - prevents low-volatility traps
- **RSI**: <30 for longs, >70 for shorts (trending), or 35/65 boundaries (sideways)

## Configuration Patterns

### Input Groups
Organized into logical sections: indicators, volume, risk, modes, rules, filters, debug. When adding inputs, follow existing `input group` structure.

### Mode Toggles
Three independent trading modes via boolean inputs:
- `InpAllowTrendingBuy` / `InpAllowTrendingSell` - Trend-following
- `InpAllowSidewayTrade` - Range trading with separate SL/TP (typically tighter)

**Strategy Selection**: Enable combinations (e.g., trend-only, sideways-only, or both) via inputs without code changes.

## Debugging & Logging

### Detailed Logs
Enable `InpEnableDetailedLogs = true` for verbose output:
- Bar-level analysis logs in `OnTick()`
- Signal rejection reasons (volume, ADX, cooldown)
- SL/TP calculations with risk-reward ratios

### On-Chart Display
`Comment()` in `AnalyzeAndTrade()` shows live status: balance, market state, RSI, volume/ATR status, position count. Update this when adding new indicators/filters.

## Common Modifications

### Adding a New Indicator
1. Declare handle: `int g_handleNEW;`
2. Initialize in `OnInit()`: `g_handleNEW = iCustom(...)`
3. Release in `OnDeinit()`: `IndicatorRelease(g_handleNEW)`
4. Add to `GetIndicatorValues()` array fetching
5. Integrate in `AnalyzeAndTrade()` logic

### Adding a Filter
Insert in `CheckTradingConditions()` (blocks trade entry) or `AnalyzeAndTrade()` (signal-specific). Return early with log message if filter fails.

### Symbol Support
Add pip value case in `GetPipValue()` and display logic in `OnInit()` initialization summary.

## Key Conventions

- **Array Ordering**: Always use `ArraySetAsSeries(..., true)` for indicator buffers (index 0 = current bar)
- **Error Handling**: Check handle validity (`INVALID_HANDLE`) and array copy results (return count)
- **Normalization**: Use `NormalizeDouble(price, _Digits)` before sending orders
- **Trade Object**: Single global `CTrade trade` instance, set magic number once in `OnInit()`
- **Cooldown Tracking**: Update `g_lastTradeTime = TimeCurrent()` only on successful order placement

## Testing Workflow
No automated tests. Validate changes via:
1. Compile in MetaEditor (Ctrl+F7)
2. Strategy Tester with M15 BTC/XAU historical data
3. Monitor logs for filter behavior and execution paths
4. Verify SL/TP distances match expected pip values in results
