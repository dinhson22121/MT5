//+------------------------------------------------------------------+
//|                                    ea_multi_tf_momentum_v1.mq5   |
//|                                    Copyright 2026                  |
//|  v1.3 - Multi-Timeframe Momentum Strategy                        |
//|        Phase-7 analysis (Jun 2026) — RAISE WIN RATE, keep all syms|
//|         Win/loss study of 25 live trades found 3 loss drivers:    |
//|         1. ADX < 24 => 0 wins, 4 full SL + 3 BE. Min ADX 18->24.  |
//|         2. Chasing: entered after price left M15 EMA (BTC 9 SELL   |
//|            churn; GBP BUY RSI 61 = overbought). Added anti-chase   |
//|            EMA-distance (ATR) filter + RSI overextension cap.      |
//|         3. RSI ~50 = weak momentum. RSI band tightened.           |
//|         => All filters toggleable; tune in Strategy Tester.        |
//|        Phase-6 tuning (May 2026):                                 |
//|         - Daily loss limit 4.0% -> 6.0% (was tripping on $582 acct|
//|           after only 3 SLs; 6% = 4 SL @1.5% before lockout)       |
//|         - Cooldown 14400s -> 7200s (only 9 trades in 7 days)      |
//|         - OrderCalcProfit() fallback via tick value/size          |
//|         - Optional InpManageLegacyMagic for v5 orphan positions   |
//|  Target: 10% / month on $1,000 - $10,000 capital                |
//+------------------------------------------------------------------+
//| STRATEGY: H4 macro trend + H1 trend + M15 RSI50 momentum entry  |
//|                                                                   |
//| ENTRY LOGIC (all 5 must be true):                                |
//|  1. H4 Macro: H4 EMA20 > H4 EMA50 (bullish) / < (bearish)       |
//|  2. H1 Trend: H1 EMA20 > H1 EMA50 + ADX >= 18                   |
//|  3. M15 Price: Close > M15 EMA20 (above trend MA) / <            |
//|  4. M15 RSI50: RSI(14) crossed above 50 in last 3 bars (momentum)|
//|  5. Volume: 1.2x avg <= Vol <= 3.0x avg (no news spikes)         |
//|                                                                   |
//| LOGIC RATIONALE vs v5.0 (EMA Pullback):                          |
//|  v5.0 required exact pullback-to-EMA + bounce = rare signal      |
//|  v1.0 uses RSI50 cross = momentum confirmation, more frequent    |
//|  RSI50 cross = price momentum shifting, not overbought/oversold  |
//|  H4 macro filter adds 3rd timeframe = fewer false signals        |
//|                                                                   |
//| RISK TARGET:                                                      |
//|  1.5% risk/trade | R:R 1:2.2 | 15-20 trades/month               |
//|  Expected: 55% WR → (0.55×2.2 - 0.45×1) × 1.5% ≈ 1.1%/trade   |
//|  20 trades × 1.1% ≈ 22% theoretical → ~10-12% realistic/month   |
//|                                                                   |
//| LESSONS FROM PREVIOUS EAs:                                       |
//|  - BTC mean reversion = catastrophic (v4.5: 0 wins / 20 trades) |
//|  - Best symbols: AUDUSDc, USDJPYc, USDCADc                      |
//|  - Daily trade cap prevents cluster losses (Apr 6: -$203 in 1d)  |
//|  - Portfolio cap critical vs correlation cascade                  |
//|  - SL modify throttle reduces broker server load                 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "1.30"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//--- Constants
const double BROKER_STOP_BUFFER = 1.1;

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Strategy: Multi-TF Momentum ==="
input int    InpEMA_H4_Fast    = 20;           // H4 Fast EMA (macro trend)
input int    InpEMA_H4_Slow    = 50;           // H4 Slow EMA (macro trend)
input int    InpEMA_H1_Fast    = 20;           // H1 Fast EMA (trend direction)
input int    InpEMA_H1_Slow    = 50;           // H1 Slow EMA (trend direction)
input int    InpH1ADXPeriod    = 14;           // H1 ADX period
input double InpMinH1ADX       = 24.0;         // v1.3: 18->24 (live data: ADX<24 = 0 wins, all SL/BE)
input int    InpEMA_M15        = 20;           // M15 EMA (price position filter)
input int    InpRSIPeriod      = 14;           // M15 RSI period
input int    InpRSICrossLookback = 3;          // RSI50 cross lookback bars (how recently must cross have occurred)
input double InpRSI50Buffer    = 2.0;          // RSI must be >= 50 + buffer for BUY (prevents weak crosses)
input bool   InpAllowBuy       = true;         // Allow BUY signals
input bool   InpAllowSell      = true;         // Allow SELL signals

input group "=== Entry Quality Filters (v1.3) ==="
input bool   InpUseEMADistanceFilter = true;   // Anti-chase: reject entries too far from M15 EMA
input double InpMaxEMADistATR        = 1.5;    // Max |close - M15 EMA| in ATR units (lower = stricter, less chasing)
input bool   InpUseRSIOverextCap     = true;   // Reject chasing entries where RSI already overextended past 50
input double InpRSIMaxDistFrom50     = 12.0;   // BUY: RSI <= 50+this (62); SELL: RSI >= 50-this (38)

input group "=== Symbol Selection ==="
input bool   InpEnableSymbolFilter = false;    // OFF: trade all symbols (v1.3 raises win-rate via entry filters, not symbol cuts)
input bool   InpTradeAUDUSD    = true;         // AUDUSDc — best historical performer
input bool   InpTradeUSDJPY    = true;         // USDJPYc — strong performer
input bool   InpTradeUSDCAD    = true;         // USDCADc — best risk-adjusted
input bool   InpTradeGBPUSD    = true;         // GBPUSDc — kept; needs ADX>=24 + anti-chase to fix BUY losses
input bool   InpTradeEURUSD    = true;         // EURUSDc — kept
input bool   InpTradeXAUUSD    = true;         // XAUUSDc — kept; volatile, ATR filters help
input bool   InpTradeBTCUSD    = true;         // BTCUSDc — kept; anti-chase targets the all-SELL churn

input group "=== Volume Filter ==="
input bool   InpUseVolumeFilter      = true;   // Enable volume filter
input double InpVolumeMultiplier     = 1.2;    // Min: volume > avg × this
input double InpVolumeMaxMultiplier  = 3.0;    // Max: block news spikes (0=no cap)
input int    InpVolumePeriod         = 20;     // Average volume lookback period

input group "=== ATR-Based SL/TP ==="
input int    InpATRPeriod            = 14;     // ATR period (M15)
input double InpATRSLMultiplier      = 1.8;    // SL = ATR × this
input double InpATRTPRatio           = 2.2;    // TP = SL × this (R:R 1:2.2)
input int    InpATRSLMinPips         = 25;     // Min SL pips (fallback if class-floor = 0)
input int    InpATRSLMinPipsForex    = 35;     // Min SL for 5-digit forex (EUR/GBP/AUD/USDCAD)
input int    InpATRSLMinPipsJPY      = 30;     // Min SL for JPY pairs
input int    InpATRSLMinPipsXAU      = 80;     // Min SL for Gold
input int    InpATRSLMinPipsBTC      = 30;     // Min SL for BTC
input int    InpATRSLMaxPips         = 200;    // Max SL pips (cap, for XAU/volatile)
input int    InpFixedSLPips          = 50;     // Fallback SL (no ATR)
input int    InpFixedTPPips          = 110;    // Fallback TP (no ATR)

input group "=== Risk Management ==="
input double InpRiskPercent          = 1.5;    // Risk % per trade (target 10%/month)
input bool   InpAutoRiskScaleBySymbols = false; // Auto-scale risk when running multiple enabled symbols
input bool   InpRiskScaleBySqrt      = true;   // true: risk/sqrt(N), false: risk/N
input double InpMinRiskPercent       = 0.35;   // Floor for effective risk % after scaling
input double InpMaxLotSize           = 1.0;    // Hard max lot (0=no limit)
input double InpMaxSafetyPercent     = 8.0;    // Absolute max risk % (safety cap)
input double InpMaxMarginPercent     = 30.0;   // Max margin % per trade
input double InpSmallAccountThreshold = 500.0; // Below → use min lot sizing

