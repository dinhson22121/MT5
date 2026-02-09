# MT5 Expert Advisor - Trend & Range Trading System v4.0

> **High-Performance Trading Robot** cho MetaTrader 5  
> Dual-mode strategy: Trend Following + Sideways Range Trading  
> Optimized for: Gold (XAUUSD), Forex (EURUSD), Bitcoin (BTCUSD)

![Version](https://img.shields.io/badge/version-4.0%20Phase%201-blue)
![Platform](https://img.shields.io/badge/platform-MetaTrader%205-green)
![Language](https://img.shields.io/badge/language-MQL5-orange)
![Status](https://img.shields.io/badge/status-Testing-yellow)

---

## 📋 Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Features](#features)
- [Configuration Profiles](#configuration-profiles)
- [Phase 1 Upgrade](#phase-1-upgrade)
- [Documentation](#documentation)
- [Performance Targets](#performance-targets)
- [Support](#support)

---

## 🎯 Overview

**ea_trend_and_reveres** là một Expert Advisor (EA) tự động giao dịch trên MT5, sử dụng chiến lược kết hợp:
- **Trend Mode**: RSI mean reversion trong xu hướng rõ ràng (ADX + EMA)
- **Sideways Mode**: Range trading khi thị trường đi ngang
- **Pattern Recognition**: Engulfing & Pinbar patterns với volume confirmation

### Key Highlights
- ✅ Multi-timeframe M15 (15-minute candles)
- ✅ Smart market state detection (Uptrend/Downtrend/Sideways)
- ✅ Advanced filters: ADX, Volume Trend, ATR, Pattern Detection
- ✅ Risk management: Fixed pip SL/TP, breakeven, trailing stops
- ✅ Symbol-specific: Tối ưu riêng cho Gold/Forex/Crypto

---

## 🚀 Quick Start

### 1. Installation

```bash
# Copy EA file to MT5 directory
Copy ea_trend_and_reveres.mq5 to:
C:\Users\[YourName]\AppData\Roaming\MetaQuotes\Terminal\[BrokerID]\MQL5\Experts\

# Compile in MetaEditor
Press F7 or Compile button
```

### 2. Load Configuration Profile ⭐

**Recommended**: Sử dụng pre-configured profiles thay vì manual setup!

```
1. Attach EA to M15 chart
2. EA Properties → Inputs tab
3. Click "Load" button
4. Navigate to: MT5\Profiles\
5. Choose profile:
   - Conservative_Phase1.set (recommended for testing)
   - Gold_Scalping_Phase1.set (for XAUUSD)
   - EURUSD_LongTerm_Phase1.set (for forex)
   - Bitcoin_Scalping_Phase1.set (for BTC)
6. Click Open → OK
```

See [Configuration Profiles](#configuration-profiles) for details.

### 3. Run Backtest

```
Strategy Tester (Ctrl+R)
- Symbol: XAUUSD / EURUSD / BTCUSD
- Timeframe: M15
- Period: Last 6 months
- Mode: Every tick (most accurate)
- Load profile before running
```

---

## ✨ Features

### Core Trading Logic
- **Market State Engine**: Auto-detects Uptrend/Downtrend/Sideways using EMA crossover + ADX
- **RSI Mean Reversion**: Buy RSI<30 in uptrend, Sell RSI>70 in downtrend
- **Range Trading**: RSI 35-65 boundaries when sideways (ADX < 25)
- **Pattern Confirmation**: Requires Engulfing or Pinbar patterns with 2.0x volume spike

### Advanced Filters
- **ADX Filter**: Minimum 25 (strengthened from 15 in Phase 1)
- **Volume Trend**: Current volume > 1.5x average + trending upward
- **ATR Filter**: Minimum 0.8x average (prevents dead market trades)
- **Spread Protection**: Max spread limits per symbol
- **Time Filter**: European/US session focus (08:00-20:00)
- **Cooldown**: 30-60 min between trades (prevents overtrading)

### Risk Management
- **Position Sizing**: 1.5-2% of balance per trade
- **Fixed Pip SL/TP**: Gold 40/70 pips, Forex 80/200 pips, etc.
- **Breakeven**: Moves SL to entry when profit > 1.0x SL distance
- **Max Positions**: Auto-scales with account size (3-7 positions)
- **Symbol-Specific Pip Values**: Handles Gold (0.10), BTC (10.0), JPY (0.01) correctly

### Smart Features
- **Detailed Logging**: Optional verbose logs for debugging
- **On-Chart Display**: Live market state, RSI, volume/ATR status
- **Profile System**: Quick-load optimized configurations
- **Version Control**: Change tracking via CHANGELOG.md

---

## 📦 Configuration Profiles

### Available Profiles (in `Profiles/` folder)

| Profile | Symbol | Win Rate | Trades/Week | Risk | Best For |
|---------|--------|----------|-------------|------|----------|
| **Conservative** ⭐ | All | 60%+ | 5-8 | 1.5% | **Testing Phase 1** |
| **Gold_Scalping** | XAUUSD | 55-60% | 10-15 | 2.0% | Gold traders |
| **EURUSD_LongTerm** | EURUSD | 57-62% | 8-12 | 2.0% | Forex trend |
| **Bitcoin_Scalping** | BTCUSD | 55-60% | 12-18 | 1.5% | Crypto 24/7 |
| **Aggressive** | All | 52-57% | 12-18 | 2.0% | After validation |

### Profile Comparison

**Conservative** (Start here!):
```
✅ Strictest filters (ADX 27, Volume 1.6x, ATR 0.9x)
✅ Strongest patterns (Engulfing 1.6, Pinbar 2.7)
✅ Trend-only (no sideways)
✅ 60-min cooldown
🎯 Use this first to prove Phase 1 works!
```

**Gold_Scalping**:
```
✅ Optimized for XAUUSD
✅ Tight SL/TP (40/70 pips)
✅ 30-min cooldown
✅ European/US sessions
✅ Max spread 5 pips
```

**EURUSD_LongTerm**:
```
✅ Wider SL/TP (80/200 pips)
✅ Trend-following only
✅ 60-min cooldown
✅ Max spread 3 pips
```

**Bitcoin_Scalping**:
```
✅ 24/7 trading (no time filter)
✅ Lower risk (1.5% for volatility)
✅ Max spread 10 pips
✅ Tight SL/TP adapted for BTC
```

**Aggressive**:
```
⚠️ More relaxed filters (ADX 23, Volume 1.4x)
✅ Both trend + sideways
✅ 20-min cooldown
⚡ Only use after Conservative proven profitable!
```

📚 **Full Guide**: See [PROFILES_GUIDE.md](PROFILES_GUIDE.md) for detailed usage

---

## 🎯 Phase 1 Upgrade

**Current Version**: v4.0 Phase 1  
**Previous Version**: v3.00

### What Changed in Phase 1?

#### ❌ Critical Issues Fixed
1. **Momentum Mode Disabled**: Contradicted trend strategy (buying at opposite RSI levels)
2. **ADX Strengthened**: 15 → 25 (filters out weak trends)
3. **Volume Filter Tightened**: 1.0x → 1.5x average + trend check added
4. **ATR Filter Increased**: 0.5x → 0.8x (prevents dead market trades)
5. **Pattern Detection Enabled**: Was disabled by default (critical oversight!)
6. **Pattern Thresholds Raised**: 
   - Engulfing: 1.2 → 1.5 ratio
   - Pinbar: 2.0 → 2.5 wick ratio
   - Volume: 1.3x → 2.0x spike required

#### ✅ Expected Improvements
- **Win Rate**: 45-50% → 55-60%
- **Trade Frequency**: -40-50% (20-30/week → 10-15/week for Forex)
- **Quality over Quantity**: Only high-probability setups

### Testing Phase 1

**Recommended Order**:
```
1️⃣ Backtest with Conservative_Phase1.set (6 months)
   Expected: 60%+ win rate, 5-8 trades/week

2️⃣ Demo trade 2-4 weeks
   Monitor: Win rate stability, filter effectiveness

3️⃣ Switch to symbol-specific profile
   Gold/EURUSD/Bitcoin based on your market

4️⃣ After validation, try Aggressive profile
   Compare: More trades vs lower win rate tradeoff
```

📚 **Full Upgrade Guide**: See [PHASE1_UPGRADE.md](PHASE1_UPGRADE.md)

---

## 📚 Documentation

### Core Files
- **[README.md](README.md)** - This file (overview & quick start)
- **[PHASE1_UPGRADE.md](PHASE1_UPGRADE.md)** - Complete Phase 1 implementation guide
- **[PHASE1_SETTINGS.md](PHASE1_SETTINGS.md)** - Detailed settings explanations
- **[CHANGELOG.md](CHANGELOG.md)** - Version history & roadmap
- **[PROFILES_GUIDE.md](PROFILES_GUIDE.md)** - Configuration profiles usage

### Configuration Profiles
- **[Profiles/README.md](Profiles/README.md)** - Quick profile import guide
- **[Profiles/*.set](Profiles/)** - 5 pre-configured profiles

### Architecture Reference
- **[.github/copilot-instructions.md](.github/copilot-instructions.md)** - Development guide for contributors

---

## 📊 Performance Targets

### Phase 1 (Current) ✅
- **Win Rate**: 55-60% (baseline: 45-50%)
- **Trades/Week**: 10-15 for Forex, 12-18 for Crypto
- **Risk/Reward**: 1:1.5 minimum (e.g., 40 pips SL → 70 pips TP)
- **Max Drawdown**: 15-20%
- **Status**: Implementation complete, testing phase

### Phase 2 (Planned) 🔄
- **Win Rate**: 60-65%
- **Trades/Week**: 5-8 (more selective)
- **Features**: Multi-timeframe confirmation + RSI divergence
- **Status**: Awaiting Phase 1 validation

### Phase 3-6 Roadmap 🗺️
- **Phase 3**: Support/Resistance zones
- **Phase 4**: Advanced filters + entry timing
- **Phase 5**: Adaptive optimization
- **Phase 6**: Machine learning integration
- **Ultimate Goal**: 70% win rate

See [CHANGELOG.md](CHANGELOG.md) for full roadmap.

---

## 🛠️ Technical Specifications

### Requirements
- **Platform**: MetaTrader 5 (build 3802+)
- **Timeframe**: M15 (15-minute candles)
- **Symbols**: XAUUSD, EURUSD, BTCUSD (others can be adapted)
- **Account**: Minimum $200 recommended
- **Broker**: 5-digit broker required (e.g., XM, IC Markets)

### Indicators Used
- **RSI**: 7 (scalping) / 14 (long-term)
- **EMA Fast**: 34 periods
- **EMA Slow**: 89 periods
- **ADX**: 14 periods
- **ATR**: 14 periods
- **Volume**: 20-period moving average

### Key Settings (Phase 1 Defaults)
```
InpMinADX = 25.0
InpVolumeMultiplier = 1.5
InpMinATRMultiplier = 0.8
InpRequireCandlePattern = true
InpMinEngulfingRatio = 1.5
InpMinPinbarWickRatio = 2.5
InpAllowMomentumTrade = false (disabled in Phase 1)
```

---

## ⚠️ Important Notes

### DO NOT Modify (Critical)
```
❌ InpAllowMomentumTrade = false   ← MUST stay disabled until Phase 2
❌ InpRequireCandlePattern = true  ← MUST stay enabled in Phase 1
❌ RSI periods (logic depends on it)
❌ EMA periods (34/89 - strategy core)
```

### Safe to Customize
```
✅ Cooldown times (InpMinutesBetwenTrades)
✅ Spread limits (InpMaxSpreadPips)
✅ Time filters (InpTrade...Session)
✅ Position size % (within 1-2% range)
```

### Testing Checklist
- [ ] Compile EA successfully (Ctrl+F7)
- [ ] Load Conservative profile first
- [ ] Verify `InpAllowMomentumTrade = false` in logs
- [ ] Verify `InpRequireCandlePattern = true` in logs
- [ ] Check ADX/Volume/ATR filters in chart comments
- [ ] Run 6-month backtest before demo
- [ ] Demo trade minimum 2 weeks before live

---

## 🆘 Support & Troubleshooting

### Common Issues

**Profile Won't Load**:
```
Error: "Cannot find file"
Solution: Copy .set files to correct folder
Path: MT5\MQL5\Files\Profiles\ or MT5\MQL5\Presets\ea_trend_and_reveres\
```

**No Trades Executing**:
```
Check:
1. InpEnableDetailedLogs = true
2. Review logs for filter rejections
3. Verify spread < InpMaxSpreadPips
4. Confirm trading hours within session filter
5. Check cooldown period hasn't blocked new trades
```

**Too Many Trades**:
```
Solution:
1. Use Conservative profile instead of Aggressive
2. Increase InpMinutesBetwenTrades (30 → 60)
3. Increase InpMinADX (25 → 27)
4. Lower max positions (InpMaxOpenPositions)
```

**Low Win Rate**:
```
Check:
1. Are you using Phase 1 settings? (see PHASE1_SETTINGS.md)
2. Is momentum trading disabled? (must be false)
3. Are patterns enabled? (must be true)
4. Backtest period sufficient? (minimum 6 months)
```

### Getting Help

1. **Check Documentation**: 
   - [PHASE1_UPGRADE.md](PHASE1_UPGRADE.md) - Implementation details
   - [PROFILES_GUIDE.md](PROFILES_GUIDE.md) - Profile usage
   
2. **Enable Detailed Logs**:
   ```
   Set InpEnableDetailedLogs = true
   Check MT5 Experts log for rejection reasons
   ```

3. **Review Settings**:
   - Compare your settings vs profile defaults
   - Check [PHASE1_SETTINGS.md](PHASE1_SETTINGS.md)

---

## 📋 Version History

### v4.0 Phase 1 (2026-02-09) - Current
- ✅ Momentum mode disabled (contradicted trend logic)
- ✅ ADX increased: 15 → 25
- ✅ Volume filter strengthened: 1.0x → 1.5x + trend check
- ✅ ATR filter raised: 0.5x → 0.8x
- ✅ Pattern detection enabled by default
- ✅ Pattern thresholds increased
- ✅ Created 5 configuration profiles
- ✅ Comprehensive documentation added

### v3.00 (Previous)
- Multi-mode trading (Trend/Momentum/Sideways)
- RSI + EMA + ADX strategy
- Pattern recognition framework
- Basic filters

See [CHANGELOG.md](CHANGELOG.md) for complete history.

---

## 🚀 Roadmap

### Immediate (Phase 1 Testing)
- [ ] Backtest validation with Conservative profile
- [ ] Demo trading 2-4 weeks
- [ ] Performance metrics collection
- [ ] Win rate verification (target: 60%+)

### Short-term (Phase 2)
- [ ] Multi-timeframe confirmation (H4/H1/M15)
- [ ] RSI divergence detection
- [ ] Momentum mode redesign (non-contradicting)
- [ ] Target: 60-65% win rate

### Medium-term (Phase 3-4)
- [ ] Support/Resistance detection
- [ ] Market structure analysis
- [ ] Advanced entry timing
- [ ] Target: 65-68% win rate

### Long-term (Phase 5-6)
- [ ] Adaptive parameter optimization
- [ ] Machine learning integration
- [ ] Multi-symbol correlation
- [ ] **Ultimate Goal: 70% win rate**

---

## 📝 License & Disclaimer

**Educational Purposes Only**

This EA is provided for educational purposes. Trading involves substantial risk of loss. Past performance does not guarantee future results. Always test thoroughly on demo accounts before risking real capital.

**Recommended Testing**:
1. Backtest minimum 6 months
2. Demo trade minimum 2-4 weeks
3. Start with Conservative profile
4. Begin live with minimum position sizes

---

## 🔗 Quick Links

- [Quick Start](#quick-start)
- [Phase 1 Upgrade Details](PHASE1_UPGRADE.md)
- [Configuration Profiles](PROFILES_GUIDE.md)
- [Settings Guide](PHASE1_SETTINGS.md)
- [Version History](CHANGELOG.md)
- [Profile Files](Profiles/)

---

**Version**: 4.0 Phase 1  
**Status**: ✅ Testing Phase  
**Last Updated**: 2026-02-09  
**Author**: MT5 Learning Project

---
