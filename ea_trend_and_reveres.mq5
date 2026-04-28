//+------------------------------------------------------------------+
//|                                BTC_RSI_MeanReversion_Optimized.mq5 |
//|                                  Copyright 2024, Optimized Version |
//|                                  v4.2 - PHASE 3: Quality-Focused Optimization |
//+------------------------------------------------------------------+
//| v4.5 (2026-04-13) - Phase 3 Data-Driven Optimization            |
//| 29 trades, 40.9% WR, -$22 (11 days). 5 improvements:           |
//| 1. Daily cap 4 trades (Apr 6: 7 trades=-$203)                   |
//| 2. Momentum relaxed (Vol 2.0→1.5, ATR 1.2→1.0)                 |
//| 3. ATR-based SL (1.5x ATR, R:R 2.0, clamp 30-150)              |
//| 4. Spread 6→10 pips (233 blocks in Phase 3)                     |
//| 5. Sideways RSI 30/70→35/65 (0 sideways trades)                 |
//+------------------------------------------------------------------+
//| v4.4 (2026-04-02) - RSI Cross-Over Lookback Fix                 |
//| Problem: 0 trades Apr 1 (504 evals). Cross-over required single-|
//| bar RSI jump (rsi[1]<30→rsi[0]>33). RSI exits gradually over    |
//| 2-3 bars, so condition never met. Fix: lookback window (3 bars).|
//+------------------------------------------------------------------+
//| v4.3 (2026-04-01) - RSI Cross-Over + EURUSD Filter              |
//| Analysis: 19 trades, 36.8% WR, -$371 (Mar 18-31)                |
//| Root cause 1: Trailing stop destroying R:R (avg win $51 vs $66)  |
//| Root cause 2: Trend mean reversion = 20% WR, -$407               |
//| Root cause 3: Momentum Vol <200% = 0% WR (all losses)            |
//| 1. TRAILING FIX: Wider activation (70/150) & distance (40/70)    |
//|    - ATR multiplier 1.0x→2.5x, min trail 40, min activate 60    |
//| 2. ADX CAP: Max ADX=45 for trend mean reversion                  |
//|    - ADX>45 = trend too strong, pullback is actually reversal    |
//| 3. MOMENTUM VOL: 1.5x→2.0x (data: >200% = 75% WR)              |
//| 4. SIDEWAYS BOUNDARY: fixed 50pips→15% of range (dynamic)        |
//| NOT changed: Volume(trend), cooldown, sideways RSI - quality>qty |
//+------------------------------------------------------------------+
//| v4.0.2 Lot calculation fix: Uses broker's actual contract size   |
//| v4.0 Phase 1: ADX 25, Volume 1.5x, ATR 0.8x, Pattern mandatory |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property version   "4.50"  // v4.5: Phase 3 data-driven optimization (daily cap, ATR SL, relaxed filters)
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//--- Constants
const double EMA_DIFF_PERCENT_THRESHOLD = 0.3;
const double SMALL_WICK_RATIO = 0.3;
const double BROKER_STOP_BUFFER = 1.1;
const int ATR_AVERAGE_PERIOD = 20;
const double MOMENTUM_MIN_BODY_ATR = 0.5;  // Candle body must be >= 50% of ATR

//--- Input Parameters
input group "=== PROFILE SELECTION ==="
input bool InpEnableScalping = true;        // TRUE=Scalping (RSI 7, SL 40, TP 70) | FALSE=Long-Term (RSI 14, SL 80, TP 200)

input group "=== Indicator Settings ==="
input int InpRSIPeriod_Scalp = 7;          // Scalping: Fast RSI
input int InpRSIPeriod_LongTerm = 14;      // Long-Term: Stable RSI
input int InpRSIOversold = 30;             // RSI oversold level
input int InpRSIOverbought = 70;           // RSI overbought level
input bool InpUseRSIConfirmation = true;   // Wait for RSI reversal
input bool InpUseRSICrossOver = true;      // NEW: Wait for RSI to cross BACK above/below threshold (not just turning)
input int InpRSICrossBuffer = 3;           // NEW: Buffer above oversold/below overbought for cross confirmation (e.g. 30+3=33)
input int InpRSICrossLookback = 3;         // v4.4: Lookback bars for oversold/overbought detection (1=prev only, 3=check last 3 bars)
input int InpEMAFast = 34;
input int InpEMASlow = 89;
input int InpADXPeriod = 14;
input double InpMinADX = 25;                   // STRENGTHENED: Min ADX for strong trend (was 15)
input double InpMaxADXForMeanReversion = 45;    // NEW: Max ADX for mean reversion (>45 = trend too strong, reversals fail)

input group "=== Volume Filter ==="
input int InpVolumePeriod = 20;
input double InpVolumeMultiplier = 1.0;          // Trend: Vol > avg × this (1.0 = above average)
input double InpSidewayVolumeMultiplier = 0.8;   // Sideways: lower threshold (range = low vol naturally)

input group "=== Risk Management - SCALPING ==="
input double InpPositionSizePercent = 3.0;    // Risk 3% per trade (Exness Standard)
input double InpMaxLotSize = 0.5;             // Hard max lot size limit (0=no limit, safety cap)
input double InpMaxSafetyPercent = 10.0;      // Max risk % hard limit (safety cap)
input double InpMaxMarginPercent = 30.0;      // Max margin % per trade (30=safe, prevents overleveraging)
input double InpRiskBasedThreshold = 300.0;    // Balance >= this → use risk% lot sizing; below → use min lot
input int InpStopLossPips_Scalp = 50;         // Scalping: SL 50 pips
input int InpTakeProfitPips_Scalp = 100;      // Scalping: TP 100 (R:R = 1:2)
input int InpBreakevenPips_Scalp = 40;        // Scalping: Activate breakeven at +40
input int InpTrailingActivatePips_Scalp = 70; // Scalping: Activate trailing at +70 pips (was 40 - too early)
input int InpTrailingDistancePips_Scalp = 40; // Scalping: Trail distance 40 pips (was 20 - too tight)

input group "=== Risk Management - LONG-TERM ==="
input int InpStopLossPips_LongTerm = 80;      // Long-Term: Wider SL (80 pips)
input int InpTakeProfitPips_LongTerm = 200;   // Long-Term: TP 200 (R:R = 1:2.5)
input int InpBreakevenPips_LongTerm = 100;    // Long-Term: Activate breakeven at +100
input int InpTrailingActivatePips_LongTerm = 150;  // Long-Term: Activate trailing at +150 pips (was 80)
input int InpTrailingDistancePips_LongTerm = 70;  // Long-Term: Trail distance 70 pips (was 50)

input bool InpUseTrailingStop = true;         // Enable Trailing Stop
input bool InpUseAutoMaxPositions = false;
input int InpMaxPositions = 3;
input int InpMagicNumber = 123456;

input group "=== Trading Modes ==="
input bool InpAllowTrendingBuy = true;         // Trade BUY in uptrend
input bool InpAllowTrendingSell = true;        // Trade SELL in downtrend
input bool InpAllowSidewayTrade = true;        // NEW: Trade in sideways market

input group "=== Sideways Trading Settings ==="
input int InpSidewayStopLossPips_Scalp = 50;   // Scalping: SL 50 pips
input int InpSidewayTakeProfitPips_Scalp = 100; // Scalping: TP 100 (R:R = 1:2)
input int InpSidewayStopLossPips_LongTerm = 80;   // Long-Term: Match trend SL
input int InpSidewayTakeProfitPips_LongTerm = 200; // Long-Term: Match trend TP
input int InpSidewayRangePeriod = 50;          // Bars to calculate range on H4 timeframe
input int InpSidewayMinRangePips = 200;        // Min range size to trade (skip small ranges)
input int InpSidewayMaxDistanceToBoundary = 50; // Max distance from S/R (pips, fallback - see dynamic calc)
input double InpSidewayBoundaryPercent = 15.0; // Max distance as % of range (15%=top/bottom 15%)
input int InpSidewayRSIOversold = 35;      // v4.5: Relaxed 30→35 (RSI rarely hits 30 in sideways)
input int InpSidewayRSIOverbought = 65;    // v4.5: Relaxed 70→65 (RSI rarely hits 70 in sideways)

input group "=== Momentum Trading Settings ==="
input bool InpAllowMomentumTrade = true;       // Momentum mode: FOMO breakout trading
input bool InpMomentumRequireH1 = false;       // Require H1 trend alignment for momentum
input bool InpMomentumRequirePattern = false;   // Require candle pattern for momentum (false=just direction)
input int InpMomentumStopLossPips_Scalp = 50;   // Scalping: SL 50 pips
input int InpMomentumTakeProfitPips_Scalp = 100; // Scalping: TP 100 (R:R = 1:2)
input int InpMomentumStopLossPips_LongTerm = 80; // Long-Term: Wider SL
input int InpMomentumTakeProfitPips_LongTerm = 200; // Long-Term: TP
input double InpMomentumVolumeMultiplier = 1.5; // v4.5: Lowered 2.0→1.5 (0 momentum trades in Phase 3)
input double InpMomentumATRMultiplier = 1.0;    // v4.5: Lowered 1.2→1.0 (too strict, blocked all momentum)

input group "=== Crypto/BTC Adaptation ==="
input int InpCryptoRSIOversold = 30;            // Crypto RSI oversold
input int InpCryptoRSIOverbought = 70;          // Crypto RSI overbought

input group "=== Trading Rules ==="
input int InpCooldownSeconds = 3600;          // Cooldown between trades (seconds)
input int InpMaxTradesPerDay = 4;              // v4.5: Max trades per day (0=unlimited, 4=prevent cluster loss)
input bool InpAllowOnCurrentBar = false;      // Allow trading on currently forming bar (for testing)
input bool InpUseTimeFilter = false;           // Enable session filter
input bool InpTradeAsianSession = false;       // Asian: 1:00-9:00 UTC (Tokyo)
input bool InpTradeEuropeanSession = true;     // European: 7:00-16:00 UTC (London)
input bool InpTradeUSSession = true;           // US: 13:00-22:00 UTC (New York)

input group "=== Additional Filters ==="
input double InpMinATRMultiplier = 0.5;        // Min ATR vs avg (0.5=easy, 0.8=strict)
input int InpATRPeriod = 14;
input int InpMaxSpreadPips = 10;               // v4.5: Raised 6→10 (233 blocks in Phase 3, GBP/JPY/CAD)
input bool InpUseCandleConfirmation = true;    // Check candle direction
input bool InpRequireCandlePattern = false;    // Require exact pattern (Engulfing/Pinbar) - false=just candle direction
input double InpMinPinbarWickRatio = 2.0;      // Min wick/body ratio for Pinbar
input double InpMinEngulfingRatio = 1.2;       // Min engulfing body ratio

input group "=== Symbol Filter ==="
input bool InpExcludeEURUSD = false;           // Fully exclude EURUSD from ALL strategies
input bool InpEURUSDMomentumOnly = false;      // EURUSD: Only allow Momentum trades (v4.4: re-enabled with cross-over fix)

input group "=== ATR-Based SL/TP ==="
input bool InpUseATRBasedSL = true;            // v4.5: SL = ATR × multiplier (auto-adapts per symbol)
input double InpATRSLMultiplier = 1.5;         // v4.5: SL distance = ATR × this (1.5 = safe for Gold/BTC)
input double InpATRTPRatio = 2.0;              // v4.5: TP = SL × this (2.0 = 1:2 R:R)
input int InpATRSLMinPips = 30;                // v4.5: Min SL in pips (floor, prevent too tight SL)
input int InpATRSLMaxPips = 150;               // v4.5: Max SL in pips (cap, prevent too wide SL)

input group "=== Trailing Stop (ATR-Based) ==="
input bool InpUseATRTrailing = true;           // Use ATR for trailing distance (adaptive)
input double InpTrailingATRMultiplier = 2.5;   // Trail distance = ATR × this (was 1.0 - too tight)

input group "=== Multi-Timeframe Confirmation ==="
input bool InpUseH1Confirmation = true;        // Require H1 trend alignment before M15 entry
input int InpH1EMAFast = 20;                   // H1 Fast EMA period
input int InpH1EMASlow = 50;                   // H1 Slow EMA period

input group "=== Debug Settings ==="
input bool InpEnableDetailedLogs = true;
input bool InpEnableFileLogging = true;            // Write signal/trade events to daily CSV
input string InpLogFolder = "EA_Logs";               // Folder in MT5 Files (daily files auto-created)

//--- Global Variables
datetime g_lastTradeTime = 0;
int g_dailyTradeCount = 0;    // v4.5: Daily trade counter (reset each new day)
int g_lastTradeDay = 0;       // v4.5: Last trading day (for daily counter reset)
int g_handleRSI;
int g_handleEMAFast;
int g_handleEMASlow;
int g_handleATR;
int g_handleADX;
int g_handleEMAFast_H1;  // H1 timeframe EMA for multi-TF confirmation
int g_handleEMASlow_H1;  // H1 timeframe EMA for multi-TF confirmation

//--- Position close tracking (detect SL/TP/stale/manual exits)
ulong g_trackedTickets[];    // Currently open position tickets
int   g_trackedCount = 0;

//--- Small account lot mode check
//    Equity < $300: Use broker minimum lot (no risk% calculation)
//    Equity >= $300: Use risk-based lot sizing (InpPositionSizePercent)
bool IsSmallAccount()
{
   return (AccountInfoDouble(ACCOUNT_EQUITY) < InpRiskBasedThreshold);
}

//--- Profile helper functions (no more balance scaling - SL/TP always at full input values)
int GetRSIPeriod() { return InpEnableScalping ? InpRSIPeriod_Scalp : InpRSIPeriod_LongTerm; }
int GetStopLossPips()        { return InpEnableScalping ? InpStopLossPips_Scalp : InpStopLossPips_LongTerm; }
int GetTakeProfitPips()      { return InpEnableScalping ? InpTakeProfitPips_Scalp : InpTakeProfitPips_LongTerm; }
int GetBreakevenPips()       { return InpEnableScalping ? InpBreakevenPips_Scalp : InpBreakevenPips_LongTerm; }
int GetTrailingActivatePips(){ return InpEnableScalping ? InpTrailingActivatePips_Scalp : InpTrailingActivatePips_LongTerm; }
int GetTrailingDistancePips(){ return InpEnableScalping ? InpTrailingDistancePips_Scalp : InpTrailingDistancePips_LongTerm; }
int GetSidewayStopLossPips()   { return InpEnableScalping ? InpSidewayStopLossPips_Scalp : InpSidewayStopLossPips_LongTerm; }
int GetSidewayTakeProfitPips() { return InpEnableScalping ? InpSidewayTakeProfitPips_Scalp : InpSidewayTakeProfitPips_LongTerm; }
int GetMomentumStopLossPips()  { return InpEnableScalping ? InpMomentumStopLossPips_Scalp : InpMomentumStopLossPips_LongTerm; }
int GetMomentumTakeProfitPips(){ return InpEnableScalping ? InpMomentumTakeProfitPips_Scalp : InpMomentumTakeProfitPips_LongTerm; }

//+------------------------------------------------------------------+
// FILE LOGGING: Write every Print() message to daily text log file
// File location: Terminal Common Files → EA_Logs/EA_FullLog_YYYY.MM.DD_SYMBOL.txt
// Open MT5 → File → Open Data Folder → go up to Terminal → Common → Files → EA_Logs
//+------------------------------------------------------------------+
string _GetDailyTextLogFileName()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string dateStr = IntegerToString(dt.year) + "."
                  + StringFormat("%02d", dt.mon) + "."
                  + StringFormat("%02d", dt.day);
   return InpLogFolder + "/EA_FullLog_" + dateStr + "_" + _Symbol + ".txt";
}

void _WriteLogLine(string msg)
{
   if(!InpEnableFileLogging) return;
   string fileName = _GetDailyTextLogFileName();
   int fh = FileOpen(fileName, FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON|FILE_SHARE_READ);
   if(fh == INVALID_HANDLE)
      fh = FileOpen(fileName, FILE_WRITE|FILE_TXT|FILE_COMMON|FILE_SHARE_READ);
   if(fh == INVALID_HANDLE) return;
   FileSeek(fh, 0, SEEK_END);
   string ts = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   FileWriteString(fh, ts + "\t" + msg + "\r\n");
   FileClose(fh);
}