input group "=== Position Management ==="
input int    InpBreakevenPips        = 45;     // Activate BE at +X pips (0=disabled)
input int    InpBreakevenLockPips    = 10;     // Lock +N pips at BE (0=plain entry BE)
input bool   InpUseTrailingStop      = true;   // Enable trailing stop
input int    InpManageIntervalSeconds = 5;     // Min seconds between ManageOpenPositions() runs (reduces load)
input double InpTrailingATRMultiplier = 1.8;   // Trail distance = ATR × this
input int    InpTrailingMinDistance  = 40;     // Min trailing distance in pips
input int    InpTrailingMinActivate  = 60;     // Min profit pips to start trailing
input int    InpMinSLUpdatePips      = 6;      // Min SL improvement before sending modify
input int    InpMinSecondsBetweenSLUpdates = 30; // Min seconds between SL updates per ticket

input group "=== Portfolio Risk Control ==="
input double InpMaxDailyLossPercent  = 6.0;   // Daily loss circuit breaker (0=disabled). v1.1: 4.0->6.0 (allow 4 SL @ default risk)
input double InpMaxWeeklyLossPercent = 10.0;  // Weekly loss circuit breaker (0=disabled)
input int    InpMaxTotalPositions    = 3;      // Max total positions all symbols (0=unlimited)
input bool   InpUseUSDBiasCap        = true;   // Limit correlated USD exposure
input int    InpMaxUSDBiasPositions  = 2;      // Max positions same USD direction

input group "=== Trading Rules ==="
input int    InpCooldownSeconds      = 7200;   // Min seconds between trades. v1.1: 14400->7200 (2h) for thin signal yield
input int    InpMaxTradesPerDay      = 3;      // Max new trades per day (0=unlimited)
input int    InpMaxPositions         = 1;      // Max positions per symbol
input int    InpMaxSpreadPips        = 10;     // Max spread to enter trade
input int    InpMagicNumber          = 234567; // EA magic number
input bool   InpManageLegacyMagic    = true;   // v1.1: Also BE/trail positions opened by old v5 EA (magic 123456). No new entries.
input int    InpLegacyMagicNumber    = 123456; // v5/v4.5 magic to manage when InpManageLegacyMagic=true

input group "=== Session Filter ==="
input bool   InpUseTimeFilter        = true;   // Enable session filter (auto-off for crypto)
input bool   InpTradeAsianSession    = true;   // Asian: 00:00-09:00 UTC
input bool   InpTradeEuropeanSession = true;   // European: 07:00-16:00 UTC
input bool   InpTradeUSSession       = true;   // US: 13:00-21:00 UTC
input int    InpAsianStartHourUTC    = 0;
input int    InpAsianEndHourUTC      = 9;
input int    InpEuropeanStartHourUTC = 7;
input int    InpEuropeanEndHourUTC   = 16;
input int    InpUSStartHourUTC       = 13;
input int    InpUSEndHourUTC         = 21;

input group "=== Debug ==="
input bool   InpLowMemoryMode        = true;   // Reduce memory footprint for multi-chart runs
input bool   InpEnableChartComment   = false;  // Show on-chart dashboard (can consume memory on many charts)
input bool   InpEnableDetailedLogs   = true;   // Verbose logging
input bool   InpEnableFileLogging    = true;   // Write events to daily log files
input string InpLogFolder            = "EA_Logs"; // Log folder in MT5 Common Files

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
datetime g_lastTradeTime    = 0;
int      g_dailyTradeCount  = 0;
int      g_lastTradeDay     = 0;

// Daily/weekly loss tracking
int      g_dailyLossDay     = 0;
double   g_dailyStartEquity = 0;
int      g_weeklyLossWeek   = -1;
double   g_weeklyStartEquity = 0;

// Per-ticket SL update throttle
ulong    g_slUpdateTickets[];
datetime g_slUpdateTimes[];
int      g_slUpdateCount = 0;

// Indicator handles
int g_handleEMAFast_H4;
int g_handleEMASlow_H4;
int g_handleEMAFast_H1;
int g_handleEMASlow_H1;
int g_handleADX_H1;
int g_handleEMA_M15;
int g_handleRSI_M15;
int g_handleATR_M15;

// Position close tracking
ulong g_trackedTickets[];
int   g_trackedCount = 0;

//+------------------------------------------------------------------+
//| Utility: Symbol & Account                                         |
//+------------------------------------------------------------------+
bool IsCryptoSymbol()
{
   string s = _Symbol;
   return (StringFind(s, "BTC") >= 0 || StringFind(s, "ETH") >= 0 ||
           StringFind(s, "XRP") >= 0 || StringFind(s, "CRYPTO") >= 0);
}

bool IsSmallAccount()
{
   return (AccountInfoDouble(ACCOUNT_EQUITY) < InpSmallAccountThreshold);
}

bool IsSymbolEnabledByInput()
{
   if(!InpEnableSymbolFilter) return true;
   string s = _Symbol;
   if(StringFind(s, "AUDUSD") >= 0) return InpTradeAUDUSD;
   if(StringFind(s, "USDJPY") >= 0) return InpTradeUSDJPY;
   if(StringFind(s, "USDCAD") >= 0) return InpTradeUSDCAD;
   if(StringFind(s, "GBPUSD") >= 0) return InpTradeGBPUSD;
   if(StringFind(s, "EURUSD") >= 0) return InpTradeEURUSD;
   if(StringFind(s, "XAU") >= 0 || StringFind(s, "GOLD") >= 0) return InpTradeXAUUSD;
   if(StringFind(s, "BTC") >= 0) return InpTradeBTCUSD;
   return false; // Unknown symbols blocked when filter is on
}

int CountEnabledSymbols()
{
   if(!InpEnableSymbolFilter)
      return 1;

   int count = 0;
   if(InpTradeAUDUSD) count++;
   if(InpTradeUSDJPY) count++;
   if(InpTradeUSDCAD) count++;
   if(InpTradeGBPUSD) count++;
   if(InpTradeEURUSD) count++;
   if(InpTradeXAUUSD) count++;
   if(InpTradeBTCUSD) count++;

   if(count <= 0)
      count = 1;
   return count;
}

double GetEffectiveRiskPercent()
{
   double effectiveRisk = InpRiskPercent;

   if(InpAutoRiskScaleBySymbols)
   {
      int enabledSymbols = CountEnabledSymbols();
      if(enabledSymbols > 1)
      {
         if(InpRiskScaleBySqrt)
            effectiveRisk = InpRiskPercent / MathSqrt((double)enabledSymbols);
         else
            effectiveRisk = InpRiskPercent / (double)enabledSymbols;
      }
   }

   if(effectiveRisk < InpMinRiskPercent)
      effectiveRisk = InpMinRiskPercent;
   if(effectiveRisk > InpMaxSafetyPercent)
      effectiveRisk = InpMaxSafetyPercent;

   return effectiveRisk;
}

double GetPipValue()
{
   string s = _Symbol;
   double point = SymbolInfoDouble(s, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);

   if(point <= 0) { Print("WARNING: SYMBOL_POINT=0 for ", s, " - fallback 0.0001"); point = 0.0001; }

   if(StringFind(s, "XAU") >= 0 || StringFind(s, "GOLD") >= 0) return 0.10;
   if(StringFind(s, "BTC") >= 0)  return 10.0;
   if(StringFind(s, "JPY") >= 0)  return (digits == 3 || digits == 2) ? 0.01 : point * 10;
   return (digits == 5 || digits == 3) ? point * 10 : point;
}

//+------------------------------------------------------------------+
//| USD Bias (correlation cap)                                        |
//+------------------------------------------------------------------+
int GetUSDBias(const string symbol, const bool isBuy)
{
   int usdPos = StringFind(symbol, "USD");
   if(usdPos < 0) return 0;
   bool usdIsBase = (usdPos == 0);
   if(usdIsBase) return isBuy ? 1 : -1;
   return isBuy ? -1 : 1;
}

int CountUSDBiasPositions(const int bias)
{
   if(bias == 0) return 0;
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      bool posIsBuy = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if(GetUSDBias(sym, posIsBuy) == bias) count++;
   }
   return count;
}

bool IsUSDBiasCapHit(const bool isBuy)
{
   if(!InpUseUSDBiasCap || InpMaxUSDBiasPositions <= 0) return false;
   int bias = GetUSDBias(_Symbol, isBuy);
   if(bias == 0) return false;
   return (CountUSDBiasPositions(bias) >= InpMaxUSDBiasPositions);
}

//+------------------------------------------------------------------+
//| Position Counting                                                 |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         count++;
   }
   return count;
}

