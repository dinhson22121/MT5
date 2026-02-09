# 📁 EA Configuration Profiles

## Quick Import Guide

### Step 1: Open MT5 & Attach EA
1. Drag `ea_trend_and_reveres.ex5` from Navigator to your chart (M15 timeframe)
2. EA Properties window opens automatically

### Step 2: Load Profile
1. Click **"Inputs"** tab
2. Click **"Load"** button (at bottom)
3. Browse to this folder: `C:\Learning\MT5\Profiles\`
4. Select appropriate `.set` file (see below)
5. Click **Open**, then **OK**

---

## 📦 Available Profiles

### 🥇 Gold_Scalping_Phase1.set
- **For**: XAUUSD (Gold)
- **Target**: 55-60% win rate, 10-15 trades/week
- **Best for**: European/US session scalpers
- **Risk**: 2%

### 💶 EURUSD_LongTerm_Phase1.set
- **For**: EURUSD (Major forex pairs)
- **Target**: 57-62% win rate, 8-12 trades/week
- **Best for**: Trend-following traders
- **Risk**: 2%

### ₿ Bitcoin_Scalping_Phase1.set
- **For**: BTCUSD (Crypto)
- **Target**: 55-60% win rate, 12-18 trades/week
- **Best for**: 24/7 crypto traders
- **Risk**: 1.5%

### 🛡️ Conservative_Phase1.set ⭐ **START HERE**
- **For**: All symbols (Universal)
- **Target**: 60%+ win rate, 5-8 trades/week
- **Best for**: Testing Phase 1 effectiveness
- **Risk**: 1.5%
- **⚠️ Use this first to validate the strategy!**

### ⚡ Aggressive_Phase1.set
- **For**: All symbols (Universal)
- **Target**: 52-57% win rate, 12-18 trades/week
- **Best for**: After Conservative proven successful
- **Risk**: 2%

---

## 🎯 Recommended Order

```
1️⃣ Conservative_Phase1.set     (Test on demo 2-4 weeks)
   ↓
2️⃣ Gold/EURUSD/Bitcoin profile (Your main symbol)
   ↓
3️⃣ Aggressive_Phase1.set        (Only after proving profitability)
```

---

## ⚙️ After Loading Profile

Check these settings are correct:
- ✅ `InpAllowMomentumTrade = false` (MUST be disabled!)
- ✅ `InpRequireCandlePattern = true` (MUST be enabled!)
- ✅ `InpMinADX` = 23-27 (Strengthened)
- ✅ `InpVolumeMultiplier` ≥ 1.4

EA should display in OnInit log:
```
⚡ UPGRADE: Core filters strengthened
Pattern Detection: ENABLED ✓
```

---

## 📚 Full Documentation

See **PROFILES_GUIDE.md** in root folder for:
- Detailed profile comparison
- Customization tips
- Troubleshooting
- Advanced usage

---

**Version**: 4.0 Phase 1  
**Status**: ✅ Ready to Use  
**Last Updated**: 2026-02-09
