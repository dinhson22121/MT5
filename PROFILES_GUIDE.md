# 📁 EA Configuration Profiles - Quick Start Guide

## 🎯 Overview

Thay vì phải copy-paste settings từ tài liệu, giờ bạn có thể **import trực tiếp** các profile đã được tối ưu sẵn cho từng symbol và trading style!

---

## 📦 Available Profiles

### 1. **Gold_Scalping_Phase1.set** 🥇
- **Symbol**: XAUUSD (Gold)
- **Style**: Scalping
- **Timeframe**: M15
- **Win Rate Target**: 55-60%
- **Trades/Week**: 10-15
- **Risk**: Moderate (2%)
- **Features**:
  - ✅ European + US sessions
  - ✅ Sideway trading enabled
  - ✅ Tight SL/TP (40/70 pips)
  - ✅ 30-min cooldown

### 2. **EURUSD_LongTerm_Phase1.set** 💶
- **Symbol**: EURUSD (Major forex pairs)
- **Style**: Long-term
- **Timeframe**: M15
- **Win Rate Target**: 57-62%
- **Trades/Week**: 8-12
- **Risk**: Moderate (2%)
- **Features**:
  - ✅ European + US sessions
  - ❌ Sideway trading disabled (trend-following only)
  - ✅ Wider SL/TP (80/200 pips)
  - ✅ 1-hour cooldown

### 3. **Bitcoin_Scalping_Phase1.set** ₿
- **Symbol**: BTCUSD (Bitcoin)
- **Style**: Scalping 24/7
- **Timeframe**: M15
- **Win Rate Target**: 55-60%
- **Trades/Week**: 12-18
- **Risk**: Lower (1.5% for crypto volatility)
- **Features**:
  - ✅ 24/7 trading (no time filter)
  - ❌ Sideway disabled (BTC trends strongly)
  - ✅ Tight SL/TP (40/70 pips)
  - ✅ 45-min cooldown
  - ✅ Wider spread tolerance (10 pips)

### 4. **Conservative_Phase1.set** 🛡️
- **Symbol**: All (Universal)
- **Style**: Ultra-selective
- **Win Rate Target**: 60%+
- **Trades/Week**: 5-8
- **Risk**: Low (1.5%)
- **Use Case**: **Testing Phase 1 effectiveness**
- **Features**:
  - ✅ Strictest filters (ADX 27, Vol 1.6x, ATR 0.9x)
  - ✅ Strongest patterns only (Engulf 1.6, Pinbar 2.7)
  - ✅ Higher TP for better R:R
  - ✅ Trend-only (no sideway)
  - ✅ 1-hour cooldown

### 5. **Aggressive_Phase1.set** ⚡
- **Symbol**: All (Universal)
- **Style**: More opportunities
- **Win Rate Target**: 52-57%
- **Trades/Week**: 12-18
- **Risk**: Moderate-High (2%)
- **Use Case**: After Conservative proven successful
- **Features**:
  - ⚠️ Moderately relaxed filters (ADX 23, Vol 1.4x)
  - ✅ Both trend + sideway trading
  - ✅ More max positions (4)
  - ✅ 20-min cooldown

---

## 🚀 How to Import Profiles

### Method 1: Load via EA Properties (Recommended)

1. **Attach EA to Chart**
   ```
   Drag EA from Navigator → Drop on chart
   ```

2. **Open EA Properties**
   ```
   Right-click EA name (top-right corner) → Properties
   OR
   Press F7 while EA is selected
   ```

3. **Load Profile**
   ```
   Go to "Inputs" tab
   Click "Load" button (bottom)
   Navigate to: MT5\MQL5\Files\Profiles\
   Select profile (e.g., Gold_Scalping_Phase1.set)
   Click Open
   ```

4. **Verify & Apply**
   ```
   Check all values loaded correctly
   Click OK
   ```

### Method 2: Copy to Presets Folder

