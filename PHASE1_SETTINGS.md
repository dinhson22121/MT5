# EA v4.0 PHASE 1 - Recommended Settings

## 🎯 TARGET: 55-60% Win Rate | 10-15 Trades/Week (Forex)

---

## QUICK START SETTINGS

### For GOLD (XAUUSD) - Scalping
```
InpEnableScalping = true

// Core Filters (Phase 1 Strengthened)
InpMinADX = 25
InpVolumeMultiplier = 1.5
InpMinATRMultiplier = 0.8

// Pattern Detection (MANDATORY)
InpRequireCandlePattern = true
InpMinEngulfingRatio = 1.5
InpMinPinbarWickRatio = 2.5

// Trading Modes
InpAllowTrendingBuy = true
InpAllowTrendingSell = true
InpAllowMomentumTrade = false    // DISABLED (fixing logic)
InpAllowSidewayTrade = true

// Risk Management
InpPositionSizePercent = 2.0     // 2% per trade (SAFE)
InpStopLossPips_Scalp = 40
InpTakeProfitPips_Scalp = 70     // R:R = 1:1.75

// Cooldown
InpMinutesBetwenTrades = 30      // 30 min between trades
InpCooldownSeconds = 1800

// Spread Filter
InpMaxSpreadPips = 5             // Block if spread > 5 pips
```

### For EURUSD - Long-Term
```
InpEnableScalping = false

// Core Filters
InpMinADX = 25
InpVolumeMultiplier = 1.5
InpMinATRMultiplier = 0.8

// Pattern Detection
InpRequireCandlePattern = true
InpMinEngulfingRatio = 1.5
InpMinPinbarWickRatio = 2.5

// Trading Modes
InpAllowTrendingBuy = true
InpAllowTrendingSell = true
InpAllowMomentumTrade = false
InpAllowSidewayTrade = false     // Disable for trending pairs

// Risk Management
InpPositionSizePercent = 2.0
InpStopLossPips_LongTerm = 80
InpTakeProfitPips_LongTerm = 200  // R:R = 1:2.5

// Cooldown
InpMinutesBetwenTrades = 60       // 1 hour between trades
InpCooldownSeconds = 3600
```

### For BITCOIN (BTCUSD) - Scalping 24/7
```
InpEnableScalping = true

// Core Filters (Stricter for crypto volatility)
InpMinADX = 25
InpVolumeMultiplier = 1.5         // High volume needed
InpMinATRMultiplier = 0.8

// Pattern Detection
InpRequireCandlePattern = true
InpMinEngulfingRatio = 1.5
InpMinPinbarWickRatio = 2.5

// Trading Modes
InpAllowTrendingBuy = true
InpAllowTrendingSell = true
InpAllowMomentumTrade = false
InpAllowSidewayTrade = false      // BTC trends strongly

// Risk Management
InpPositionSizePercent = 1.5      // Lower risk for crypto
InpStopLossPips_Scalp = 40
InpTakeProfitPips_Scalp = 70

// Time Filter
InpUseTimeFilter = false          // Crypto 24/7

// Cooldown
InpMinutesBetwenTrades = 45       // 45 min (BTC moves fast)
InpCooldownSeconds = 2700

// Spread
InpMaxSpreadPips = 10             // Crypto has wider spreads
```

---

## CONSERVATIVE vs AGGRESSIVE

### CONSERVATIVE (Recommended for Phase 1 Testing)
```
InpMinADX = 27                    // Very strong trends only
InpVolumeMultiplier = 1.6         // Very high volume
InpMinATRMultiplier = 0.9         // High volatility
InpMinEngulfingRatio = 1.6        // Stronger patterns
InpMinPinbarWickRatio = 2.7

Expected: ~5-8 trades/week, 60%+ win rate
```

### AGGRESSIVE (After Phase 1 Proven)
```
InpMinADX = 23                    // Allow slightly weaker trends
InpVolumeMultiplier = 1.4
InpMinATRMultiplier = 0.75
InpMinEngulfingRatio = 1.4
InpMinPinbarWickRatio = 2.3

Expected: ~12-18 trades/week, 52-57% win rate
```

---

## ⚠️ DO NOT CHANGE (Critical for Phase 1)