int CountTotalPositionsAllSymbols()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Spread Check                                                      |
//+------------------------------------------------------------------+
bool CheckSpread()
{
   if(InpMaxSpreadPips <= 0) return true;
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / GetPipValue();
   if(spread > InpMaxSpreadPips)
   {
      if(InpEnableDetailedLogs)
         PrintLog("BLOCKED: Spread " + DoubleToString(spread, 1) + " pips > max " + IntegerToString(InpMaxSpreadPips));
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Daily / Weekly Loss Tracking                                      |
//+------------------------------------------------------------------+
void UpdateDailyEquityBaseline()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_dailyLossDay)
   {
      g_dailyLossDay      = dt.day_of_year;
      g_dailyStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
      if(InpEnableDetailedLogs) PrintLog("DAILY RESET: Start equity=$" + DoubleToString(g_dailyStartEquity, 2));
   }
}

bool IsDailyLossLimitHit()
{
   if(InpMaxDailyLossPercent <= 0) return false;
   UpdateDailyEquityBaseline();
   if(g_dailyStartEquity <= 0) return false;
   double lossPct = ((g_dailyStartEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / g_dailyStartEquity) * 100.0;
   if(lossPct >= InpMaxDailyLossPercent)
   {
      if(InpEnableDetailedLogs)
         PrintLog("BLOCKED: Daily loss " + DoubleToString(lossPct, 2) + "% >= limit " + DoubleToString(InpMaxDailyLossPercent, 1) + "%");
      return true;
   }
   return false;
}

void UpdateWeeklyEquityBaseline()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int weekIndex = dt.day_of_year / 7;
   if(weekIndex != g_weeklyLossWeek)
   {
      g_weeklyLossWeek     = weekIndex;
      g_weeklyStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
      if(InpEnableDetailedLogs) PrintLog("WEEKLY RESET: Start equity=$" + DoubleToString(g_weeklyStartEquity, 2));
   }
}

bool IsWeeklyLossLimitHit()
{
   if(InpMaxWeeklyLossPercent <= 0) return false;
   UpdateWeeklyEquityBaseline();
   if(g_weeklyStartEquity <= 0) return false;
   double lossPct = ((g_weeklyStartEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / g_weeklyStartEquity) * 100.0;
   if(lossPct >= InpMaxWeeklyLossPercent)
   {
      if(InpEnableDetailedLogs)
         PrintLog("BLOCKED: Weekly loss " + DoubleToString(lossPct, 2) + "% >= limit " + DoubleToString(InpMaxWeeklyLossPercent, 1) + "%");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| SL Update Throttle (prevent modify storms)                       |
//+------------------------------------------------------------------+
datetime GetLastSLUpdateTime(ulong ticket)
{
   for(int i = 0; i < g_slUpdateCount; i++)
      if(g_slUpdateTickets[i] == ticket) return g_slUpdateTimes[i];
   return 0;
}

void SetLastSLUpdateTime(ulong ticket, datetime updateTime)
{
   for(int i = 0; i < g_slUpdateCount; i++)
   {
      if(g_slUpdateTickets[i] == ticket) { g_slUpdateTimes[i] = updateTime; return; }
   }
   int newSize = g_slUpdateCount + 1;
   ArrayResize(g_slUpdateTickets, newSize);
   ArrayResize(g_slUpdateTimes,   newSize);
   g_slUpdateTickets[g_slUpdateCount] = ticket;
   g_slUpdateTimes[g_slUpdateCount]   = updateTime;
   g_slUpdateCount = newSize;
}

//+------------------------------------------------------------------+
//| File Logging                                                      |
//+------------------------------------------------------------------+
string _GetDailyLogFileName(string suffix)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string dateStr = IntegerToString(dt.year) + "." + StringFormat("%02d", dt.mon) + "." + StringFormat("%02d", dt.day);
   return InpLogFolder + "/EA_v1_" + suffix + "_" + dateStr + "_" + _Symbol + ".txt";
}

void _WriteLogLine(string msg)
{
   if(!InpEnableFileLogging || InpLowMemoryMode) return;
   int fh = FileOpen(_GetDailyLogFileName("FullLog"), FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON|FILE_SHARE_READ);
   if(fh == INVALID_HANDLE) fh = FileOpen(_GetDailyLogFileName("FullLog"), FILE_WRITE|FILE_TXT|FILE_COMMON|FILE_SHARE_READ);
   if(fh == INVALID_HANDLE) return;
   FileSeek(fh, 0, SEEK_END);
   FileWriteString(fh, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "\t" + msg + "\r\n");
   FileClose(fh);
}

void PrintLog(string msg)
{
   Print(msg);
   _WriteLogLine(msg);
}

//+------------------------------------------------------------------+
//| Trade Event CSV Logging                                           |
//+------------------------------------------------------------------+
void LogTradeCSV(string stage, string comment, bool isBuy, double price,
                 double sl, double tp, double lot, int resultCode, ulong ticket)
{
   if(!InpEnableFileLogging || InpLowMemoryMode) return;
   string fileName = _GetDailyLogFileName("Trades");
   bool isNew = !FileIsExist(fileName, FILE_COMMON);
   int fh = FileOpen(fileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(fh == INVALID_HANDLE) { fh = FileOpen(fileName, FILE_WRITE|FILE_CSV|FILE_COMMON); isNew = true; }
   if(fh == INVALID_HANDLE) return;
   if(isNew && FileSize(fh) == 0)
      FileWriteString(fh, "Time,Symbol,Stage,Direction,Comment,Price,SL,TP,Lot,RiskPct,Code,Ticket\r\n");
   FileSeek(fh, 0, SEEK_END);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double pipVal  = GetPipValue();
   double moneyPerPip = 0;
   double riskPct = 0;
   if(sl > 0 && pipVal > 0 && lot > 0)
   {
      double pips = MathAbs(price - sl) / pipVal;
      if(OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, price, price + pipVal, moneyPerPip))
         riskPct = (lot * pips * MathAbs(moneyPerPip) / equity) * 100.0;
   }
   string rec = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)
              + "," + _Symbol + "," + stage + "," + (isBuy ? "BUY" : "SELL")
              + "," + comment
              + "," + DoubleToString(price, _Digits)
              + "," + DoubleToString(sl, _Digits)
              + "," + DoubleToString(tp, _Digits)
              + "," + DoubleToString(lot, 2)
              + "," + DoubleToString(riskPct, 1) + "%"
              + "," + IntegerToString(resultCode)
              + "," + IntegerToString((long)ticket);
   FileWriteString(fh, rec + "\r\n");
   FileClose(fh);
}

//+------------------------------------------------------------------+
//| Position Close Tracking                                           |
//+------------------------------------------------------------------+
void TrackOpenPositions()
{
   int total = PositionsTotal();
   ulong currentTickets[];
   int   count = 0;
   ArrayResize(currentTickets, total);
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      currentTickets[count++] = ticket;
   }
   ArrayResize(currentTickets, count);

   // Detect closed positions
   for(int i = 0; i < g_trackedCount; i++)
   {
      bool stillOpen = false;
      for(int j = 0; j < count; j++)
         if(g_trackedTickets[i] == currentTickets[j]) { stillOpen = true; break; }
      if(!stillOpen) LogClosedPosition(g_trackedTickets[i]);
   }

   g_trackedCount = count;
   ArrayResize(g_trackedTickets, count);
   for(int i = 0; i < count; i++) g_trackedTickets[i] = currentTickets[i];
}