1. **Copy Profile Files**
   ```
   From: C:\Learning\MT5\Profiles\*.set
   To: %APPDATA%\MetaQuotes\Terminal\[YourBrokerID]\MQL5\Presets\ea_trend_and_reveres\
   ```

2. **Restart MT5**

3. **Load Preset**
   ```
   EA Properties → Inputs tab
   Top dropdown: Select your profile name
   ```

---

## 📊 Profile Comparison Matrix

| Profile | Symbol | ADX | Volume | ATR | Pattern Engulf | Pattern Pinbar | Spread | Cooldown | Win Rate | Trades/Week |
|---------|--------|-----|--------|-----|----------------|----------------|--------|----------|----------|-------------|
| **Gold Scalp** | XAUUSD | 25 | 1.5x | 0.8x | 1.5 | 2.5 | 5 | 30m | 55-60% | 10-15 |
| **EURUSD Long** | EURUSD | 25 | 1.5x | 0.8x | 1.5 | 2.5 | 3 | 60m | 57-62% | 8-12 |
| **BTC Scalp** | BTCUSD | 25 | 1.5x | 0.8x | 1.5 | 2.5 | 10 | 45m | 55-60% | 12-18 |
| **Conservative** | All | **27** | **1.6x** | **0.9x** | **1.6** | **2.7** | 4 | 60m | **60%+** | 5-8 |
| **Aggressive** | All | **23** | **1.4x** | **0.75x** | **1.4** | **2.3** | 6 | 20m | 52-57% | 12-18 |

---

## 🎓 Usage Recommendations

### For Beginners
```
Start with: Conservative_Phase1.set
Reason: Highest win rate, lowest risk, proves the strategy works
Duration: 2-4 weeks on demo
Goal: Consistent 60%+ win rate before moving to symbol-specific
```

### For Testing Phase 1
```
Order of testing:
1. Conservative (prove filters work)
2. Gold_Scalping (live symbol test)
3. EURUSD_LongTerm OR Bitcoin_Scalping (your main symbol)
4. Aggressive (only after 1-3 proven)
```

### For Different Symbols

**Gold Traders**:
- Use: `Gold_Scalping_Phase1.set`
- Customize spread if needed
- Works well with European/US overlap

**Forex Traders (EURUSD, GBPUSD, USDJPY)**:
- Use: `EURUSD_LongTerm_Phase1.set` as base
- Adjust spread per symbol:
  - EURUSD: 2-3 pips
  - GBPUSD: 3-4 pips
  - USDJPY: 2-3 pips

**Crypto Traders (BTC, ETH)**:
- Use: `Bitcoin_Scalping_Phase1.set`
- Lower risk %: 1.0-1.5%
- Wider spread: 10-20 pips
- 24/7 trading

**Indices Traders (US30, NI225)**:
- Use: `Gold_Scalping_Phase1.set` as base
- Increase spread: 8-15 pips
- Adjust pip value in EA code if needed

---

## ⚙️ Customization Tips

### Fine-Tuning Filters

If you find the profile is:

**Too Selective (almost no trades)**:
```
Decrease:
- InpMinADX (25 → 23)
- InpMinEngulfingRatio (1.5 → 1.4)
- InpMinPinbarWickRatio (2.5 → 2.3)

Increase:
- InpMaxSpreadPips (5 → 7)
```

**Too Aggressive (too many trades)**:
```
Increase:
- InpMinADX (25 → 27)
- InpVolumeMultiplier (1.5 → 1.6)
- InpMinEngulfingRatio (1.5 → 1.6)

Decrease:
- InpMaxSpreadPips (5 → 3)
Increase:
- InpMinutesBetwenTrades (30 → 45)
```

### Saving Custom Profiles

After modifying:
```
1. EA Properties → Inputs tab
2. Click "Save" button
3. Enter name: "MyCustom_Gold.set"
4. File saved to Presets folder
5. Can reload anytime via Load button
```

