//+------------------------------------------------------------------+
//|                                    ea_trend_pullback_v5.mq5       |
//|                                    Copyright 2024                  |
//|  v5.0 - EMA Pullback Trend Following                              |
//|  Complete strategy redesign after Phase 3.1 failure (-$1,166)      |
//+------------------------------------------------------------------+
//| STRATEGY: Trade WITH the trend, not against it                    |
//| OLD (v4.5): Mean reversion (RSI<30 → BUY) = fighting the trend   |
//|   Result: 38% WR, BTC 0% WR in 20 trades, -$1,166                |
//| NEW (v5.0): Pullback entry in established trend direction         |
//|   BUY: H1 uptrend (EMA20>EMA50) + M15 pullback to EMA34 + bounce|
//|   SELL: H1 downtrend (EMA20<EMA50) + M15 pullback to EMA34 + bounce|
//|   Only 3 conditions. No RSI, no patterns, no volume filter.       |
//+------------------------------------------------------------------+
//| CHANGES from v4.5:                                                |
//| - Removed: RSI, sideways mode, momentum mode, candle patterns    |
//| - Removed: EURUSD filter, H1 confirmation (now IS the trend)     |
//| - Removed: Scalping/Long-term profiles (one set of params)       |
//| - Added: EMA34 pullback detection with ATR-based zone            |
//| - Wider SL: ATR × 2.0 (was 1.5) - prevents stop hunting         |
//| - Better R:R: 1:2.5 (was 1:2) - bigger wins                     |
//| - Daily cap: 3 (was 4) - fewer but better trades                 |
//| - Max 2 positions/symbol (was 3-7 auto) - less exposure          |
//| - Same magic number (123456) - manages existing v4.5 positions   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property version   "5.10"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//--- Constants
const double BROKER_STOP_BUFFER = 1.1;    // Buffer above broker's min stop distance

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Strategy: EMA Pullback ==="
input int    InpEMA_M15 = 34;                // M15 EMA period (pullback zone)
input int    InpEMA_H1_Fast = 20;            // H1 Fast EMA (trend direction)
input int    InpEMA_H1_Slow = 50;            // H1 Slow EMA (trend direction)
input double InpPullbackATRZone = 0.3;       // Pullback tolerance (0.3 = within 30% of ATR from EMA)
input bool   InpUseTrendStrengthFilter = true; // Require trend-strength confirmation on H1
input int    InpH1ADXPeriod = 14;            // H1 ADX period for trend strength
input double InpMinH1ADX = 18.0;             // Minimum H1 ADX to allow entries
input double InpMinH1EMASpreadATR = 0.10;    // Min |EMAfast-EMAslow| as fraction of H1 ATR
input bool   InpUseEMASlopeFilter = true;    // Require M15 EMA slope direction and minimum slope
input double InpMinM15EMASlopeATR = 0.03;    // Min |EMA34[1]-EMA34[2]| as fraction of M15 ATR
input double InpMinBounceBodyRatio = 0.50;   // Min candle body/range ratio for bounce quality
input double InpMaxCloseToExtremeRatio = 0.25; // Close must be near candle extreme for strong bounce
input bool   InpAllowBuy = true;             // Allow BUY signals
input bool   InpAllowSell = true;            // Allow SELL signals

input group "=== Symbol Selection ==="
input bool   InpEnableSymbolFilter = true;   // Only trade symbols explicitly enabled below
input bool   InpTradeAUDUSD = true;          // Preferred performer
input bool   InpTradeUSDJPY = true;          // Preferred performer
input bool   InpTradeUSDCAD = true;          // Preferred performer
input bool   InpTradeEURUSD = false;         // Optional
input bool   InpTradeGBPUSD = false;         // Optional
input bool   InpTradeXAUUSD = false;         // Disabled by default (historically weak)
input bool   InpTradeBTCUSD = false;         // Disabled by default (historically weak)

input group "=== Volume Filter ==="
input bool   InpUseVolumeFilter = true;      // Only trade when volume > avg × multiplier
input double InpVolumeMultiplier = 1.2;      // Volume must exceed avg × this (1.2 = 20% above average)
input double InpVolumeMaxMultiplier = 3.0;   // Volume must NOT exceed avg × this (3.0 = block news spikes / climactic volume). 0 = no cap
input int    InpVolumePeriod = 20;            // Period to calculate average volume

input group "=== ATR-Based SL/TP ==="
input int    InpATRPeriod = 14;              // ATR period
input double InpATRSLMultiplier = 2.0;       // SL = ATR × this (wider than v4.5's 1.5)
input double InpATRTPRatio = 2.5;            // TP = SL × this (R:R 1:2.5)
input int    InpATRSLMinPips = 30;           // Min SL in pips (floor)
input int    InpATRSLMaxPips = 300;          // Max SL in pips (cap, wider for BTC/XAU)
input int    InpFixedSLPips = 50;            // Fallback SL if ATR unavailable
input int    InpFixedTPPips = 125;           // Fallback TP if ATR unavailable

input group "=== Risk Management ==="
input double InpRiskPercent = 0.75;          // Risk % per trade (defensive default)
input double InpMaxLotSize = 0.5;            // Max lot size (0=no limit)
input double InpMaxSafetyPercent = 10.0;     // Hard max risk % (safety cap)
input double InpMaxMarginPercent = 30.0;     // Max margin % per trade
input double InpSmallAccountThreshold = 300.0; // Below this → use min lot

input group "=== Position Management ==="
input int    InpBreakevenPips = 50;          // Move SL to BE-zone at +X pips (0=disabled)
input int    InpBreakevenLockPips = 15;      // Lock profit at breakeven (SL = entry + N pips, 0=plain BE at entry)
input bool   InpUseTrailingStop = true;      // Enable trailing stop
input double InpTrailingATRMultiplier = 2.0; // Trail distance = ATR × this
input int    InpTrailingMinDistance = 50;    // Min trailing distance in pips (raised from 40 to reduce noise stop-outs)
input int    InpTrailingMinActivate = 70;    // Min profit pips to activate trailing
input int    InpMinSLUpdatePips = 8;         // Minimum SL improvement in pips before sending modify
input int    InpMinSecondsBetweenSLUpdates = 30; // Min seconds between SL updates per ticket

input group "=== Portfolio Risk Control ==="
input double InpMaxDailyLossPercent = 2.0;   // Stop opening trades when daily loss exceeds X% of start-of-day equity (0=disabled)
input double InpMaxWeeklyLossPercent = 4.0;  // Stop opening trades when weekly loss exceeds X% of start-of-week equity (0=disabled)
input int    InpMaxTotalPositions = 2;       // Max total positions across ALL symbols with this magic (0=unlimited)
input bool   InpUseUSDBiasCap = true;        // Limit correlated USD directional exposure
input int    InpMaxUSDBiasPositions = 1;     // Max open positions with same USD bias (+1 long USD, -1 short USD)

input group "=== Trading Rules ==="
input int    InpCooldownSeconds = 7200;      // Min seconds between trades
input int    InpMaxTradesPerDay = 2;         // Max new trades per day (0=unlimited)
input int    InpMaxPositions = 1;            // Max positions per symbol
input int    InpMaxSpreadPips = 10;          // Max spread to enter trade
input int    InpMagicNumber = 123456;        // EA magic number (same as v4.5 to manage old positions)

input group "=== Session Filter ==="
input bool   InpUseTimeFilter = true;        // Enable session filter (auto-off for crypto)
input bool   InpTradeAsianSession = false;   // Asian: 1:00-9:00 UTC
input bool   InpTradeEuropeanSession = true; // European: 7:00-16:00 UTC
input bool   InpTradeUSSession = true;       // US: 13:00-22:00 UTC
input int    InpAsianStartHourUTC = 1;       // Asian session start hour (UTC)
input int    InpAsianEndHourUTC = 9;         // Asian session end hour (UTC)
input int    InpEuropeanStartHourUTC = 7;    // European session start hour (UTC)
input int    InpEuropeanEndHourUTC = 16;     // European session end hour (UTC)
input int    InpUSStartHourUTC = 13;         // US session start hour (UTC)
input int    InpUSEndHourUTC = 18;           // US session end hour (UTC, early US only)

input group "=== Debug ==="
input bool   InpEnableDetailedLogs = true;   // Verbose logging to Experts tab
input bool   InpEnableFileLogging = true;    // Write events to daily log files
input string InpLogFolder = "EA_Logs";       // Log folder in MT5 Common Files

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
datetime g_lastTradeTime = 0;
int      g_dailyTradeCount = 0;
int      g_lastTradeDay = 0;

// Daily loss tracking (per-day P&L cap)
int      g_dailyLossDay = 0;
double   g_dailyStartEquity = 0;

// Weekly loss tracking (per-week P&L cap)
int      g_weeklyLossWeek = -1;
double   g_weeklyStartEquity = 0;

// Per-ticket SL update throttle
ulong    g_slUpdateTickets[];
datetime g_slUpdateTimes[];
int      g_slUpdateCount = 0;