void LogClosedPosition(ulong posTicket)
{
   HistorySelect(TimeCurrent() - 86400, TimeCurrent() + 3600);
   int totalDeals = HistoryDealsTotal();
   for(int i = totalDeals - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket <= 0) continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID) != posTicket) continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;

      double  dealPrice  = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      double  profit     = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      double  swap       = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
      double  comm       = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      double  vol        = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      string  dealComment = HistoryDealGetString(dealTicket, DEAL_COMMENT);
      ENUM_DEAL_REASON reason  = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
      ENUM_DEAL_TYPE   dType   = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);

      string exitReason = "UNKNOWN";
      if(reason == DEAL_REASON_SL)      exitReason = "STOP_LOSS";
      else if(reason == DEAL_REASON_TP) exitReason = "TAKE_PROFIT";
      else if(reason == DEAL_REASON_SO) exitReason = "STOP_OUT";
      else if(reason == DEAL_REASON_EXPERT) exitReason = "EA_CLOSE";
      else if(reason == DEAL_REASON_CLIENT) exitReason = "MANUAL";
      else exitReason = "OTHER(" + IntegerToString((int)reason) + ")";

      double netPL = profit + swap + comm;
      Print("╔═══════════════════════════════════╗");
      Print("║ CLOSED - ", exitReason);
      Print("╠═══════════════════════════════════╣");
      Print("  Ticket: #", posTicket);
      Print("  Close: ", DoubleToString(dealPrice, _Digits), " | Vol: ", DoubleToString(vol, 2));
      Print("  P/L: $", DoubleToString(profit, 2), " | Swap: $", DoubleToString(swap, 2), " | Comm: $", DoubleToString(comm, 2));
      Print("  NET: $", DoubleToString(netPL, 2));
      Print("╚═══════════════════════════════════╝");
      _WriteLogLine("CLOSED | " + exitReason + " | #" + IntegerToString((long)posTicket)
                    + " | Price: " + DoubleToString(dealPrice, _Digits)
                    + " | NET: $" + DoubleToString(netPL, 2)
                    + " | " + dealComment);
      LogTradeCSV(exitReason, dealComment, (dType == DEAL_TYPE_SELL), dealPrice, 0, 0, vol, (int)reason, posTicket);
      return;
   }
   Print("WARNING: Position #", posTicket, " closed but deal not found in history");
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // Create indicator handles
   g_handleEMAFast_H4 = iMA(_Symbol, PERIOD_H4, InpEMA_H4_Fast, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEMASlow_H4 = iMA(_Symbol, PERIOD_H4, InpEMA_H4_Slow, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEMAFast_H1 = iMA(_Symbol, PERIOD_H1, InpEMA_H1_Fast, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEMASlow_H1 = iMA(_Symbol, PERIOD_H1, InpEMA_H1_Slow, 0, MODE_EMA, PRICE_CLOSE);
   g_handleADX_H1     = iADX(_Symbol, PERIOD_H1, InpH1ADXPeriod);
   g_handleEMA_M15    = iMA(_Symbol, PERIOD_M15, InpEMA_M15, 0, MODE_EMA, PRICE_CLOSE);
   g_handleRSI_M15    = iRSI(_Symbol, PERIOD_M15, InpRSIPeriod, PRICE_CLOSE);
   g_handleATR_M15    = iATR(_Symbol, PERIOD_M15, InpATRPeriod);

   if(g_handleEMAFast_H4 == INVALID_HANDLE || g_handleEMASlow_H4 == INVALID_HANDLE ||
      g_handleEMAFast_H1 == INVALID_HANDLE || g_handleEMASlow_H1 == INVALID_HANDLE ||
      g_handleADX_H1 == INVALID_HANDLE     || g_handleEMA_M15 == INVALID_HANDLE    ||
      g_handleRSI_M15 == INVALID_HANDLE    || g_handleATR_M15 == INVALID_HANDLE)
   {
      Print("FATAL: Failed to create indicator handles!");
      return INIT_FAILED;
   }

   if(InpFixedSLPips <= 0 || InpFixedTPPips <= 0)
   {
      Print("FATAL: Fixed SL/TP must be > 0");
      return INIT_FAILED;
   }

   double pipVal = GetPipValue();
   if(pipVal <= 0) { Print("FATAL: GetPipValue()=0 for ", _Symbol); return INIT_FAILED; }

   // Configure trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(100);
   long fillingMode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillingMode & SYMBOL_FILLING_FOK) != 0)        trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillingMode & SYMBOL_FILLING_IOC) != 0)   trade.SetTypeFilling(ORDER_FILLING_IOC);
   else                                                trade.SetTypeFilling(ORDER_FILLING_RETURN);

   // Init baselines
   UpdateDailyEquityBaseline();
   UpdateWeeklyEquityBaseline();

   // === Initialization Summary ===
   double bal = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("══════════════════════════════════════════");
   Print("  EA v1.3 — Multi-TF Momentum Strategy");
   Print("  Target: 10% / month | Max capital: $10,000");
   Print("══════════════════════════════════════════");
   Print("  Symbol: ", _Symbol, " | Pip: ", DoubleToString(pipVal, _Digits));
   Print("  Equity: $", DoubleToString(bal, 2));
   if(IsSmallAccount())
      Print("  Mode: SMALL ACCOUNT (min lot)");
   else
      Print("  Mode: RISK-BASED ", DoubleToString(GetEffectiveRiskPercent(), 2), "% per trade (base ", DoubleToString(InpRiskPercent, 2), "%)");
   if(InpAutoRiskScaleBySymbols)
      Print("  Portfolio risk scaling: ", (InpRiskScaleBySqrt ? "risk/sqrt(N)" : "risk/N"), " | Enabled symbols: ", CountEnabledSymbols(), " | Min risk floor: ", DoubleToString(InpMinRiskPercent, 2), "%");
   Print("──────────────────────────────────────────");
   Print("  ENTRY CONDITIONS (all 5 must be true):");
   Print("  1. H4 Macro: EMA", InpEMA_H4_Fast, " vs EMA", InpEMA_H4_Slow);
   Print("  2. H1 Trend: EMA", InpEMA_H1_Fast, " vs EMA", InpEMA_H1_Slow, " + ADX >= ", InpMinH1ADX);
   Print("  3. M15 Price: Close vs EMA", InpEMA_M15);
   Print("  4. M15 RSI: RSI(", InpRSIPeriod, ") crossed 50 in last ", InpRSICrossLookback, " bars (buffer ", InpRSI50Buffer, ")");
   Print("  5. Volume: ", InpVolumeMultiplier, "x - ", InpVolumeMaxMultiplier, "x avg");
   Print("──────────────────────────────────────────");
   Print("  ENTRY QUALITY FILTERS (v1.3):");
   Print("  - Anti-chase EMA distance: ", InpUseEMADistanceFilter ? "ON" : "OFF",
         " | max ", InpMaxEMADistATR, " ATR from M15 EMA");
   Print("  - RSI overextension cap: ", InpUseRSIOverextCap ? "ON" : "OFF",
         " | BUY<=", 50.0 + InpRSIMaxDistFrom50, " SELL>=", 50.0 - InpRSIMaxDistFrom50);
   Print("  SL: ATR×", InpATRSLMultiplier,
         " | Floor[FX=", InpATRSLMinPipsForex,
         " JPY=", InpATRSLMinPipsJPY,
         " XAU=", InpATRSLMinPipsXAU,
         " BTC=", InpATRSLMinPipsBTC,
         " other=", InpATRSLMinPips,
         "] | Max=", InpATRSLMaxPips);
   Print("  TP: SL×", InpATRTPRatio, " (R:R 1:", InpATRTPRatio, ")");
   Print("  BE: +", InpBreakevenPips, " pips → lock +", InpBreakevenLockPips, " pips");
   Print("  Trail: ATR×", InpTrailingATRMultiplier, " (min ", InpTrailingMinDistance, " pips, activate +", InpTrailingMinActivate, " pips)");
   Print("──────────────────────────────────────────");
   Print("  Daily loss breaker: ", InpMaxDailyLossPercent, "%");
   Print("  Weekly loss breaker: ", InpMaxWeeklyLossPercent, "%");
   Print("  Max total positions: ", InpMaxTotalPositions);
   Print("  Max positions/symbol: ", InpMaxPositions);
   Print("  Daily cap: ", InpMaxTradesPerDay, " trades");
   Print("  Cooldown: ", InpCooldownSeconds / 3600, " hours");
   Print("  Low-memory mode: ", InpLowMemoryMode ? "ON" : "OFF", " | Manage interval: ", InpManageIntervalSeconds, "s");
   Print("  Magic: ", InpMagicNumber, " (new — does NOT manage v5.0 positions)");
   if(InpEnableSymbolFilter)
   {
      string allowed = "";
      if(InpTradeAUDUSD) allowed += "AUD ";
      if(InpTradeUSDJPY) allowed += "USDJPY ";
      if(InpTradeUSDCAD) allowed += "USDCAD ";
      if(InpTradeGBPUSD) allowed += "GBP ";
      if(InpTradeEURUSD) allowed += "EUR ";
      if(InpTradeXAUUSD) allowed += "XAU ";
      if(InpTradeBTCUSD) allowed += "BTC ";
      Print("  Symbol filter: ON | Allowed: ", allowed, "| This chart (", _Symbol, "): ", IsSymbolEnabledByInput() ? "ENABLED" : "BLOCKED");
   }
   else
      Print("  Symbol filter: OFF (all symbols trade)");
   Print("══════════════════════════════════════════");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(g_handleEMAFast_H4);
   IndicatorRelease(g_handleEMASlow_H4);
   IndicatorRelease(g_handleEMAFast_H1);
   IndicatorRelease(g_handleEMASlow_H1);
   IndicatorRelease(g_handleADX_H1);
   IndicatorRelease(g_handleEMA_M15);
   IndicatorRelease(g_handleRSI_M15);
   IndicatorRelease(g_handleATR_M15);
   Comment("");
   Print("EA v1.3 STOPPED. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // Throttle position management to reduce CPU/memory pressure on multi-chart runs.
   static datetime lastManageTime = 0;
   int manageEvery = (InpManageIntervalSeconds > 0) ? InpManageIntervalSeconds : 1;
   if((TimeCurrent() - lastManageTime) >= manageEvery)
   {
      ManageOpenPositions();
      lastManageTime = TimeCurrent();
   }

   // New M15 bar detection
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_M15, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   // === NEW M15 BAR ===
   TrackOpenPositions();

   // Fetch indicator values
   double h4Fast[], h4Slow[];
   double h1Fast[], h1Slow[], h1Adx[];
   double m15Ema[], m15Rsi[], m15Atr[];

   if(!GetIndicatorValues(h4Fast, h4Slow, h1Fast, h1Slow, h1Adx, m15Ema, m15Rsi, m15Atr))
   {
      if(InpEnableDetailedLogs) Print("WARNING: GetIndicatorValues() failed — skipping bar");
      return;
   }

   if(!CheckTradingConditions()) return;

   AnalyzeAndTrade(h4Fast, h4Slow, h1Fast, h1Slow, h1Adx, m15Ema, m15Rsi, m15Atr);
}