---

## 🔍 Verification Checklist

After loading profile, verify these CRITICAL settings:

- [ ] `InpAllowMomentumTrade = false` ✅ (MUST be disabled!)
- [ ] `InpRequireCandlePattern = true` ✅ (MUST be enabled!)
- [ ] `InpMinADX` = 23-27 ✅ (Strengthened)
- [ ] `InpVolumeMultiplier` ≥ 1.4 ✅ (Minimum 1.4x)
- [ ] `InpMinATRMultiplier` ≥ 0.75 ✅ (Minimum 0.75x)
- [ ] `InpPositionSizePercent` ≤ 2.0 ✅ (Max 2% risk)

Check EA logs after start - should show:
```
=====================================
EA INITIALIZED - v4.0 PHASE 1
PROFILE: SCALPING/LONG-TERM
=====================================
⚡ UPGRADE: Core filters strengthened...
```

---

## 📝 Profile Maintenance

### When to Update Profiles

**After Backtesting**:
- If win rate < target, use more conservative
- If too few trades, use more aggressive

**After Demo Testing**:
- Fine-tune based on actual market behavior
- Save as new custom profile

**When Moving to Live**:
- Start with Conservative for 1-2 weeks
- Gradually increase to symbol-specific
- Never jump straight to Aggressive

### Profile Naming Convention

When creating custom profiles:
```
Format: [Symbol]_[Style]_[YourName].set

Examples:
- Gold_Scalping_TightFilters.set
- EURUSD_Conservative_SessionOptimized.set
- BTC_Aggressive_VolatilityAdapted.set
```

---

## ⚠️ Important Notes

### DO NOT Modify These (Critical)
```
InpAllowMomentumTrade = false      ← Phase 1: MUST stay disabled
InpRequireCandlePattern = true     ← Phase 1: MUST stay enabled
InpMagicNumber = 123456            ← Keep consistent per symbol
```

### Safe to Customize
```
✅ Cooldown times (InpMinutesBetwenTrades)
✅ Spread limits (InpMaxSpreadPips)
✅ Time filters (InpTrade...Session)
✅ Position size % (within 1-2% range)
✅ Max positions (within 2-4 range)
```

### Requires Code Change (Advanced)
```
❌ RSI periods (hardcoded logic depends on it)
❌ EMA periods (34/89 - strategy core)
❌ Pattern detection logic
❌ Pip values per symbol
```

---

## 🆘 Troubleshooting

### Profile Won't Load
```
Error: "Cannot find file"
Solution: Copy .set files to correct folder (see Method 2)
```

### Settings Reverted After Restart
```
Reason: Profile not saved with chart template
Solution: 
1. After loading profile, right-click chart
2. Template → Save Template
3. Name it (e.g., "Gold_Phase1_Template")
4. Use template on new charts
```

### Different Values Than Documentation
```
Reason: Profile updated but docs not
Solution: Trust the .set file values (most recent)
Check: CHANGELOG.md for latest updates
```

---

## 📚 Related Files

- **PHASE1_SETTINGS.md** - Detailed explanation of each setting
- **PHASE1_UPGRADE.md** - Phase 1 implementation guide
- **CHANGELOG.md** - Version history
- **README.md** - Project overview

---

## 🔄 Profile Update History

**v4.0 Phase 1** (2026-02-09):
- ✅ Initial profiles created
- ✅ 5 profiles: Gold, EURUSD, Bitcoin, Conservative, Aggressive
- ✅ All profiles tested in backtest
- ✅ Ready for demo/live testing

**Future Updates**:
- Phase 2: Will add MTF profiles
- Phase 3: Will add S/R-optimized profiles
- Phase 4: Will add divergence-enhanced profiles

---

**Version**: 4.0 Phase 1  
**Last Updated**: 2026-02-09  
**Total Profiles**: 5  
**Status**: ✅ Ready to Use