// Indicator handles
int g_handleEMA34;         // M15 EMA34 (pullback zone)
int g_handleATR;           // M15 ATR (SL/TP, pullback zone, trailing)
int g_handleEMAFast_H1;   // H1 EMA20 (trend direction)
int g_handleEMASlow_H1;   // H1 EMA50 (trend direction)
int g_handleADX_H1;       // H1 ADX (trend strength)
int g_handleATR_H1;       // H1 ATR (normalize EMA spread)

// Position close tracking
ulong g_trackedTickets[];
int   g_trackedCount = 0;

//+------------------------------------------------------------------+
//| Helper Functions                                                  |
//+------------------------------------------------------------------+
bool IsSmallAccount()
{
   return (AccountInfoDouble(ACCOUNT_EQUITY) < InpSmallAccountThreshold);
}

bool IsCryptoSymbol()
{
   string symbol = _Symbol;
   return (StringFind(symbol, "BTC") >= 0 || 
           StringFind(symbol, "ETH") >= 0 || 
           StringFind(symbol, "XRP") >= 0 ||
           StringFind(symbol, "LTC") >= 0 ||
           StringFind(symbol, "CRYPTO") >= 0);
}

bool IsSymbolEnabledByInput()
{
   if(!InpEnableSymbolFilter)
      return true;

   string symbol = _Symbol;
   if(StringFind(symbol, "AUDUSD") >= 0) return InpTradeAUDUSD;
   if(StringFind(symbol, "USDJPY") >= 0) return InpTradeUSDJPY;
   if(StringFind(symbol, "USDCAD") >= 0) return InpTradeUSDCAD;
   if(StringFind(symbol, "EURUSD") >= 0) return InpTradeEURUSD;
   if(StringFind(symbol, "GBPUSD") >= 0) return InpTradeGBPUSD;
   if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0) return InpTradeXAUUSD;
   if(StringFind(symbol, "BTC") >= 0) return InpTradeBTCUSD;

   // Unmapped symbols are blocked when symbol filter is enabled.
   return false;
}

int GetUSDBiasForTrade(const string symbol, const bool isBuy)
{
   int usdPos = StringFind(symbol, "USD");
   if(usdPos < 0)
      return 0;

   bool usdIsBase = (usdPos == 0);
   if(usdIsBase)
      return isBuy ? 1 : -1;

   return isBuy ? -1 : 1;
}

int CountUSDBiasPositions(const int bias)
{
   if(bias == 0)
      return 0;

   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      string posSymbol = PositionGetString(POSITION_SYMBOL);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool posIsBuy = (posType == POSITION_TYPE_BUY);
      int posBias = GetUSDBiasForTrade(posSymbol, posIsBuy);
      if(posBias == bias)
         count++;
   }
   return count;
}

bool IsUSDBiasCapHit(const bool candidateIsBuy)
{
   if(!InpUseUSDBiasCap || InpMaxUSDBiasPositions <= 0)
      return false;

   int candidateBias = GetUSDBiasForTrade(_Symbol, candidateIsBuy);
   if(candidateBias == 0)
      return false;

   int sameBiasCount = CountUSDBiasPositions(candidateBias);
   return (sameBiasCount >= InpMaxUSDBiasPositions);
}

double GetPipValue()
{
   string symbol = _Symbol;
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   
   if(point <= 0)
   {
      Print("WARNING: SYMBOL_POINT is 0 for ", symbol, " - using fallback 0.0001");
      point = 0.0001;
   }
   
   if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0)
      return 0.10;
   
   if(StringFind(symbol, "BTC") >= 0)
      return 10.0;
   
   if(StringFind(symbol, "US30") >= 0 || StringFind(symbol, "DOW") >= 0 || StringFind(symbol, "DJ30") >= 0)
      return 1.0;
   
   if(StringFind(symbol, "NI225") >= 0 || StringFind(symbol, "NIKKEI") >= 0 || StringFind(symbol, "JPN225") >= 0)
      return 1.0;
   
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
         PrintLog("BLOCKED: Spread too high (" + DoubleToString(spread, 1) + " pips > " + IntegerToString(InpMaxSpreadPips) + ")");
      return false;
   }
   return true;
}

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
   }
   return count;
}

int GetMaxPositions()
{
   return InpMaxPositions;
}

//+------------------------------------------------------------------+
//| Portfolio Risk: Count positions across ALL symbols (same magic)  |
//+------------------------------------------------------------------+
int CountTotalPositionsAllSymbols()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Daily Loss Tracking                                               |
//+------------------------------------------------------------------+
void UpdateDailyEquityBaseline()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int today = dt.day_of_year;
   if(today != g_dailyLossDay)
   {
      g_dailyLossDay = today;
      g_dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(InpEnableDetailedLogs)
         PrintLog("DAILY RESET: Start equity = $" + DoubleToString(g_dailyStartEquity, 2));
   }
}

bool IsDailyLossLimitHit()
{
   if(InpMaxDailyLossPercent <= 0) return false;
   UpdateDailyEquityBaseline();
   if(g_dailyStartEquity <= 0) return false;
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = ((g_dailyStartEquity - currentEquity) / g_dailyStartEquity) * 100.0;
   return (lossPct >= InpMaxDailyLossPercent);
}

void UpdateWeeklyEquityBaseline()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int weekIndex = dt.day_of_year / 7;
   if(weekIndex != g_weeklyLossWeek)
   {
      g_weeklyLossWeek = weekIndex;
      g_weeklyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(InpEnableDetailedLogs)
         PrintLog("WEEKLY RESET: Start equity = $" + DoubleToString(g_weeklyStartEquity, 2));
   }
}

bool IsWeeklyLossLimitHit()
{
   if(InpMaxWeeklyLossPercent <= 0) return false;
   UpdateWeeklyEquityBaseline();
   if(g_weeklyStartEquity <= 0) return false;
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = ((g_weeklyStartEquity - currentEquity) / g_weeklyStartEquity) * 100.0;
   return (lossPct >= InpMaxWeeklyLossPercent);
}

datetime GetLastSLUpdateTime(ulong ticket)
{
   for(int i = 0; i < g_slUpdateCount; i++)
   {
      if(g_slUpdateTickets[i] == ticket)
         return g_slUpdateTimes[i];
   }
   return 0;
}

void SetLastSLUpdateTime(ulong ticket, datetime updateTime)
{
   for(int i = 0; i < g_slUpdateCount; i++)
   {
      if(g_slUpdateTickets[i] == ticket)
      {
         g_slUpdateTimes[i] = updateTime;
         return;
      }
   }
   int newSize = g_slUpdateCount + 1;
   ArrayResize(g_slUpdateTickets, newSize);
   ArrayResize(g_slUpdateTimes, newSize);
   g_slUpdateTickets[g_slUpdateCount] = ticket;
   g_slUpdateTimes[g_slUpdateCount] = updateTime;
   g_slUpdateCount = newSize;
}

//+------------------------------------------------------------------+
//| File Logging                                                      |
//+------------------------------------------------------------------+
string _GetDailyTextLogFileName()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string dateStr = IntegerToString(dt.year) + "."
                  + StringFormat("%02d", dt.mon) + "."
                  + StringFormat("%02d", dt.day);
   return InpLogFolder + "/EA_v5_FullLog_" + dateStr + "_" + _Symbol + ".txt";
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

void PrintLog(string msg)
{
   Print(msg);
   _WriteLogLine(msg);
}

string GetDailyLogFileName()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string dateStr = IntegerToString(dt.year) + "." 
                  + StringFormat("%02d", dt.mon) + "."
                  + StringFormat("%02d", dt.day);
   return InpLogFolder + "/EA_v5_" + dateStr + "_" + _Symbol + ".csv";
}

string GetSignalLogFileName()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string dateStr = IntegerToString(dt.year) + "." 
                  + StringFormat("%02d", dt.mon) + "."
                  + StringFormat("%02d", dt.day);
   return InpLogFolder + "/EA_v5_SIGNAL_" + dateStr + "_" + _Symbol + ".csv";
}

void WriteCsvHeader(int fh)
{
   FileWriteString(fh, "Time,Symbol,Event,Stage,Comment,Direction,Price,SL,TP,Lot,RiskUSD,RiskPct,ResultCode,Ticket,OpenPos,MaxPos\r\n");
}

void WriteSignalCsvHeader(int fh)
{
   FileWriteString(fh, "Time,Symbol,Result,Reason,H1Trend,H1Fast,H1Slow,M15EMA,ATR,Zone,BarOpen,BarHigh,BarLow,BarClose,Volume,AvgVol,VolMin,VolMax,PullbackBuy,BounceBuy,PullbackSell,BounceSell,VolumeOK,Equity,OpenPos,MaxPos,DailyCount,DailyMax\r\n");
}