//+------------------------------------------------------------------+
//| Get All Indicator Values                                          |
//+------------------------------------------------------------------+
bool GetIndicatorValues(double &h4Fast[], double &h4Slow[],
                        double &h1Fast[], double &h1Slow[], double &h1Adx[],
                        double &m15Ema[], double &m15Rsi[], double &m15Atr[])
{
   int lookback = InpRSICrossLookback + 2;  // Need enough bars for RSI cross check

   ArraySetAsSeries(h4Fast, true); ArraySetAsSeries(h4Slow, true);
   ArraySetAsSeries(h1Fast, true); ArraySetAsSeries(h1Slow, true);
   ArraySetAsSeries(h1Adx, true);
   ArraySetAsSeries(m15Ema, true); ArraySetAsSeries(m15Rsi, true);
   ArraySetAsSeries(m15Atr, true);

   if(CopyBuffer(g_handleEMAFast_H4, 0, 0, 2, h4Fast) < 2) return false;
   if(CopyBuffer(g_handleEMASlow_H4, 0, 0, 2, h4Slow) < 2) return false;
   if(CopyBuffer(g_handleEMAFast_H1, 0, 0, 2, h1Fast) < 2) return false;
   if(CopyBuffer(g_handleEMASlow_H1, 0, 0, 2, h1Slow) < 2) return false;
   if(CopyBuffer(g_handleADX_H1,     0, 0, 2, h1Adx)  < 2) return false;
   if(CopyBuffer(g_handleEMA_M15,    0, 0, 2, m15Ema)  < 2) return false;
   if(CopyBuffer(g_handleRSI_M15,    0, 0, lookback, m15Rsi) < lookback) return false;
   if(CopyBuffer(g_handleATR_M15,    0, 0, 2, m15Atr)  < 2) return false;

   return true;
}

//+------------------------------------------------------------------+
//| Check Trading Conditions                                          |
//+------------------------------------------------------------------+
bool CheckTradingConditions()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   { if(InpEnableDetailedLogs) Print("BLOCKED: Terminal trading not allowed"); return false; }

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   { if(InpEnableDetailedLogs) Print("BLOCKED: EA trading not allowed"); return false; }

   if(!IsSymbolEnabledByInput())
   { if(InpEnableDetailedLogs) Print("BLOCKED: Symbol filter blocked ", _Symbol); return false; }

   // Session filter (skip for crypto)
   if(InpUseTimeFilter && !IsCryptoSymbol())
   {
      MqlDateTime t;
      TimeToStruct(TimeGMT(), t);
      int h = t.hour;
      bool inSession = false;
      if(InpTradeAsianSession    && h >= InpAsianStartHourUTC    && h < InpAsianEndHourUTC)    inSession = true;
      if(InpTradeEuropeanSession && h >= InpEuropeanStartHourUTC && h < InpEuropeanEndHourUTC) inSession = true;
      if(InpTradeUSSession       && h >= InpUSStartHourUTC       && h < InpUSEndHourUTC)       inSession = true;
      if(!inSession)
      { if(InpEnableDetailedLogs) Print("BLOCKED: Outside sessions (UTC ", h, ")"); return false; }
   }

   // Cooldown
   if(g_lastTradeTime > 0 && (int)(TimeCurrent() - g_lastTradeTime) < InpCooldownSeconds)
   {
      if(InpEnableDetailedLogs)
         Print("BLOCKED: Cooldown ", (InpCooldownSeconds - (int)(TimeCurrent() - g_lastTradeTime)) / 60, " min left");
      return false;
   }

   // Max positions per symbol
   if(CountOpenPositions() >= InpMaxPositions)
   { if(InpEnableDetailedLogs) Print("BLOCKED: Max positions per symbol"); return false; }

   // Portfolio cap
   if(InpMaxTotalPositions > 0 && CountTotalPositionsAllSymbols() >= InpMaxTotalPositions)
   { if(InpEnableDetailedLogs) PrintLog("BLOCKED: Portfolio cap " + IntegerToString(CountTotalPositionsAllSymbols()) + "/" + IntegerToString(InpMaxTotalPositions)); return false; }

   // Loss circuit breakers
   if(IsDailyLossLimitHit())  return false;
   if(IsWeeklyLossLimitHit()) return false;

   // Daily trade cap
   if(InpMaxTradesPerDay > 0)
   {
      MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
      if(dt.day_of_year != g_lastTradeDay) { g_dailyTradeCount = 0; g_lastTradeDay = dt.day_of_year; }
      if(g_dailyTradeCount >= InpMaxTradesPerDay)
      { if(InpEnableDetailedLogs) Print("BLOCKED: Daily cap (", g_dailyTradeCount, "/", InpMaxTradesPerDay, ")"); return false; }
   }

   if(!CheckSpread()) return false;

   return true;
}