// PrintLog: Print to Experts tab AND write to log file
// Use this instead of Print() when you need file logging
void PrintLog(string msg)
{
   Print(msg);
   _WriteLogLine(msg);
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_handleRSI = iRSI(_Symbol, PERIOD_M15, GetRSIPeriod(), PRICE_CLOSE);
   g_handleEMAFast = iMA(_Symbol, PERIOD_M15, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEMASlow = iMA(_Symbol, PERIOD_M15, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   g_handleATR = iATR(_Symbol, PERIOD_M15, InpATRPeriod);
   g_handleADX = iADX(_Symbol, PERIOD_M15, InpADXPeriod);
   
   // H1 Multi-Timeframe EMAs
   g_handleEMAFast_H1 = iMA(_Symbol, PERIOD_H1, InpH1EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEMASlow_H1 = iMA(_Symbol, PERIOD_H1, InpH1EMASlow, 0, MODE_EMA, PRICE_CLOSE);
   
   if(g_handleRSI == INVALID_HANDLE || g_handleEMAFast == INVALID_HANDLE || 
      g_handleEMASlow == INVALID_HANDLE || g_handleATR == INVALID_HANDLE ||
      g_handleADX == INVALID_HANDLE ||
      g_handleEMAFast_H1 == INVALID_HANDLE || g_handleEMASlow_H1 == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicators!");
      return(INIT_FAILED);
   }
   
   // === INPUT VALIDATION: Prevent division-by-zero and invalid config ===
   if(GetStopLossPips() <= 0 || GetTakeProfitPips() <= 0)
   {
      Print("FATAL: Invalid Trend SL/TP settings (SL=", GetStopLossPips(), ", TP=", GetTakeProfitPips(), ") - must be > 0");
      return(INIT_FAILED);
   }
   if(InpAllowSidewayTrade && (GetSidewayStopLossPips() <= 0 || GetSidewayTakeProfitPips() <= 0))
   {
      Print("FATAL: Invalid Sideways SL/TP settings (SL=", GetSidewayStopLossPips(), ", TP=", GetSidewayTakeProfitPips(), ") - must be > 0");
      return(INIT_FAILED);
   }
   if(InpAllowMomentumTrade && (GetMomentumStopLossPips() <= 0 || GetMomentumTakeProfitPips() <= 0))
   {
      Print("FATAL: Invalid Momentum SL/TP settings (SL=", GetMomentumStopLossPips(), ", TP=", GetMomentumTakeProfitPips(), ") - must be > 0");
      return(INIT_FAILED);
   }
   double initPipValue = GetPipValue();
   if(initPipValue <= 0)
   {
      Print("FATAL: GetPipValue() returned ", initPipValue, " for ", _Symbol, " - cannot trade this symbol");
      return(INIT_FAILED);
   }
   
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(100);  // XM: wider slippage tolerance
   
   // Auto-detect filling mode from broker (XM uses RETURN, Exness uses FOK)
   long fillingMode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillingMode & SYMBOL_FILLING_FOK) != 0)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillingMode & SYMBOL_FILLING_IOC) != 0)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
   
   Print("Filling mode: ", 
         ((fillingMode & SYMBOL_FILLING_FOK) != 0) ? "FOK" : 
         ((fillingMode & SYMBOL_FILLING_IOC) != 0) ? "IOC" : "RETURN");
   
   double pipValue = GetPipValue();
   
   Print("=====================================");
   Print("EA INITIALIZED - v4.3");
   Print("PROFILE: ", InpEnableScalping ? "SCALPING" : "LONG-TERM");
   double bal = AccountInfoDouble(ACCOUNT_EQUITY);
   if(IsSmallAccount())
   {
      Print("💰 SMALL ACCOUNT MODE: Equity $", DoubleToString(bal,2), " < $", DoubleToString(InpRiskBasedThreshold,0));
      Print("   Lot sizing: MINIMUM LOT (broker min) | SL/TP: FULL (no scaling)");
      Print("   Risk% calculation disabled - will use broker min lot per trade");
   }
   else
   {
      Print("💰 RISK-BASED MODE: Equity $", DoubleToString(bal,2), " ≥ $", DoubleToString(InpRiskBasedThreshold,0));
      Print("   Lot sizing: Risk ", DoubleToString(InpPositionSizePercent,1), "% per trade");
   }
   Print("   Safety limit: ", DoubleToString(InpMaxSafetyPercent,1), "% max risk per trade");
   Print("=====================================");
   Print("🔧 v4.5: Phase 3 Optimization (Apr 2026)");
   Print("   SL/TP: ", InpUseATRBasedSL ? StringFormat("ATR-BASED (%.1fx ATR, R:R 1:%.1f, clamp %d-%d pips)", InpATRSLMultiplier, InpATRTPRatio, InpATRSLMinPips, InpATRSLMaxPips) : "FIXED (Scalp: 50/100, LongTerm: 80/200)");
   Print("   Daily Trade Cap: ", InpMaxTradesPerDay > 0 ? IntegerToString(InpMaxTradesPerDay) + " trades/day" : "UNLIMITED");
   Print("   Trailing: WIDER (activate ", GetTrailingActivatePips(), " / dist ", GetTrailingDistancePips(), " pips)");
   Print("   ATR Trail: ", InpTrailingATRMultiplier, "x (was 1.0x - too tight)");
   Print("   Trend ADX cap: ", InpMaxADXForMeanReversion, " (skip mean reversion in extreme trends)");
   Print("   Momentum Vol: ", InpMomentumVolumeMultiplier, "x | ATR: ", InpMomentumATRMultiplier, "x (v4.5: lowered for more signals)");
   Print("   Sideways RSI: ", InpSidewayRSIOversold, "/", InpSidewayRSIOverbought, " (v4.5: relaxed for more signals)");
   Print("   Spread Max: ", InpMaxSpreadPips, " pips (v4.5: raised from 6)");
   Print("   Sideways Boundary: ", InpSidewayBoundaryPercent, "% of range (dynamic)");
   Print("   RSI Cross-Over: ", InpUseRSICrossOver ? "ENABLED" : "DISABLED", " (buffer=", InpRSICrossBuffer, ", lookback=", InpRSICrossLookback, " bars)");
   Print("   EURUSD Filter: ", InpExcludeEURUSD ? "EXCLUDED" : (InpEURUSDMomentumOnly ? "MOMENTUM ONLY" : "ALL STRATEGIES"));
   Print("------------------------------------");
   Print("Symbol: ", _Symbol);
   Print("Pip Value: ", DoubleToString(pipValue, _Digits));
   Print("Position Size: ", InpPositionSizePercent, "%");
   Print("------------------------------------");
   Print("TRENDING MODE (Mean Reversion):");
   Print("  SL: ", GetStopLossPips(), " pips | TP: ", GetTakeProfitPips(), " pips");
   Print("  R:R = 1:", DoubleToString((double)GetTakeProfitPips()/GetStopLossPips(), 2));
   Print("  ADX Range: ", InpMinADX, " - ", InpMaxADXForMeanReversion, " (skip extreme trends)");
   Print("  RSI Entry: ", InpUseRSICrossOver ? StringFormat("CROSS-OVER (lookback %d bars, exit >%d/%d)", InpRSICrossLookback, InpRSIOversold+InpRSICrossBuffer, InpRSIOverbought-InpRSICrossBuffer) : "LEGACY (RSI<30 + turning up)");
   Print("  BUY Trend: ", InpAllowTrendingBuy ? "YES" : "NO");
   Print("  SELL Trend: ", InpAllowTrendingSell ? "YES" : "NO");
   Print("------------------------------------");
   Print("POSITION MANAGEMENT:");
   Print("  Breakeven: ", GetBreakevenPips() > 0 ? IntegerToString(GetBreakevenPips()) + " pips" : "DISABLED");
   Print("  Trailing Stop: ", InpUseTrailingStop ? "ENABLED" : "DISABLED");
   if(InpUseTrailingStop)
   {
      Print("    Activate at: ", GetTrailingActivatePips(), " pips profit");
      Print("    Trail distance: ", GetTrailingDistancePips(), " pips");
   }
   Print("------------------------------------");
   Print("SIDEWAYS MODE: ", InpAllowSidewayTrade ? "ENABLED" : "DISABLED");
   if(InpAllowSidewayTrade)
   {
      Print("  RSI Levels: ", InpSidewayRSIOversold, "/", InpSidewayRSIOverbought);
      Print("  SL: ", GetSidewayStopLossPips(), " pips | TP: ", GetSidewayTakeProfitPips(), " pips");
      Print("  R:R = 1:", DoubleToString((double)GetSidewayTakeProfitPips()/GetSidewayStopLossPips(), 2));
      Print("  Range Filter: Min ", InpSidewayMinRangePips, " pips over ", InpSidewayRangePeriod, " H4 bars");
      Print("  Boundary Filter: ", InpSidewayBoundaryPercent, "% of range (min ", InpSidewayMaxDistanceToBoundary, " pips from S/R)");
   }
   Print("------------------------------------");
   Print("MOMENTUM MODE: ", InpAllowMomentumTrade ? "ENABLED" : "DISABLED (FIXING LOGIC)");
   if(InpAllowMomentumTrade)
   {
      Print("  Logic: UPTREND+RSI>70=BUY | DOWNTREND+RSI<30=SELL");
      Print("  Require H1 Alignment: ", InpMomentumRequireH1 ? "YES" : "NO");
      Print("  Require Candle Pattern: ", InpMomentumRequirePattern ? "YES" : "NO");
      Print("  SL: ", GetMomentumStopLossPips(), " pips | TP: ", GetMomentumTakeProfitPips(), " pips");
      Print("  R:R = 1:", DoubleToString((double)GetMomentumTakeProfitPips()/GetMomentumStopLossPips(), 2));
   }
   else
   {
      Print("  ⚠️ NOTE: Momentum temporarily disabled - logic needs fixing");
      Print("  Issue: Contradicts trend strategy (buys at RSI>70 vs RSI<30)");
      Print("  Will be redesigned in Phase 2 with proper momentum detection");
   }
   Print("------------------------------------");
   Print("FILTERS:");
   Print("  ADX Min: ", InpMinADX, " (STRONG - filters weak trends)");
   Print("  Volume: ", InpVolumeMultiplier, "x avg (HIGH - filters low conviction)");
   Print("  ATR: ", InpMinATRMultiplier, "x avg (NORMAL - requires volatility)");
   Print("  Pattern: ", InpRequireCandlePattern ? "REQUIRED ✓" : "OPTIONAL");
   Print("  Spread Max: ", InpMaxSpreadPips > 0 ? IntegerToString(InpMaxSpreadPips) + " pips" : "DISABLED");
   Print("  Cooldown: ", InpCooldownSeconds, " seconds (", InpCooldownSeconds/60, " min)");
   Print("------------------------------------");
   Print("TRADING SESSIONS (UTC):");
   if(IsCryptoSymbol())
   {
      Print("  Crypto 24/7: YES (time filter disabled)");
   }
   else if(InpUseTimeFilter)
   {
      Print("  Asian (1-9h): ", InpTradeAsianSession ? "YES" : "NO");
      Print("  European (7-16h): ", InpTradeEuropeanSession ? "YES" : "NO");
      Print("  US (13-22h): ", InpTradeUSSession ? "YES" : "NO");
   }
   else
   {
      Print("  Time Filter: DISABLED (24/7 trading)");
   }
   
   if(StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0)
   {
      Print("------------------------------------");
      Print("GOLD: 10 pips = 1 gia");
      Print("  Trend SL/TP: ", GetStopLossPips()/10.0, "/", GetTakeProfitPips()/10.0, " gia");
      Print("  Momentum SL/TP: ", GetMomentumStopLossPips()/10.0, "/", GetMomentumTakeProfitPips()/10.0, " gia");
      Print("  Sideway SL/TP: ", GetSidewayStopLossPips()/10.0, "/", GetSidewayTakeProfitPips()/10.0, " gia");
   }
   
   if(StringFind(_Symbol, "BTC") >= 0)
   {
      Print("------------------------------------");
      Print("BTC: 100 pips = $1000");
      Print("  Trend SL/TP: $", GetStopLossPips()*10, "/$", GetTakeProfitPips()*10);
      Print("  Momentum SL/TP: $", GetMomentumStopLossPips()*10, "/$", GetMomentumTakeProfitPips()*10);
      Print("  Sideway SL/TP: $", GetSidewayStopLossPips()*10, "/$", GetSidewayTakeProfitPips()*10);
   }
   
   if(StringFind(_Symbol, "US30") >= 0 || StringFind(_Symbol, "DOW") >= 0 || StringFind(_Symbol, "DJ30") >= 0)
   {
      Print("------------------------------------");
      Print("US30 (DOW JONES): 1 pip = 1 point");
      Print("  Trend SL/TP: ", GetStopLossPips(), " / ", GetTakeProfitPips(), " points");
      Print("  Momentum SL/TP: ", GetMomentumStopLossPips(), " / ", GetMomentumTakeProfitPips(), " points");
      Print("  Sideway SL/TP: ", GetSidewayStopLossPips(), " / ", GetSidewayTakeProfitPips(), " points");
      Print("  Example: 40 pips SL at 35000 = 34960");
   }
   
   if(StringFind(_Symbol, "NI225") >= 0 || StringFind(_Symbol, "NIKKEI") >= 0 || StringFind(_Symbol, "JPN225") >= 0)
   {
      Print("------------------------------------");
      Print("NIKKEI 225: 1 pip = 1 point");
      Print("  Trend SL/TP: ", GetStopLossPips(), " / ", GetTakeProfitPips(), " points");
      Print("  Momentum SL/TP: ", GetMomentumStopLossPips(), " / ", GetMomentumTakeProfitPips(), " points");
      Print("  Sideway SL/TP: ", GetSidewayStopLossPips(), " / ", GetSidewayTakeProfitPips(), " points");
      Print("  Example: 40 pips SL at 33000 = 32960");
   }
   
   if(StringFind(_Symbol, "USDJPY") >= 0)
   {
      Print("------------------------------------");
      Print("USDJPY: 1 pip = 0.01 (or 0.001 for 3-digit)");
      Print("  Trend SL/TP: ", GetStopLossPips(), " / ", GetTakeProfitPips(), " pips");
      Print("  Momentum SL/TP: ", GetMomentumStopLossPips(), " / ", GetMomentumTakeProfitPips(), " pips");
      Print("  Sideway SL/TP: ", GetSidewayStopLossPips(), " / ", GetSidewayTakeProfitPips(), " pips");
      Print("  Example: Entry 150.00, SL 40 pips = 149.60, TP 100 pips = 151.00");
   }
   
   if(StringFind(_Symbol, "EURUSD") >= 0)
   {
      Print("------------------------------------");
      Print("EURUSD: 1 pip = 0.0001 (5-digit broker) or 0.00001 (pipette)");
      Print("  Trend SL/TP: ", GetStopLossPips(), " / ", GetTakeProfitPips(), " pips");
      Print("  Momentum SL/TP: ", GetMomentumStopLossPips(), " / ", GetMomentumTakeProfitPips(), " pips");
      Print("  Sideway SL/TP: ", GetSidewayStopLossPips(), " / ", GetSidewayTakeProfitPips(), " pips");
      Print("  Example: Entry 1.0500, SL 40 pips = 1.0460, TP 100 pips = 1.0600");
   }
   
   if(StringFind(_Symbol, "EURCHF") >= 0)
   {
      Print("------------------------------------");
      Print("EURCHF: 1 pip = 0.0001 (quote=CHF, auto-converted to USD)");
      Print("  Trend SL/TP: ", GetStopLossPips(), " / ", GetTakeProfitPips(), " pips");
      Print("  Momentum SL/TP: ", GetMomentumStopLossPips(), " / ", GetMomentumTakeProfitPips(), " pips");
      Print("  Sideway SL/TP: ", GetSidewayStopLossPips(), " / ", GetSidewayTakeProfitPips(), " pips");
      Print("  $/pip uses broker tickValue (CHF→USD conversion automatic)");
      Print("  Example: Entry 0.9350, SL 50 pips = 0.9300, TP 100 pips = 0.9450");
   }
   
   if(StringFind(_Symbol, "GBPUSD") >= 0)
   {
      Print("------------------------------------");
      Print("GBPUSD: 1 pip = 0.0001 (5-digit broker, spread ~0.3 pip Exness)");
      Print("  Trend SL/TP: ", GetStopLossPips(), " / ", GetTakeProfitPips(), " pips");
      Print("  Momentum SL/TP: ", GetMomentumStopLossPips(), " / ", GetMomentumTakeProfitPips(), " pips");
      Print("  Sideway SL/TP: ", GetSidewayStopLossPips(), " / ", GetSidewayTakeProfitPips(), " pips");
      Print("  Example: Entry 1.2950, SL 40 pips = 1.2910, TP 100 pips = 1.3050");
   }
   
   if(StringFind(_Symbol, "AUDUSD") >= 0)
   {
      Print("------------------------------------");
      Print("AUDUSD: 1 pip = 0.0001 (5-digit broker, spread ~0.6 pip Exness)");
      Print("  Trend SL/TP: ", GetStopLossPips(), " / ", GetTakeProfitPips(), " pips");
      Print("  Momentum SL/TP: ", GetMomentumStopLossPips(), " / ", GetMomentumTakeProfitPips(), " pips");
      Print("  Sideway SL/TP: ", GetSidewayStopLossPips(), " / ", GetSidewayTakeProfitPips(), " pips");
      Print("  Example: Entry 0.6550, SL 40 pips = 0.6510, TP 100 pips = 0.6650");
   }
   
   if(StringFind(_Symbol, "USDCAD") >= 0)
   {
      Print("------------------------------------");
      Print("USDCAD: 1 pip = 0.0001 (5-digit broker, spread ~0.8 pip Exness)");
      Print("  Trend SL/TP: ", GetStopLossPips(), " / ", GetTakeProfitPips(), " pips");
      Print("  Momentum SL/TP: ", GetMomentumStopLossPips(), " / ", GetMomentumTakeProfitPips(), " pips");
      Print("  Sideway SL/TP: ", GetSidewayStopLossPips(), " / ", GetSidewayTakeProfitPips(), " pips");
      Print("  Example: Entry 1.3600, SL 40 pips = 1.3640 (inverted), TP 100 pips = 1.3500");
   }
   
   Print("====================================");
   
   // Show log file location
   if(InpEnableFileLogging)
   {
      string logPath = TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\Files\\" + InpLogFolder;
      Print("📁 FULL LOG FILE: ", logPath);
      Print("   File: EA_FullLog_", TimeToString(TimeCurrent(), TIME_DATE), "_", _Symbol, ".txt");
      Print("   All Print() messages are written to this file");
   }
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(g_handleRSI);
   IndicatorRelease(g_handleEMAFast);
   IndicatorRelease(g_handleEMASlow);
   IndicatorRelease(g_handleATR);
   IndicatorRelease(g_handleADX);
   IndicatorRelease(g_handleEMAFast_H1);
   IndicatorRelease(g_handleEMASlow_H1);
   
   Print("====================================");
   Print("EA STOPPED - Reason: ", reason);
   Print("====================================");
}