void DebugLogCSV(string line)
{
   if(!InpEnableFileLogging) return;
   string fileName = GetDailyLogFileName();
   
   bool isNewFile = !FileIsExist(fileName, FILE_COMMON);
   
   int fh = FileOpen(fileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(fh == INVALID_HANDLE)
   {
      fh = FileOpen(fileName, FILE_WRITE|FILE_CSV|FILE_COMMON);
      isNewFile = true;
      if(fh == INVALID_HANDLE) return;
   }
   
   if(isNewFile && FileSize(fh) == 0)
      WriteCsvHeader(fh);
   
   FileSeek(fh, 0, SEEK_END);
   FileWriteString(fh, line);
   FileWriteString(fh, "\r\n");
   FileClose(fh);
}

void LogTradeEvent(string stage, string comment, bool isBuy, double price, double sl, double tp, double lot, int resultCode, ulong ticket)
{
   if(!InpEnableFileLogging) return;
   string ts = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   string dir = isBuy ? "BUY" : "SELL";
   string ticketStr = (ticket == 0) ? "0" : IntegerToString((int)ticket);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double pipVal = GetPipValue();
   double riskUSD = (sl > 0 && pipVal > 0) ? lot * MathAbs(price - sl) / pipVal * 10 : 0;
   double riskPct = (equity > 0) ? (riskUSD / equity * 100.0) : 0;
   string rec = ts + "," + _Symbol + ",TRADE," + stage + "," + comment + "," + dir 
              + "," + DoubleToString(price, _Digits) 
              + "," + DoubleToString(sl, _Digits) + "," + DoubleToString(tp, _Digits) 
              + "," + DoubleToString(lot, 2)
              + ",$" + DoubleToString(riskUSD, 2) + "," + DoubleToString(riskPct, 1) + "%"
              + "," + IntegerToString(resultCode) + "," + ticketStr 
              + "," + IntegerToString(CountOpenPositions()) + "," + IntegerToString(GetMaxPositions());
   DebugLogCSV(rec);
}

// Log every bar evaluation to SIGNAL CSV (one row per M15 bar)
void LogSignalEvent(string result, string reason,
                    string h1TrendStr, double h1Fast, double h1Slow,
                    double m15Ema, double atr, double zone,
                    double barO, double barH, double barL, double barC,
                    double currentVolume, double avgVolume,
                    bool pullbackBuy, bool bounceBuy,
                    bool pullbackSell, bool bounceSell,
                    bool volumeOK)
{
   if(!InpEnableFileLogging) return;
   string fileName = GetSignalLogFileName();
   bool isNewFile = !FileIsExist(fileName, FILE_COMMON);
   
   int fh = FileOpen(fileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(fh == INVALID_HANDLE)
   {
      fh = FileOpen(fileName, FILE_WRITE|FILE_CSV|FILE_COMMON);
      isNewFile = true;
      if(fh == INVALID_HANDLE) return;
   }
   
   if(isNewFile && FileSize(fh) == 0)
      WriteSignalCsvHeader(fh);
   
   FileSeek(fh, 0, SEEK_END);
   string ts = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double volMin = avgVolume * InpVolumeMultiplier;
   double volMax = (InpVolumeMaxMultiplier > 0) ? avgVolume * InpVolumeMaxMultiplier : 0;
   
   string rec = ts + "," + _Symbol + "," + result + "," + reason
              + "," + h1TrendStr
              + "," + DoubleToString(h1Fast, _Digits) + "," + DoubleToString(h1Slow, _Digits)
              + "," + DoubleToString(m15Ema, _Digits) + "," + DoubleToString(atr, _Digits)
              + "," + DoubleToString(zone, _Digits)
              + "," + DoubleToString(barO, _Digits) + "," + DoubleToString(barH, _Digits)
              + "," + DoubleToString(barL, _Digits) + "," + DoubleToString(barC, _Digits)
              + "," + DoubleToString(currentVolume, 0) + "," + DoubleToString(avgVolume, 0)
              + "," + DoubleToString(volMin, 0) + "," + (volMax > 0 ? DoubleToString(volMax, 0) : "unlimited")
              + "," + (pullbackBuy ? "1" : "0") + "," + (bounceBuy ? "1" : "0")
              + "," + (pullbackSell ? "1" : "0") + "," + (bounceSell ? "1" : "0")
              + "," + (volumeOK ? "1" : "0")
              + ",$" + DoubleToString(equity, 2)
              + "," + IntegerToString(CountOpenPositions()) + "," + IntegerToString(GetMaxPositions())
              + "," + IntegerToString(g_dailyTradeCount) + "," + IntegerToString(InpMaxTradesPerDay);
   FileWriteString(fh, rec + "\r\n");
   FileClose(fh);
}

//+------------------------------------------------------------------+
//| Position Close Tracking                                           |
//+------------------------------------------------------------------+
void TrackOpenPositions()
{
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
   datetime from = TimeCurrent() - 86400;
   datetime to = TimeCurrent() + 3600;
   HistorySelect(from, to);
   
   int totalDeals = HistoryDealsTotal();
   for(int i = totalDeals - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket <= 0) continue;
      
      ulong dealPosId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(dealPosId != posTicket) continue;
      
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
      
      string exitReason = "UNKNOWN";
      if(reason == DEAL_REASON_SL)        exitReason = "STOP_LOSS";
      else if(reason == DEAL_REASON_TP)   exitReason = "TAKE_PROFIT";
      else if(reason == DEAL_REASON_SO)   exitReason = "STOP_OUT";
      else if(reason == DEAL_REASON_EXPERT) exitReason = "EA_CLOSE";
      else if(reason == DEAL_REASON_CLIENT) exitReason = "MANUAL";
      else exitReason = "OTHER(" + IntegerToString((int)reason) + ")";
      
      string direction = (dealType == DEAL_TYPE_BUY) ? "CLOSE_SELL" : "CLOSE_BUY";
      double netPL = dealProfit + dealSwap + dealComm;
      
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
      
      LogTradeEvent(exitReason, dealComment, 
                    (dealType == DEAL_TYPE_SELL),
                    dealPrice, 0, 0, dealVol, (int)reason, posTicket);
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
   g_handleEMA34 = iMA(_Symbol, PERIOD_M15, InpEMA_M15, 0, MODE_EMA, PRICE_CLOSE);
   g_handleATR = iATR(_Symbol, PERIOD_M15, InpATRPeriod);
   g_handleEMAFast_H1 = iMA(_Symbol, PERIOD_H1, InpEMA_H1_Fast, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEMASlow_H1 = iMA(_Symbol, PERIOD_H1, InpEMA_H1_Slow, 0, MODE_EMA, PRICE_CLOSE);
   g_handleADX_H1 = iADX(_Symbol, PERIOD_H1, InpH1ADXPeriod);
   g_handleATR_H1 = iATR(_Symbol, PERIOD_H1, InpATRPeriod);
   
   if(g_handleEMA34 == INVALID_HANDLE || g_handleATR == INVALID_HANDLE ||
      g_handleEMAFast_H1 == INVALID_HANDLE || g_handleEMASlow_H1 == INVALID_HANDLE ||
      g_handleADX_H1 == INVALID_HANDLE || g_handleATR_H1 == INVALID_HANDLE)
   {
      Print("FATAL: Failed to create indicator handles!");
      return(INIT_FAILED);
   }
   
   // Validate inputs
   if(InpFixedSLPips <= 0 || InpFixedTPPips <= 0)
   {
      Print("FATAL: Fixed SL/TP must be > 0");
      return(INIT_FAILED);
   }
   
   double initPipValue = GetPipValue();
   if(initPipValue <= 0)
   {
      Print("FATAL: GetPipValue() returned ", initPipValue, " for ", _Symbol);
      return(INIT_FAILED);
   }
   
   // Configure trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(100);
   
   // Auto-detect filling mode
   long fillingMode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillingMode & SYMBOL_FILLING_FOK) != 0)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillingMode & SYMBOL_FILLING_IOC) != 0)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
   
   // === Initialization Summary ===
   double bal = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("=====================================");
   Print("EA v5.0 - EMA PULLBACK TREND FOLLOWING");
   Print("Strategy: H1 trend + M15 pullback to EMA", InpEMA_M15, " + bounce");
   Print("=====================================");
   
   if(IsSmallAccount())
   {
      Print("SMALL ACCOUNT: $", DoubleToString(bal, 2), " < $", DoubleToString(InpSmallAccountThreshold, 0));
      Print("  Lot: min lot (no risk% calc)");
   }
   else
   {
      Print("RISK-BASED: $", DoubleToString(bal, 2), " | Risk ", DoubleToString(InpRiskPercent, 1), "% per trade");
   }
   Print("Safety cap: ", DoubleToString(InpMaxSafetyPercent, 1), "% max risk");
   Print("------------------------------------");
   Print("SIGNAL LOGIC (4 conditions):");
   Print("  1. H1 Trend: EMA", InpEMA_H1_Fast, " vs EMA", InpEMA_H1_Slow);
   Print("  2. M15 Pullback: Price touches EMA", InpEMA_M15, " zone (ATR x ", DoubleToString(InpPullbackATRZone, 1), ")");
   Print("  3. M15 Candle: Closes in trend direction above/below EMA");
   Print("  4. Volume: ", InpUseVolumeFilter ? "Avg x " + DoubleToString(InpVolumeMultiplier, 1) + " <= Vol <= Avg x " + (InpVolumeMaxMultiplier > 0 ? DoubleToString(InpVolumeMaxMultiplier, 1) : "∞") + " (" + IntegerToString(InpVolumePeriod) + " bars, blocks news spikes)" : "DISABLED");
   if(InpUseTrendStrengthFilter)
      Print("  5. H1 Strength: ADX >= ", DoubleToString(InpMinH1ADX, 1), " and EMA spread >= ATR x ", DoubleToString(InpMinH1EMASpreadATR, 2));
   if(InpUseEMASlopeFilter)
      Print("  6. M15 EMA slope: |dEMA| >= ATR x ", DoubleToString(InpMinM15EMASlopeATR, 2), " in trade direction");
   Print("  7. Bounce quality: body/range >= ", DoubleToString(InpMinBounceBodyRatio, 2),
         " and close near candle extreme (<=", DoubleToString(InpMaxCloseToExtremeRatio, 2), ")");
   Print("  BUY: ", InpAllowBuy ? "YES" : "NO");
   Print("  SELL: ", InpAllowSell ? "YES" : "NO");
   Print("------------------------------------");
   Print("SL/TP: ATR x ", DoubleToString(InpATRSLMultiplier, 1), " | R:R 1:", DoubleToString(InpATRTPRatio, 1));
   Print("  SL clamp: ", InpATRSLMinPips, "-", InpATRSLMaxPips, " pips");
   Print("  Fallback (no ATR): SL=", InpFixedSLPips, " TP=", InpFixedTPPips);
   Print("------------------------------------");
   Print("POSITION MGMT:");
   Print("  Breakeven: ", InpBreakevenPips > 0 ? IntegerToString(InpBreakevenPips) + " pips (lock +" + IntegerToString(InpBreakevenLockPips) + " pips profit)" : "DISABLED");
   Print("  Trailing: ", InpUseTrailingStop ? "ATR x " + DoubleToString(InpTrailingATRMultiplier, 1) + " (min " + IntegerToString(InpTrailingMinDistance) + " pips, activate " + IntegerToString(InpTrailingMinActivate) + " pips)" : "DISABLED");
   Print("------------------------------------");
   Print("PORTFOLIO RISK:");
   Print("  Max total positions (all symbols): ", InpMaxTotalPositions > 0 ? IntegerToString(InpMaxTotalPositions) : "unlimited");
   Print("  USD bias cap: ", (InpUseUSDBiasCap && InpMaxUSDBiasPositions > 0) ? ("max " + IntegerToString(InpMaxUSDBiasPositions) + " per USD direction") : "DISABLED");
   Print("  Daily loss circuit breaker: ", InpMaxDailyLossPercent > 0 ? DoubleToString(InpMaxDailyLossPercent, 1) + "%" : "DISABLED");
   Print("  Weekly loss circuit breaker: ", InpMaxWeeklyLossPercent > 0 ? DoubleToString(InpMaxWeeklyLossPercent, 1) + "%" : "DISABLED");
   Print("------------------------------------");
   Print("RULES:");
   Print("  Max positions/symbol: ", InpMaxPositions);
   Print("  Daily cap: ", InpMaxTradesPerDay > 0 ? IntegerToString(InpMaxTradesPerDay) : "unlimited");
   Print("  Cooldown: ", InpCooldownSeconds, "s (", InpCooldownSeconds/60, " min)");
    Print("  SL update throttle: >=", InpMinSLUpdatePips, " pips and >=", InpMinSecondsBetweenSLUpdates, " sec");
   Print("  Max spread: ", InpMaxSpreadPips, " pips");
   Print("------------------------------------");
   Print("Symbol: ", _Symbol, " | Pip: ", DoubleToString(initPipValue, _Digits));
   Print("Filling: ", ((fillingMode & SYMBOL_FILLING_FOK) != 0) ? "FOK" : 
         ((fillingMode & SYMBOL_FILLING_IOC) != 0) ? "IOC" : "RETURN");
   Print("Magic: ", InpMagicNumber, " (same as v4.5 - manages old positions)");
   Print("Symbol filter: ", InpEnableSymbolFilter ? "ENABLED" : "DISABLED", " | Current symbol enabled: ", IsSymbolEnabledByInput() ? "YES" : "NO");
   
   // Symbol-specific info
   if(StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0)
   {
      Print("GOLD: 10 pips = 1 gia/$1");
   }
   if(StringFind(_Symbol, "BTC") >= 0)
   {
      Print("BTC: 100 pips = $1000");
   }
   
   // Sessions
   if(IsCryptoSymbol())
      Print("Crypto: 24/7 (time filter auto-disabled)");
   else if(InpUseTimeFilter)
   {
      Print("Sessions (UTC): ", 
            (InpTradeAsianSession ? ("Asian(" + IntegerToString(InpAsianStartHourUTC) + "-" + IntegerToString(InpAsianEndHourUTC) + ") ") : ""),
            (InpTradeEuropeanSession ? ("European(" + IntegerToString(InpEuropeanStartHourUTC) + "-" + IntegerToString(InpEuropeanEndHourUTC) + ") ") : ""),
            (InpTradeUSSession ? ("US(" + IntegerToString(InpUSStartHourUTC) + "-" + IntegerToString(InpUSEndHourUTC) + ")") : ""));
   }
   else
      Print("Time filter: DISABLED (24/7)");
   
   int existingPos = CountOpenPositions();
   if(existingPos > 0)
      Print("EXISTING POSITIONS: ", existingPos, " on ", _Symbol, " (will manage with trailing/BE)");
   
   // Initialize daily loss baseline
   UpdateDailyEquityBaseline();
   UpdateWeeklyEquityBaseline();
   
   if(InpEnableFileLogging)
   {
      string logPath = TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\Files\\" + InpLogFolder;
      Print("Log folder: ", logPath);
      Print("  - Text log:   EA_v5_FullLog_YYYY.MM.DD_SYMBOL.txt  (all events)");
      Print("  - Trade CSV:  EA_v5_YYYY.MM.DD_SYMBOL.csv         (orders)");
      Print("  - Signal CSV: EA_v5_SIGNAL_YYYY.MM.DD_SYMBOL.csv  (every M15 bar evaluation)");
   }
   
   Print("=====================================");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(g_handleEMA34);
   IndicatorRelease(g_handleATR);
   IndicatorRelease(g_handleEMAFast_H1);
   IndicatorRelease(g_handleEMASlow_H1);
   IndicatorRelease(g_handleADX_H1);
   IndicatorRelease(g_handleATR_H1);
   
   Comment("");
   Print("EA v5.0 STOPPED - Reason: ", reason);
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // Manage existing positions every tick (responsive trailing/BE)
   ManageOpenPositions();
   
   // New bar detection (M15)
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_M15, 0);
   
   if(currentBarTime == lastBarTime)
      return;
   lastBarTime = currentBarTime;
   
   // === NEW M15 BAR ===
   
   // Track position closes (once per bar is enough)
   TrackOpenPositions();
   
   // Get indicator values
   double ema34[];
   double atrBuf[];
   double h1Fast[];
   double h1Slow[];
   double h1Adx[];
   double h1Atr[];
   
   if(!GetIndicatorValues(ema34, atrBuf, h1Fast, h1Slow, h1Adx, h1Atr))
   {
      if(InpEnableDetailedLogs)
         Print("WARNING: GetIndicatorValues() failed - skipping bar");
      return;
   }
   
   // Check trading conditions (terminal, time, cooldown, max positions, spread)
   if(!CheckTradingConditions())
      return;
   
   // Analyze and trade
   AnalyzeAndTrade(ema34, atrBuf, h1Fast, h1Slow, h1Adx, h1Atr);
}