//+------------------------------------------------------------------+
//| RSI50 Cross Detection                                             |
//| Returns true if RSI crossed 50 (in the correct direction)        |
//| within the last InpRSICrossLookback completed bars                |
//+------------------------------------------------------------------+
bool CheckRSI50Cross(const double &rsi[], bool forBuy)
{
   // rsi[0] = current forming bar, rsi[1] = last closed, rsi[1+N] = N bars ago
   // We look at rsi[1] (most recent closed bar) as current reading
   // RSI must currently be on the correct side with buffer
   double currentRSI = rsi[1];
   double threshold  = forBuy ? (50.0 + InpRSI50Buffer) : (50.0 - InpRSI50Buffer);

   if(forBuy  && currentRSI < threshold) return false;
   if(!forBuy && currentRSI > threshold) return false;

   // Check that RSI was on the OTHER side (< 50 for buy, > 50 for sell)
   // in at least one of the lookback bars
   for(int i = 2; i <= InpRSICrossLookback + 1; i++)
   {
      if(i >= ArraySize(rsi)) break;
      if(forBuy  && rsi[i] < 50.0) return true;
      if(!forBuy && rsi[i] > 50.0) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Core Signal: Multi-TF Momentum                                    |
//+------------------------------------------------------------------+
void AnalyzeAndTrade(const double &h4Fast[], const double &h4Slow[],
                     const double &h1Fast[], const double &h1Slow[], const double &h1Adx[],
                     const double &m15Ema[], const double &m15Rsi[], const double &m15Atr[])
{
   // === TIMEFRAME ANALYSIS ===

   // H4 Macro trend
   bool h4Bullish   = (h4Fast[0] > h4Slow[0]);
   bool h4Bearish   = (h4Fast[0] < h4Slow[0]);

   // H1 Trend
   bool h1Bullish   = (h1Fast[0] > h1Slow[0]);
   bool h1Bearish   = (h1Fast[0] < h1Slow[0]);
   bool h1ADXStrong = (h1Adx[0] >= InpMinH1ADX);

   // M15 Price vs EMA
   double barClose  = iClose(_Symbol, PERIOD_M15, 1);
   double barOpen   = iOpen( _Symbol, PERIOD_M15, 1);
   double barHigh   = iHigh( _Symbol, PERIOD_M15, 1);
   double barLow    = iLow(  _Symbol, PERIOD_M15, 1);
   double m15EmaVal = m15Ema[1];
   double currentATR = m15Atr[0];

   bool priceAboveEMA = (barClose > m15EmaVal);
   bool priceBelowEMA = (barClose < m15EmaVal);

   // M15 RSI50 Cross
   bool rsiBullishCross = CheckRSI50Cross(m15Rsi, true);
   bool rsiBearishCross = CheckRSI50Cross(m15Rsi, false);

   // Volume
   double currentVol = 0, avgVol = 0;
   bool   volumeOK   = true;
   bool   volSpike   = false;

   if(InpUseVolumeFilter)
   {
      long volArr[];
      ArraySetAsSeries(volArr, true);
      if(CopyTickVolume(_Symbol, PERIOD_M15, 1, InpVolumePeriod + 1, volArr) > 0)
      {
         currentVol = (double)volArr[0];
         int cnt = ArraySize(volArr) - 1;
         if(cnt > 0)
         {
            for(int v = 1; v <= cnt; v++) avgVol += (double)volArr[v];
            avgVol /= cnt;
         }
         if(avgVol > 0)
         {
            bool aboveMin = (currentVol >= avgVol * InpVolumeMultiplier);
            bool belowMax = (InpVolumeMaxMultiplier <= 0) ? true : (currentVol <= avgVol * InpVolumeMaxMultiplier);
            volSpike   = !belowMax;
            volumeOK   = aboveMin && belowMax;
         }
         else volumeOK = false;
      }
      else volumeOK = false;
   }

   // === ENTRY QUALITY FILTERS (v1.3) ===
   // Anti-chase: reject when price already extended too far from M15 EMA (ATR units)
   double emaDistATR = (currentATR > 0) ? MathAbs(barClose - m15EmaVal) / currentATR : 0.0;
   bool notOverextended = (!InpUseEMADistanceFilter) || (currentATR <= 0)
                          || (emaDistATR <= InpMaxEMADistATR);
   // RSI overextension cap: BUY rejected if RSI too high (chasing top), SELL if RSI too low (chasing bottom)
   double rsiNow     = m15Rsi[1];
   bool buyRSIok  = (!InpUseRSIOverextCap) || (rsiNow <= 50.0 + InpRSIMaxDistFrom50);
   bool sellRSIok = (!InpUseRSIOverextCap) || (rsiNow >= 50.0 - InpRSIMaxDistFrom50);

   // === BUILD SIGNALS ===
   bool buySignal  = InpAllowBuy
                     && h4Bullish
                     && h1Bullish && h1ADXStrong
                     && priceAboveEMA
                     && rsiBullishCross
                     && notOverextended && buyRSIok
                     && volumeOK;

   bool sellSignal = InpAllowSell
                     && h4Bearish
                     && h1Bearish && h1ADXStrong
                     && priceBelowEMA
                     && rsiBearishCross
                     && notOverextended && sellRSIok
                     && volumeOK;

   // === CHART COMMENT ===
   string macroStr  = h4Bullish ? "BULLISH" : (h4Bearish ? "BEARISH" : "FLAT");
   string trendStr  = h1Bullish ? "UPTREND" : (h1Bearish ? "DOWNTREND" : "FLAT");
   string signalStr = buySignal ? ">>> BUY <<<" : (sellSignal ? ">>> SELL <<<" : "Waiting...");
   string volStr    = volumeOK ? StringFormat("OK (%.0f/avg %.0f)", currentVol, avgVol)
                               : (volSpike ? "SPIKE-BLOCKED" : StringFormat("LOW (%.0f/min %.0f)", currentVol, avgVol * InpVolumeMultiplier));

   if(InpEnableChartComment && !InpLowMemoryMode)
   {
      Comment(StringFormat(
         "v1.0 Multi-TF Momentum\n"
         "══════════════════════════\n"
         "Balance: $%.2f | Equity: $%.2f\n"
         "Symbol: %s | Pos: %d/%d | Daily: %d/%d\n"
         "──────────────────────────\n"
         "H4 Macro: %s (EMA%d=%.5f / EMA%d=%.5f)\n"
         "H1 Trend: %s | ADX: %.1f (%s)\n"
         "  EMA%d=%.5f / EMA%d=%.5f\n"
         "──────────────────────────\n"
         "M15 EMA%d: %.5f | Price: %s\n"
         "M15 RSI(%d): %.1f | Cross BUY:%s SELL:%s\n"
         "Volume: %s\n"
         "ATR: %.5f\n"
         "──────────────────────────\n"
         "Signal: %s\n"
         "%s",
         AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY),
         _Symbol, CountOpenPositions(), InpMaxPositions, g_dailyTradeCount, InpMaxTradesPerDay,
         macroStr, InpEMA_H4_Fast, h4Fast[0], InpEMA_H4_Slow, h4Slow[0],
         trendStr, h1Adx[0], h1ADXStrong ? "STRONG" : "WEAK",
         InpEMA_H1_Fast, h1Fast[0], InpEMA_H1_Slow, h1Slow[0],
         InpEMA_M15, m15EmaVal, priceAboveEMA ? "ABOVE" : "BELOW",
         InpRSIPeriod, m15Rsi[1],
         rsiBullishCross ? "YES" : "no", rsiBearishCross ? "YES" : "no",
         volStr,
         currentATR,
         signalStr,
         TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)
      ));
   }

   // === DETAILED LOGS ===
   if(InpEnableDetailedLogs)
   {
      PrintLog("--- BAR ANALYSIS [" + _Symbol + "] ---");
      PrintLog("  H4: " + macroStr + " (EMA" + IntegerToString(InpEMA_H4_Fast) + "=" + DoubleToString(h4Fast[0], _Digits)
            + " / EMA" + IntegerToString(InpEMA_H4_Slow) + "=" + DoubleToString(h4Slow[0], _Digits) + ")");
      PrintLog("  H1: " + trendStr + " ADX=" + DoubleToString(h1Adx[0], 1) + " (" + (h1ADXStrong ? "STRONG" : "WEAK-BLOCKED") + ")"
            + " | EMA" + IntegerToString(InpEMA_H1_Fast) + "=" + DoubleToString(h1Fast[0], _Digits)
            + " / EMA" + IntegerToString(InpEMA_H1_Slow) + "=" + DoubleToString(h1Slow[0], _Digits));
      PrintLog("  M15 EMA" + IntegerToString(InpEMA_M15) + "=" + DoubleToString(m15EmaVal, _Digits)
            + " | Close=" + DoubleToString(barClose, _Digits)
            + " | Price " + (priceAboveEMA ? "ABOVE" : "BELOW") + " EMA");
      PrintLog("  RSI(" + IntegerToString(InpRSIPeriod) + "): " + DoubleToString(m15Rsi[1], 1)
            + " | Bullish cross: " + (rsiBullishCross ? "YES" : "no")
            + " | Bearish cross: " + (rsiBearishCross ? "YES" : "no")
            + " | Lookback: " + IntegerToString(InpRSICrossLookback) + " bars, buffer: " + DoubleToString(InpRSI50Buffer, 1));
      PrintLog("  Volume: " + (volumeOK ? "OK" : (volSpike ? "SPIKE" : "LOW"))
            + " (curr=" + DoubleToString(currentVol, 0)
            + " avg=" + DoubleToString(avgVol, 0)
            + " min=" + DoubleToString(avgVol * InpVolumeMultiplier, 0)
            + " max=" + (InpVolumeMaxMultiplier > 0 ? DoubleToString(avgVol * InpVolumeMaxMultiplier, 0) : "∞") + ")");

      string result = buySignal ? "BUY_SIGNAL" : (sellSignal ? "SELL_SIGNAL" : "NO_SIGNAL");
      string reason = "";
      if(!buySignal && !sellSignal)
      {
         if(!h4Bullish && !h4Bearish)          reason = "H4_flat";
         else if(h4Bullish && !h1Bullish)      reason = "H1_not_aligned_with_H4_bull";
         else if(h4Bearish && !h1Bearish)      reason = "H1_not_aligned_with_H4_bear";
         else if(!h1ADXStrong)                 reason = "H1_ADX_weak";
         else if(h4Bullish && !priceAboveEMA)  reason = "M15_price_below_EMA";
         else if(h4Bearish && !priceBelowEMA)  reason = "M15_price_above_EMA";
         else if(h4Bullish && !rsiBullishCross) reason = "no_RSI50_bullish_cross";
         else if(h4Bearish && !rsiBearishCross) reason = "no_RSI50_bearish_cross";
         else if(!notOverextended)             reason = StringFormat("overextended_%.2fATR_from_EMA", emaDistATR);
         else if(h4Bullish && !buyRSIok)        reason = StringFormat("RSI_overbought_%.1f", rsiNow);
         else if(h4Bearish && !sellRSIok)       reason = StringFormat("RSI_oversold_%.1f", rsiNow);
         else if(!volumeOK)                    reason = volSpike ? "volume_spike" : "volume_low";
         else                                  reason = "unknown";
      }
      PrintLog("  RESULT: " + result + (reason != "" ? " | Reason: " + reason : ""));
   }

   // === EXECUTE ===
   if(buySignal)
   {
      if(IsUSDBiasCapHit(true)) { PrintLog("BLOCKED: USD bias cap hit for BUY"); return; }
      PrintLog(StringFormat(">>> BUY SIGNAL: H4 bull + H1 bull(ADX %.1f) + price>EMA(%.2fATR) + RSI50 cross(%.1f) + volume OK",
               h1Adx[0], emaDistATR, rsiNow));
      OpenPosition(true, InpFixedSLPips, InpFixedTPPips, "v1_MTF_BUY", currentATR);
   }
   else if(sellSignal)
   {
      if(IsUSDBiasCapHit(false)) { PrintLog("BLOCKED: USD bias cap hit for SELL"); return; }
      PrintLog(StringFormat(">>> SELL SIGNAL: H4 bear + H1 bear(ADX %.1f) + price<EMA(%.2fATR) + RSI50 cross(%.1f) + volume OK",
               h1Adx[0], emaDistATR, rsiNow));
      OpenPosition(false, InpFixedSLPips, InpFixedTPPips, "v1_MTF_SELL", currentATR);
   }
}