//+------------------------------------------------------------------+
bool IsCryptoSymbol()
{
   string symbol = _Symbol;
   return (StringFind(symbol, "BTC") >= 0 || 
           StringFind(symbol, "ETH") >= 0 || 
           StringFind(symbol, "XRP") >= 0 ||
           StringFind(symbol, "LTC") >= 0 ||
           StringFind(symbol, "CRYPTO") >= 0);
}

//+------------------------------------------------------------------+
bool CheckSpread()
{
   if(InpMaxSpreadPips <= 0)
      return true;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = (ask - bid) / GetPipValue();
   
   if(spread > InpMaxSpreadPips)
   {
      if(InpEnableDetailedLogs)
         Print("BLOCKED: Spread too high (", DoubleToString(spread, 1), " pips > ", InpMaxSpreadPips, ")");
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
double GetPipValue()
{
   string symbol = _Symbol;
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   
   // Safety: if broker returns 0 point, use fallback
   if(point <= 0)
   {
      Print("WARNING: SYMBOL_POINT is 0 for ", symbol, " - using fallback 0.0001");
      point = 0.0001;
   }
   
   if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0)
      return 0.10;
   
   if(StringFind(symbol, "BTC") >= 0)
      return 10.0;
   
   // US30 (Dow Jones Industrial Average)
   if(StringFind(symbol, "US30") >= 0 || StringFind(symbol, "DOW") >= 0 || StringFind(symbol, "DJ30") >= 0)
   {
      // US30 typically: 1 pip = 1 point = 1.0
      // Example: 35000 -> 35001 = 1 pip
      return 1.0;
   }
   
   // Nikkei 225 (Japan stock index)
   if(StringFind(symbol, "NI225") >= 0 || StringFind(symbol, "NIKKEI") >= 0 || StringFind(symbol, "JPN225") >= 0)
   {
      // Nikkei typically: 1 pip = 1 point = 1.0
      // Example: 33000 -> 33001 = 1 pip
      return 1.0;
   }
   
   if(StringFind(symbol, "JPY") >= 0)
   {
      if(digits == 3 || digits == 2)
         return 0.01;
      else
         return point * 10;
   }
   
   if(digits == 5 || digits == 3)
      return point * 10;
   else
      return point;
}

//+------------------------------------------------------------------+
bool CheckCandlePattern(bool isBuySignal, double currentVolume, double avgVolume)
{
   if(!InpRequireCandlePattern)
   {
      // Fallback to simple direction check if pattern not required
      if(!InpUseCandleConfirmation)
         return true;
      
      double open = iOpen(_Symbol, PERIOD_M15, 1);
      double close = iClose(_Symbol, PERIOD_M15, 1);
      
      if(isBuySignal)
         return (close > open);
      else
         return (close < open);
   }
   
   // Get last 2 candles for pattern detection
   double open1 = iOpen(_Symbol, PERIOD_M15, 1);    // Previous candle
   double close1 = iClose(_Symbol, PERIOD_M15, 1);
   double high1 = iHigh(_Symbol, PERIOD_M15, 1);
   double low1 = iLow(_Symbol, PERIOD_M15, 1);
   
   double open2 = iOpen(_Symbol, PERIOD_M15, 2);    // 2 candles ago
   double close2 = iClose(_Symbol, PERIOD_M15, 2);
   double high2 = iHigh(_Symbol, PERIOD_M15, 2);
   double low2 = iLow(_Symbol, PERIOD_M15, 2);
   
   // Volume already checked per-strategy before calling this function
   // No duplicate volume check here
   
   if(isBuySignal)
   {
      bool isBullish1 = (close1 > open1);
      bool isBearish2 = (close2 < open2);
      double body1 = MathAbs(close1 - open1);
      double body2 = MathAbs(close2 - open2);
      
      // BULLISH ENGULFING
      bool bullishEngulfing = isBullish1 && isBearish2 && 
                              (close1 > open2) && (open1 < close2) &&
                              (body1 > body2 * InpMinEngulfingRatio);
      
      if(bullishEngulfing)
      {
         if(InpEnableDetailedLogs)
            Print("✅ BULLISH ENGULFING detected | Body ratio: ", DoubleToString(body1/body2, 2));
         return true;
      }
      
      // BULLISH PINBAR (Hammer)
      double totalRange1 = high1 - low1;
      double lowerWick1 = MathMin(open1, close1) - low1;
      double upperWick1 = high1 - MathMax(open1, close1);
      
      bool bullishPinbar = isBullish1 &&
                          (lowerWick1 > body1 * InpMinPinbarWickRatio) &&
                          (upperWick1 < body1 * SMALL_WICK_RATIO) &&
                          (totalRange1 > 0) &&
                          (body1 > 0);
      
      if(bullishPinbar)
      {
         if(InpEnableDetailedLogs)
            Print("✅ BULLISH PINBAR (Hammer) detected | Wick/Body: ", DoubleToString(lowerWick1/body1, 2));
         return true;
      }
      
      if(InpEnableDetailedLogs)
         Print("PATTERN REJECT: No bullish pattern found (Engulfing or Pinbar)");
      return false;
   }
   else
   {
      bool isBearish1 = (close1 < open1);
      bool isBullish2 = (close2 > open2);
      double body1 = MathAbs(close1 - open1);
      double body2 = MathAbs(close2 - open2);
      
      // BEARISH ENGULFING
      bool bearishEngulfing = isBearish1 && isBullish2 && 
                              (close1 < open2) && (open1 > close2) &&
                              (body1 > body2 * InpMinEngulfingRatio);
      
      if(bearishEngulfing)
      {
         if(InpEnableDetailedLogs)
            Print("✅ BEARISH ENGULFING detected | Body ratio: ", DoubleToString(body1/body2, 2));
         return true;
      }
      
      // BEARISH PINBAR (Shooting Star)
      double totalRange1 = high1 - low1;
      double upperWick1 = high1 - MathMax(open1, close1);
      double lowerWick1 = MathMin(open1, close1) - low1;
      
      bool bearishPinbar = isBearish1 &&
                          (upperWick1 > body1 * InpMinPinbarWickRatio) &&
                          (lowerWick1 < body1 * SMALL_WICK_RATIO) &&
                          (totalRange1 > 0) &&
                          (body1 > 0);
      
      if(bearishPinbar)
      {
         if(InpEnableDetailedLogs)
            Print("✅ BEARISH PINBAR (Shooting Star) detected | Wick/Body: ", DoubleToString(upperWick1/body1, 2));
         return true;
      }
      
      if(InpEnableDetailedLogs)
         Print("PATTERN REJECT: No bearish pattern found (Engulfing or Pinbar)");
      return false;
   }
}

//+------------------------------------------------------------------+
bool CheckPriceRejection(bool isBuySignal, double supportLevel, double resistanceLevel)
{
   // Check last closed candle for rejection wick
   double open1 = iOpen(_Symbol, PERIOD_M15, 1);
   double close1 = iClose(_Symbol, PERIOD_M15, 1);
   double high1 = iHigh(_Symbol, PERIOD_M15, 1);
   double low1 = iLow(_Symbol, PERIOD_M15, 1);
   
   double body = MathAbs(close1 - open1);
   double totalRange = high1 - low1;
   
   if(totalRange == 0 || body == 0)
      return false;
   
   if(isBuySignal)
   {
      // Check for bullish rejection at support
      double lowerWick = MathMin(open1, close1) - low1;
      double upperWick = high1 - MathMax(open1, close1);
      
      // Wick should be at least 50% of total range
      // And lower wick > upper wick (rejection from below)
      bool hasRejectionWick = (lowerWick >= totalRange * 0.5) && (lowerWick > upperWick * 1.5);
      
      // Price should have touched near support level
      double pipValue = GetPipValue();
      bool touchedSupport = (low1 - supportLevel) / pipValue < 20; // Within 20 pips
      
      if(hasRejectionWick && touchedSupport)
      {
         if(InpEnableDetailedLogs)
            Print("✅ REJECTION: Bullish wick rejection at support | Wick: ", 
                  DoubleToString(lowerWick / pipValue, 1), " pips");
         return true;
      }
   }
   else
   {
      // Check for bearish rejection at resistance
      double upperWick = high1 - MathMax(open1, close1);
      double lowerWick = MathMin(open1, close1) - low1;
      
      bool hasRejectionWick = (upperWick >= totalRange * 0.5) && (upperWick > lowerWick * 1.5);
      
      double pipValue = GetPipValue();
      bool touchedResistance = (resistanceLevel - high1) / pipValue < 20;
      
      if(hasRejectionWick && touchedResistance)
      {
         if(InpEnableDetailedLogs)
            Print("✅ REJECTION: Bearish wick rejection at resistance | Wick: ", 
                  DoubleToString(upperWick / pipValue, 1), " pips");
         return true;
      }
   }
   
   if(InpEnableDetailedLogs)
      Print("REJECTION FAIL: No clear price rejection pattern");
   return false;
}

//+------------------------------------------------------------------+
enum ENUM_MARKET_STATE
{
   MARKET_UPTREND,
   MARKET_DOWNTREND,
   MARKET_SIDEWAYS
};

//+------------------------------------------------------------------+
ENUM_MARKET_STATE GetMarketState(double emaFast, double emaSlow, double adx)
{
   // PHASE 1 UPGRADE: Require ADX >= 25 for strong trend
   // Also check ADX trend direction (optional but recommended)
   bool hasStrongTrend = (InpMinADX > 0) ? (adx >= InpMinADX) : 
                         (MathAbs(emaFast - emaSlow) / ((emaFast + emaSlow) / 2) * 100 > EMA_DIFF_PERCENT_THRESHOLD);
   
   if(!hasStrongTrend)
      return MARKET_SIDEWAYS;
   
   return (emaFast > emaSlow) ? MARKET_UPTREND : MARKET_DOWNTREND;
}

//+------------------------------------------------------------------+
bool CheckH1TrendAlignment(bool isBuySignal)
{
   if(!InpUseH1Confirmation)
      return true;  // Skip if disabled
   
   double h1EmaFast[], h1EmaSlow[];
   ArraySetAsSeries(h1EmaFast, true);
   ArraySetAsSeries(h1EmaSlow, true);
   
   if(CopyBuffer(g_handleEMAFast_H1, 0, 0, 2, h1EmaFast) < 2) return true;  // Fail-safe: allow trade
   if(CopyBuffer(g_handleEMASlow_H1, 0, 0, 2, h1EmaSlow) < 2) return true;
   
   if(isBuySignal)
   {
      // H1 must show uptrend (fast EMA > slow EMA)
      bool h1Uptrend = (h1EmaFast[0] > h1EmaSlow[0]);
      if(!h1Uptrend && InpEnableDetailedLogs)
         Print("BLOCKED: H1 not aligned for BUY (H1 EMA", InpH1EMAFast, "=",
               DoubleToString(h1EmaFast[0], _Digits), " < EMA", InpH1EMASlow, "=",
               DoubleToString(h1EmaSlow[0], _Digits), ")");
      return h1Uptrend;
   }
   else
   {
      // H1 must show downtrend (fast EMA < slow EMA)
      bool h1Downtrend = (h1EmaFast[0] < h1EmaSlow[0]);
      if(!h1Downtrend && InpEnableDetailedLogs)
         Print("BLOCKED: H1 not aligned for SELL (H1 EMA", InpH1EMAFast, "=",
               DoubleToString(h1EmaFast[0], _Digits), " > EMA", InpH1EMASlow, "=",
               DoubleToString(h1EmaSlow[0], _Digits), ")");
      return h1Downtrend;
   }
}

//+------------------------------------------------------------------+
void CalculateSLTP_FixedPips(double entryPrice, bool isBuy, int slPips, int tpPips, 
                             double &sl, double &tp)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipValue = GetPipValue();
   
   // Safety: prevent zero SL/TP distances
   if(pipValue <= 0 || slPips <= 0 || tpPips <= 0)
   {
      Print("ERROR: Invalid SL/TP params (pipValue=", pipValue, ", slPips=", slPips, ", tpPips=", tpPips, ")");
      sl = 0;
      tp = 0;
      return;
   }
   
   double slDistance = slPips * pipValue;
   double tpDistance = tpPips * pipValue;
   
   if(isBuy)
   {
      sl = entryPrice - slDistance;
      tp = entryPrice + tpDistance;
   }
   else
   {
      sl = entryPrice + slDistance;
      tp = entryPrice - tpDistance;
   }
   
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDistance = stopLevel * point;
   
   if(minDistance > 0)
   {
      double actualSLDistance = MathAbs(entryPrice - sl);
      double actualTPDistance = MathAbs(entryPrice - tp);
      
      if(actualSLDistance < minDistance)
      {
         if(isBuy)
            sl = entryPrice - minDistance * BROKER_STOP_BUFFER;
         else
            sl = entryPrice + minDistance * BROKER_STOP_BUFFER;
         sl = NormalizeDouble(sl, digits);
      }
      
      if(actualTPDistance < minDistance)
      {
         if(isBuy)
            tp = entryPrice + minDistance * BROKER_STOP_BUFFER;
         else
            tp = entryPrice - minDistance * BROKER_STOP_BUFFER;
         tp = NormalizeDouble(tp, digits);
      }
   }
   
   if(InpEnableDetailedLogs)
   {
      Print("SL/TP Calculation:");
      Print("  Entry: ", DoubleToString(entryPrice, digits));
      Print("  SL: ", DoubleToString(sl, digits), " (", slPips, " pips)");
      Print("  TP: ", DoubleToString(tp, digits), " (", tpPips, " pips)");
      Print("  R:R = 1:", DoubleToString((double)tpPips/slPips, 2));
   }
}

//+------------------------------------------------------------------+
// v4.5: Get ATR-adjusted SL/TP pips (auto-adapts per symbol volatility)
// Returns SL pips; TP pips = SL * InpATRTPRatio
// Falls back to fixed pips if ATR unavailable or ATR SL disabled
//+------------------------------------------------------------------+
int GetATRBasedSLPips(double currentATR)
{
   if(!InpUseATRBasedSL || currentATR <= 0)
      return 0;  // Caller should use fixed pips
   
   double pipValue = GetPipValue();
   if(pipValue <= 0) return 0;
   
   int atrSLPips = (int)MathRound((currentATR * InpATRSLMultiplier) / pipValue);
   
   // Clamp to min/max
   if(atrSLPips < InpATRSLMinPips) atrSLPips = InpATRSLMinPips;
   if(atrSLPips > InpATRSLMaxPips) atrSLPips = InpATRSLMaxPips;
   
   return atrSLPips;
}

int GetATRBasedTPPips(int atrSLPips)
{
   return (int)MathRound(atrSLPips * InpATRTPRatio);
}