```
InpAllowMomentumTrade = false     // Must stay DISABLED!
InpRequireCandlePattern = true    // Must stay ENABLED!
InpPositionSizePercent <= 2.0     // Max 2% risk!
```

---

## Session Filters (For Forex Only)

### Best Sessions for GOLD
```
InpUseTimeFilter = true
InpTradeAsianSession = false      // Skip low liquidity
InpTradeEuropeanSession = true    // London session ✓
InpTradeUSSession = true          // New York session ✓
```

### Best Sessions for EURUSD
```
InpUseTimeFilter = true
InpTradeAsianSession = false
InpTradeEuropeanSession = true    // EU overlap ✓
InpTradeUSSession = true          // US overlap ✓
```

---

## Debugging & Logs

### During Testing
```
InpEnableDetailedLogs = true
InpEnableFileLogging = true
InpDebugLogFileName = "EA_v4_Phase1_DebugLog.csv"
```

### After Stable
```
InpEnableDetailedLogs = false     // Reduce noise
InpEnableFileLogging = true       // Keep trade log
```

---

## Backtest Optimization Tips

1. **Test Period**: Minimum 6 months of M15 data
2. **Mode**: "Every tick based on real ticks"
3. **Spread**: Use "Current" or set fixed spread matching broker
4. **Initial Deposit**: $1000-$10000 (realistic)

### Expected Backtest Results (Phase 1)

**GOLD - 6 Months**:
```
Total Trades: 120-180
Win Rate: 55-60%
Profit Factor: 1.3-1.5
Max Drawdown: 10-15%
Monthly Return: 3-8%
```

**EURUSD - 6 Months**:
```
Total Trades: 60-100
Win Rate: 57-62%
Profit Factor: 1.4-1.6
Max Drawdown: 8-12%
Monthly Return: 2-6%
```

---

## Common Adjustments by Broker

### If Spreads are High (>5 pips normally)
```
InpMaxSpreadPips = [your_typical_spread * 1.5]
Example: If typical = 8 pips, set to 12

Also consider:
InpStopLossPips_Scalp = 50    // Wider SL
InpTakeProfitPips_Scalp = 90  // Maintain R:R
```

### If Symbol is Low Volatility
```
InpMinATRMultiplier = 0.6     // Lower threshold
InpMinADX = 22                // Allow weaker trends

Or switch to Long-Term profile (more suitable)
```

### If Symbol is High Volatility (Crypto, indices)
```
InpMinATRMultiplier = 1.0     // Higher threshold
InpMinADX = 27                // Stronger trends only
InpMaxSpreadPips = 15         // Wider tolerance
```

---

## Settings Import (MT5)

1. Copy settings above
2. In MT5: Right-click EA → Properties
3. Go to "Inputs" tab
4. Enter values manually OR
5. Use "Load" button to import .set file (if provided)

---

## Monitoring Checklist

After EA starts, verify:

- [ ] Version shows "v4.0 PHASE 1" in logs
- [ ] "UPGRADE: Core filters strengthened..." message appears
- [ ] Momentum mode shows "DISABLED (fixing logic)"
- [ ] Pattern Detection shows "REQUIRED ✓"
- [ ] ADX min = 25 in FILTERS section
- [ ] Volume = 1.5x in FILTERS section
- [ ] Chart comment shows "v4.0 PHASE 1"

---

## Troubleshooting Settings

### Problem: Too Many Trades Still
**Check**:
1. InpRequireCandlePattern = true? (Must be!)
2. InpAllowMomentumTrade = false? (Must be!)
3. Increase InpMinADX to 27
4. Increase InpVolumeMultiplier to 1.6

### Problem: Almost No Trades
**Check**:
1. Symbol has enough volatility? (Check ATR)
2. Spread filter too tight? (Increase InpMaxSpreadPips)
3. Try lowering InpMinADX to 23 (min threshold)
4. Check time filter - may be blocking sessions

### Problem: Patterns Never Trigger
**Check**:
1. InpMinEngulfingRatio - try 1.3-1.4
2. InpMinPinbarWickRatio - try 2.2-2.3
3. Check InpUseCandleConfirmation = true

---

**Updated**: 2026-02-09  
**Version**: 4.0 Phase 1  
**Status**: Ready for Testing