//+------------------------------------------------------------------+
//| ATR-Based SL/TP                                                   |
//+------------------------------------------------------------------+
int GetMinSLPipsForSymbol()
{
   string s = _Symbol;
   if((StringFind(s, "XAU") >= 0 || StringFind(s, "GOLD") >= 0) && InpATRSLMinPipsXAU > 0) return InpATRSLMinPipsXAU;
   if(StringFind(s, "BTC") >= 0 && InpATRSLMinPipsBTC > 0)                                 return InpATRSLMinPipsBTC;
   if(StringFind(s, "JPY") >= 0 && InpATRSLMinPipsJPY > 0)                                 return InpATRSLMinPipsJPY;
   int digits = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
   if((digits == 5 || digits == 3) && InpATRSLMinPipsForex > 0)                            return InpATRSLMinPipsForex;
   return InpATRSLMinPips;
}

int GetATRBasedSLPips(double atr)
{
   if(atr <= 0) return 0;
   double pipValue = GetPipValue();
   if(pipValue <= 0) return 0;
   int pips = (int)MathRound((atr * InpATRSLMultiplier) / pipValue);
   pips = MathMax(pips, GetMinSLPipsForSymbol());
   pips = MathMin(pips, InpATRSLMaxPips);
   return pips;
}

int GetATRBasedTPPips(int slPips)
{
   return (int)MathRound(slPips * InpATRTPRatio);
}

//+------------------------------------------------------------------+
//| SL/TP Fixed-Pip Calculation                                       |
//+------------------------------------------------------------------+
void CalculateSLTP(double entryPrice, bool isBuy, int slPips, int tpPips, double &sl, double &tp)
{
   int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipValue = GetPipValue();
   if(pipValue <= 0 || slPips <= 0 || tpPips <= 0) { sl = tp = 0; return; }

   double slDist = slPips * pipValue;
   double tpDist = tpPips * pipValue;
   sl = isBuy ? (entryPrice - slDist) : (entryPrice + slDist);
   tp = isBuy ? (entryPrice + tpDist) : (entryPrice - tpDist);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   // Broker minimum stop distance compliance
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(minDist > 0)
   {
      if(MathAbs(entryPrice - sl) < minDist)
         sl = NormalizeDouble(isBuy ? entryPrice - minDist * BROKER_STOP_BUFFER : entryPrice + minDist * BROKER_STOP_BUFFER, digits);
      if(MathAbs(entryPrice - tp) < minDist)
         tp = NormalizeDouble(isBuy ? entryPrice + minDist * BROKER_STOP_BUFFER : entryPrice - minDist * BROKER_STOP_BUFFER, digits);
   }

   if(InpEnableDetailedLogs)
      Print("  SL/TP: Entry=", DoubleToString(entryPrice, digits),
            " SL=", DoubleToString(sl, digits), " (", slPips, " pips)",
            " TP=", DoubleToString(tp, digits), " (", tpPips, " pips)",
            " R:R=1:", DoubleToString((double)tpPips / slPips, 2));
}

//+------------------------------------------------------------------+
//| Lot Size Calculation (Risk-Based)                                 |
//+------------------------------------------------------------------+
double CalculateLotSize(double entryPrice, int slPips)
{
   double balance  = AccountInfoDouble(ACCOUNT_EQUITY);
   double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double pipValue = GetPipValue();

   if(balance <= 0 || slPips <= 0 || entryPrice <= 0 || pipValue <= 0)
   { Print("BLOCKED: Invalid inputs for lot calculation"); return -1; }

   // Small account
   if(IsSmallAccount())
   {
      double lot = minLot;
      if(balance >= 200) lot = minLot * 2;
      if(balance >= 400) lot = minLot * 3;
      lot = MathFloor(lot / lotStep) * lotStep;
      lot = MathMax(minLot, MathMin(lot, maxLot));
      if(InpMaxLotSize > 0) lot = MathMin(lot, InpMaxLotSize);
      return NormalizeDouble(lot, 2);
   }

   // Risk-based
   double effectiveRiskPercent = GetEffectiveRiskPercent();
   double riskUSD = balance * (effectiveRiskPercent / 100.0);
   double moneyPerPipPerLot = 0;
   double profitTest = 0;
   bool calcOK = OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, entryPrice, entryPrice + pipValue, profitTest);
   if(!calcOK) calcOK = OrderCalcProfit(ORDER_TYPE_SELL, _Symbol, 1.0, entryPrice, entryPrice - pipValue, profitTest);
   if(calcOK) moneyPerPipPerLot = MathAbs(profitTest);

   // v1.1: Fallback for when OrderCalcProfit() fails (observed at 22:15 on GBPUSDc).
   // Compute money-per-pip from tick value/size, which is symbol metadata and doesn't
   // require live quote context.
   if(moneyPerPipPerLot <= 0)
   {
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickValue > 0 && tickSize > 0)
      {
         moneyPerPipPerLot = tickValue * (pipValue / tickSize);
         if(InpEnableDetailedLogs)
            Print("  OrderCalcProfit failed -> fallback tickValue=", DoubleToString(tickValue, 5),
                  " tickSize=", DoubleToString(tickSize, _Digits),
                  " => $/pip/lot=", DoubleToString(moneyPerPipPerLot, 4));
      }
   }

   if(moneyPerPipPerLot <= 0)
   { Print("BLOCKED: Cannot determine money-per-pip (OrderCalcProfit + tick fallback both failed)"); return -1; }

   double lotSize = riskUSD / (slPips * moneyPerPipPerLot);

   // Dynamic max lot: scale with equity (1 lot per $2,000)
   double dynMax = MathFloor((balance / 2000.0) / lotStep) * lotStep;
   dynMax = MathMax(dynMax, minLot);
   double effMax = (InpMaxLotSize > 0) ? MathMin(InpMaxLotSize, dynMax) : dynMax;
   if(lotSize > effMax) { if(InpEnableDetailedLogs) Print("  Lot capped: ", DoubleToString(lotSize, 2), " -> ", DoubleToString(effMax, 2)); lotSize = effMax; }

   // Normalize
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(minLot, MathMin(lotSize, maxLot));

   // Safety hard cap
   double maxRiskUSD = balance * (InpMaxSafetyPercent / 100.0);
   double actualRisk = lotSize * slPips * moneyPerPipPerLot;
   if(actualRisk > maxRiskUSD)
   {
      double safeLot = MathFloor((maxRiskUSD / (slPips * moneyPerPipPerLot)) / lotStep) * lotStep;
      if(safeLot < minLot)
      {
         double minRisk = minLot * slPips * moneyPerPipPerLot;
         if((minRisk / balance) * 100.0 > InpMaxSafetyPercent)
         { Print("BLOCKED: Min lot risk exceeds safety cap"); return -1; }
         safeLot = minLot;
      }
      Print("SAFETY CAP: Lot ", DoubleToString(lotSize, 2), " -> ", DoubleToString(safeLot, 2));
      lotSize = safeLot;
   }

   if(InpEnableDetailedLogs)
      Print("  LOT: Risk ", DoubleToString(effectiveRiskPercent, 2), "% = $", DoubleToString(riskUSD, 2),
            " | SL ", slPips, " pips",
            " | $/pip=", DoubleToString(moneyPerPipPerLot, 4),
            " | Lot=", DoubleToString(lotSize, 2));

   return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