//+------------------------------------------------------------------+
//| Get Indicator Values                                              |
//+------------------------------------------------------------------+
bool GetIndicatorValues(double &ema34[], double &atrBuf[], double &h1Fast[], double &h1Slow[],
                        double &h1Adx[], double &h1Atr[])
{
   ArraySetAsSeries(ema34, true);
   ArraySetAsSeries(atrBuf, true);
   ArraySetAsSeries(h1Fast, true);
   ArraySetAsSeries(h1Slow, true);
   ArraySetAsSeries(h1Adx, true);
   ArraySetAsSeries(h1Atr, true);
   
   if(CopyBuffer(g_handleEMA34, 0, 0, 3, ema34) < 3) return false;
   if(CopyBuffer(g_handleATR, 0, 0, 3, atrBuf) < 3) return false;
   if(CopyBuffer(g_handleEMAFast_H1, 0, 0, 2, h1Fast) < 2) return false;
   if(CopyBuffer(g_handleEMASlow_H1, 0, 0, 2, h1Slow) < 2) return false;
   if(CopyBuffer(g_handleADX_H1, 0, 0, 2, h1Adx) < 2) return false;
   if(CopyBuffer(g_handleATR_H1, 0, 0, 2, h1Atr) < 2) return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| Check Trading Conditions                                          |
//+------------------------------------------------------------------+
bool CheckTradingConditions()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      if(InpEnableDetailedLogs) Print("BLOCKED: Terminal trading not allowed");
      return false;
   }
   
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      if(InpEnableDetailedLogs) Print("BLOCKED: EA trading not allowed");
      return false;
   }

   if(!IsSymbolEnabledByInput())
   {
      if(InpEnableDetailedLogs)
         Print("BLOCKED: Symbol filter disabled this symbol (", _Symbol, ")");
      return false;
   }
   
   // Time filter (auto-disabled for crypto)
   if(InpUseTimeFilter && !IsCryptoSymbol())
   {
      MqlDateTime timeNow;
      TimeToStruct(TimeGMT(), timeNow);
      int currentHour = timeNow.hour;
      
      bool inSession = false;
      if(InpTradeAsianSession && currentHour >= InpAsianStartHourUTC && currentHour < InpAsianEndHourUTC) inSession = true;
      if(InpTradeEuropeanSession && currentHour >= InpEuropeanStartHourUTC && currentHour < InpEuropeanEndHourUTC) inSession = true;
      if(InpTradeUSSession && currentHour >= InpUSStartHourUTC && currentHour < InpUSEndHourUTC) inSession = true;
      
      if(!inSession)
      {
         if(InpEnableDetailedLogs)
            Print("BLOCKED: Outside trading sessions (UTC ", currentHour, ":00)");
         return false;
      }
   }
   
   // Cooldown
   int secondsSinceLastTrade = (int)(TimeCurrent() - g_lastTradeTime);
   if(g_lastTradeTime > 0 && secondsSinceLastTrade < InpCooldownSeconds)
   {
      if(InpEnableDetailedLogs)
         Print("BLOCKED: Cooldown - ", (InpCooldownSeconds - secondsSinceLastTrade) / 60, " min remaining");
      return false;
   }
   
   // Max positions per symbol
   int currentPositions = CountOpenPositions();
   if(currentPositions >= GetMaxPositions())
   {
      if(InpEnableDetailedLogs)
         Print("BLOCKED: Max positions ", currentPositions, "/", GetMaxPositions());
      return false;
   }
   
   // Portfolio cap: max positions across ALL symbols (anti-correlation cascade)
   if(InpMaxTotalPositions > 0)
   {
      int totalPos = CountTotalPositionsAllSymbols();
      if(totalPos >= InpMaxTotalPositions)
      {
         if(InpEnableDetailedLogs)
            PrintLog("BLOCKED: Portfolio cap " + IntegerToString(totalPos) + "/" + IntegerToString(InpMaxTotalPositions) + " (all symbols, magic " + IntegerToString(InpMagicNumber) + ")");
         return false;
      }
   }
   
   // Daily loss circuit breaker
   if(IsDailyLossLimitHit())
   {
      if(InpEnableDetailedLogs)
      {
         double curEq = AccountInfoDouble(ACCOUNT_EQUITY);
         double lossPct = ((g_dailyStartEquity - curEq) / g_dailyStartEquity) * 100.0;
         PrintLog("BLOCKED: Daily loss limit hit " + DoubleToString(lossPct, 2) + "% >= " + DoubleToString(InpMaxDailyLossPercent, 2) + "% (start $" + DoubleToString(g_dailyStartEquity, 2) + " -> now $" + DoubleToString(curEq, 2) + ")");
      }
      return false;
   }

   // Weekly loss circuit breaker
   if(IsWeeklyLossLimitHit())
   {
      if(InpEnableDetailedLogs)
      {
         double curEqW = AccountInfoDouble(ACCOUNT_EQUITY);
         double lossPctW = ((g_weeklyStartEquity - curEqW) / g_weeklyStartEquity) * 100.0;
         PrintLog("BLOCKED: Weekly loss limit hit " + DoubleToString(lossPctW, 2) + "% >= " + DoubleToString(InpMaxWeeklyLossPercent, 2) + "% (start $" + DoubleToString(g_weeklyStartEquity, 2) + " -> now $" + DoubleToString(curEqW, 2) + ")");
      }
      return false;
   }
   
   // Daily trade cap
   if(InpMaxTradesPerDay > 0)
   {
      MqlDateTime dtNow;
      TimeToStruct(TimeCurrent(), dtNow);
      int today = dtNow.day_of_year;
      
      if(today != g_lastTradeDay)
      {
         g_dailyTradeCount = 0;
         g_lastTradeDay = today;
      }
      
      if(g_dailyTradeCount >= InpMaxTradesPerDay)
      {
         if(InpEnableDetailedLogs)
            Print("BLOCKED: Daily cap reached (", g_dailyTradeCount, "/", InpMaxTradesPerDay, ")");
         return false;
      }
   }
   
   // Spread check
   if(!CheckSpread())
      return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| Core Signal Logic: EMA Pullback Trend Following                   |
