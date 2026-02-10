# 🚨 CRITICAL FIX - v4.0.2 Quick Guide

**Ngày**: 2026-02-10  
**Version**: 4.0.2  
**Issue**: Forex lot calculation sai → loss 10% thay vì 1%!

---

## ⚡ TÓM TẮT NHANH

### Vấn đề v4.0.1 (SAI)
```
Hardcoded: $10/pip cho mọi forex pair
→ Chỉ đúng với Standard Lot (100,000 units)
→ SAI với Mini Lot (10,000 units) - $1/pip
→ Lot size tính ra NHỎ HƠN 10 LẦN cần thiết!
```

### Giải pháp v4.0.2 (ĐÚNG)
```cpp
// Dùng contract size THẬT từ broker
moneyPerPipPerLot = contractSize × pipValue;

Standard (100K): 100,000 × 0.0001 = $10/pip ✓
Mini (10K): 10,000 × 0.0001 = $1/pip ✓
Micro (1K): 1,000 × 0.0001 = $0.10/pip ✓
```

---

## 🔧 CẬP NHẬT NGAY

### 1. Compile
```
MetaEditor → F7
Verify: v4.02 compiled successfully
```

### 2. Bật logs
```
EA Properties → Inputs
InpEnableDetailedLogs = true
```

### 3. Kiểm tra initialization
```
Attach EA → Check Experts log:

=====================================
EA INITIALIZED - v4.0.2 PHASE 1      ✓
🔧 v4.0.2: Position sizing RE-FIXED! ✓
   Now uses broker's actual contract size
   Standard lot (100K): $10/pip | Mini (10K): $1/pip
=====================================
```

### 4. Verify lot calculation (QUAN TRỌNG!)

Khi EA tính lot size, log PHẢI hiển thị:

```
═══════════════════════════════════
LOT SIZE CALCULATION:
  Symbol: EURUSD
  Balance: $1000.00
  Risk %: 1% = $10.00
  ---
  Broker Contract Size: _____ units  ← CHECK CÁI NÀY!
  Tick Size: _____
  Tick Value: $_____
  Pip Value: _____
  ---
  $ per pip (1 lot): $_____          ← VERIFY CÁI NÀY!
  SL Pips: 40
  Calculated Lot: _____
  ---
  VERIFICATION:
    Actual Risk = _____ 
    Target Risk = $_____
    Difference = _____               ← GẦN 0 = ĐÚNG!
═══════════════════════════════════
```

---

## ✅ CÁCH VERIFY ĐÚNG/SAI

### Check 1: Contract Size

| Broker Type | Contract Size | $ per pip (1 lot) |
|-------------|---------------|-------------------|
| **Standard** | 100,000 | **$10.00** |
| **Mini** | 10,000 | **$1.00** |
| **Micro** | 1,000 | **$0.10** |

**Ví dụ EURUSD broker mini lot**:
```
✓ ĐÚNG:
  Broker Contract Size: 10000 units
  $ per pip (1 lot): $1.000

✗ SAI (v4.0.1):
  Broker Contract Size: 10000 units
  $ per pip (1 lot): $10.000  ← Hardcoded wrong!
```

### Check 2: Actual Risk

**CÔNG THỨC**:
```
Actual Risk = Lot × SL Pips × $ per pip
```

**Ví dụ**:
```
Account: $1000
Risk: 1% = $10
SL: 40 pips
Broker: Mini lot ($1/pip)

✓ ĐÚNG (v4.0.2):
  Calculated Lot: 0.25
  Actual Risk = 0.25 × 40 × $1.00 = $10.00 ✓
  Difference = $0.00 ✓

✗ SAI (v4.0.1):
  Calculated Lot: 0.025  ← 10x quá nhỏ!
  Actual Risk = 0.025 × 40 × $1.00 = $1.00 ← Chỉ 0.1%!
  → Loss 40 pips = $1, cần 400 pips mới = $10 (1%)
  → 40 pips tưởng 1% nhưng thực ra chỉ 0.1%
  → Nếu loss 100 pips = 10%! 💥
```

### Check 3: Test Trade

**Run 1 test trade trên demo**:
1. Set risk 1%
2. Place trade với SL 50 pips
3. Close ngay với loss ~50 pips
4. Check balance:
   - Balance $1000 → After close: **$990** ✓ ĐÚNG (1% loss)
   - Balance $1000 → After close: **$900** ✗ SAI (10% loss!)