//+------------------------------------------------------------------+
void OnTick()
{
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_M15, 0);
   
   if(currentBarTime == lastBarTime)
   {
      TrackOpenPositions();
      ManageOpenPositions();
      return;
   }
   
   lastBarTime = currentBarTime;
   
   if(InpEnableDetailedLogs)
      Print("\n--- NEW BAR: ", TimeToString(currentBarTime), " ---");
   
   double rsi[], emaFast[], emaSlow[], atr[], adxMain[], diPlus[], diMinus[];
   long volume[];
   
   if(!GetIndicatorValues(rsi, emaFast, emaSlow, atr, adxMain, diPlus, diMinus, volume))
   {
      Print("WARNING: Failed to get indicator values");
      return;
   }
   
   if(!CheckTradingConditions())
      return;
   
   TrackOpenPositions();
   AnalyzeAndTrade(rsi, emaFast[0], emaSlow[0], atr[0], adxMain[0], diPlus[0], diMinus[0], (double)volume[0]);
}

//+------------------------------------------------------------------+
bool GetIndicatorValues(double &rsi[], double &emaFast[], double &emaSlow[], 
                        double &atr[], double &adxMain[], double &diPlus[], double &diMinus[], long &volume[])
{
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(adxMain, true);
   ArraySetAsSeries(diPlus, true);
   ArraySetAsSeries(diMinus, true);
   
   if(CopyBuffer(g_handleRSI, 0, 0, 5, rsi) != 5) return false;        // Need more bars for confirmation
   if(CopyBuffer(g_handleEMAFast, 0, 0, 3, emaFast) != 3) return false;
   if(CopyBuffer(g_handleEMASlow, 0, 0, 3, emaSlow) != 3) return false;
   if(CopyBuffer(g_handleATR, 0, 0, 3, atr) != 3) return false;
   if(CopyBuffer(g_handleADX, 0, 0, 3, adxMain) != 3) return false;
   if(CopyBuffer(g_handleADX, 1, 0, 3, diPlus) != 3) return false;     // +DI buffer
   if(CopyBuffer(g_handleADX, 2, 0, 3, diMinus) != 3) return false;    // -DI buffer
   
   ArraySetAsSeries(volume, true);
   if(CopyTickVolume(_Symbol, PERIOD_M15, 1, InpVolumePeriod + 1, volume) <= 0)
      return false;
   
   return true;
}

//+------------------------------------------------------------------+
bool CheckTradingConditions()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      if(InpEnableDetailedLogs)
         Print("BLOCKED: Terminal trading not allowed");
      return false;
   }
   
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      if(InpEnableDetailedLogs)
         Print("BLOCKED: EA trading not allowed");
      return false;
   }
   
   // Time Filter - Auto-disable for crypto (24/7)
   if(InpUseTimeFilter && !IsCryptoSymbol())
   {
      MqlDateTime timeNow;
      TimeToStruct(TimeGMT(), timeNow);  // Use GMT/UTC time
      int currentHour = timeNow.hour;
      
      bool inTradingSession = false;
      string activeSessions = "";
      
      // Asian Session: 1:00-9:00 UTC (Tokyo: 10:00-18:00 JST)
      if(InpTradeAsianSession && currentHour >= 1 && currentHour < 9)
      {
         inTradingSession = true;
         activeSessions += "ASIAN ";
      }
      
      // European Session: 7:00-16:00 UTC (London: 8:00-17:00 GMT+1)
      if(InpTradeEuropeanSession && currentHour >= 7 && currentHour < 16)
      {
         inTradingSession = true;
         activeSessions += "EUROPEAN ";
      }
      
      // US Session: 13:00-22:00 UTC (New York: 8:00-17:00 EST)
      if(InpTradeUSSession && currentHour >= 13 && currentHour < 22)
      {
         inTradingSession = true;
         activeSessions += "US ";
      }
      
      if(!inTradingSession)
      {
         if(InpEnableDetailedLogs)
            Print("BLOCKED: Outside trading sessions (UTC ", currentHour, ":00)");
         return false;
      }
      
      if(InpEnableDetailedLogs && activeSessions != "")
      {
         static string lastSessionLog = "";
         if(lastSessionLog != activeSessions)
         {
            Print("INFO: Active sessions - ", activeSessions);
            lastSessionLog = activeSessions;
         }
      }
   }
   else if(InpUseTimeFilter && IsCryptoSymbol())
   {
      static bool cryptoWarningShown = false;
      if(!cryptoWarningShown && InpEnableDetailedLogs)
      {
         Print("INFO: Crypto detected - Time filter auto-disabled (24/7 trading)");
         cryptoWarningShown = true;
      }
   }
   
   int secondsSinceLastTrade = (int)(TimeCurrent() - g_lastTradeTime);
   int requiredSeconds = InpCooldownSeconds;
   
   if(g_lastTradeTime > 0 && secondsSinceLastTrade < requiredSeconds)
   {
      if(InpEnableDetailedLogs)
         Print("BLOCKED: Cooldown - ", (requiredSeconds - secondsSinceLastTrade) / 60, " min remaining");
      return false;
   }
   
   int currentPositions = CountOpenPositions();
   int maxPositions = GetMaxPositions();
   
   if(currentPositions >= maxPositions)
   {
      if(InpEnableDetailedLogs)
         Print("BLOCKED: Max positions ", currentPositions, "/", maxPositions);
      return false;
   }
   
   // v4.5: Daily trade cap - prevent cluster losses (Apr 6: 7 trades = -$203)
   if(InpMaxTradesPerDay > 0)
   {
      MqlDateTime dtNow;
      TimeToStruct(TimeCurrent(), dtNow);
      int today = dtNow.day_of_year;
      
      // Reset counter on new day
      if(today != g_lastTradeDay)
      {
         g_dailyTradeCount = 0;
         g_lastTradeDay = today;
      }
      
      if(g_dailyTradeCount >= InpMaxTradesPerDay)
      {
         if(InpEnableDetailedLogs)
            Print("BLOCKED: Daily trade cap reached (", g_dailyTradeCount, "/", InpMaxTradesPerDay, ")");
         return false;
      }
   }
   
   if(!CheckSpread())
      return false;
   
   return true;
}

//+------------------------------------------------------------------+
int GetMaxPositions()
{
   if(!InpUseAutoMaxPositions)
      return InpMaxPositions;
   
   double balance = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance < 200) return 1;       // <$200: Only 1 position (survival mode)
   else if(balance < 500) return 3;
   else if(balance < 1000) return 4;
   else return 7;
}

//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            count++;
      }
      else
      {
         if(InpEnableDetailedLogs) Print("WARN: PositionSelectByTicket failed for ticket ", ticket);
      }
   }
   return count;
}

//+------------------------------------------------------------------+
// Position close tracking: detect when positions disappear and log exit reason
//+------------------------------------------------------------------+
void TrackOpenPositions()
{
   // Build current list of open tickets for this EA
   int total = PositionsTotal();
   int count = 0;
   ulong currentTickets[];
   ArrayResize(currentTickets, total);
   
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      currentTickets[count++] = ticket;
   }
   ArrayResize(currentTickets, count);
   
   // Check which tracked tickets are no longer open
   for(int i = 0; i < g_trackedCount; i++)
   {
      bool stillOpen = false;
      for(int j = 0; j < count; j++)
      {
         if(g_trackedTickets[i] == currentTickets[j])
         { stillOpen = true; break; }
      }
      if(!stillOpen)
         LogClosedPosition(g_trackedTickets[i]);
   }
   
   // Update tracked list
   g_trackedCount = count;
   ArrayResize(g_trackedTickets, count);
   for(int i = 0; i < count; i++)
      g_trackedTickets[i] = currentTickets[i];
}

void LogClosedPosition(ulong posTicket)
{
   // Search deal history for this position
   datetime from = TimeCurrent() - 86400;  // last 24h
   datetime to = TimeCurrent() + 3600;
   HistorySelect(from, to);
   
   int totalDeals = HistoryDealsTotal();
   for(int i = totalDeals - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket <= 0) continue;
      
      // Match by position ID
      ulong dealPosId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(dealPosId != posTicket) continue;
      
      // Only interested in the closing deal (DEAL_ENTRY_OUT)
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;
      
      double dealPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      double dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      double dealSwap = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
      double dealComm = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      double dealVol = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      string dealComment = HistoryDealGetString(dealTicket, DEAL_COMMENT);
      ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
      ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      
      // Determine exit reason
      string exitReason = "UNKNOWN";
      if(reason == DEAL_REASON_SL)        exitReason = "STOP_LOSS";
      else if(reason == DEAL_REASON_TP)   exitReason = "TAKE_PROFIT";
      else if(reason == DEAL_REASON_SO)   exitReason = "STOP_OUT";
      else if(reason == DEAL_REASON_EXPERT) exitReason = "EA_CLOSE";  // stale exit, manual close by EA
      else if(reason == DEAL_REASON_CLIENT) exitReason = "MANUAL";
      else exitReason = "OTHER(" + IntegerToString((int)reason) + ")";
      
      string direction = (dealType == DEAL_TYPE_BUY) ? "CLOSE_SELL" : "CLOSE_BUY";
      double netPL = dealProfit + dealSwap + dealComm;
      double pipValue = GetPipValue();
      
      Print("╔══════════════════════════════════╗");
      Print("║ POSITION CLOSED - ", exitReason);
      Print("╠══════════════════════════════════╣");
      Print("  Ticket: #", posTicket, " | ", direction);
      Print("  Close Price: ", DoubleToString(dealPrice, _Digits));
      Print("  Volume: ", DoubleToString(dealVol, 2));
      Print("  Profit: $", DoubleToString(dealProfit, 2),
            " | Swap: $", DoubleToString(dealSwap, 2),
            " | Comm: $", DoubleToString(dealComm, 2));
      Print("  NET P/L: $", DoubleToString(netPL, 2));
      Print("  Comment: ", dealComment);
      Print("╚══════════════════════════════════╝");
      _WriteLogLine("CLOSED | " + exitReason + " | Ticket #" + IntegerToString((long)posTicket)
                    + " | " + direction
                    + " | Price: " + DoubleToString(dealPrice, _Digits)
                    + " | Vol: " + DoubleToString(dealVol, 2)
                    + " | P/L: $" + DoubleToString(netPL, 2)
                    + " | " + dealComment);
      
      // Also log to CSV
      LogTradeEvent(exitReason, dealComment, 
                    (dealType == DEAL_TYPE_SELL),  // original position was BUY if closing deal is SELL
                    dealPrice, 0, 0, dealVol, (int)reason, posTicket);
      return;
   }
   
   // If no matching deal found (shouldn't happen normally)
   Print("⚠️ POSITION #", posTicket, " closed but deal not found in history");
}

//+------------------------------------------------------------------+
// File logging helpers (CSV) - Daily file: EA_Logs/EA_2026.02.24_BTCUSD.csv
string GetDailyLogFileName()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string dateStr = IntegerToString(dt.year) + "." 
                  + StringFormat("%02d", dt.mon) + "."
                  + StringFormat("%02d", dt.day);
   return InpLogFolder + "/EA_" + dateStr + "_" + _Symbol + ".csv";
}

void WriteCsvHeader(int fh, string fileType)
{
   if(fileType == "SIGNAL")
      FileWriteString(fh, "Time,Symbol,Event,SignalType,MarketState,Reason,RSI,AvgVol,CurrVol,ATR,AvgATR,ADX,Equity,OpenPos,MaxPos\r\n");
   else
      FileWriteString(fh, "Time,Symbol,Event,Stage,Comment,Direction,Price,SL,TP,Lot,RiskUSD,RiskPct,ResultCode,Ticket,OpenPos,MaxPos\r\n");
}