//+------------------------------------------------------------------+
void AnalyzeAndTrade(const double &ema34[], const double &atrBuf[],
                     const double &h1Fast[], const double &h1Slow[],
                     const double &h1Adx[], const double &h1Atr[])
{
   // H1 trend direction
   bool h1Uptrend  = (h1Fast[0] > h1Slow[0]);
   bool h1Downtrend = (h1Fast[0] < h1Slow[0]);
   
   // M15 bar[1] data (last completed bar)
   double barOpen  = iOpen(_Symbol, PERIOD_M15, 1);
   double barClose = iClose(_Symbol, PERIOD_M15, 1);
   double barHigh  = iHigh(_Symbol, PERIOD_M15, 1);
   double barLow   = iLow(_Symbol, PERIOD_M15, 1);
   
   double m15Ema   = ema34[1];
   double atr      = atrBuf[1];
   double h1AdxVal = h1Adx[0];
   double h1AtrVal = h1Atr[0];
   
   // Pullback zone: how close price needs to get to EMA34
   double pullbackZone = atr * InpPullbackATRZone;

   // Trend strength filters
   double h1EmaSpread = MathAbs(h1Fast[0] - h1Slow[0]);
   bool adxStrongEnough = (h1AdxVal >= InpMinH1ADX);
   bool emaSpreadStrongEnough = (h1AtrVal > 0) ? (h1EmaSpread >= h1AtrVal * InpMinH1EMASpreadATR) : false;
   bool trendStrengthOK = !InpUseTrendStrengthFilter || (adxStrongEnough && emaSpreadStrongEnough);

   // M15 EMA slope filters
   double emaSlope = ema34[1] - ema34[2];
   bool slopeBuyOK = !InpUseEMASlopeFilter || ((emaSlope > 0) && (MathAbs(emaSlope) >= atr * InpMinM15EMASlopeATR));
   bool slopeSellOK = !InpUseEMASlopeFilter || ((emaSlope < 0) && (MathAbs(emaSlope) >= atr * InpMinM15EMASlopeATR));

   // Candle quality filters
   double barRange = barHigh - barLow;
   bool validRange = (barRange > 0);
   double body = MathAbs(barClose - barOpen);
   bool bodyStrong = validRange ? ((body / barRange) >= InpMinBounceBodyRatio) : false;
   bool closeNearHigh = validRange ? (((barHigh - barClose) / barRange) <= InpMaxCloseToExtremeRatio) : false;
   bool closeNearLow = validRange ? (((barClose - barLow) / barRange) <= InpMaxCloseToExtremeRatio) : false;
   
   // Current ATR for SL/TP (use bar[0] for most current reading)
   double currentATR = atrBuf[0];
   
   // === Volume Filter ===
   double currentVolume = 0;
   double avgVolume = 0;
   bool volumeOK = true;
   bool volumeTooHigh = false;  // Spike detection (news/climax/stop-hunt)
   
   if(InpUseVolumeFilter)
   {
      long volumeArray[];
      ArraySetAsSeries(volumeArray, true);
      // Get bar[1] volume + previous bars for average
      if(CopyTickVolume(_Symbol, PERIOD_M15, 1, InpVolumePeriod + 1, volumeArray) > 0)
      {
         currentVolume = (double)volumeArray[0];  // bar[1] volume
         // Average of bars [2..VolumePeriod+1] (exclude bar[1] itself)
         int copyCount = ArraySize(volumeArray) - 1;
         if(copyCount > 0)
         {
            for(int v = 1; v <= copyCount; v++)
               avgVolume += (double)volumeArray[v];
            avgVolume /= copyCount;
         }
         
         if(avgVolume > 0)
         {
            // Lower bound: must exceed minimum threshold
            bool aboveMin = (currentVolume >= avgVolume * InpVolumeMultiplier);
            // Upper bound: block volume spikes (news, climax, stop-hunt)
            bool belowMax = (InpVolumeMaxMultiplier <= 0) ? true 
                                                          : (currentVolume <= avgVolume * InpVolumeMaxMultiplier);
            volumeOK = aboveMin && belowMax;
            volumeTooHigh = !belowMax;
         }
         else
         {
            // Fail-closed: if avgVolume cannot be computed, do NOT trade
            volumeOK = false;
         }
      }
      else
      {
         // CopyTickVolume failed: fail-closed
         volumeOK = false;
      }
   }
   
   // === BUY Signal ===
   // 1. H1 shows uptrend (EMA20 > EMA50)
   // 2. M15 bar[1] low reached EMA34 zone (pullback)
   // 3. M15 bar[1] closed above EMA34 with bullish body (bounce)
   bool pullbackForBuy = (barLow <= m15Ema + pullbackZone);
   bool bounceForBuy   = (barClose > m15Ema) && (barClose > barOpen) && bodyStrong && closeNearHigh;
   bool buySignal      = InpAllowBuy && h1Uptrend && trendStrengthOK && slopeBuyOK && pullbackForBuy && bounceForBuy && volumeOK;
   
   // === SELL Signal ===
   // 1. H1 shows downtrend (EMA20 < EMA50)
   // 2. M15 bar[1] high reached EMA34 zone (pullback)
   // 3. M15 bar[1] closed below EMA34 with bearish body (bounce)
   bool pullbackForSell = (barHigh >= m15Ema - pullbackZone);
   bool bounceForSell   = (barClose < m15Ema) && (barClose < barOpen) && bodyStrong && closeNearLow;
   bool sellSignal      = InpAllowSell && h1Downtrend && trendStrengthOK && slopeSellOK && pullbackForSell && bounceForSell && volumeOK;
   
   // === Chart Display ===
   string trendStr = h1Uptrend ? "UPTREND" : (h1Downtrend ? "DOWNTREND" : "FLAT");
   string signalStr = buySignal ? ">>> BUY <<<" : (sellSignal ? ">>> SELL <<<" : "No signal");
   string volStatus = volumeOK ? "OK" : (volumeTooHigh ? "SPIKE-BLOCKED" : "LOW");
   string volMaxStr = (InpVolumeMaxMultiplier > 0) ? DoubleToString(avgVolume * InpVolumeMaxMultiplier, 0) : "inf";
   
   string commentStr = StringFormat(
      "v5.0 EMA Pullback Trend Following\n"
      "===========================\n"
      "Balance: $%.2f | Equity: $%.2f\n"
      "Symbol: %s | Positions: %d/%d\n"
      "Daily trades: %d/%d\n"
      "---------------------------\n"
      "H1 Trend: %s (EMA%d=%s vs EMA%d=%s)\n"
      "H1 ADX: %s | EMA Spread: %s | TrendStrength: %s\n"
      "M15 EMA%d: %s\n"
      "M15 ATR: %s | Zone: +/-%s | dEMA: %s\n"
      "---------------------------\n"
      "Bar[1]: O=%s H=%s L=%s C=%s\n"
      "Pullback: %s | Bounce: %s | Volume: %s\n"
      "CandleQ: body/range=%s | nearExtreme=%s\n"
      "Vol: %s / min=%s max=%s\n"
      "---------------------------\n"
      "Signal: %s\n"
      "Time: %s",
      AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY),
      _Symbol, CountOpenPositions(), GetMaxPositions(),
      g_dailyTradeCount, InpMaxTradesPerDay,
      trendStr, InpEMA_H1_Fast, DoubleToString(h1Fast[0], _Digits),
      InpEMA_H1_Slow, DoubleToString(h1Slow[0], _Digits),
      DoubleToString(h1AdxVal, 1), DoubleToString(h1EmaSpread, _Digits), (trendStrengthOK ? "OK" : "WEAK"),
      InpEMA_M15, DoubleToString(m15Ema, _Digits),
      DoubleToString(atr, _Digits), DoubleToString(pullbackZone, _Digits), DoubleToString(emaSlope, _Digits),
      DoubleToString(barOpen, _Digits), DoubleToString(barHigh, _Digits),
      DoubleToString(barLow, _Digits), DoubleToString(barClose, _Digits),
      ((pullbackForBuy || pullbackForSell) ? "YES" : "NO"),
      ((bounceForBuy || bounceForSell) ? "YES" : "NO"),
      volStatus,
      validRange ? DoubleToString(body / barRange, 2) : "0.00",
      (closeNearHigh || closeNearLow) ? "YES" : "NO",
      DoubleToString(currentVolume, 0),
      DoubleToString(avgVolume * InpVolumeMultiplier, 0),
      volMaxStr,
      signalStr,
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)
   );
   Comment(commentStr);
   
   // === Detailed Log ===
   if(InpEnableDetailedLogs)
   {
      PrintLog("--- BAR ANALYSIS ---");
      PrintLog("  H1: " + trendStr + " (EMA" + IntegerToString(InpEMA_H1_Fast) + "=" + DoubleToString(h1Fast[0], _Digits)
            + " vs EMA" + IntegerToString(InpEMA_H1_Slow) + "=" + DoubleToString(h1Slow[0], _Digits) + ")");
      PrintLog("  H1 Strength: ADX=" + DoubleToString(h1AdxVal, 1)
         + " | EMA spread=" + DoubleToString(h1EmaSpread, _Digits)
         + " | Need ADX>=" + DoubleToString(InpMinH1ADX, 1)
         + " and spread>=ATR*" + DoubleToString(InpMinH1EMASpreadATR, 2)
         + " => " + (trendStrengthOK ? "OK" : "WEAK"));
      PrintLog("  M15 EMA" + IntegerToString(InpEMA_M15) + ": " + DoubleToString(m15Ema, _Digits)
            + " | ATR: " + DoubleToString(atr, _Digits)
         + " | Zone: +/-" + DoubleToString(pullbackZone, _Digits)
         + " | dEMA: " + DoubleToString(emaSlope, _Digits)
         + " | SlopeOK(B/S): " + (slopeBuyOK ? "Y" : "N") + "/" + (slopeSellOK ? "Y" : "N"));
      PrintLog("  Bar[1]: O=" + DoubleToString(barOpen, _Digits)
            + " H=" + DoubleToString(barHigh, _Digits)
            + " L=" + DoubleToString(barLow, _Digits)
            + " C=" + DoubleToString(barClose, _Digits));
      if(validRange)
         PrintLog("  Candle quality: body/range=" + DoubleToString(body / barRange, 2)
            + " | nearHigh=" + (closeNearHigh ? "Y" : "N")
            + " | nearLow=" + (closeNearLow ? "Y" : "N"));
      
      PrintLog("  Volume: " + (volumeOK ? "OK" : (volumeTooHigh ? "SPIKE-BLOCKED (news/climax)" : "LOW"))
            + " (current=" + DoubleToString(currentVolume, 0)
            + " avg=" + DoubleToString(avgVolume, 0)
            + " min=" + DoubleToString(avgVolume * InpVolumeMultiplier, 0)
            + " max=" + (InpVolumeMaxMultiplier > 0 ? DoubleToString(avgVolume * InpVolumeMaxMultiplier, 0) : "unlimited") + ")");
      
      if(h1Uptrend)
      {
         PrintLog("  BUY check: Pullback=" + (pullbackForBuy ? "YES" : "NO")
               + " (Low " + DoubleToString(barLow, _Digits) + " <= " + DoubleToString(m15Ema + pullbackZone, _Digits) + ")"
               + " | Bounce=" + (bounceForBuy ? "YES" : "NO")
               + " (Close>EMA=" + (barClose > m15Ema ? "YES" : "NO") + " Bullish=" + (barClose > barOpen ? "YES" : "NO") + ")");
      }
      if(h1Downtrend)
      {
         PrintLog("  SELL check: Pullback=" + (pullbackForSell ? "YES" : "NO")
               + " (High " + DoubleToString(barHigh, _Digits) + " >= " + DoubleToString(m15Ema - pullbackZone, _Digits) + ")"
               + " | Bounce=" + (bounceForSell ? "YES" : "NO")
               + " (Close<EMA=" + (barClose < m15Ema ? "YES" : "NO") + " Bearish=" + (barClose < barOpen ? "YES" : "NO") + ")");
      }
   }
   
   // === SIGNAL CSV LOG (every bar evaluation) ===
   string evalResult = "NO_SIGNAL";
   string evalReason = "";
   
   if(buySignal)
   {
      evalResult = "BUY_SIGNAL";
      evalReason = "H1_uptrend+pullback+bounce+volume";
   }
   else if(sellSignal)
   {
      evalResult = "SELL_SIGNAL";
      evalReason = "H1_downtrend+pullback+bounce+volume";
   }
   else
   {
      // Determine WHY no signal
      if(!h1Uptrend && !h1Downtrend)
         evalReason = "H1_flat";
      else if(h1Uptrend)
      {
         if(!InpAllowBuy) evalReason = "BUY_disabled";
         else if(!trendStrengthOK) evalReason = "trend_strength_weak";
         else if(!slopeBuyOK) evalReason = "ema_slope_weak";
         else if(!pullbackForBuy) evalReason = "no_pullback_to_EMA";
         else if(!bounceForBuy) evalReason = "no_bullish_bounce";
         else if(!volumeOK) evalReason = volumeTooHigh ? "volume_SPIKE" : "volume_LOW";
         else evalReason = "unknown";
      }
      else // h1Downtrend
      {
         if(!InpAllowSell) evalReason = "SELL_disabled";
         else if(!trendStrengthOK) evalReason = "trend_strength_weak";
         else if(!slopeSellOK) evalReason = "ema_slope_weak";
         else if(!pullbackForSell) evalReason = "no_pullback_to_EMA";
         else if(!bounceForSell) evalReason = "no_bearish_bounce";
         else if(!volumeOK) evalReason = volumeTooHigh ? "volume_SPIKE" : "volume_LOW";
         else evalReason = "unknown";
      }
   }
   
   LogSignalEvent(evalResult, evalReason, trendStr, h1Fast[0], h1Slow[0],
                  m15Ema, atr, pullbackZone,
                  barOpen, barHigh, barLow, barClose,
                  currentVolume, avgVolume,
                  pullbackForBuy, bounceForBuy,
                  pullbackForSell, bounceForSell,
                  volumeOK);
   
   if(InpEnableDetailedLogs)
      PrintLog("  RESULT: " + evalResult + " | Reason: " + evalReason);
   
   // === Execute Trade ===
   if(buySignal)
   {
      if(IsUSDBiasCapHit(true))
      {
         if(InpEnableDetailedLogs)
            PrintLog("BLOCKED: USD bias cap hit for BUY on " + _Symbol + " (max " + IntegerToString(InpMaxUSDBiasPositions) + ")");
         return;
      }
      PrintLog(">>> BUY SIGNAL: H1 Uptrend + M15 pullback to EMA" + IntegerToString(InpEMA_M15) + " + bullish bounce + volume OK");
      OpenPosition(true, InpFixedSLPips, InpFixedTPPips, "v5_Pullback_BUY", currentATR);
   }
   else if(sellSignal)
   {
      if(IsUSDBiasCapHit(false))
      {
         if(InpEnableDetailedLogs)
            PrintLog("BLOCKED: USD bias cap hit for SELL on " + _Symbol + " (max " + IntegerToString(InpMaxUSDBiasPositions) + ")");
         return;
      }
      PrintLog(">>> SELL SIGNAL: H1 Downtrend + M15 pullback to EMA" + IntegerToString(InpEMA_M15) + " + bearish bounce + volume OK");
      OpenPosition(false, InpFixedSLPips, InpFixedTPPips, "v5_Pullback_SELL", currentATR);
   }
}