---

## 🔍 TROUBLESHOOTING

### "Difference" lớn hơn $1.00

**Nguyên nhân**: Lot step của broker (e.g., 0.05 instead of 0.01)

**Giải pháp**: OK nếu <5% target risk
```
Target Risk: $10.00
Actual Risk: $10.50  ← OK (5% diff)
Actual Risk: $15.00  ← NOT OK (50% diff) - report bug!
```

### Contract Size = 0 hoặc rất lạ

**Nguyên nhân**: Symbol không standard (e.g., futures, exotic pairs)

**Giải pháp**: 
1. Check broker symbol specification
2. May need manual InpMaxLotSize cap
3. Report symbol name for custom fix

### $ per pip vẫn = $10 với mini lot

**Nguyên nhân**: Code không update đúng

**Giải pháp**:
1. Recompile lại (F7)
2. Restart MT5
3. Clear cache: Tools → Options → Expert Advisors → Delete all

---

## 📊 BROKER TYPE DETECTION

Không chắc broker bạn dùng loại nào? Check OnInit log:

```
Symbol: EURUSD
Pip Value: 0.0001

THEN CHECK CONTRACT SIZE LOG:
  Broker Contract Size: 100000  → Standard lot
  Broker Contract Size: 10000   → Mini lot ⚠️
  Broker Contract Size: 1000    → Micro lot ⚠️
```

**Popular Brokers**:
- **IC Markets**: Standard (100K)
- **XM**: Mini (10K) ⚠️
- **Exness**: Standard (100K)
- **FXTM**: Mini (10K) ⚠️
- **Pepperstone**: Standard (100K)

Nếu broker bạn dùng mini → v4.0.1 SAI nghiêm trọng!

---

## ⚠️ CRITICAL ACTIONS

### Nếu đã trade với v4.0.1:

1. **Review lịch sử**:
   ```
   Check: Lot sizes có nhỏ bất thường?
   Standard account $1000, risk 1%:
   - Mini broker: Expect 0.20-0.30 lot
   - If seeing 0.02-0.03 lot → BỊ SAI!
   ```

2. **Calculate actual risk**:
   ```
   Pick 1 trade bất kỳ:
   Lot × SL pips × $1 (mini) hoặc $10 (standard)
   
   Ví dụ mini broker:
   0.05 lot × 50 pips × $1 = $2.50 risk
   If balance $1000 → 0.25% (not 1%!)
   ```

3. **If confirmed wrong**:
   - Note: You were risking 10x LESS than intended
   - Good news: Account safer than thought!
   - Bad news: Profits also 10x smaller
   - Update to v4.0.2 để risk đúng

### Nếu chưa trade:

1. ✅ Update v4.0.2 ngay
2. ✅ Verify logs như trên
3. ✅ Demo test 1 trade
4. ✅ Continue trading

---

## 📝 VERSION SUMMARY

| Version | Status | Issue |
|---------|--------|-------|
| **v4.0** | ❌ Had bug | contractSize × pipValue (correct formula) but then removed it |
| **v4.0.1** | ❌ Made worse | Hardcoded $10/pip (wrong for mini lots) |
| **v4.0.2** | ✅ **FIXED** | **Use contractSize × pipValue correctly** |

**CURRENT**: v4.0.2 ✅  
**ACTION**: Update immediately if using forex pairs!

---

## 🆘 SUPPORT

### Logs to send if still seeing issues:

1. **Full "LOT SIZE CALCULATION" log**
2. **Symbol name** (e.g., EURUSD, GBPUSD)
3. **Broker name**
4. **Account balance** và **actual risk %** bạn muốn

### Quick self-check script:

Paste trong Experts log after 1 test trade:
```
Symbol: _______
Broker Contract Size: _______
$ per pip (1 lot): $_______
SL Pips: _______
Calculated Lot: _______
Actual Risk: $_______
Target Risk (1% of balance): $_______
Match? YES / NO
```

---

**Version**: 4.0.2  
**Status**: ✅ CRITICAL FIX APPLIED  
**Date**: 2026-02-10  
**Priority**: 🔴 UPDATE IMMEDIATELY