//| Open Position                                                     |
//+------------------------------------------------------------------+
void OpenPosition(bool isBuy, int slPips, int tpPips, string comment, double currentATR = 0)
{
   // ATR-based SL/TP (overrides fixed if ATR available)
   int effSL = slPips, effTP = tpPips;
   if(currentATR > 0)
   {
      int atrSL = GetATRBasedSLPips(currentATR);
      if(atrSL > 0) { effSL = atrSL; effTP = GetATRBasedTPPips(atrSL); }
      if(InpEnableDetailedLogs)
         Print("  ATR SL/TP: ATR=", DoubleToString(currentATR, _Digits),
               " SL=", effSL, " pips TP=", effTP, " pips R:R=1:", DoubleToString(InpATRTPRatio, 1));
   }

   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot   = CalculateLotSize(price, effSL);
   if(lot < 0) { Print("TRADE CANCELLED: Lot sizing failed"); LogTradeCSV("CANCEL", comment, isBuy, price, 0, 0, 0, -1, 0); return; }

   // Margin safety check
   if(InpMaxMarginPercent > 0)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double marginReq = 0;
      ENUM_ORDER_TYPE ot = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(OrderCalcMargin(ot, _Symbol, lot, price, marginReq))
      {
         double marginPct = (equity > 0) ? (marginReq / equity * 100.0) : 100.0;
         if(marginPct > InpMaxMarginPercent)
         {
            double maxMarginUSD = equity * (InpMaxMarginPercent / 100.0);
            double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            double reducedLot = MathFloor((lot * (maxMarginUSD / marginReq)) / lotStep) * lotStep;
            if(reducedLot < minLot) reducedLot = minLot;
            Print("MARGIN SAFETY: Lot ", DoubleToString(lot, 2), " -> ", DoubleToString(reducedLot, 2),
                  " (margin ", DoubleToString(marginPct, 1), "%)");
            lot = reducedLot;
         }
      }
   }

   double sl = 0, tp = 0;
   CalculateSLTP(price, isBuy, effSL, effTP, sl, tp);

   // Validate SL/TP direction
   if(isBuy  && (sl >= price || tp <= price)) { Print("ERROR: Invalid BUY SL/TP"); LogTradeCSV("CANCEL", comment, isBuy, price, sl, tp, lot, -1, 0); return; }
   if(!isBuy && (sl <= price || tp >= price)) { Print("ERROR: Invalid SELL SL/TP"); LogTradeCSV("CANCEL", comment, isBuy, price, sl, tp, lot, -1, 0); return; }

   Print("════════════════════════════════════");
   Print("OPENING ", isBuy ? "BUY" : "SELL", " | ", _Symbol, " | ", comment);
   Print("Entry: ", price, " | SL: ", sl, " | TP: ", tp, " | Lot: ", lot);
   Print("════════════════════════════════════");
   _WriteLogLine("OPENING " + (isBuy ? "BUY" : "SELL") + " | " + _Symbol + " | " + comment
                 + " | Entry=" + DoubleToString(price, _Digits)
                 + " | SL=" + DoubleToString(sl, _Digits)
                 + " | TP=" + DoubleToString(tp, _Digits)
                 + " | Lot=" + DoubleToString(lot, 2));

   LogTradeCSV("ATTEMPT", comment, isBuy, price, sl, tp, lot, -1, 0);

   bool result = isBuy ? trade.Buy(lot, _Symbol, 0, sl, tp, comment)
                       : trade.Sell(lot, _Symbol, 0, sl, tp, comment);

   if(result)
   {
      Print("SUCCESS: Ticket #", trade.ResultOrder());
      _WriteLogLine("SUCCESS: #" + IntegerToString((long)trade.ResultOrder()));
      LogTradeCSV("SUCCESS", comment, isBuy, price, sl, tp, lot, trade.ResultRetcode(), trade.ResultOrder());
      g_lastTradeTime = TimeCurrent();
      g_dailyTradeCount++;
   }
   else
   {
      int err = (int)trade.ResultRetcode();
      Print("FAILED: Error ", err, " | ", trade.ResultRetcodeDescription());
      _WriteLogLine("FAILED: Error " + IntegerToString(err) + " | " + trade.ResultRetcodeDescription());
      LogTradeCSV("FAILED", comment, isBuy, price, sl, tp, lot, err, 0);
   }
}

//+------------------------------------------------------------------+
//| Manage Open Positions (Breakeven + Trailing Stop)                 |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   bool hasATR = (CopyBuffer(g_handleATR_M15, 0, 0, 2, atrBuf) >= 2);
   double currentATR = hasATR ? atrBuf[0] : 0;
   double pipValue   = GetPipValue();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long posMagic = PositionGetInteger(POSITION_MAGIC);
      bool isOwn    = (posMagic == InpMagicNumber);
      bool isLegacy = (InpManageLegacyMagic && posMagic == InpLegacyMagicNumber);
      if(!isOwn && !isLegacy) continue;

      ENUM_POSITION_TYPE posType  = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool isBuy   = (posType == POSITION_TYPE_BUY);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentPrice = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                  : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

      double profitPips = isBuy ? (currentPrice - openPrice) / pipValue
                                : (openPrice - currentPrice) / pipValue;

      double newSL = currentSL;

      // --- Breakeven ---
      if(InpBreakevenPips > 0 && profitPips >= InpBreakevenPips)
      {
         double beLevel = isBuy ? openPrice + InpBreakevenLockPips * pipValue
                                : openPrice - InpBreakevenLockPips * pipValue;
         beLevel = NormalizeDouble(beLevel, digits);

         bool needBE = isBuy  ? (currentSL < beLevel)
                              : (currentSL > beLevel || currentSL == 0);
         if(needBE) newSL = beLevel;
      }

      // --- Trailing Stop ---
      if(InpUseTrailingStop && profitPips >= InpTrailingMinActivate)
      {
         double trailDist = 0;
         if(currentATR > 0 && pipValue > 0)
            trailDist = MathMax(currentATR * InpTrailingATRMultiplier, InpTrailingMinDistance * pipValue);
         else
            trailDist = InpTrailingMinDistance * pipValue;

         double trailSL = NormalizeDouble(isBuy ? currentPrice - trailDist
                                                : currentPrice + trailDist, digits);
         bool trailBetter = isBuy  ? (trailSL > newSL)
                                   : (trailSL < newSL || newSL == 0);
         if(trailBetter) newSL = trailSL;
      }

      // Apply SL update (throttled)
      if(newSL != currentSL && newSL > 0)
      {
         // Min improvement check
         double improvementPips = isBuy ? (newSL - currentSL) / pipValue
                                        : (currentSL - newSL) / pipValue;
         if(currentSL == 0) improvementPips = InpMinSLUpdatePips; // First BE move always allowed

         if(improvementPips < InpMinSLUpdatePips)
         {
            if(InpEnableDetailedLogs)
               Print("  SL throttle: improvement ", DoubleToString(improvementPips, 1), " pips < min ", InpMinSLUpdatePips);
            continue;
         }

         // Time throttle
         datetime lastUpdate = GetLastSLUpdateTime(ticket);
         if(lastUpdate > 0 && (int)(TimeCurrent() - lastUpdate) < InpMinSecondsBetweenSLUpdates)
         {
            if(InpEnableDetailedLogs)
               Print("  SL time-throttle: last update ", (int)(TimeCurrent() - lastUpdate), "s ago, min ", InpMinSecondsBetweenSLUpdates, "s");
            continue;
         }

         if(trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP)))
         {
            SetLastSLUpdateTime(ticket, TimeCurrent());
            if(InpEnableDetailedLogs)
               Print("  SL UPDATED", (isLegacy ? " [LEGACY]" : ""), ": #", ticket, " ", DoubleToString(currentSL, digits), " -> ", DoubleToString(newSL, digits),
                     " (+", DoubleToString(improvementPips, 1), " pips)");
         }
         else
            Print("  SL MODIFY FAILED", (isLegacy ? " [LEGACY]" : ""), ": #", ticket, " Error: ", trade.ResultRetcode());
      }
   }
}