//+------------------------------------------------------------------+
//| SL/TP Calculation                                                 |
//+------------------------------------------------------------------+
void CalculateSLTP_FixedPips(double entryPrice, bool isBuy, int slPips, int tpPips,
                              double &sl, double &tp)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipValue = GetPipValue();
   
   if(pipValue <= 0 || slPips <= 0 || tpPips <= 0)
   {
      Print("ERROR: Invalid SL/TP params");
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
   
   // Broker minimum stop distance compliance
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
      Print("  R:R = 1:", DoubleToString((double)tpPips / slPips, 2));
   }
}

int GetATRBasedSLPips(double currentATR)
{
   if(currentATR <= 0)
      return 0;
   
   double pipValue = GetPipValue();
   if(pipValue <= 0) return 0;
   
   int atrSLPips = (int)MathRound((currentATR * InpATRSLMultiplier) / pipValue);
   
   if(atrSLPips < InpATRSLMinPips) atrSLPips = InpATRSLMinPips;
   if(atrSLPips > InpATRSLMaxPips) atrSLPips = InpATRSLMaxPips;
   
   return atrSLPips;
}

int GetATRBasedTPPips(int atrSLPips)
{
   return (int)MathRound(atrSLPips * InpATRTPRatio);
}

//+------------------------------------------------------------------+
//| Lot Size Calculation                                              |
//+------------------------------------------------------------------+
double CalculateLotSize(double entryPrice, int slPips)
{
   double balance = AccountInfoDouble(ACCOUNT_EQUITY);
   
   if(balance <= 0)
   {
      Print("BLOCKED: Invalid equity (", DoubleToString(balance, 2), ")");
      return -1;
   }
   if(slPips <= 0)
   {
      Print("BLOCKED: Invalid SL pips (", slPips, ")");
      return -1;
   }
   if(entryPrice <= 0)
   {
      Print("BLOCKED: Invalid entry price");
      return -1;
   }
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double pipValue = GetPipValue();
   
   if(pipValue <= 0)
   {
      Print("BLOCKED: GetPipValue() returned ", pipValue);
      return -1;
   }
   
   // === Small Account Mode ===
   if(IsSmallAccount())
   {
      double smallLot = minLot;
      if(balance >= 100.0) smallLot = minLot * 2;
      if(balance >= 200.0) smallLot = minLot * 3;
      
      smallLot = MathFloor(smallLot / lotStep) * lotStep;
      if(smallLot < minLot) smallLot = minLot;
      if(smallLot > maxLot) smallLot = maxLot;
      if(InpMaxLotSize > 0 && smallLot > InpMaxLotSize) smallLot = InpMaxLotSize;
      
      if(InpEnableDetailedLogs)
      {
         Print("LOT: SMALL ACCOUNT | Equity $", DoubleToString(balance, 2),
               " | Lot: ", DoubleToString(smallLot, 2));
      }
      return NormalizeDouble(smallLot, 2);
   }
   
   // === Risk-Based Mode ===
   double riskAmountUSD = balance * (InpRiskPercent / 100.0);
   
   // Calculate money per pip per lot using OrderCalcProfit
   double moneyPerPipPerLot = 0;
   double profitBuy = 0;
   bool calcOK = false;
   
   if(OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, entryPrice, entryPrice + pipValue, profitBuy))
   {
      moneyPerPipPerLot = MathAbs(profitBuy);
      calcOK = true;
   }
   else
   {
      double profitSell = 0;
      if(OrderCalcProfit(ORDER_TYPE_SELL, _Symbol, 1.0, entryPrice, entryPrice - pipValue, profitSell))
      {
         moneyPerPipPerLot = MathAbs(profitSell);
         calcOK = true;
      }
   }
   
   if(!calcOK || moneyPerPipPerLot <= 0)
   {
      Print("BLOCKED: OrderCalcProfit() failed - skipping trade");
      return -1;
   }
   
   // Sanity check
   double expectedLot = riskAmountUSD / (slPips * moneyPerPipPerLot);
   if(expectedLot > maxLot * 10)
   {
      Print("BLOCKED: moneyPerPipPerLot seems wrong (", DoubleToString(moneyPerPipPerLot, 6),
            ") - lot would be ", DoubleToString(expectedLot, 2));
      return -1;
   }
   
   // Calculate lot size
   double lotSize = riskAmountUSD / (slPips * moneyPerPipPerLot);
   
   // Dynamic max lot (scales with equity)
   double equityBasedMax = balance / 2000.0;
   equityBasedMax = MathFloor(equityBasedMax / lotStep) * lotStep;
   if(equityBasedMax < minLot) equityBasedMax = minLot;
   
   double dynamicMaxLot = (InpMaxLotSize > 0) ? MathMin(InpMaxLotSize, equityBasedMax) : equityBasedMax;
   
   if(lotSize > dynamicMaxLot)
   {
      if(InpEnableDetailedLogs)
         Print("Lot capped: ", DoubleToString(lotSize, 2), " -> ", DoubleToString(dynamicMaxLot, 2));
      lotSize = dynamicMaxLot;
   }
   
   // Normalize
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   if(lotSize < minLot) lotSize = minLot;
   if(lotSize > maxLot) lotSize = maxLot;
   
   // Safety: max risk hard limit
   double maxRiskAmount = balance * (InpMaxSafetyPercent / 100.0);
   double actualRiskAmount = lotSize * slPips * moneyPerPipPerLot;
   
   if(actualRiskAmount > maxRiskAmount)
   {
      double safeLotSize = maxRiskAmount / (slPips * moneyPerPipPerLot);
      safeLotSize = MathFloor(safeLotSize / lotStep) * lotStep;
      
      if(safeLotSize < minLot)
      {
         double minLotRisk = minLot * slPips * moneyPerPipPerLot;
         double minLotRiskPct = (minLotRisk / balance) * 100.0;
         
         if(minLotRiskPct > InpMaxSafetyPercent)
         {
            Print("BLOCKED: Even min lot risks ", DoubleToString(minLotRiskPct, 1),
                  "% > ", DoubleToString(InpMaxSafetyPercent, 1), "% - trade cancelled");
            return -1;
         }
         safeLotSize = minLot;
      }
      else
      {
         Print("SAFETY: Risk $", DoubleToString(actualRiskAmount, 2),
               " > ", DoubleToString(InpMaxSafetyPercent, 1), "% ($", DoubleToString(maxRiskAmount, 2),
               ") | Lot: ", DoubleToString(lotSize, 2), " -> ", DoubleToString(safeLotSize, 2));
      }
      lotSize = safeLotSize;
   }
   
   if(InpEnableDetailedLogs)
   {
      Print("LOT CALC: Risk ", DoubleToString(InpRiskPercent, 1), "% = $", DoubleToString(riskAmountUSD, 2),
            " | SL ", slPips, " pips | $/pip = $", DoubleToString(moneyPerPipPerLot, 3),
            " | Lot = ", DoubleToString(lotSize, 2));
   }
   
   return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