void DebugLogCSV(string line)
{
   if(!InpEnableFileLogging) return;
   string fileName = GetDailyLogFileName();
   
   // Check if file exists to decide whether to write header
   bool isNewFile = !FileIsExist(fileName, FILE_COMMON);
   
   int fh = FileOpen(fileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(fh == INVALID_HANDLE)
   {
      // Try create folder + file
      fh = FileOpen(fileName, FILE_WRITE|FILE_CSV|FILE_COMMON);
      isNewFile = true;
      if(fh == INVALID_HANDLE)
      {
         if(InpEnableDetailedLogs) Print("ERROR: Cannot open log file ", fileName);
         return;
      }
   }
   
   if(isNewFile && FileSize(fh) == 0)
   {
      // Auto-detect header type from line content
      if(StringFind(line, ",TRADE,") >= 0)
         WriteCsvHeader(fh, "TRADE");
      else
         WriteCsvHeader(fh, "SIGNAL");
   }
   
   FileSeek(fh, 0, SEEK_END);
   FileWriteString(fh, line);
   FileWriteString(fh, "\r\n");
   FileClose(fh);
}

void LogSignalEvent(string eventType, string signalType, string reason, double rsiVal, double avgVol, double currVol, double atrVal, double avgATRVal, double adxVal, string marketStateStr)
{
   if(!InpEnableFileLogging) return;
   string ts = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   string rec = ts + "," + _Symbol + "," + eventType + "," + signalType + "," + marketStateStr + "," + reason 
              + "," + DoubleToString(rsiVal,1) 
              + "," + DoubleToString(avgVol,0) + "," + DoubleToString(currVol,0) 
              + "," + DoubleToString(atrVal,_Digits) + "," + DoubleToString(avgATRVal,_Digits) 
              + "," + DoubleToString(adxVal,1)
              + ",$" + DoubleToString(equity,2)
              + "," + IntegerToString(CountOpenPositions()) + "," + IntegerToString(GetMaxPositions());
   DebugLogCSV(rec);
}

void LogTradeEvent(string stage, string comment, bool isBuy, double price, double sl, double tp, double lot, int resultCode, ulong ticket)
{
   if(!InpEnableFileLogging) return;
   string ts = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   string dir = isBuy ? "BUY" : "SELL";
   string ticketStr = (ticket == 0) ? "0" : IntegerToString((int)ticket);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double pipVal = GetPipValue();
   double riskUSD = lot * MathAbs(price - sl) / pipVal * 10;  // approximate
   double riskPct = (equity > 0) ? (riskUSD / equity * 100.0) : 0;
   string rec = ts + "," + _Symbol + ",TRADE," + stage + "," + comment + "," + dir 
              + "," + DoubleToString(price, _Digits) 
              + "," + DoubleToString(sl, _Digits) + "," + DoubleToString(tp, _Digits) 
              + "," + DoubleToString(lot,2)
              + ",$" + DoubleToString(riskUSD,2) + "," + DoubleToString(riskPct,1) + "%"
              + "," + IntegerToString(resultCode) + "," + ticketStr 
              + "," + IntegerToString(CountOpenPositions()) + "," + IntegerToString(GetMaxPositions());
   DebugLogCSV(rec);
}  

//+------------------------------------------------------------------+
void AnalyzeAndTrade(const double &rsi[], double emaFast, double emaSlow, 
                     double atr, double adx, double diPlus, double diMinus, double currentVolume)
{
   // Calculate average volume (used for pattern confirmation)
   double avgVolume = 0;
   long volumeArray[];
   ArraySetAsSeries(volumeArray, true);
   
   if(CopyTickVolume(_Symbol, PERIOD_M15, 1, InpVolumePeriod, volumeArray) > 0)
   {
      for(int i = 0; i < InpVolumePeriod; i++)
         avgVolume += (double)volumeArray[i];
      avgVolume /= InpVolumePeriod;
   }
   
   // Per-strategy volume flags (no more global gate blocking all strategies)
   bool volumeOK_Trend = (currentVolume > avgVolume * InpVolumeMultiplier);        // 1.0x for trend
   bool volumeOK_Sideways = (currentVolume > avgVolume * InpSidewayVolumeMultiplier); // 0.8x for sideways
   bool volumeOK_Momentum = (currentVolume > avgVolume * InpMomentumVolumeMultiplier); // 1.5x for momentum
   
   // Calculate average ATR
   bool volatilityOK = true;
   double avgATR = 0;
   if(InpMinATRMultiplier > 0)
   {
      double atrArray[];
      ArraySetAsSeries(atrArray, true);
      if(CopyBuffer(g_handleATR, 0, 0, ATR_AVERAGE_PERIOD, atrArray) > 0)
      {
         for(int i = 0; i < ATR_AVERAGE_PERIOD; i++)
            avgATR += atrArray[i];
         avgATR /= ATR_AVERAGE_PERIOD;
         volatilityOK = (atr > avgATR * InpMinATRMultiplier);
      }
   }
   
   // Determine market state
   ENUM_MARKET_STATE marketState = GetMarketState(emaFast, emaSlow, adx);
   
   string marketStateStr = "";
   switch(marketState)
   {
      case MARKET_UPTREND: marketStateStr = "UPTREND"; break;
      case MARKET_DOWNTREND: marketStateStr = "DOWNTREND"; break;
      case MARKET_SIDEWAYS: marketStateStr = "SIDEWAYS"; break;
   }
   
   // === BAR ANALYSIS SUMMARY LOG ===
   if(InpEnableDetailedLogs)
   {
      Print("══════════════════════════════════════");
      Print("📊 BAR ANALYSIS | ", _Symbol, " | ", TimeToString(iTime(_Symbol, PERIOD_M15, 0)));
      Print("══════════════════════════════════════");
      Print("  Market State: ", marketStateStr, " | EMA34=", DoubleToString(emaFast, _Digits), " EMA89=", DoubleToString(emaSlow, _Digits));
      Print("  RSI(", InpRSIPeriod_Scalp, "): ", DoubleToString(rsi[0], 1), " | prev=", DoubleToString(rsi[1], 1), " | prev2=", DoubleToString(rsi[2], 1));
      Print("  ADX: ", DoubleToString(adx, 1), " (threshold=", InpMinADX, ") | ATR: ", DoubleToString(atr, _Digits));
      Print("  Volume: ", (int)currentVolume, " vs avg=", (int)avgVolume, " (", DoubleToString(currentVolume/MathMax(avgVolume,1)*100, 0), "%)");
      Print("    Trend(", InpVolumeMultiplier, "x)=", (volumeOK_Trend ? "OK" : "LOW"),
            " | Sideways(", InpSidewayVolumeMultiplier, "x)=", (volumeOK_Sideways ? "OK" : "LOW"),
            " | Momentum(", InpMomentumVolumeMultiplier, "x)=", (volumeOK_Momentum ? "OK" : "LOW"));
      Print("  Volatility (Global): ATR=", DoubleToString(atr, _Digits), " vs avg=", DoubleToString(avgATR, _Digits),
            " (", DoubleToString(atr/MathMax(avgATR,0.0001), 2), "x | need ", InpMinATRMultiplier, "x) = ", (volatilityOK ? "OK" : "BLOCKED"));
      Print("  Volatility (Momentum): ATR ", DoubleToString(atr/MathMax(avgATR,0.0001), 2), "x vs need ", InpMomentumATRMultiplier, "x = ",
            ((atr > avgATR * InpMomentumATRMultiplier) ? "OK" : "LOW"),
            " (need >", DoubleToString(avgATR * InpMomentumATRMultiplier, _Digits), ")");
      Print("──────────────────────────────────────");
      
      // Log which strategies are eligible this bar
      string eligible = "  Eligible Strategies: ";
      if(marketState == MARKET_UPTREND && InpAllowTrendingBuy) eligible += "[TREND_BUY] ";
      if(marketState == MARKET_DOWNTREND && InpAllowTrendingSell) eligible += "[TREND_SELL] ";
      if(InpAllowMomentumTrade) eligible += "[MOMENTUM] ";
      if(marketState == MARKET_SIDEWAYS && InpAllowSidewayTrade) eligible += "[SIDEWAYS] ";
      Print(eligible);
      
      // Log RSI zone (using effective thresholds for crypto)
      string rsiZone = "NEUTRAL";
      if(rsi[0] < InpRSIOversold) rsiZone = "OVERSOLD (<" + IntegerToString(InpRSIOversold) + ")";
      else if(rsi[0] > InpRSIOverbought) rsiZone = "OVERBOUGHT (>" + IntegerToString(InpRSIOverbought) + ")";
      else if(marketState == MARKET_SIDEWAYS)
      {
         if(rsi[0] < InpSidewayRSIOversold) rsiZone = "SIDEWAYS_OVERSOLD (<" + IntegerToString(InpSidewayRSIOversold) + ")";
         else if(rsi[0] > InpSidewayRSIOverbought) rsiZone = "SIDEWAYS_OVERBOUGHT (>" + IntegerToString(InpSidewayRSIOverbought) + ")";
      }
      if(IsCryptoSymbol())
         Print("  RSI Zone: ", rsiZone, " | Crypto thresholds: ", InpCryptoRSIOversold, "/", InpCryptoRSIOverbought);
      else
         Print("  RSI Zone: ", rsiZone);
   }
   
   // Crypto-adaptive RSI thresholds
   int effectiveRSIOversold = IsCryptoSymbol() ? InpCryptoRSIOversold : InpRSIOversold;
   int effectiveRSIOverbought = IsCryptoSymbol() ? InpCryptoRSIOverbought : InpRSIOverbought;
   
   // Check if we have STRONG MOMENTUM (high vol + high ATR + DI direction)
   bool hasMomentum = false;
   if(InpAllowMomentumTrade)
   {
      bool isHighVolume = (currentVolume > avgVolume * InpMomentumVolumeMultiplier);
      bool isHighATR = (atr > avgATR * InpMomentumATRMultiplier);
      // DI direction: confirms trend strength direction (not just ADX magnitude)
      bool isDIPlusDominant = (diPlus > diMinus);   // Bullish pressure
      bool isDIMinusDominant = (diMinus > diPlus);   // Bearish pressure
      
      if(InpEnableDetailedLogs)
      {
         Print("  Momentum Check: Vol=", (isHighVolume ? "HIGH" : "LOW"), 
               " (", DoubleToString(currentVolume/MathMax(avgVolume,1), 2), "x/", InpMomentumVolumeMultiplier, "x)",
               " | ATR=", (isHighATR ? "HIGH" : "LOW"),
               " (", DoubleToString(atr/MathMax(avgATR,0.0001), 2), "x/", InpMomentumATRMultiplier, "x)",
               " | DI+=", DoubleToString(diPlus, 1), " DI-=", DoubleToString(diMinus, 1),
               " (", (isDIPlusDominant ? "BULLISH" : (isDIMinusDominant ? "BEARISH" : "NEUTRAL")), ")");
      }
      
      // UPTREND + RSI overbought + HIGH vol + HIGH ATR + DI+ > DI- = Strong buying momentum
      if(marketState == MARKET_UPTREND && rsi[0] > effectiveRSIOverbought && isHighVolume && isHighATR && isDIPlusDominant)
      {
         hasMomentum = true;
         if(InpEnableDetailedLogs)
            Print("  >>> MOMENTUM BUY QUALIFIED: All conditions met! (DI+ dominant)");
      }
      
      // DOWNTREND + RSI oversold + HIGH vol + HIGH ATR + DI- > DI+ = Strong selling momentum
      if(marketState == MARKET_DOWNTREND && rsi[0] < effectiveRSIOversold && isHighVolume && isHighATR && isDIMinusDominant)
      {
         hasMomentum = true;
         if(InpEnableDetailedLogs)
            Print("  >>> MOMENTUM SELL QUALIFIED: All conditions met! (DI- dominant)");
      }
      
      if(!hasMomentum && InpEnableDetailedLogs)
      {
         string reasons = "  Momentum NOT met: ";
         if(marketState == MARKET_SIDEWAYS) reasons += "Market=SIDEWAYS ";
         if(rsi[0] >= effectiveRSIOversold && rsi[0] <= effectiveRSIOverbought) reasons += "RSI=NEUTRAL ";
         if(!isHighVolume) reasons += "Vol=LOW ";
         if(!isHighATR) reasons += "ATR=LOW ";
         if(marketState == MARKET_UPTREND && !isDIPlusDominant) reasons += "DI+=WEAK(need DI+>DI-) ";
         if(marketState == MARKET_DOWNTREND && !isDIMinusDominant) reasons += "DI-=WEAK(need DI->DI+) ";
         Print(reasons);
      }
   } // end if(InpAllowMomentumTrade)
   
   if(InpEnableDetailedLogs)
      Print("──────────────────────────────────────");
   
   // Display status
   double balance = AccountInfoDouble(ACCOUNT_EQUITY);
   double positionValue = balance * (InpPositionSizePercent / 100.0);
   
   string volumeStatus = volumeOK_Trend ? "HIGH" : "LOW";
   string atrStatus = volatilityOK ? "OK" : "LOW";
   
   // Get current session info
   string sessionInfo = "";
   if(IsCryptoSymbol())
   {
      sessionInfo = "24/7";
   }
   else if(InpUseTimeFilter)
   {
      MqlDateTime timeNow;
      TimeToStruct(TimeGMT(), timeNow);
      int h = timeNow.hour;
      
      if(h >= 1 && h < 9 && InpTradeAsianSession) sessionInfo = "ASIAN";
      if(h >= 7 && h < 16 && InpTradeEuropeanSession) 
      {
         if(sessionInfo != "") sessionInfo += "+";
         sessionInfo += "EU";
      }
      if(h >= 13 && h < 22 && InpTradeUSSession)
      {
         if(sessionInfo != "") sessionInfo += "+";
         sessionInfo += "US";
      }
      
      if(sessionInfo == "") sessionInfo = "OFF-HOURS";
   }
   else
   {
      sessionInfo = "NO FILTER";
   }
   
   // Get H1 trend info for display
   string h1Info = "OFF";
   if(InpUseH1Confirmation)
   {
      double h1f[], h1s[];
      ArraySetAsSeries(h1f, true);
      ArraySetAsSeries(h1s, true);
      if(CopyBuffer(g_handleEMAFast_H1, 0, 0, 1, h1f) > 0 && CopyBuffer(g_handleEMASlow_H1, 0, 0, 1, h1s) > 0)
         h1Info = (h1f[0] > h1s[0]) ? "UP" : "DOWN";
   }
   
   Comment(
      "=== ", _Symbol, " - v4.3 ===", "\n",
      "🎯 LOG-DRIVEN OPT | Wider Trail | Lower Vol | Dynamic Boundary", "\n",
      "Balance: $", DoubleToString(balance, 2), " | Risk: ", InpPositionSizePercent, "%", "\n",
      "Session: ", sessionInfo, " | UTC: ", TimeToString(TimeGMT(), TIME_MINUTES), "\n",
      "Market: ", marketStateStr, " | H1: ", h1Info, " | ADX: ", DoubleToString(adx, 1), "\n",
      "RSI: ", DoubleToString(rsi[0], 1), " | Vol: ", volumeStatus, " | ATR: ", atrStatus, "\n",
      "SL/TP: FIXED | ATR=$", DoubleToString(atr, 2), "\n",
      "Positions: ", CountOpenPositions(), "/", GetMaxPositions(), "\n",
      "Trend: BUY=", (InpAllowTrendingBuy ? "YES" : "NO"), " SELL=", (InpAllowTrendingSell ? "YES" : "NO"),
      " | Sideway: ", (InpAllowSidewayTrade ? "YES" : "NO")
   );
   
   // Common filter: ATR only (volume is now per-strategy)
   if(!volatilityOK)
   {
      if(InpEnableDetailedLogs)
         Print("NO SIGNAL: ATR too low (", DoubleToString(atr, 2), " vs ", DoubleToString(avgATR * InpMinATRMultiplier, 2), ")");
      LogSignalEvent("REJECT", "ATRLow", "atr < avg*minMult", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
      return;
   }
   
   // Momentum trades skip pattern check only
   if(hasMomentum && InpEnableDetailedLogs)
   {
      Print("⚡ MOMENTUM DETECTED: Pattern check per InpMomentumRequirePattern=", InpMomentumRequirePattern ? "YES" : "SKIP");
   }
   
   // TRENDING SIGNALS (Mean Reversion - Wait for Reversal)
   if(marketState == MARKET_UPTREND && InpAllowTrendingBuy)
   {
      // EURUSD filter: skip Trend strategy for EUR (data: -$355 of -$371 total loss from EUR Trend)
      bool isEURUSD = (StringFind(_Symbol, "EUR") >= 0 && StringFind(_Symbol, "USD") >= 0);
      if(isEURUSD && (InpExcludeEURUSD || InpEURUSDMomentumOnly))
      {
         if(InpEnableDetailedLogs)
            Print("BLOCKED: TREND BUY - EURUSD excluded from Trend strategy");
         // Don't return - let it fall through to Momentum/Sideways
      }
      else
      {
      if(InpEnableDetailedLogs)
         Print("🔍 Evaluating: TREND BUY | UPTREND + RSI=", DoubleToString(rsi[0], 1), 
               " prev=", DoubleToString(rsi[1], 1), " | ADX=", DoubleToString(adx, 1));
      
      // ADX cap: Don't do mean reversion when trend is too strong (ADX > 45)
      if(InpMaxADXForMeanReversion > 0 && adx > InpMaxADXForMeanReversion)
      {
         if(InpEnableDetailedLogs)
            Print("BLOCKED: TREND BUY - ADX too high for mean reversion (", DoubleToString(adx, 1), " > ", InpMaxADXForMeanReversion, ")");
         LogSignalEvent("REJECT", "Trend_Buy", "ADXTooHigh", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
      }
      else
      {
      // === RSI CROSS-OVER MODE (v4.4): Wait for RSI to EXIT oversold zone ===
      // v4.2: Only checked rsi[1] → missed when RSI exits gradually over 2-3 bars
      // v4.4: Check rsi[1..N] lookback window for oversold, then confirm rsi[0] crossed back
      bool rsiEntryCondition = false;
      if(InpUseRSICrossOver)
      {
         int crossTarget = effectiveRSIOversold + InpRSICrossBuffer;  // e.g. 30 + 3 = 33
         
         // Check if ANY bar in lookback window was oversold
         bool wasOversold = false;
         int oversoldBar = -1;
         for(int lb = 1; lb <= InpRSICrossLookback; lb++)
         {
            if(rsi[lb] < effectiveRSIOversold)
            {
               wasOversold = true;
               oversoldBar = lb;
               break;  // Found most recent oversold bar
            }
         }
         
         rsiEntryCondition = (wasOversold && rsi[0] > crossTarget);
         
         if(InpEnableDetailedLogs)
         {
            if(wasOversold)
               Print("  RSI Cross-Over: rsi[", oversoldBar, "]=", DoubleToString(rsi[oversoldBar], 1), 
                     " was oversold | current=", DoubleToString(rsi[0], 1), 
                     " need >", crossTarget, " → ", (rsiEntryCondition ? "CONFIRMED" : "NOT YET"));
            else
               Print("  RSI Cross-Over: no oversold in last ", InpRSICrossLookback, 
                     " bars (closest=", DoubleToString(rsi[1], 1), ") → skip");
         }
      }
      else
      {
         // Legacy mode: enter while RSI is still oversold but turning up
         rsiEntryCondition = (rsi[0] < effectiveRSIOversold);
      }
      
      if(rsiEntryCondition)
      {
         // Volume check for Trend strategy (1.0x)
         if(!volumeOK_Trend)
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: TREND BUY vol too low (", (int)currentVolume, " vs ", (int)(avgVolume * InpVolumeMultiplier), ")");
            LogSignalEvent("REJECT", "Trend_Buy", "VolumeLow", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
         }
         else
         {
         // H1 Multi-Timeframe Confirmation
         if(!CheckH1TrendAlignment(true))
         {
            LogSignalEvent("REJECT", "Trend_Buy", "H1NotAligned", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
         }
         else
         {
         // RSI Confirmation (legacy mode only - cross-over already confirms direction)
         bool rsiConfirmed = InpUseRSICrossOver || !InpUseRSIConfirmation || (rsi[0] > rsi[1]);
         
         if(!rsiConfirmed)
         {
            if(InpEnableDetailedLogs)
               Print("WAITING: TREND BUY - RSI not reversing yet (RSI=", DoubleToString(rsi[0], 1), 
                     " prev=", DoubleToString(rsi[1], 1), ")");
            LogSignalEvent("WAIT", "Trend_Buy", "RSI not reversing", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
         }
         else
         {
         // Pattern Confirmation REQUIRED: Bullish Engulfing
         bool patternOK_buy = CheckCandlePattern(true, currentVolume, avgVolume);
         bool bypassPattern_buy = (!patternOK_buy && InpAllowOnCurrentBar);
         
         if(!patternOK_buy && !bypassPattern_buy)
         {
            if(InpEnableDetailedLogs)
               Print("WAITING: TREND BUY - No bullish engulfing pattern yet");
            LogSignalEvent("REJECT", "Trend_Buy", "PatternMissing", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
         }
         else
         {
            if(bypassPattern_buy && InpEnableDetailedLogs)
               Print("FORCED: TREND BUY - Pattern bypass due to InpAllowOnCurrentBar");
            if(InpEnableDetailedLogs)
               Print("✅ SIGNAL: TREND BUY (Uptrend + RSI ", (InpUseRSICrossOver ? "CrossOver" : "Reversal"), " + Pattern + H1)");
            _WriteLogLine("SIGNAL: TREND BUY | RSI=" + DoubleToString(rsi[0], 1)
                          + " | prev=" + DoubleToString(rsi[1], 1)
                          + " | ADX=" + DoubleToString(adx, 1)
                          + " | Vol=" + DoubleToString(currentVolume, 0) + "/" + DoubleToString(avgVolume, 0));
            LogSignalEvent("SIGNAL", "Trend_Buy", "Confirmed", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
            OpenPosition(true, GetStopLossPips(), GetTakeProfitPips(), "Trend_Buy", atr);
            return;
         }
         } // rsiConfirmed
         } // H1 aligned
         } // volume OK
      } // rsiEntryCondition
      } // ADX cap
      } // EURUSD filter
   }
   
   if(marketState == MARKET_DOWNTREND && InpAllowTrendingSell)
   {
      // EURUSD filter: skip Trend strategy for EUR
      bool isEURUSD_sell = (StringFind(_Symbol, "EUR") >= 0 && StringFind(_Symbol, "USD") >= 0);
      if(isEURUSD_sell && (InpExcludeEURUSD || InpEURUSDMomentumOnly))
      {
         if(InpEnableDetailedLogs)
            Print("BLOCKED: TREND SELL - EURUSD excluded from Trend strategy");
         // Don't return - let it fall through to Momentum/Sideways
      }
      else
      {
      if(InpEnableDetailedLogs)
         Print("🔍 Evaluating: TREND SELL | DOWNTREND + RSI=", DoubleToString(rsi[0], 1), 
               " prev=", DoubleToString(rsi[1], 1), " | ADX=", DoubleToString(adx, 1));
      
      // ADX cap: Don't do mean reversion when trend is too strong
      if(InpMaxADXForMeanReversion > 0 && adx > InpMaxADXForMeanReversion)
      {
         if(InpEnableDetailedLogs)
            Print("BLOCKED: TREND SELL - ADX too high for mean reversion (", DoubleToString(adx, 1), " > ", InpMaxADXForMeanReversion, ")");
         LogSignalEvent("REJECT", "Trend_Sell", "ADXTooHigh", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
      }
      else
      {
      // === RSI CROSS-OVER MODE (v4.4): Wait for RSI to EXIT overbought zone ===
      bool rsiEntryCondition_sell = false;
      if(InpUseRSICrossOver)
      {
         int crossTarget_sell = effectiveRSIOverbought - InpRSICrossBuffer;  // e.g. 70 - 3 = 67
         
         // Check if ANY bar in lookback window was overbought
         bool wasOverbought = false;
         int overboughtBar = -1;
         for(int lb = 1; lb <= InpRSICrossLookback; lb++)
         {
            if(rsi[lb] > effectiveRSIOverbought)
            {
               wasOverbought = true;
               overboughtBar = lb;
               break;  // Found most recent overbought bar
            }
         }
         
         rsiEntryCondition_sell = (wasOverbought && rsi[0] < crossTarget_sell);
         
         if(InpEnableDetailedLogs)
         {
            if(wasOverbought)
               Print("  RSI Cross-Over: rsi[", overboughtBar, "]=", DoubleToString(rsi[overboughtBar], 1), 
                     " was overbought | current=", DoubleToString(rsi[0], 1), 
                     " need <", crossTarget_sell, " → ", (rsiEntryCondition_sell ? "CONFIRMED" : "NOT YET"));
            else
               Print("  RSI Cross-Over: no overbought in last ", InpRSICrossLookback, 
                     " bars (closest=", DoubleToString(rsi[1], 1), ") → skip");
         }
      }
      else
      {
         // Legacy mode: enter while RSI is still overbought but turning down
         rsiEntryCondition_sell = (rsi[0] > effectiveRSIOverbought);
      }
      
      if(rsiEntryCondition_sell)
      {
         // Volume check for Trend strategy (1.0x)
         if(!volumeOK_Trend)
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: TREND SELL vol too low (", (int)currentVolume, " vs ", (int)(avgVolume * InpVolumeMultiplier), ")");
            LogSignalEvent("REJECT", "Trend_Sell", "VolumeLow", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
         }
         else
         {
         // H1 Multi-Timeframe Confirmation
         if(!CheckH1TrendAlignment(false))
         {
            LogSignalEvent("REJECT", "Trend_Sell", "H1NotAligned", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
         }
         else
         {
         // RSI Confirmation (legacy mode only - cross-over already confirms direction)
         bool rsiConfirmed_sell = InpUseRSICrossOver || !InpUseRSIConfirmation || (rsi[0] < rsi[1]);
         
         if(!rsiConfirmed_sell)
         {
            if(InpEnableDetailedLogs)
               Print("WAITING: TREND SELL - RSI not reversing yet (RSI=", DoubleToString(rsi[0], 1), 
                     " prev=", DoubleToString(rsi[1], 1), ")");
            LogSignalEvent("WAIT", "Trend_Sell", "RSI not reversing", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
         }
         else
         {
         // Pattern Confirmation REQUIRED: Bearish Engulfing
         bool patternOK_sell = CheckCandlePattern(false, currentVolume, avgVolume);
         bool bypassPattern_sell = (!patternOK_sell && InpAllowOnCurrentBar);
         
         if(!patternOK_sell && !bypassPattern_sell)
         {
            if(InpEnableDetailedLogs)
               Print("WAITING: TREND SELL - No bearish engulfing pattern yet");
            LogSignalEvent("REJECT", "Trend_Sell", "PatternMissing", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
         }
         else
         {
            if(bypassPattern_sell && InpEnableDetailedLogs)
               Print("FORCED: TREND SELL - Pattern bypass due to InpAllowOnCurrentBar");
            if(InpEnableDetailedLogs)
               Print("✅ SIGNAL: TREND SELL (Downtrend + RSI ", (InpUseRSICrossOver ? "CrossOver" : "Reversal"), " + Pattern + H1)");
            _WriteLogLine("SIGNAL: TREND SELL | RSI=" + DoubleToString(rsi[0], 1)
                          + " | prev=" + DoubleToString(rsi[1], 1)
                          + " | ADX=" + DoubleToString(adx, 1)
                          + " | Vol=" + DoubleToString(currentVolume, 0) + "/" + DoubleToString(avgVolume, 0));
            LogSignalEvent("SIGNAL", "Trend_Sell", "Confirmed", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
            OpenPosition(false, GetStopLossPips(), GetTakeProfitPips(), "Trend_Sell", atr);
            return;
         }
         } // rsiConfirmed_sell
         } // H1 aligned
         } // volume OK
      } // rsiEntryCondition_sell
      } // ADX cap
      } // EURUSD filter
   }
   
   // MOMENTUM SIGNALS (DI direction + Candle body size confirmation)
   if(InpAllowMomentumTrade && hasMomentum)
   {
      // EURUSD filter: block Momentum only if fully excluded (InpExcludeEURUSD)
      // InpEURUSDMomentumOnly=true means Momentum is ALLOWED for EURUSD
      bool isEURUSD_mom = (StringFind(_Symbol, "EUR") >= 0 && StringFind(_Symbol, "USD") >= 0);
      if(isEURUSD_mom && InpExcludeEURUSD)
      {
         if(InpEnableDetailedLogs)
            Print("BLOCKED: MOMENTUM - EURUSD fully excluded (InpExcludeEURUSD=true)");
      }
      else
      {
      // hasMomentum already guarantees: correct market state + RSI extreme + high volume + high ATR + DI direction
      // Signal phase only adds: H1 (optional), candle body size check
      
      // BUY: UPTREND momentum confirmed
      if(marketState == MARKET_UPTREND && InpAllowTrendingBuy)
      {
         // H1 Confirmation (optional, default OFF)
         if(InpMomentumRequireH1 && !CheckH1TrendAlignment(true))
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: MOMENTUM BUY - H1 not aligned");
            LogSignalEvent("REJECT", "Momentum_Buy", "H1NotAligned", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
            return;
         }
         
         // Candle body size check: last candle must be bullish AND body >= 50% ATR
         double lastOpen = iOpen(_Symbol, PERIOD_M15, 1);
         double lastClose = iClose(_Symbol, PERIOD_M15, 1);
         double lastHigh = iHigh(_Symbol, PERIOD_M15, 1);
         double lastLow = iLow(_Symbol, PERIOD_M15, 1);
         bool isBullishCandle = (lastClose > lastOpen);
         double bodySize = MathAbs(lastClose - lastOpen);
         bool isStrongBody = (bodySize >= atr * MOMENTUM_MIN_BODY_ATR);
         // Wick rejection: upper wick > 35% body = selling pressure, don't buy
         double upperWick = lastHigh - MathMax(lastOpen, lastClose);
         bool hasWickRejection = (bodySize > 0 && upperWick > bodySize * 0.35);
         
         // Pattern check (optional, default OFF) — if enabled, requires Engulfing/Pinbar
         if(InpMomentumRequirePattern && !CheckCandlePattern(true, currentVolume, avgVolume))
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: MOMENTUM BUY - No bullish candle pattern");
            LogSignalEvent("REJECT", "Momentum_Buy", "PatternMissing", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
            return;
         }
         else if(!InpMomentumRequirePattern)
         {
            if(!isBullishCandle)
            {
               if(InpEnableDetailedLogs)
                  Print("BLOCKED: MOMENTUM BUY - Last candle not bullish");
               LogSignalEvent("REJECT", "Momentum_Buy", "CandleDirection", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
               return;
            }
            if(!isStrongBody)
            {
               if(InpEnableDetailedLogs)
                  Print("BLOCKED: MOMENTUM BUY - Candle body too small (", DoubleToString(bodySize, _Digits), 
                        " < ", DoubleToString(atr * MOMENTUM_MIN_BODY_ATR, _Digits), " = 50% ATR)");
               LogSignalEvent("REJECT", "Momentum_Buy", "BodyTooSmall", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
               return;
            }
            if(hasWickRejection)
            {
               if(InpEnableDetailedLogs)
                  Print("BLOCKED: MOMENTUM BUY - Upper wick too long (", DoubleToString(upperWick/GetPipValue(), 1),
                        " pips > 35% body ", DoubleToString(bodySize/GetPipValue(), 1), " pips) = selling pressure");
               LogSignalEvent("REJECT", "Momentum_Buy", "WickRejection", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
               return;
            }
         }
         
         if(InpEnableDetailedLogs)
         {
            Print("⚡ MOMENTUM BUY CONFIRMED:");
            Print("  RSI: ", DoubleToString(rsi[0], 1), " (>", effectiveRSIOverbought, ")");
            Print("  Volume: ", DoubleToString(currentVolume/avgVolume, 2), "x avg (HIGH)");
            Print("  ATR: ", DoubleToString(atr/avgATR, 2), "x avg (HIGH)");
            Print("  DI+: ", DoubleToString(diPlus, 1), " > DI-: ", DoubleToString(diMinus, 1), " ✅");
            Print("  Candle Body: ", DoubleToString(bodySize/GetPipValue(), 1), " pips (", DoubleToString(bodySize/atr*100, 0), "% ATR) ✅");
         }
         LogSignalEvent("SIGNAL", "Momentum_Buy", "MomentumConfirmed", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
         _WriteLogLine("SIGNAL: MOMENTUM BUY | RSI=" + DoubleToString(rsi[0], 1)
                       + " | Vol=" + DoubleToString(currentVolume/avgVolume, 2) + "x"
                       + " | ATR=" + DoubleToString(atr/avgATR, 2) + "x"
                       + " | DI+=" + DoubleToString(diPlus, 1) + " DI-=" + DoubleToString(diMinus, 1));
         OpenPosition(true, GetMomentumStopLossPips(), GetMomentumTakeProfitPips(), "Momentum_Buy", atr);
         return;
      }
      
      // SELL: DOWNTREND momentum confirmed
      if(marketState == MARKET_DOWNTREND && InpAllowTrendingSell)
      {
         // H1 Confirmation (optional, default OFF)
         if(InpMomentumRequireH1 && !CheckH1TrendAlignment(false))
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: MOMENTUM SELL - H1 not aligned");
            LogSignalEvent("REJECT", "Momentum_Sell", "H1NotAligned", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
            return;
         }
         
         // Candle body size check: last candle must be bearish AND body >= 50% ATR
         double lastOpen = iOpen(_Symbol, PERIOD_M15, 1);
         double lastClose = iClose(_Symbol, PERIOD_M15, 1);
         double lastHigh = iHigh(_Symbol, PERIOD_M15, 1);
         double lastLow = iLow(_Symbol, PERIOD_M15, 1);
         bool isBearishCandle = (lastClose < lastOpen);
         double bodySize = MathAbs(lastClose - lastOpen);
         bool isStrongBody = (bodySize >= atr * MOMENTUM_MIN_BODY_ATR);
         // Wick rejection: lower wick > 35% body = buying pressure, don't sell
         double lowerWick = MathMin(lastOpen, lastClose) - lastLow;
         bool hasWickRejection = (bodySize > 0 && lowerWick > bodySize * 0.35);
         
         // Pattern check (optional, default OFF)
         if(InpMomentumRequirePattern && !CheckCandlePattern(false, currentVolume, avgVolume))
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: MOMENTUM SELL - No bearish candle pattern");
            LogSignalEvent("REJECT", "Momentum_Sell", "PatternMissing", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
            return;
         }
         else if(!InpMomentumRequirePattern)
         {
            if(!isBearishCandle)
            {
               if(InpEnableDetailedLogs)
                  Print("BLOCKED: MOMENTUM SELL - Last candle not bearish");
               LogSignalEvent("REJECT", "Momentum_Sell", "CandleDirection", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
               return;
            }
            if(!isStrongBody)
            {
               if(InpEnableDetailedLogs)
                  Print("BLOCKED: MOMENTUM SELL - Candle body too small (", DoubleToString(bodySize, _Digits),
                        " < ", DoubleToString(atr * MOMENTUM_MIN_BODY_ATR, _Digits), " = 50% ATR)");
               LogSignalEvent("REJECT", "Momentum_Sell", "BodyTooSmall", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
               return;
            }
            if(hasWickRejection)
            {
               if(InpEnableDetailedLogs)
                  Print("BLOCKED: MOMENTUM SELL - Lower wick too long (", DoubleToString(lowerWick/GetPipValue(), 1),
                        " pips > 35% body ", DoubleToString(bodySize/GetPipValue(), 1), " pips) = buying pressure");
               LogSignalEvent("REJECT", "Momentum_Sell", "WickRejection", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
               return;
            }
         }
         
         if(InpEnableDetailedLogs)
         {
            Print("⚡ MOMENTUM SELL CONFIRMED:");
            Print("  RSI: ", DoubleToString(rsi[0], 1), " (< ", effectiveRSIOversold, ")");
            Print("  Volume: ", DoubleToString(currentVolume/avgVolume, 2), "x avg (HIGH)");
            Print("  ATR: ", DoubleToString(atr/avgATR, 2), "x avg (HIGH)");
            Print("  DI-: ", DoubleToString(diMinus, 1), " > DI+: ", DoubleToString(diPlus, 1), " ✅");
            Print("  Candle Body: ", DoubleToString(bodySize/GetPipValue(), 1), " pips (", DoubleToString(bodySize/atr*100, 0), "% ATR) ✅");
         }
         LogSignalEvent("SIGNAL", "Momentum_Sell", "MomentumConfirmed", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
         _WriteLogLine("SIGNAL: MOMENTUM SELL | RSI=" + DoubleToString(rsi[0], 1)
                       + " | Vol=" + DoubleToString(currentVolume/avgVolume, 2) + "x"
                       + " | ATR=" + DoubleToString(atr/avgATR, 2) + "x"
                       + " | DI+=" + DoubleToString(diPlus, 1) + " DI-=" + DoubleToString(diMinus, 1));
         OpenPosition(false, GetMomentumStopLossPips(), GetMomentumTakeProfitPips(), "Momentum_Sell", atr);
         return;
      }
   } // EURUSD Momentum filter
   }
   
   // SIDEWAYS SIGNALS (Range Trading with Boundary Confirmation)
   if(marketState == MARKET_SIDEWAYS && InpAllowSidewayTrade)
   {
      // EURUSD filter: block Sideways if EUR restricted to Momentum only
      bool isEURUSD_sw = (StringFind(_Symbol, "EUR") >= 0 && StringFind(_Symbol, "USD") >= 0);
      if(isEURUSD_sw && (InpExcludeEURUSD || InpEURUSDMomentumOnly))
      {
         if(InpEnableDetailedLogs)
            Print("BLOCKED: SIDEWAYS - EURUSD excluded from Sideways strategy");
      }
      else
      {
      if(InpEnableDetailedLogs)
         Print("🔍 Evaluating: SIDEWAYS RANGE | ADX=", DoubleToString(adx, 1), " RSI=", DoubleToString(rsi[0], 1));
      
      // Sideways-specific RSI levels (40/60 - realistic for range market)
      int lowerBound = InpSidewayRSIOversold;   // 40
      int upperBound = InpSidewayRSIOverbought;  // 60
      
      // Calculate recent range using H4 for better range detection
      ENUM_TIMEFRAMES rangeTimeframe = PERIOD_H4;
      int highestBar = iHighest(_Symbol, rangeTimeframe, MODE_HIGH, InpSidewayRangePeriod, 0);
      int lowestBar = iLowest(_Symbol, rangeTimeframe, MODE_LOW, InpSidewayRangePeriod, 0);
      
      double rangeHigh = iHigh(_Symbol, rangeTimeframe, highestBar);
      double rangeLow = iLow(_Symbol, rangeTimeframe, lowestBar);
      double rangeSize = (rangeHigh - rangeLow) / GetPipValue();
      
      if(InpEnableDetailedLogs)
      {
         Print("  Sideways Range: Low=", DoubleToString(rangeLow, _Digits), " High=", DoubleToString(rangeHigh, _Digits),
               " Size=", DoubleToString(rangeSize, 0), " pips (min=", InpSidewayMinRangePips, ")");
         Print("  Price=", DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits),
               " | Dist from Low=", DoubleToString((SymbolInfoDouble(_Symbol, SYMBOL_BID) - rangeLow) / GetPipValue(), 1), " pips",
               " | Dist from High=", DoubleToString((rangeHigh - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / GetPipValue(), 1), " pips");
         Print("  RSI Zone: ", DoubleToString(rsi[0], 1), " (Buy<", lowerBound, " | Sell>", upperBound, ")");
      }
      
      // Filter 1: Check if range is large enough to trade
      if(rangeSize < InpSidewayMinRangePips)
      {
         if(InpEnableDetailedLogs)
            Print("NO SIGNAL: Range too small (", DoubleToString(rangeSize, 0), 
                  " pips < ", InpSidewayMinRangePips, ")");
         return;
      }
      
      double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double distanceFromLow = (currentPrice - rangeLow) / GetPipValue();
      double distanceFromHigh = (rangeHigh - currentPrice) / GetPipValue();
      
      // Dynamic boundary distance: use percentage of range OR fixed pips, whichever is larger
      double dynamicBoundaryPips = rangeSize * (InpSidewayBoundaryPercent / 100.0);
      double effectiveBoundary = MathMax(dynamicBoundaryPips, (double)InpSidewayMaxDistanceToBoundary);
      
      if(InpEnableDetailedLogs)
         Print("  Boundary Filter: dynamic=", DoubleToString(dynamicBoundaryPips, 1), 
               " pips (", InpSidewayBoundaryPercent, "% of range) | fixed=", InpSidewayMaxDistanceToBoundary,
               " | effective=", DoubleToString(effectiveBoundary, 1), " pips");
      
      // BUY when RSI hits lower bound (oversold in range)
      if(rsi[0] < lowerBound)
      {
         // Volume check for Sideways strategy (0.8x — lower threshold)
         if(!volumeOK_Sideways)
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: SIDEWAYS BUY vol too low (", (int)currentVolume, " vs ", (int)(avgVolume * InpSidewayVolumeMultiplier), ")");
            return;
         }
         
         // Filter 1: Must be near range bottom (support) - dynamic boundary
         if(distanceFromLow > effectiveBoundary)
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: Sideways BUY too far from support (", 
                     DoubleToString(distanceFromLow, 1), " pips from low, max=", DoubleToString(effectiveBoundary, 1), ")");
            return;
         }
         
         // Filter 2: Price rejection OR candlestick pattern (need at least one)
         bool hasRejection = CheckPriceRejection(true, rangeLow, rangeHigh);
         bool hasPattern = CheckCandlePattern(true, currentVolume, avgVolume);
         
         if(!hasRejection && !hasPattern)
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: Sideways BUY - no price rejection AND no candle pattern");
            return;
         }
         
         // Filter 3: RSI Confirmation (must be turning up)
         bool rsiConfirmed = !InpUseRSIConfirmation || (rsi[0] > rsi[1]);
         
         if(!rsiConfirmed)
         {
            if(InpEnableDetailedLogs)
               Print("WAITING: Sideways BUY but RSI not confirmed");
            return;
         }
         
         if(InpEnableDetailedLogs)
         {
            Print("✅ SIGNAL: SIDEWAYS BUY - DOUBLE CONFIRMED");
            Print("  RSI: ", DoubleToString(rsi[0], 1), " < ", lowerBound);
            Print("  Range: ", DoubleToString(rangeLow, _Digits), " - ", DoubleToString(rangeHigh, _Digits), 
                  " (", DoubleToString(rangeSize, 0), " pips)");
            Print("  Distance from support: ", DoubleToString(distanceFromLow, 1), " pips");
            Print("  Price rejection: CONFIRMED");
         }
         
         LogSignalEvent("SIGNAL", "Sideway_Buy", "Confirmed", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
         _WriteLogLine("SIGNAL: SIDEWAYS BUY | RSI=" + DoubleToString(rsi[0], 1)
                       + " | Range: " + DoubleToString(rangeLow, _Digits) + "-" + DoubleToString(rangeHigh, _Digits)
                       + " | Dist support: " + DoubleToString(distanceFromLow, 1) + " pips");
         OpenPosition(true, GetSidewayStopLossPips(), GetSidewayTakeProfitPips(), "Sideway_Buy", atr);
         return;
      }
      
      // SELL when RSI hits upper bound (overbought in range)
      if(rsi[0] > upperBound)
      {
         // Volume check for Sideways strategy (0.8x — lower threshold)
         if(!volumeOK_Sideways)
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: SIDEWAYS SELL vol too low (", (int)currentVolume, " vs ", (int)(avgVolume * InpSidewayVolumeMultiplier), ")");
            return;
         }
         
         // Filter 1: Must be near range top (resistance) - dynamic boundary
         if(distanceFromHigh > effectiveBoundary)
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: Sideways SELL too far from resistance (", 
                     DoubleToString(distanceFromHigh, 1), " pips from high, max=", DoubleToString(effectiveBoundary, 1), ")");
            return;
         }
         
         // Filter 2: Price rejection OR candlestick pattern (need at least one)
         bool hasRejection = CheckPriceRejection(false, rangeLow, rangeHigh);
         bool hasPattern = CheckCandlePattern(false, currentVolume, avgVolume);
         
         if(!hasRejection && !hasPattern)
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: Sideways SELL - no price rejection AND no candle pattern");
            return;
         }
         
         // Filter 3: RSI Confirmation (must be turning down)
         bool rsiConfirmed = !InpUseRSIConfirmation || (rsi[0] < rsi[1]);
         
         if(!rsiConfirmed)
         {
            if(InpEnableDetailedLogs)
               Print("WAITING: Sideways SELL but RSI not confirmed");
            return;
         }
         
         if(InpEnableDetailedLogs)
         {
            Print("✅ SIGNAL: SIDEWAYS SELL - DOUBLE CONFIRMED");
            Print("  RSI: ", DoubleToString(rsi[0], 1), " > ", upperBound);
            Print("  Range: ", DoubleToString(rangeLow, _Digits), " - ", DoubleToString(rangeHigh, _Digits), 
                  " (", DoubleToString(rangeSize, 0), " pips)");
            Print("  Distance from resistance: ", DoubleToString(distanceFromHigh, 1), " pips");
            Print("  Price rejection: CONFIRMED");
         }
         
         LogSignalEvent("SIGNAL", "Sideway_Sell", "Confirmed", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
         _WriteLogLine("SIGNAL: SIDEWAYS SELL | RSI=" + DoubleToString(rsi[0], 1)
                       + " | Range: " + DoubleToString(rangeLow, _Digits) + "-" + DoubleToString(rangeHigh, _Digits)
                       + " | Dist resistance: " + DoubleToString(distanceFromHigh, 1) + " pips");
         OpenPosition(false, GetSidewayStopLossPips(), GetSidewayTakeProfitPips(), "Sideway_Sell", atr);
         return;
      }
   } // EURUSD Sideways filter
   }
   
   if(InpEnableDetailedLogs)
   {
      Print("NO SIGNAL: Market=", marketStateStr, " | RSI=", DoubleToString(rsi[0], 1), 
            " | ADX=", DoubleToString(adx, 1));
   }
   LogSignalEvent("NO_SIGNAL", "NoTrade", "MarketStateNoSignal", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
}

//+------------------------------------------------------------------+
double CalculateLotSize(double entryPrice, int slPips)
{
   double balance = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // === SAFETY: Validate critical inputs ===
   if(balance <= 0)
   {
      Print("🛑 BLOCKED: Invalid equity (", DoubleToString(balance, 2), ") - cannot calculate lot size");
      return -1;
   }
   if(slPips <= 0)
   {
      Print("🛑 BLOCKED: Invalid SL pips (", slPips, ") - must be > 0");
      return -1;
   }
   if(entryPrice <= 0)
   {
      Print("🛑 BLOCKED: Invalid entry price (", DoubleToString(entryPrice, _Digits), ")");
      return -1;
   }
   
   // Get broker constraints
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double pipValue = GetPipValue();
   string symbol = _Symbol;
   
   if(pipValue <= 0)
   {
      Print("🛑 BLOCKED: GetPipValue() returned ", pipValue, " - cannot calculate lot size");
      return -1;
   }
   
   // ================================================================
   // SMALL ACCOUNT MODE: Equity < $300 → use broker minimum lot
   // No risk% calculation - just trade with min lot (typically 0.01)
   // SL/TP stays at full values (50/100 pips)
   // ================================================================
   if(IsSmallAccount())
   {
      double smallLot = minLot;
      
      // For slightly larger small accounts ($100-299), allow 2x min lot
      if(balance >= 100.0)
         smallLot = minLot * 2;
      if(balance >= 200.0)
         smallLot = minLot * 3;
      
      // Normalize to lot step
      smallLot = MathFloor(smallLot / lotStep) * lotStep;
      
      // Cap at broker min/max
      if(smallLot < minLot) smallLot = minLot;
      if(smallLot > maxLot) smallLot = maxLot;
      
      // Apply user max lot cap
      if(InpMaxLotSize > 0 && smallLot > InpMaxLotSize)
         smallLot = InpMaxLotSize;
      
      if(InpEnableDetailedLogs)
      {
         Print("═══════════════════════════════════");
         Print("LOT SIZE: SMALL ACCOUNT MODE");
         Print("  Equity: $", DoubleToString(balance, 2), " (< $", DoubleToString(InpRiskBasedThreshold, 0), ")");
         Print("  Lot: ", DoubleToString(smallLot, 2), " (min lot based, no risk%)");
         Print("  SL: ", slPips, " pips | SL/TP at full value (no scaling)");
         Print("═══════════════════════════════════");
      }
      
      return NormalizeDouble(smallLot, 2);
   }
   
   // ================================================================
   // RISK-BASED MODE: Equity >= $300 → use risk% lot sizing
   // ================================================================
   double effectiveRisk = InpPositionSizePercent;
   double riskAmountUSD = balance * (effectiveRisk / 100.0);
   
   // ==================================================================
   // Calculate money per pip per lot using OrderCalcProfit()
   // This is 100% accurate for ALL account types (USD, cent, micro)
   // Because it uses broker's internal calculation
   // ==================================================================
   double moneyPerPipPerLot = 0;
   
   // Method 1: OrderCalcProfit (most reliable - works for any account type)
   double profitBuy = 0, profitSell = 0;
   bool calcOK = false;
   
   if(OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, entryPrice, entryPrice + pipValue, profitBuy))
   {
      moneyPerPipPerLot = MathAbs(profitBuy);
      calcOK = true;
   }
   else if(OrderCalcProfit(ORDER_TYPE_SELL, _Symbol, 1.0, entryPrice, entryPrice - pipValue, profitSell))
   {
      moneyPerPipPerLot = MathAbs(profitSell);
      calcOK = true;
   }
   
   // If OrderCalcProfit fails, SKIP the trade instead of using unreliable fallback
   // This prevents wrong lot size calculation (e.g., 1.5 lot instead of 0.22)
   // Common at market open when prices aren't fully loaded yet
   if(!calcOK || moneyPerPipPerLot <= 0)
   {
      Print("🛑 OrderCalcProfit() FAILED - cannot calculate accurate lot size");
      Print("   Skipping trade to prevent incorrect position sizing");
      Print("   Will retry on next signal when market data is available");
      return -1;  // Signal to caller: do not trade
   }
   
   // Sanity check: moneyPerPipPerLot must be reasonable
   // If too small, lot size becomes astronomically large → overleveraging
   double expectedLot = riskAmountUSD / (slPips * moneyPerPipPerLot);
   if(expectedLot > maxLot * 10)
   {
      Print("🛑 BLOCKED: moneyPerPipPerLot (", DoubleToString(moneyPerPipPerLot, 6), 
            ") seems wrong - calculated lot would be ", DoubleToString(expectedLot, 2),
            " (>", DoubleToString(maxLot * 10, 0), ")");
      Print("   This likely indicates incorrect broker data. Trade skipped.");
      return -1;
   }
   
   // ==================================================================
   // Calculate lot size: Risk = SL pips × $ per pip × lot size
   // ==================================================================
   double lotSize = riskAmountUSD / (slPips * moneyPerPipPerLot);
   
   // ==================================================================
   // DYNAMIC MAX LOT: Scale with equity to prevent overleveraging
   // Small equity gets small max lot, large equity allows bigger lot
   // This prevents scenarios like $300 account opening 1.5 lot
   // ==================================================================
   double dynamicMaxLot = maxLot; // Start with broker max
   
   // Dynamic cap: max lot scales linearly with equity
   // $300 → 0.15, $500 → 0.25, $1000 → 0.50, $5000 → 2.50, $10000 → 5.0
   double equityBasedMax = balance / 2000.0;
   equityBasedMax = MathFloor(equityBasedMax / lotStep) * lotStep;
   if(equityBasedMax < minLot) equityBasedMax = minLot;
   
   // Use the SMALLER of: user cap, equity-based cap
   if(InpMaxLotSize > 0)
      dynamicMaxLot = MathMin(InpMaxLotSize, equityBasedMax);
   else
      dynamicMaxLot = equityBasedMax;
   
   if(lotSize > dynamicMaxLot)
   {
      if(InpEnableDetailedLogs)
         Print("⚠️ Lot size capped: ", DoubleToString(lotSize,2), " → ", DoubleToString(dynamicMaxLot,2),
               " (equity-based max: ", DoubleToString(equityBasedMax,2),
               " | user max: ", (InpMaxLotSize > 0 ? DoubleToString(InpMaxLotSize,2) : "none"), ")");
      lotSize = dynamicMaxLot;
   }
   
   // Normalize to broker's lot step
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   
   // Apply broker min/max constraints
   if(lotSize < minLot) 
   {
      lotSize = minLot;
      if(InpEnableDetailedLogs)
         Print("⚠️ Lot size below minimum, using: ", minLot);
   }
   
   if(lotSize > maxLot)
   {
      lotSize = maxLot;
      if(InpEnableDetailedLogs)
         Print("⚠️ Lot size above maximum, capped at: ", maxLot);
   }
   
   // Additional safety: Never risk more than InpMaxSafetyPercent% even if user sets higher
   double maxRiskAmount = balance * (InpMaxSafetyPercent / 100.0); // Configurable hard limit
   double actualRiskAmount = lotSize * slPips * moneyPerPipPerLot;
   
   if(actualRiskAmount > maxRiskAmount)
   {
      double safeLotSize = maxRiskAmount / (slPips * moneyPerPipPerLot);
      safeLotSize = MathFloor(safeLotSize / lotStep) * lotStep;
      
      // If safe lot < min lot, check if min lot risk is still acceptable
      if(safeLotSize < minLot)
      {
         double minLotRisk = minLot * slPips * moneyPerPipPerLot;
         double minLotRiskPct = (minLotRisk / balance) * 100.0;
         
         // BLOCK trade if min lot risks more than safety limit
         // This prevents Gold/expensive instruments from blowing small/cent accounts
         if(minLotRiskPct > InpMaxSafetyPercent)
         {
            Print("🛑 BLOCKED: Even min lot ", DoubleToString(minLot,2), 
                  " risks ", DoubleToString(minLotRiskPct,1), "% of equity (",
                  DoubleToString(minLotRisk,2), " / ", DoubleToString(balance,2), ")");
            Print("   Max allowed: ", DoubleToString(InpMaxSafetyPercent,1), 
                  "% | This symbol is too expensive for current balance");
            Print("   → Trade CANCELLED. Increase balance or trade cheaper instrument.");
            return -1;  // Signal to caller: do not trade
         }
         
         // Min lot risk is within safety limit - allow with warning
         Print("⚠️ MIN LOT MODE: ", DoubleToString(minLot,2), 
               " lot risks ", DoubleToString(minLotRiskPct,1), "% (",
               DoubleToString(minLotRisk,2), " of ", DoubleToString(balance,2), ")");
         safeLotSize = minLot;
      }
      else
      {
         Print("🛑 SAFETY LIMIT: Risk $", DoubleToString(actualRiskAmount,2), 
               " exceeds ", DoubleToString(InpMaxSafetyPercent,1), "% max ($", DoubleToString(maxRiskAmount,2), ")");
         Print("   Reducing lot: ", DoubleToString(lotSize,2), " → ", DoubleToString(safeLotSize,2));
      }
      
      lotSize = safeLotSize;
   }
   
   if(InpEnableDetailedLogs)
   {
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      
      Print("═══════════════════════════════════");
      Print("LOT SIZE CALCULATION:");
      Print("  Symbol: ", _Symbol);
      Print("  Balance: $", DoubleToString(balance, 2));
      Print("  Risk %: ", InpPositionSizePercent, "% = $", DoubleToString(riskAmountUSD, 2));
      Print("  ---");
      Print("  Broker Contract Size: ", DoubleToString(contractSize, 0), " units");
      Print("  Tick Size: ", DoubleToString(tickSize, _Digits));
      Print("  Tick Value: $", DoubleToString(tickValue, 2));
      Print("  Pip Value: ", DoubleToString(pipValue, _Digits));
      Print("  ---");
      Print("  $ per pip (1 lot): $", DoubleToString(moneyPerPipPerLot, 3));
      Print("  SL Pips: ", slPips);
      Print("  Calculated Lot: ", DoubleToString(lotSize, 2));
      Print("  ---");
      Print("  VERIFICATION:");
      Print("    Actual Risk = Lot × SL × $/pip");
      Print("               = ", DoubleToString(lotSize,2), " × ", slPips, " × $", DoubleToString(moneyPerPipPerLot,3));
      Print("               = $", DoubleToString(lotSize * slPips * moneyPerPipPerLot, 2));
      Print("    Target Risk = $", DoubleToString(riskAmountUSD, 2));
      Print("    Difference = ", DoubleToString(MathAbs(lotSize * slPips * moneyPerPipPerLot - riskAmountUSD), 2));
      Print("  ---");
      Print("  Min/Max Broker Lot: ", minLot, "/", maxLot);
      Print("  Dynamic Max Lot: ", DoubleToString(dynamicMaxLot, 2), 
            " (equity-based: ", DoubleToString(equityBasedMax, 2),
            " | user cap: ", (InpMaxLotSize > 0 ? DoubleToString(InpMaxLotSize,2) : "none"), ")");
      Print("═══════════════════════════════════");
   }
   
   return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
void OpenPosition(bool isBuy, int slPips, int tpPips, string comment, double currentATR = 0)
{
   // v4.5: ATR-based SL/TP (auto-adapts per symbol volatility)
   int effectiveSL = slPips;
   int effectiveTP = tpPips;
   if(InpUseATRBasedSL && currentATR > 0)
   {
      int atrSL = GetATRBasedSLPips(currentATR);
      if(atrSL > 0)
      {
         effectiveSL = atrSL;
         effectiveTP = GetATRBasedTPPips(atrSL);
         if(InpEnableDetailedLogs)
            Print("  ATR-Based SL/TP: ATR=", DoubleToString(currentATR, _Digits), 
                  " | SL=", effectiveSL, " pips (was ", slPips, ") | TP=", effectiveTP, 
                  " pips (was ", tpPips, ") | R:R=1:", DoubleToString(InpATRTPRatio, 1));
      }
   }
   
   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = CalculateLotSize(price, effectiveSL);
   
   // CalculateLotSize returns -1 if even min lot is too risky for current balance
   if(lot < 0)
   {
      Print("TRADE CANCELLED: Lot sizing returned -1 (instrument too expensive for balance)");
      LogTradeEvent("CANCEL", comment, isBuy, price, 0, 0, 0, -1, 0);
      return;
   }
   
   // ================================================================
   // MARGIN SAFETY CHECK: Universal protection for all account types
   // Uses broker's OrderCalcMargin() — accurate for cent/micro/standard
   // ================================================================
   if(InpMaxMarginPercent > 0)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      double marginRequired = 0;
      ENUM_ORDER_TYPE orderType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      
      if(OrderCalcMargin(orderType, _Symbol, lot, price, marginRequired))
      {
         double marginPercent = (equity > 0) ? (marginRequired / equity * 100.0) : 100.0;
         
         if(marginPercent > InpMaxMarginPercent)
         {
            // Auto-reduce lot to fit within max margin %
            double maxMarginAllowed = equity * (InpMaxMarginPercent / 100.0);
            double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            
            // Estimate reduced lot proportionally
            double reducedLot = lot * (maxMarginAllowed / marginRequired);
            reducedLot = MathFloor(reducedLot / lotStep) * lotStep;
            
            if(reducedLot < minLot)
            {
               // Even min lot exceeds margin limit — check if we can afford it
               double minMargin = 0;
               if(OrderCalcMargin(orderType, _Symbol, minLot, price, minMargin))
               {
                  double minMarginPct = (equity > 0) ? (minMargin / equity * 100.0) : 100.0;
                  if(minMarginPct > 50.0)  // Hard limit: min lot uses >50% margin
                  {
                     Print("BLOCKED: Min lot margin ", DoubleToString(minMarginPct, 1), 
                           "% exceeds 50% of equity. Trade cancelled.");
                     LogTradeEvent("CANCEL", comment, isBuy, price, 0, 0, minLot, -1, 0);
                     return;
                  }
               }
               reducedLot = minLot;
            }
            
            Print("⚠️ MARGIN SAFETY: Lot reduced ", DoubleToString(lot, 2), " → ", DoubleToString(reducedLot, 2),
                  " (margin ", DoubleToString(marginPercent, 1), "% > max ", DoubleToString(InpMaxMarginPercent, 1), "%)");
            Print("   Margin required: ", DoubleToString(marginRequired, 2), 
                  " | Free margin: ", DoubleToString(freeMargin, 2),
                  " | Equity: ", DoubleToString(equity, 2));
            lot = reducedLot;
         }
         else if(InpEnableDetailedLogs)
         {
            Print("MARGIN CHECK OK: ", DoubleToString(marginPercent, 1), "% of equity",
                  " (required: ", DoubleToString(marginRequired, 2),
                  " | free: ", DoubleToString(freeMargin, 2), ")");
         }
      }
      else
      {
         Print("WARNING: OrderCalcMargin failed, proceeding with calculated lot");
      }
   }
   
   double sl, tp;
   
   CalculateSLTP_FixedPips(price, isBuy, effectiveSL, effectiveTP, sl, tp);
   
   Print("====================================");
   Print("OPENING ", isBuy ? "BUY" : "SELL", " - ", _Symbol);
   Print("Type: ", comment);
   Print("Entry: ", price, " | SL: ", sl, " | TP: ", tp, " | Lot: ", lot);
   Print("====================================");
   _WriteLogLine("OPENING " + (isBuy ? "BUY" : "SELL") + " | " + _Symbol
                 + " | Type: " + comment
                 + " | Entry: " + DoubleToString(price, _Digits)
                 + " | SL: " + DoubleToString(sl, _Digits)
                 + " | TP: " + DoubleToString(tp, _Digits)
                 + " | Lot: " + DoubleToString(lot, 2));
   
   // Validation
   if(isBuy && (sl >= price || tp <= price))
   {
      Print("ERROR: Invalid BUY SL/TP! Cancelled.");
      LogTradeEvent("CANCEL", comment, isBuy, price, sl, tp, lot, -1, 0);
      return;
   }
   
   if(!isBuy && (sl <= price || tp >= price))
   {
      Print("ERROR: Invalid SELL SL/TP! Cancelled.");
      LogTradeEvent("CANCEL", comment, isBuy, price, sl, tp, lot, -1, 0);
      return;
   }
   
   // LOG: attempt
   LogTradeEvent("ATTEMPT", comment, isBuy, price, sl, tp, lot, -1, 0);
   
   bool result = false;
   if(isBuy)
      result = trade.Buy(lot, _Symbol, 0, sl, tp, comment);
   else
      result = trade.Sell(lot, _Symbol, 0, sl, tp, comment);
   
   if(result)
   {
      Print("SUCCESS: Order placed | Ticket: ", trade.ResultOrder());
      _WriteLogLine("SUCCESS: Ticket #" + IntegerToString((long)trade.ResultOrder()) + " | " + comment
                    + " | " + (isBuy ? "BUY" : "SELL") + " " + DoubleToString(lot, 2) + " lot"
                    + " | Entry: " + DoubleToString(price, _Digits)
                    + " | SL: " + DoubleToString(sl, _Digits)
                    + " | TP: " + DoubleToString(tp, _Digits));
      LogTradeEvent("SUCCESS", comment, isBuy, price, sl, tp, lot, trade.ResultRetcode(), trade.ResultOrder());
      g_lastTradeTime = TimeCurrent();
      g_dailyTradeCount++;  // v4.5: Increment daily counter
   }
   else
   {
      Print("FAILED: Error ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      _WriteLogLine("FAILED: " + comment + " | Error " + IntegerToString(trade.ResultRetcode())
                    + " - " + trade.ResultRetcodeDescription());
      LogTradeEvent("FAILED", comment, isBuy, price, sl, tp, lot, trade.ResultRetcode(), 0);
   }
}

//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   double pipValue = GetPipValue();
   if(pipValue <= 0)
   {
      Print("ERROR: GetPipValue() returned 0 in ManageOpenPositions - skipping");
      return;
   }
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // Get current ATR for adaptive trailing
   double currentATR = 0;
   if(InpUseATRTrailing)
   {
      double atrBuffer[];
      ArraySetAsSeries(atrBuffer, true);
      if(CopyBuffer(g_handleATR, 0, 0, 1, atrBuffer) > 0)
         currentATR = atrBuffer[0];
   }
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || 
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      double currentPrice = (posType == POSITION_TYPE_BUY) ? 
                           SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                           SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      double profitPips = 0;
      if(posType == POSITION_TYPE_BUY)
         profitPips = (currentPrice - openPrice) / pipValue;
      else
         profitPips = (openPrice - currentPrice) / pipValue;
      
      // ================================================================
      // STALE POSITION EXIT (MOMENTUM ONLY): Close if price can't
      // break entry candle after 3 bars. Exception: if all 3 bars
      // confirm direction (all bearish for SELL, all bullish for BUY)
      // → momentum still alive, keep position.
      // ================================================================
      string posComment = PositionGetString(POSITION_COMMENT);
      bool isMomentumTrade = (StringFind(posComment, "Momentum") >= 0);
      
      if(isMomentumTrade)
      {
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         int entryBarIndex = iBarShift(_Symbol, PERIOD_M15, openTime);
         
         // Only check if at least 3 full bars have completed after entry
         if(entryBarIndex >= 4)  // bar 0=current, 1-3=completed after entry, 4+=entry bar
         {
            double entryHigh = iHigh(_Symbol, PERIOD_M15, entryBarIndex);
            double entryLow  = iLow(_Symbol, PERIOD_M15, entryBarIndex);
            
            // Check if any of the 3 bars after entry broke the level
            bool hasBroken = false;
            // Check if all 3 bars confirm direction
            int confirmCount = 0;
            
            for(int b = entryBarIndex - 1; b >= entryBarIndex - 3 && b >= 1; b--)
            {
               double bOpen = iOpen(_Symbol, PERIOD_M15, b);
               double bClose = iClose(_Symbol, PERIOD_M15, b);
               
               if(posType == POSITION_TYPE_BUY)
               {
                  if(iHigh(_Symbol, PERIOD_M15, b) > entryHigh)
                     hasBroken = true;
                  if(bClose > bOpen)  // bullish candle
                     confirmCount++;
               }
               if(posType == POSITION_TYPE_SELL)
               {
                  if(iLow(_Symbol, PERIOD_M15, b) < entryLow)
                     hasBroken = true;
                  if(bClose < bOpen)  // bearish candle
                     confirmCount++;
               }
            }
            
            // All 3 candles confirm direction → momentum still alive, keep
            bool allConfirm = (confirmCount >= 3);
            
            if(!hasBroken && !allConfirm)
            {
               if(InpEnableDetailedLogs)
               {
                  Print("⏰ STALE EXIT: Ticket #", ticket, 
                        " | ", (posType == POSITION_TYPE_BUY ? "BUY" : "SELL"),
                        " | 3 bars passed, price didn't break entry candle ",
                        (posType == POSITION_TYPE_BUY ? "high " : "low "),
                        DoubleToString(posType == POSITION_TYPE_BUY ? entryHigh : entryLow, digits),
                        " | Confirm candles: ", confirmCount, "/3",
                        " | P/L: ", DoubleToString(profitPips, 1), " pips");
               }
               _WriteLogLine("STALE EXIT: Ticket #" + IntegerToString((long)ticket)
                             + " | " + (posType == POSITION_TYPE_BUY ? "BUY" : "SELL")
                             + " | P/L: " + DoubleToString(profitPips, 1) + " pips"
                             + " | 3 bars no breakout");
               trade.PositionClose(ticket);
               continue;  // Position closed, skip to next
            }
            else if(!hasBroken && allConfirm)
            {
               if(InpEnableDetailedLogs)
                  Print("⏰ STALE HOLD: Ticket #", ticket, 
                        " | Not broken but all 3 candles confirm direction → KEEP");
            }
         }
      }
      
      // Calculate potential new SL
      double newSL = currentSL;
      bool needsUpdate = false;
      string updateReason = "";
      
      // TRAILING STOP LOGIC (Priority 1)
      // ATR-based trailing: adaptive to current volatility
      int trailActivatePips = GetTrailingActivatePips();
      int trailDistancePips = GetTrailingDistancePips();
      
      if(InpUseATRTrailing && currentATR > 0)
      {
         trailDistancePips = (int)MathRound((currentATR * InpTrailingATRMultiplier) / pipValue);
         trailActivatePips = (int)MathRound((currentATR * InpTrailingATRMultiplier * 1.5) / pipValue);
         if(trailDistancePips < 40) trailDistancePips = 40;   // Was 20 - too tight
         if(trailActivatePips < 60) trailActivatePips = 60;   // Was 30 - too early
      }
      
      if(InpUseTrailingStop && profitPips >= trailActivatePips)
      {
         double trailingDistance = trailDistancePips * pipValue;
         double potentialSL = 0;
         
         if(posType == POSITION_TYPE_BUY)
         {
            potentialSL = currentPrice - trailingDistance;
            // Only move SL up, never down
            if(potentialSL > currentSL)
            {
               newSL = NormalizeDouble(potentialSL, digits);
               needsUpdate = true;
               updateReason = "TRAILING";
            }
         }
         else // SELL
         {
            potentialSL = currentPrice + trailingDistance;
            // Only move SL down, never up
            if(potentialSL < currentSL || currentSL == 0)
            {
               newSL = NormalizeDouble(potentialSL, digits);
               needsUpdate = true;
               updateReason = "TRAILING";
            }
         }
      }
      // BREAKEVEN LOGIC (Priority 2 - only if trailing not active)
      else if(GetBreakevenPips() > 0 && profitPips >= GetBreakevenPips())
      {
         if(posType == POSITION_TYPE_BUY && currentSL < openPrice)
         {
            newSL = NormalizeDouble(openPrice, digits);
            needsUpdate = true;
            updateReason = "BREAKEVEN";
         }
         else if(posType == POSITION_TYPE_SELL && currentSL > openPrice)
         {
            newSL = NormalizeDouble(openPrice, digits);
            needsUpdate = true;
            updateReason = "BREAKEVEN";
         }
      }
      
      // Execute SL modification
      if(needsUpdate)
      {
         // Validate new SL
         bool validSL = false;
         if(posType == POSITION_TYPE_BUY && newSL < currentPrice && newSL > currentSL)
            validSL = true;
         else if(posType == POSITION_TYPE_SELL && newSL > currentPrice && (newSL < currentSL || currentSL == 0))
            validSL = true;
         
         if(validSL)
         {
            if(InpEnableDetailedLogs)
            {
               Print(updateReason, ": Ticket #", ticket, 
                     " | Profit: ", DoubleToString(profitPips, 1), " pips",
                     " | Old SL: ", DoubleToString(currentSL, digits),
                     " | New SL: ", DoubleToString(newSL, digits));
            }
            
            if(trade.PositionModify(ticket, newSL, currentTP))
            {
               if(InpEnableDetailedLogs)
                  Print("SUCCESS: ", updateReason, " applied");
               _WriteLogLine(updateReason + ": Ticket #" + IntegerToString((long)ticket)
                             + " | Profit: " + DoubleToString(profitPips, 1) + " pips"
                             + " | Old SL: " + DoubleToString(currentSL, digits)
                             + " | New SL: " + DoubleToString(newSL, digits));
            }
            else
            {
               Print("FAILED: ", updateReason, " - Error ", trade.ResultRetcode(), 
                     " - ", trade.ResultRetcodeDescription());
            }
         }
      }
   }
}
//+------------------------------------------------------------------+