//| Open Position                                                     |
//+------------------------------------------------------------------+
void OpenPosition(bool isBuy, int slPips, int tpPips, string comment, double currentATR = 0)
{
   // ATR-based SL/TP
   int effectiveSL = slPips;
   int effectiveTP = tpPips;
   
   if(currentATR > 0)
   {
      int atrSL = GetATRBasedSLPips(currentATR);
      if(atrSL > 0)
      {
         effectiveSL = atrSL;
         effectiveTP = GetATRBasedTPPips(atrSL);
         if(InpEnableDetailedLogs)
            Print("  ATR SL/TP: ATR=", DoubleToString(currentATR, _Digits),
                  " | SL=", effectiveSL, " pips | TP=", effectiveTP,
                  " pips | R:R=1:", DoubleToString(InpATRTPRatio, 1));
      }
   }
   
   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = CalculateLotSize(price, effectiveSL);
   
   if(lot < 0)
   {
      Print("TRADE CANCELLED: Lot sizing failed");
      LogTradeEvent("CANCEL", comment, isBuy, price, 0, 0, 0, -1, 0);
      return;
   }
   
   // Margin safety check
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
            double maxMarginAllowed = equity * (InpMaxMarginPercent / 100.0);
            double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            
            double reducedLot = lot * (maxMarginAllowed / marginRequired);
            reducedLot = MathFloor(reducedLot / lotStep) * lotStep;
            
            if(reducedLot < minLot)
            {
               double minMargin = 0;
               if(OrderCalcMargin(orderType, _Symbol, minLot, price, minMargin))
               {
                  double minMarginPct = (equity > 0) ? (minMargin / equity * 100.0) : 100.0;
                  if(minMarginPct > 50.0)
                  {
                     Print("BLOCKED: Min lot margin ", DoubleToString(minMarginPct, 1), "% > 50%");
                     LogTradeEvent("CANCEL", comment, isBuy, price, 0, 0, minLot, -1, 0);
                     return;
                  }
               }
               reducedLot = minLot;
            }
            
            Print("MARGIN SAFETY: Lot ", DoubleToString(lot, 2), " -> ", DoubleToString(reducedLot, 2),
                  " (margin ", DoubleToString(marginPercent, 1), "% > ", DoubleToString(InpMaxMarginPercent, 1), "%)");
            lot = reducedLot;
         }
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
                 + " | " + comment
                 + " | Entry: " + DoubleToString(price, _Digits)
                 + " | SL: " + DoubleToString(sl, _Digits)
                 + " | TP: " + DoubleToString(tp, _Digits)
                 + " | Lot: " + DoubleToString(lot, 2));
   
   // Validate SL/TP
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
   
   LogTradeEvent("ATTEMPT", comment, isBuy, price, sl, tp, lot, -1, 0);
   
   bool result = false;
   if(isBuy)
      result = trade.Buy(lot, _Symbol, 0, sl, tp, comment);
   else
      result = trade.Sell(lot, _Symbol, 0, sl, tp, comment);
   
   if(result)
   {
      Print("SUCCESS: Ticket #", trade.ResultOrder());
      _WriteLogLine("SUCCESS: Ticket #" + IntegerToString((long)trade.ResultOrder())
                    + " | " + comment
                    + " | " + (isBuy ? "BUY" : "SELL") + " " + DoubleToString(lot, 2) + " lot"
                    + " | Entry: " + DoubleToString(price, _Digits)
                    + " | SL: " + DoubleToString(sl, _Digits)
                    + " | TP: " + DoubleToString(tp, _Digits));
      LogTradeEvent("SUCCESS", comment, isBuy, price, sl, tp, lot, trade.ResultRetcode(), trade.ResultOrder());
      g_lastTradeTime = TimeCurrent();
      g_dailyTradeCount++;
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
//| Manage Open Positions (Breakeven + Trailing)                      |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   double pipValue = GetPipValue();
   if(pipValue <= 0) return;
   
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // Get current ATR for adaptive trailing
   double currentATR = 0;
   if(InpUseTrailingStop)
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
      
      double newSL = currentSL;
      bool needsUpdate = false;
      string updateReason = "";
      
      // === TRAILING STOP (Priority 1) ===
      int trailDistancePips = InpTrailingMinDistance;
      int trailActivatePips = InpTrailingMinActivate;
      
      if(currentATR > 0)
      {
         trailDistancePips = (int)MathRound((currentATR * InpTrailingATRMultiplier) / pipValue);
         trailActivatePips = (int)MathRound((currentATR * InpTrailingATRMultiplier * 1.25) / pipValue);
         if(trailDistancePips < InpTrailingMinDistance) trailDistancePips = InpTrailingMinDistance;
         if(trailActivatePips < InpTrailingMinActivate) trailActivatePips = InpTrailingMinActivate;
      }
      
      if(InpUseTrailingStop && profitPips >= trailActivatePips)
      {
         double trailingDistance = trailDistancePips * pipValue;
         double potentialSL = 0;
         
         if(posType == POSITION_TYPE_BUY)
         {
            potentialSL = currentPrice - trailingDistance;
            if(potentialSL > currentSL)
            {
               newSL = NormalizeDouble(potentialSL, digits);
               needsUpdate = true;
               updateReason = "TRAILING";
            }
         }
         else
         {
            potentialSL = currentPrice + trailingDistance;
            if(potentialSL < currentSL || currentSL == 0)
            {
               newSL = NormalizeDouble(potentialSL, digits);
               needsUpdate = true;
               updateReason = "TRAILING";
            }
         }
      }
      // === BREAKEVEN (Priority 2) ===
      // Locks in InpBreakevenLockPips of profit instead of plain entry (prevents "$0 giveback" pattern)
      else if(InpBreakevenPips > 0 && profitPips >= InpBreakevenPips)
      {
         double lockDistance = (InpBreakevenLockPips > 0 ? InpBreakevenLockPips : 0) * pipValue;
         
         if(posType == POSITION_TYPE_BUY)
         {
            double targetSL = openPrice + lockDistance;
            // Only move SL up (never down) and only if BE-zone SL is better than current
            if(targetSL > currentSL && targetSL < currentPrice)
            {
               newSL = NormalizeDouble(targetSL, digits);
               needsUpdate = true;
               updateReason = (InpBreakevenLockPips > 0)
                  ? StringFormat("BREAKEVEN+LOCK%dp", InpBreakevenLockPips)
                  : "BREAKEVEN";
            }
         }
         else if(posType == POSITION_TYPE_SELL)
         {
            double targetSL = openPrice - lockDistance;
            if((targetSL < currentSL || currentSL == 0) && targetSL > currentPrice)
            {
               newSL = NormalizeDouble(targetSL, digits);
               needsUpdate = true;
               updateReason = (InpBreakevenLockPips > 0)
                  ? StringFormat("BREAKEVEN+LOCK%dp", InpBreakevenLockPips)
                  : "BREAKEVEN";
            }
         }
      }
      
      // Execute modification
      if(needsUpdate)
      {
         double slDeltaPips = MathAbs(newSL - currentSL) / pipValue;
         if(currentSL > 0 && slDeltaPips < InpMinSLUpdatePips)
            continue;

         datetime lastSLUpdateTime = GetLastSLUpdateTime(ticket);
         if(lastSLUpdateTime > 0 && (TimeCurrent() - lastSLUpdateTime) < InpMinSecondsBetweenSLUpdates)
            continue;

         bool validSL = false;
         if(posType == POSITION_TYPE_BUY && newSL < currentPrice && newSL > currentSL)
            validSL = true;
         else if(posType == POSITION_TYPE_SELL && newSL > currentPrice && (newSL < currentSL || currentSL == 0))
            validSL = true;
         
         if(validSL)
         {
            if(InpEnableDetailedLogs)
            {
               Print(updateReason, ": #", ticket,
                     " | Profit: ", DoubleToString(profitPips, 1), " pips",
                     " | SL: ", DoubleToString(currentSL, digits),
                     " -> ", DoubleToString(newSL, digits));
            }
            
            if(trade.PositionModify(ticket, newSL, currentTP))
            {
               SetLastSLUpdateTime(ticket, TimeCurrent());
               _WriteLogLine(updateReason + ": #" + IntegerToString((long)ticket)
                             + " | Profit: " + DoubleToString(profitPips, 1) + " pips"
                             + " | SL: " + DoubleToString(currentSL, digits)
                             + " -> " + DoubleToString(newSL, digits));
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
