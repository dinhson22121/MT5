//+------------------------------------------------------------------+
//|                                      ea_envelope_dema_v1.mq5     |
//|                                    Copyright 2026                  |
//|  v1.0 — DEMA/SMA Envelope Stack Trading                          |
//|  Strategy: 20m DEMA/SMA envelope → 10m confirm → 5m entry        |
//|  3-stack scaling: 0.01 → 0.02 → 0.03                             |
//|  Target R:R 2:1 | Max 1 hour per stack                          |
//|  Symbol: XAUUSDc (Gold)                                          |
//+------------------------------------------------------------------+
//| STRATEGY: DEMA/SMA Envelope (Bao Tử)                             |
//|                                                                   |
//|  JOB 1 (20m): Find n_max, n_min from DEMA/SMA touching candles   |
//|  JOB 2 (20m): Calculate is_high = Price-n_max, is_low=Price-n_min|
//|               Classify UP_ENVELOPE / DOWN_ENVELOPE / SIDEWAYS    |
//|  JOB 3 (10m→5m): Confirm price in envelope on 10m,              |
//|               then stack 3 entries on 5m chart                   |
//|                                                                   |
//|  ENTRY STACK (BUY):                                               |
//|    Entry 1 (0.01): Market at Mid = n_min + EnvWidth/2            |
//|    Entry 2 (0.02): BUY LIMIT at SL1 = n_min - buffer             |
//|    Entry 3 (0.03): BUY LIMIT at SL2 = SL1 - step                 |
//|    TP: n_max + avg(is_high - n_max) or $2/$4/$6 min              |
//|                                                                   |
//|  STATE (1-5): Adjusts lookback & buffers based on ATR volatility |
//|  1=dead 2=low 3=normal 4=active 5=volatile                       |
//|                                                                   |
//|  TIME LIMIT: 1 hour max per stack → close at market if unresolved |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//--- Constants
const double BROKER_STOP_BUFFER = 1.1;

//--- Stack tracking
struct StackInfo
{
   ulong    ticket1;       // Entry 1 position ticket (0 = not open)
   ulong    ticket2;       // Entry 2 position ticket
   ulong    ticket3;       // Entry 3 position ticket
   ulong    pending1;      // Entry 1 pending order ticket (LIMIT not yet filled)
   ulong    pending2;      // Entry 2 pending order ticket
   ulong    pending3;      // Entry 3 pending order ticket
   datetime placeTime;     // When stack was placed (for timeout before fill)
   datetime openTime;      // When Entry 1 filled
   bool     isBuy;         // Direction
   double   entry1Price;   // Entry 1 open price
   double   sl1, sl2, sl3; // SL levels
   double   tp;            // TP level
   double   lot1, lot2, lot3;
   int      state;         // 0=idle, 1=entry1_open+pendings_placed, 2=entry2_filled, 3=all_filled
};

StackInfo g_stack;

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Strategy: DEMA/SMA Envelope ==="
input int    InpDEMAPeriod         = 9;      // DEMA period on 20m (double-smoothed EMA)
input int    InpSMAPeriod          = 16;     // SMA period on 20m (simple moving average)
input int    InpEnvelopeLookback   = 20;     // Candles to find n_max/n_min on 20m
input double InpEnvelopeThreshold  = 0.001;  // Min envelope width % to qualify (0 = off)

input group "=== Entry: Stack Scaling ==="
input double InpEntry1Lot          = 0.01;   // Entry 1 lot size
input double InpEntry2Lot          = 0.02;   // Entry 2 lot size
input double InpEntry3Lot          = 0.03;   // Entry 3 lot size
input double InpEntry1Pct          = 50.0;   // Entry 1 at X% of envelope from n_min (50=mid)
input double InpSLBufferPct        = 10.0;   // SL buffer % outside envelope
input double InpSLStepPct          = 50.0;   // Step % between SL levels (of envelope width)

input group "=== Take Profit ==="
input double InpTPMultiplier       = 1.0;    // TP = n_max/envelope + multiplier × avg(is_high - n_max)
input double InpMinProfitUSD_01    = 2.0;    // Minimum profit $ for 0.01 lot
input double InpMinProfitUSD_02    = 4.0;    // Minimum profit $ for 0.02 lot
input double InpMinProfitUSD_03    = 6.0;    // Minimum profit $ for 0.03 lot

input group "=== State: Market Sensitivity ==="
input bool   InpAutoState          = true;   // Auto-detect state from ATR
input int    InpManualState        = 3;      // Manual state (1-5), if InpAutoState=false
input int    InpStateATRPeriod     = 20;     // ATR period for auto state detection

input group "=== Risk Management ==="
input double InpMaxRiskPerStack    = 10.0;   // Max risk % per stack (all 3 entries combined)
input double InpMaxDailyLossPct    = 10.0;   // Daily loss circuit breaker
input double InpMaxWeeklyLossPct   = 20.0;   // Weekly loss circuit breaker
input int    InpMaxStacks          = 2;      // Max active stacks
input int    InpCooldownMinutes    = 30;     // Cooldown between stacks
input int    InpMaxTradeMinutes    = 60;     // Max duration per stack (minutes), 0 = unlimited

input group "=== Symbol & Session ==="
input bool   InpTradeXAUUSD        = true;   // Trade XAUUSD/Gold
input bool   InpUseTimeFilter      = false;  // Session filter (gold trades 24h)
input int    InpDisabledStartHour   = 2;      // Block entries from this hour (server time, e.g. 2=2AM GMT+7)
input int    InpDisabledEndHour     = 6;      // Block entries until this hour (e.g. 6=6AM GMT+7)
input int    InpMagicNumber        = 345678; // EA magic number

input group "=== Debug ==="
input bool   InpEnableFileLogging  = true;
input bool   InpEnableDetailedLogs = true;
input bool   InpEnableChartComment = false;
input string InpLogFolder          = "EA_Logs";

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
datetime g_lastStackTime   = 0;

// Daily/weekly loss tracking
int      g_dailyLossDay     = 0;
double   g_dailyStartEquity = 0;
int      g_weeklyLossWeek   = -1;
double   g_weeklyStartEquity = 0;

// Indicator handles (20m timeframe)
int g_handleSMA_M20;       // SMA on 20m
int g_handleATR_M20;       // ATR on 20m for state detection
int g_handleSMA_M5;        // SMA on 5m (for Entry 1 limit)
int g_handleSMA_M10;       // SMA on 10m (for cycle confirmation)

// Computed DEMA (manual calculation, no built-in handle)
double g_demaBuf[];         // DEMA values on 20m

// ATR tracking for auto-state
double g_atrHistory[];
int    g_atrHistoryCount = 0;
double g_atrAvg = 0;

//+------------------------------------------------------------------+
//| Utility: Symbol & Account                                         |
//+------------------------------------------------------------------+
bool IsGoldSymbol()
{
   string s = _Symbol;
   return (StringFind(s, "XAU") >= 0 || StringFind(s, "GOLD") >= 0);
}

bool IsSymbolAllowed()
{
   if(!InpTradeXAUUSD) return false;
   return IsGoldSymbol();
}

double GetPipValue()
{
   string s = _Symbol;
   double point = SymbolInfoDouble(s, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);

   if(point <= 0) { Print("WARNING: SYMBOL_POINT=0 - fallback 0.01"); point = 0.01; }

   if(StringFind(s, "XAU") >= 0 || StringFind(s, "GOLD") >= 0) return 0.10;
   if(StringFind(s, "BTC") >= 0)  return 10.0;
   if(StringFind(s, "JPY") >= 0)  return (digits == 3 || digits == 2) ? 0.01 : point * 10;
   return (digits == 5 || digits == 3) ? point * 10 : point;
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
   }
}

bool IsDailyLossLimitHit()
{
   if(InpMaxDailyLossPct <= 0) return false;
   UpdateDailyEquityBaseline();
   if(g_dailyStartEquity <= 0) return false;
   double lossPct = ((g_dailyStartEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / g_dailyStartEquity) * 100.0;
   return (lossPct >= InpMaxDailyLossPct);
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
   }
}

bool IsWeeklyLossLimitHit()
{
   if(InpMaxWeeklyLossPct <= 0) return false;
   UpdateWeeklyEquityBaseline();
   if(g_weeklyStartEquity <= 0) return false;
   double lossPct = ((g_weeklyStartEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / g_weeklyStartEquity) * 100.0;
   return (lossPct >= InpMaxWeeklyLossPct);
}

//+------------------------------------------------------------------+
//| Spread Check                                                      |
//+------------------------------------------------------------------+
bool CheckSpread()
{
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / GetPipValue();
   // Gold typical spread: 20-30 pips. Block if > 50
   if(spread > 50.0)
   {
      if(InpEnableDetailedLogs)
         PrintLog("BLOCKED: Spread " + DoubleToString(spread, 1) + " pips (max 50)");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Logging                                                           |
//+------------------------------------------------------------------+
string _GetDailyLogFileName(string suffix)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string dateStr = IntegerToString(dt.year) + "." + StringFormat("%02d", dt.mon) + "." + StringFormat("%02d", dt.day);
   return InpLogFolder + "/EA_Envelope_" + suffix + "_" + dateStr + "_" + _Symbol + ".txt";
}

void _WriteLogLine(string msg)
{
   if(!InpEnableFileLogging) return;
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
   if(!InpEnableFileLogging) return;
   string fileName = _GetDailyLogFileName("Trades");
   bool isNew = !FileIsExist(fileName, FILE_COMMON);
   int fh = FileOpen(fileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(fh == INVALID_HANDLE) { fh = FileOpen(fileName, FILE_WRITE|FILE_CSV|FILE_COMMON); isNew = true; }
   if(fh == INVALID_HANDLE) return;
   if(isNew && FileSize(fh) == 0)
      FileWriteString(fh, "Time,Symbol,Stage,Direction,Comment,Price,SL,TP,Lot,Code,Ticket\r\n");
   FileSeek(fh, 0, SEEK_END);
   string rec = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)
              + "," + _Symbol + "," + stage + "," + (isBuy ? "BUY" : "SELL")
              + "," + comment + "," + DoubleToString(price, _Digits)
              + "," + DoubleToString(sl, _Digits) + "," + DoubleToString(tp, _Digits)
              + "," + DoubleToString(lot, 2) + "," + IntegerToString(resultCode)
              + "," + IntegerToString((long)ticket);
   FileWriteString(fh, rec + "\r\n");
   FileClose(fh);
}

//+------------------------------------------------------------------+
//| DEMA Calculation (Double Exponential Moving Average)              |
//| DEMA = 2 × EMA₁ − EMA₂                                           |
//|   where EMA₁ = EMA(close, N), EMA₂ = EMA(EMA₁, N)               |
//|   SMA = simple arithmetic mean of last N closes                 |
//+------------------------------------------------------------------+
void CalculateDEMA(const double &closePrices[], int period, double &dema[])
{
   int size = ArraySize(closePrices);
   if(size < period + 1)
   {
      ArrayResize(dema, size);
      for(int i = 0; i < size; i++) dema[i] = closePrices[i];
      return;
   }

   ArrayResize(dema, size);
   double alpha = 2.0 / (period + 1.0);

   // EMA1 = EMA(close, period)
   double ema1[];
   ArrayResize(ema1, size);
   ema1[size - 1] = closePrices[size - 1];  // seed with first close (oldest bar)
   for(int i = size - 2; i >= 0; i--)
      ema1[i] = alpha * closePrices[i] + (1.0 - alpha) * ema1[i + 1];

   // EMA2 = EMA(ema1, period)
   double ema2[];
   ArrayResize(ema2, size);
   ema2[size - 1] = ema1[size - 1];
   for(int i = size - 2; i >= 0; i--)
      ema2[i] = alpha * ema1[i] + (1.0 - alpha) * ema2[i + 1];

   // DEMA = 2 * EMA1 - EMA2
   for(int i = 0; i < size; i++)
      dema[i] = 2.0 * ema1[i] - ema2[i];
}

//+------------------------------------------------------------------+
//| Determine Market State (1-5) from ATR                             |
//+------------------------------------------------------------------+
int GetMarketState()
{
   if(!InpAutoState)
      return MathMax(1, MathMin(5, InpManualState));

   // Get current ATR on 20m
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(g_handleATR_M20, 0, 0, 1, atrBuf) < 1)
      return 3; // default normal

   double currentATR = atrBuf[0];
   if(currentATR <= 0) return 3;

   // Update ATR history for average
   int maxHistory = InpStateATRPeriod * 2;
   if(g_atrHistoryCount < maxHistory)
   {
      ArrayResize(g_atrHistory, g_atrHistoryCount + 1);
      g_atrHistory[g_atrHistoryCount] = currentATR;
      g_atrHistoryCount++;
   }
   else
   {
      // Shift and replace oldest
      for(int i = 0; i < maxHistory - 1; i++)
         g_atrHistory[i] = g_atrHistory[i + 1];
      g_atrHistory[maxHistory - 1] = currentATR;
   }

   // Calculate average
   if(g_atrHistoryCount < 5) return 3;
   g_atrAvg = 0;
   for(int i = 0; i < g_atrHistoryCount; i++)
      g_atrAvg += g_atrHistory[i];
   g_atrAvg /= g_atrHistoryCount;

   if(g_atrAvg <= 0) return 3;

   double ratio = currentATR / g_atrAvg;

   if(ratio < 0.6)       return 1;
   if(ratio < 0.8)       return 2;
   if(ratio <= 1.2)      return 3;
   if(ratio <= 1.5)      return 4;
   return 5;
}

//+------------------------------------------------------------------+
//| Get Lookback based on State                                       |
//+------------------------------------------------------------------+
int GetStateLookback()
{
   int base = InpEnvelopeLookback;
   int state = GetMarketState();
   switch(state)
   {
      case 1: return base + 10;  // wider lookback for low volatility
      case 2: return base + 5;
      case 3: return base;       // standard
      case 4: return base - 5;
      case 5: return base - 10;  // tighter lookback for high volatility
   }
   return base;
}

//+------------------------------------------------------------------+
//| Get SL Buffer % based on State                                    |
//+------------------------------------------------------------------+
double GetStateSLBuffer()
{
   int state = GetMarketState();
   switch(state)
   {
      case 1: return InpSLBufferPct * 0.8;
      case 2: return InpSLBufferPct * 0.9;
      case 3: return InpSLBufferPct;
      case 4: return InpSLBufferPct * 1.2;
      case 5: return InpSLBufferPct * 1.5;
   }
   return InpSLBufferPct;
}

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Fetch 10m price (REMOVED — no longer used)                        |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Get All Indicator Values from 20m                                 |
//+------------------------------------------------------------------+
bool GetIndicatorValues20m(double &dema[], double &sma[], double &highs[], double &lows[],
                           double &closes[], int lookback, int &barCount)
{
   int neededBars = lookback + InpDEMAPeriod + 10;  // extra for DEMA calculation

   // Fetch close prices
   ArraySetAsSeries(closes, true);
   if(CopyClose(_Symbol, PERIOD_M20, 0, neededBars, closes) < neededBars)
   { Print("ERROR: CopyClose 20m failed"); return false; }

   // Fetch highs and lows
   ArraySetAsSeries(highs, true);
   if(CopyHigh(_Symbol, PERIOD_M20, 0, neededBars, highs) < neededBars)
   { Print("ERROR: CopyHigh 20m failed"); return false; }

   ArraySetAsSeries(lows, true);
   if(CopyLow(_Symbol, PERIOD_M20, 0, neededBars, lows) < neededBars)
   { Print("ERROR: CopyLow 20m failed"); return false; }

   // Calculate DEMA from close prices
   CalculateDEMA(closes, InpDEMAPeriod, dema);

   // Fetch SMA
   ArraySetAsSeries(sma, true);
   if(CopyBuffer(g_handleSMA_M20, 0, 0, neededBars, sma) < neededBars)
   { Print("ERROR: CopyBuffer SMA 20m failed"); return false; }

   barCount = ArraySize(closes);
   return true;
}

//+------------------------------------------------------------------+
//| Fetch 10m price (REMOVED — no longer used)                        |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Check Trading Conditions                                          |
//+------------------------------------------------------------------+
bool CheckTradingConditions()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   { PrintLog("BLOCKED: Terminal trading not allowed"); return false; }

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   { PrintLog("BLOCKED: EA trading not allowed"); return false; }

   if(!IsSymbolAllowed())
   { PrintLog("BLOCKED: Symbol not XAUUSD or InpTradeXAUUSD=false"); return false; }

   // Cooldown
   if(g_lastStackTime > 0 && (int)(TimeCurrent() - g_lastStackTime) < InpCooldownMinutes * 60)
   { if(InpEnableDetailedLogs) Print("BLOCKED: Cooldown active"); return false; }

   // Active stack limit
   if(g_stack.state > 0 && InpMaxStacks <= 1)
   { if(InpEnableDetailedLogs) Print("BLOCKED: Stack already active"); return false; }

   // Loss circuit breakers
   if(IsDailyLossLimitHit())
   { if(InpEnableDetailedLogs) PrintLog("BLOCKED: Daily loss limit"); return false; }
   if(IsWeeklyLossLimitHit())
   { if(InpEnableDetailedLogs) PrintLog("BLOCKED: Weekly loss limit"); return false; }

   if(!CheckSpread()) return false;

   // Block entries during disabled hours (GMT+7 timezone, e.g. 2AM-6AM)
   if(InpDisabledStartHour != InpDisabledEndHour)
   {
      MqlDateTime dt;
      TimeToStruct(TimeGMT() + 7 * 3600, dt);  // GMT+7
      int h = dt.hour;
      bool blocked;
      if(InpDisabledStartHour < InpDisabledEndHour)
         blocked = (h >= InpDisabledStartHour && h < InpDisabledEndHour);
      else
         blocked = (h >= InpDisabledStartHour || h < InpDisabledEndHour);  // overnight
      if(blocked)
      { if(InpEnableDetailedLogs) PrintLog("BLOCKED: Disabled hours " + IntegerToString(InpDisabledStartHour) + "-" + IntegerToString(InpDisabledEndHour) + " GMT+7"); return false; }
   }

   return true;
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // Validate symbol
   if(!IsGoldSymbol())
   {
      Print("WARNING: EA designed for XAUUSD. Attach to XAUUSDc chart.");
      Print("         Current symbol: ", _Symbol);
   }

   // Create indicator handles (20m)
   g_handleSMA_M20 = iMA(_Symbol, PERIOD_M20, InpSMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   g_handleATR_M20 = iATR(_Symbol, PERIOD_M20, InpStateATRPeriod);
   // Create indicator handles (5m) — for Entry 1 limit price
   g_handleSMA_M5  = iMA(_Symbol, PERIOD_M5,  InpSMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   g_handleSMA_M10 = iMA(_Symbol, PERIOD_M10, InpSMAPeriod, 0, MODE_SMA, PRICE_CLOSE);

   if(g_handleSMA_M20 == INVALID_HANDLE || g_handleATR_M20 == INVALID_HANDLE ||
      g_handleSMA_M5 == INVALID_HANDLE || g_handleSMA_M10 == INVALID_HANDLE)
   {
      Print("FATAL: Failed to create indicator handles on 20m!");
      return INIT_FAILED;
   }

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

   // Init stack tracking — recover existing positions from previous run
   ZeroMemory(g_stack);
   RecoverStack();

   // === Summary ===
   double bal = AccountInfoDouble(ACCOUNT_EQUITY);
   double pipVal = GetPipValue();
   Print("══════════════════════════════════════════");
   Print("  EA v1.0 — DEMA/SMA Envelope Stack");
   Print("  Symbol: ", _Symbol, " | Pip: ", DoubleToString(pipVal, 2));
   Print("  Equity: $", DoubleToString(bal, 2));
   Print("──────────────────────────────────────────");
   Print("  DEMA(", InpDEMAPeriod, ") / SMA(", InpSMAPeriod, ") on 20m");
   Print("  Lookback: ", InpEnvelopeLookback, " candles");
   Print("  Stack: ", DoubleToString(InpEntry1Lot, 2), " → ",
                           DoubleToString(InpEntry2Lot, 2), " → ",
                           DoubleToString(InpEntry3Lot, 2));
   Print("  TP: $", DoubleToString(InpMinProfitUSD_01, 1), "/$",
                     DoubleToString(InpMinProfitUSD_02, 1), "/$",
                     DoubleToString(InpMinProfitUSD_03, 1),
         " or formula (whichever higher)");
   Print("  Max duration: ", InpMaxTradeMinutes, " min");
   Print("  Disabled hours: ", InpDisabledStartHour, ":00-", InpDisabledEndHour, ":00 (GMT+7)");
   Print("  Magic: ", InpMagicNumber);
   Print("══════════════════════════════════════════");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Recover stack from existing positions (after MT5 restart)          |
//+------------------------------------------------------------------+
void RecoverStack()
{
   int count = 0;
   datetime earliestTime = 0;

   // --- Recover filled positions ---
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      datetime posTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(earliestTime == 0 || posTime < earliestTime) earliestTime = posTime;

      string comment = PositionGetString(POSITION_COMMENT);
      if(comment == "ENV_E1_BUY" || comment == "ENV_E1_SELL")
      {
         g_stack.ticket1     = ticket;
         g_stack.isBuy       = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
         g_stack.entry1Price = PositionGetDouble(POSITION_PRICE_OPEN);
         g_stack.sl1         = PositionGetDouble(POSITION_SL);
         g_stack.tp          = PositionGetDouble(POSITION_TP);
         g_stack.lot1        = PositionGetDouble(POSITION_VOLUME);
         g_stack.openTime    = posTime;
         g_stack.state       = 1;
         count++;
      }
      else if(comment == "ENV_E2_BUY" || comment == "ENV_E2_SELL")
      {
         g_stack.ticket2 = ticket;
         g_stack.sl2     = PositionGetDouble(POSITION_SL);
         g_stack.lot2    = PositionGetDouble(POSITION_VOLUME);
         g_stack.state   = MathMax(g_stack.state, 2);
         count++;
      }
      else if(comment == "ENV_E3_BUY" || comment == "ENV_E3_SELL")
      {
         g_stack.ticket3 = ticket;
         g_stack.sl3     = PositionGetDouble(POSITION_SL);
         g_stack.lot3    = PositionGetDouble(POSITION_VOLUME);
         g_stack.state   = 3;
         count++;
      }
   }

   // --- Recover pending limit orders (not yet filled) ---
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket <= 0 || !OrderSelect(orderTicket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      long orderType = OrderGetInteger(ORDER_TYPE);
      if(orderType != ORDER_TYPE_BUY_LIMIT && orderType != ORDER_TYPE_SELL_LIMIT) continue;

      datetime orderTime = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(earliestTime == 0 || orderTime < earliestTime) earliestTime = orderTime;

      string comment = OrderGetString(ORDER_COMMENT);
      if(comment == "ENV_E1_BUY" || comment == "ENV_E1_SELL")
      {
         g_stack.pending1    = orderTicket;
         g_stack.isBuy       = (orderType == ORDER_TYPE_BUY_LIMIT);
         g_stack.entry1Price = OrderGetDouble(ORDER_PRICE_OPEN);
         g_stack.sl1         = OrderGetDouble(ORDER_SL);
         g_stack.tp          = OrderGetDouble(ORDER_TP);
         g_stack.lot1        = OrderGetDouble(ORDER_VOLUME_INITIAL);
         g_stack.state       = 1;
         count++;
      }
      else if(comment == "ENV_E2_BUY" || comment == "ENV_E2_SELL")
      {
         g_stack.pending2 = orderTicket;
         g_stack.sl2      = OrderGetDouble(ORDER_SL);
         g_stack.lot2     = OrderGetDouble(ORDER_VOLUME_INITIAL);
         g_stack.state    = MathMax(g_stack.state, 1);
         count++;
      }
      else if(comment == "ENV_E3_BUY" || comment == "ENV_E3_SELL")
      {
         g_stack.pending3 = orderTicket;
         g_stack.sl3      = OrderGetDouble(ORDER_SL);
         g_stack.lot3     = OrderGetDouble(ORDER_VOLUME_INITIAL);
         g_stack.state    = MathMax(g_stack.state, 1);
         count++;
      }
   }

   // Set openTime so the timeout can track elapsed time
   if(count > 0 && earliestTime > 0)
   {
      g_stack.openTime = earliestTime;
      g_stack.placeTime = earliestTime;
      PrintLog("Recovered " + IntegerToString(count) + " position(s)/order(s) from previous run | Stack state=" + IntegerToString(g_stack.state) + " | Timer start=" + TimeToString(earliestTime));
   }
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(g_handleSMA_M20);
   IndicatorRelease(g_handleATR_M20);
   IndicatorRelease(g_handleSMA_M5);
   IndicatorRelease(g_handleSMA_M10);
   Comment("");
   Print("EA Envelope v1.0 STOPPED. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // Manage existing stack every tick (timeout, SL consolidation, TP)
   ManageStack();

   // New 5m bar detection
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_M5, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   // === NEW 5m BAR ===

   // Don't evaluate new signals if stack already active
   if(g_stack.state > 0)
   {
      if(InpEnableDetailedLogs)
         PrintLog("Waiting: Stack #" + IntegerToString((long)g_stack.ticket1) + " active (state " + IntegerToString(g_stack.state) + ")");
      return;
   }

   // Market state
   int state = GetMarketState();
   int lookback = GetStateLookback();

   // JOB 1+2: Fetch 20m data, find envelope
   double dema[], sma[], highs[], lows[], closes[];
   int barCount;
   if(!GetIndicatorValues20m(dema, sma, highs, lows, closes, lookback, barCount))
   {
      if(InpEnableDetailedLogs) Print("WARNING: GetIndicatorValues20m failed");
      return;
   }

   // Current price (M5 close) + DEMA/SMA direction
   double currentPrice = iClose(_Symbol, PERIOD_M5, 1);
   double demaNow = dema[1];     // 20m DEMA
   double smaNow  = sma[1];      // 20m SMA

   // ── Fetch M5 DEMA/SMA for Entry 1 limit price ──
   double m5Closes[];
   double m5Dema[];
   double m5Sma[];
   int m5Needed = InpDEMAPeriod + InpSMAPeriod + 10;
   ArraySetAsSeries(m5Closes, true);
   ArraySetAsSeries(m5Sma, true);
   double dema5m = 0, sma5m = 0;
   if(CopyClose(_Symbol, PERIOD_M5, 0, m5Needed, m5Closes) >= m5Needed &&
      CopyBuffer(g_handleSMA_M5, 0, 0, m5Needed, m5Sma) >= m5Needed)
   {
      CalculateDEMA(m5Closes, InpDEMAPeriod, m5Dema);
      dema5m = m5Dema[1];  // M5 DEMA last closed bar
      sma5m  = m5Sma[1];   // M5 SMA last closed bar
   }

   // ── is_high / is_low from 4-bar Low vs min/max(DEMA,SMA) ──
   // avgLowMin uses min(DEMA,SMA), avgLowMax uses max(DEMA,SMA)
   // Direction from DEMA vs SMA cross
   double avgLowMin = 0, avgLowMax = 0;
   int barCount4 = MathMin(4, MathMin(ArraySize(dema), MathMin(ArraySize(sma), MathMin(ArraySize(highs), ArraySize(lows)))) - 1);
   if(barCount4 < 1) barCount4 = 1;
   for(int i = 1; i <= barCount4; i++)
   {
      double minMA = MathMin(dema[i], sma[i]);
      double maxMA = MathMax(dema[i], sma[i]);
      avgLowMin += lows[i] - minMA;
      avgLowMax += lows[i] - maxMA;
   }
   avgLowMin /= (double)barCount4;
   avgLowMax /= (double)barCount4;

   // Direction: DEMA < SMA → downtrend, DEMA > SMA → uptrend
   bool is_low  = (demaNow < smaNow);   // DEMA below SMA → downtrend
   bool is_high = (demaNow > smaNow);   // DEMA above SMA → uptrend

   // ── 10m cycle confirmation: n_max/n_min from 10m DEMA/SMA touching candles ──
   int lookback10 = lookback;
   double c10[], h10[], l10[], sma10[], dema10[];
   int needed10 = lookback10 + InpDEMAPeriod + 10;
   ArraySetAsSeries(c10, true);  ArraySetAsSeries(h10, true);
   ArraySetAsSeries(l10, true);  ArraySetAsSeries(sma10, true);
   bool inCycle = true;  // default pass if 10m data unavailable
   if(CopyClose(_Symbol, PERIOD_M10, 0, needed10, c10) >= needed10 &&
      CopyHigh(_Symbol, PERIOD_M10, 0, needed10, h10) >= needed10 &&
      CopyLow(_Symbol, PERIOD_M10, 0, needed10, l10) >= needed10 &&
      CopyBuffer(g_handleSMA_M10, 0, 0, needed10, sma10) >= needed10)
   {
      CalculateDEMA(c10, InpDEMAPeriod, dema10);
      double n_max_10 = -1e308, n_min_10 = 1e308;
      int cnt10 = MathMin(lookback10, ArraySize(dema10));
      for(int i = 1; i < cnt10; i++)
      {
         if(dema10[i] >= l10[i] && dema10[i] <= h10[i])
         { if(h10[i] > n_max_10) n_max_10 = h10[i]; if(l10[i] < n_min_10) n_min_10 = l10[i]; }
         if(sma10[i] >= l10[i] && sma10[i] <= h10[i])
         { if(h10[i] > n_max_10) n_max_10 = h10[i]; if(l10[i] < n_min_10) n_min_10 = l10[i]; }
      }
      // Fallback
      if(n_max_10 == -1e308) { for(int i = 1; i < cnt10; i++) { if(h10[i] > n_max_10) n_max_10 = h10[i]; } }
      if(n_min_10 == 1e308)  { for(int i = 1; i < cnt10; i++) { if(l10[i] < n_min_10) n_min_10 = l10[i]; } }

      double price10 = c10[1];
      inCycle = (price10 > n_min_10 && price10 < n_max_10);
      if(InpEnableDetailedLogs)
         PrintLog("  10m: n_min=" + DoubleToString(n_min_10, _Digits) + " n_max=" + DoubleToString(n_max_10, _Digits) +
                  " price=" + DoubleToString(price10, _Digits) + " inCycle=" + (inCycle ? "YES" : "NO"));
   }

   PrintLog("  avgLowMin: " + DoubleToString(avgLowMin, 2) + " | avgLowMax: " + DoubleToString(avgLowMax, 2) +
            " | DEMA" + (is_high ? ">" : "<") + "SMA | is_low=" + (is_low ? "YES" : "no") + " | is_high=" + (is_high ? "YES" : "no"));

   // Signal: simple DEMA/SMA direction + 200 pip distance filter
   double pipVal = GetPipValue();
   bool buySignal  = false;
   bool sellSignal = false;

   if(is_high && dema5m > 0 && sma5m > 0 && inCycle)
   {
      double midPrice = (dema5m + sma5m) / 2.0;
      // Use highest high of last 4 bars (20m) instead of currentPrice
      double refPrice = highs[1];
      for(int i = 2; i <= 4 && i < ArraySize(highs); i++)
         if(highs[i] > refPrice) refPrice = highs[i];
      double distPips = (refPrice - midPrice) / pipVal;
      buySignal = (distPips >= 130.0);
      if(InpEnableDetailedLogs) PrintLog("  BUY check: mid=" + DoubleToString(midPrice, _Digits) +
            " refHigh=" + DoubleToString(refPrice, _Digits) + " dist=" + DoubleToString(distPips, 1) + " pips " + (buySignal ? ">=130 OK" : "<130 SKIP"));
   }

   if(is_low && dema5m > 0 && sma5m > 0 && inCycle)
   {
      double midPrice = (dema5m + sma5m) / 2.0;
      // Use lowest low of last 4 bars (20m) instead of currentPrice
      double refPrice = lows[1];
      for(int i = 2; i <= 4 && i < ArraySize(lows); i++)
         if(lows[i] < refPrice) refPrice = lows[i];
      double distPips = (midPrice - refPrice) / pipVal;
      sellSignal = (distPips >= 130.0);
      if(InpEnableDetailedLogs) PrintLog("  SELL check: mid=" + DoubleToString(midPrice, _Digits) +
            " refLow=" + DoubleToString(refPrice, _Digits) + " dist=" + DoubleToString(distPips, 1) + " pips " + (sellSignal ? ">=130 OK" : "<130 SKIP"));
   }

   // Check trading conditions
   if(!CheckTradingConditions()) return;

   if(InpEnableDetailedLogs)
   {
      PrintLog("--- ANALYSIS [" + _Symbol + "] ---");
      PrintLog("  State: " + IntegerToString(state) + " | Lookback: " + IntegerToString(lookback));
      PrintLog("  DEMA20m: " + DoubleToString(demaNow, _Digits) + " | SMA20m: " + DoubleToString(smaNow, _Digits));
      PrintLog("  DEMA5m: " + DoubleToString(dema5m, _Digits) + " | SMA5m: " + DoubleToString(sma5m, _Digits));
      PrintLog("  Price: " + DoubleToString(currentPrice, _Digits));
      PrintLog("  avgLowMin: " + DoubleToString(avgLowMin, 2) + " | avgLowMax: " + DoubleToString(avgLowMax, 2));
      PrintLog("  Direction: " + (is_high ? "UP" : (is_low ? "DOWN" : "SIDEWAYS")));
      PrintLog("  Signal: " + (buySignal ? "BUY" : (sellSignal ? "SELL" : "NONE")));
   }

   if(buySignal)
   {
      double midPrice = (dema5m + sma5m) / 2.0;
      PrintLog(">>> BUY SIGNAL: DEMA5m=" + DoubleToString(dema5m, _Digits) + " SMA5m=" + DoubleToString(sma5m, _Digits) + " Mid=" + DoubleToString(midPrice, _Digits));
      OpenStack(true, midPrice);
   }
   else if(sellSignal)
   {
      double midPrice = (dema5m + sma5m) / 2.0;
      PrintLog(">>> SELL SIGNAL: DEMA5m=" + DoubleToString(dema5m, _Digits) + " SMA5m=" + DoubleToString(sma5m, _Digits) + " Mid=" + DoubleToString(midPrice, _Digits));
      OpenStack(false, midPrice);
   }
}

//+------------------------------------------------------------------+
//| Open Stack (Entry 1 market + Entry 2+3 pending)                   |
//+------------------------------------------------------------------+
void OpenStack(bool isBuy, double midPrice)
{
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipVal  = GetPipValue();

   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   price = NormalizeDouble(price, digits);

   // Session-based entry offset (GMT+7)
   //   13:00–01:00: buy early (+5), sell early (−5), LIMIT ONLY
   //   01:00–13:00: buy cheaper (−50), sell higher (+50), LIMIT→market fallback
   MqlDateTime dtSession;
   TimeToStruct(TimeGMT() + 7 * 3600, dtSession);
   bool tightSession = (dtSession.hour >= 13 || dtSession.hour < 1);  // 13h→1h next day

   midPrice = NormalizeDouble(midPrice, digits);
   double entryTarget;
   if(tightSession)
   {
      // Tight: buy early (mid+5), sell early (mid−5)
      entryTarget = isBuy ? NormalizeDouble(midPrice + 5.0 * pipVal, digits)
                          : NormalizeDouble(midPrice - 5.0 * pipVal, digits);
   }
   else
   {
      // Normal: buy cheaper (mid−50), sell higher (mid+50)
      entryTarget = isBuy ? NormalizeDouble(midPrice - 50.0 * pipVal, digits)
                          : NormalizeDouble(midPrice + 50.0 * pipVal, digits);
   }

   bool useLimit = false;
   if(isBuy && entryTarget < price)   useLimit = true;  // BUY LIMIT below current = valid
   if(!isBuy && entryTarget > price)  useLimit = true;  // SELL LIMIT above current = valid

   // Tight session: force LIMIT only, skip if target on wrong side
   if(tightSession && !useLimit)
   {
      PrintLog("BLOCKED: Tight session (13h–1h) — entryTarget on wrong side, skip");
      return;
   }

   double entry1Price = useLimit ? entryTarget : price;
   string entryType = useLimit ? "LIMIT" : "MARKET";

   // Session-based SL/TP (GMT+7): 7AM-1PM = 20/40, 1PM-1AM = 30/60
   double slPips, tpPips;
   if(dtSession.hour >= 7 && dtSession.hour < 13)
   {
      slPips = 20.0; tpPips = 40.0;  // Morning
   }
   else
   {
      slPips = 30.0; tpPips = 60.0;  // Afternoon/night
   }
   double slDist   = slPips * pipVal;
   double tpDist   = tpPips * pipVal;

   // Compute SL/TP from Entry 1 price
   double sl1, sl2, sl3, tp;
   if(isBuy)
   {
      sl1 = NormalizeDouble(entry1Price - slDist, digits);
      sl2 = NormalizeDouble(sl1 - slDist, digits);
      sl3 = NormalizeDouble(sl2 - slDist, digits);
      tp  = NormalizeDouble(entry1Price + tpDist, digits);
   }
   else
   {
      sl1 = NormalizeDouble(entry1Price + slDist, digits);
      sl2 = NormalizeDouble(sl1 + slDist, digits);
      sl3 = NormalizeDouble(sl2 + slDist, digits);
      tp  = NormalizeDouble(entry1Price - tpDist, digits);
   }

   PrintLog("════════════════════════════════════");
   PrintLog("  📐 " + (isBuy ? "BUY" : "SELL") + " STACK | Entry1=" + entryType + " @" + DoubleToString(entry1Price, digits));
   PrintLog("  Mid(DEMA+SMA)/2=" + DoubleToString(midPrice, digits) + " | EntryTarget=" + DoubleToString(entryTarget, digits) + " | Market=" + DoubleToString(price, digits));
   PrintLog("  SL₁=" + DoubleToString(sl1, digits) +
            " | SL₂=" + DoubleToString(sl2, digits) +
            " | SL₃=" + DoubleToString(sl3, digits) +
            " | TP=" + DoubleToString(tp, digits));
   PrintLog("  SL=" + DoubleToString(slPips, 0) + " pips | TP=" + DoubleToString(tpPips, 0) + " pips | R:R 2:1");

   // Validate broker min stop distance
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point * BROKER_STOP_BUFFER;
   if(slDist < minDist || tpDist < minDist)
   {
      PrintLog("BLOCKED: Stop distance too small");
      return;
   }

   // Margin check
   double totalLot = InpEntry1Lot + InpEntry2Lot + InpEntry3Lot;
   double marginReq = 0;
   if(OrderCalcMargin(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, totalLot, price, marginReq))
   {
      double marginPct = (AccountInfoDouble(ACCOUNT_EQUITY) > 0) ? (marginReq / AccountInfoDouble(ACCOUNT_EQUITY) * 100.0) : 100.0;
      if(marginPct > InpMaxRiskPerStack)
      {
         PrintLog("BLOCKED: Stack margin " + DoubleToString(marginPct, 1) + "% > max " + DoubleToString(InpMaxRiskPerStack, 1) + "%");
         return;
      }
   }

   // ── Entry 1: LIMIT or MARKET ──
   bool result;
   if(useLimit)
   {
      if(isBuy)
         result = trade.BuyLimit(InpEntry1Lot, entryTarget, _Symbol, sl1, tp, ORDER_TIME_GTC, 0, "ENV_E1_BUY");
      else
         result = trade.SellLimit(InpEntry1Lot, entryTarget, _Symbol, sl1, tp, ORDER_TIME_GTC, 0, "ENV_E1_SELL");
   }
   else
   {
      if(isBuy)
         result = trade.Buy(InpEntry1Lot, _Symbol, price, sl1, tp, "ENV_E1_BUY");
      else
         result = trade.Sell(InpEntry1Lot, _Symbol, price, sl1, tp, "ENV_E1_SELL");
   }

   if(!result)
   {
      PrintLog("FAILED Entry 1: Error " + IntegerToString((int)trade.ResultRetcode()));
      return;
   }

   // Timer starts NOW (even if limit order not yet filled)
   datetime now = TimeCurrent();
   g_stack.openTime = now;
   g_lastStackTime  = now;

   ulong ticket1 = trade.ResultOrder();
   bool isFilled = (trade.ResultRetcode() == TRADE_RETCODE_DONE);
   double fillPrice = trade.ResultPrice();

   if(useLimit && !isFilled)
   {
      // LIMIT order placed but not filled yet — store as pending
      g_stack.pending1    = ticket1;
      g_stack.entry1Price = entryTarget;  // target price, not yet filled
   }
   else
   {
      g_stack.ticket1     = ticket1;
      g_stack.entry1Price = fillPrice;
      PrintLog("✅ ENTRY 1 FILLED: #" + IntegerToString((long)ticket1) + " " +
               (isBuy ? "BUY" : "SELL") + " Lot=" + DoubleToString(InpEntry1Lot, 2) +
               " @ " + DoubleToString(fillPrice, digits) +
               " | SL=" + DoubleToString(sl1, digits) + " | TP=" + DoubleToString(tp, digits));
   }

   g_stack.isBuy       = isBuy;
   g_stack.sl1         = sl1;
   g_stack.sl2         = sl2;
   g_stack.sl3         = sl3;
   g_stack.tp          = tp;
   g_stack.lot1        = InpEntry1Lot;
   g_stack.lot2        = InpEntry2Lot;
   g_stack.lot3        = InpEntry3Lot;
   g_stack.state       = 1;  // active (even if Entry 1 is pending)

   // ── Entry 2: Pending at SL₁ ──
   if(isBuy)
      trade.BuyLimit(InpEntry2Lot, sl1, _Symbol, sl2, tp, ORDER_TIME_GTC, 0, "ENV_E2_BUY");
   else
      trade.SellLimit(InpEntry2Lot, sl1, _Symbol, sl2, tp, ORDER_TIME_GTC, 0, "ENV_E2_SELL");

   ulong pending2 = trade.ResultOrder();
   if(pending2 > 0)
   {
      g_stack.pending2 = pending2;
      PrintLog("  ⏳ PENDING E2 (0.02): @" + DoubleToString(sl1, digits) +
               " | SL=" + DoubleToString(sl2, digits) + " | TP=" + DoubleToString(tp, digits));
   }
   else
      PrintLog("  ⚠️ E2 pending FAILED");

   // ── Entry 3: Pending at SL₂ ──
   if(isBuy)
      trade.BuyLimit(InpEntry3Lot, sl2, _Symbol, sl3, tp, ORDER_TIME_GTC, 0, "ENV_E3_BUY");
   else
      trade.SellLimit(InpEntry3Lot, sl2, _Symbol, sl3, tp, ORDER_TIME_GTC, 0, "ENV_E3_SELL");

   ulong pending3 = trade.ResultOrder();
   if(pending3 > 0)
   {
      g_stack.pending3 = pending3;
      PrintLog("  ⏳ PENDING E3 (0.03): @" + DoubleToString(sl2, digits) +
               " | SL=" + DoubleToString(sl3, digits) + " | TP=" + DoubleToString(tp, digits));
   }
   else
      PrintLog("  ⚠️ E3 pending FAILED");

   g_lastStackTime = TimeCurrent();
   PrintLog("  ⏱ Timer: " + IntegerToString(InpMaxTradeMinutes) + " min");
   PrintLog("════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| Manage Stack (timeout, consolidation, TP check, pending detection)|
//+------------------------------------------------------------------+
void ManageStack()
{
   if(g_stack.state == 0) return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   bool isBuy = g_stack.isBuy;
   double currentPrice = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // === TIME LIMIT CHECK ===
   // Cancel pending orders after timeout; keep filled positions (they have SL/TP)
   if(InpMaxTradeMinutes > 0 && g_stack.openTime > 0)
   {
      int elapsedSeconds = (int)(TimeCurrent() - g_stack.openTime);
      if(elapsedSeconds >= InpMaxTradeMinutes * 60)
      {
         PrintLog("⏱ TIMEOUT: Stack exceeded " + IntegerToString(InpMaxTradeMinutes) + " min — cancelling unfilled orders");
         CancelPendingOrders();
         // If no positions remain either, reset stack completely
         bool hasPositions = (g_stack.ticket1 > 0 && PositionSelectByTicket(g_stack.ticket1))
                          || (g_stack.ticket2 > 0 && PositionSelectByTicket(g_stack.ticket2))
                          || (g_stack.ticket3 > 0 && PositionSelectByTicket(g_stack.ticket3));
         if(!hasPositions)
         {
            PrintLog("  No filled positions — stack complete");
            ResetStack();
         }
         else
         {
            PrintLog("  Pending orders cancelled. Filled positions remain active.");
         }
         return;
      }
   }

   // === DETECT PENDING ORDERS FILLED ===
   // Entry 1 pending → position
   if(g_stack.pending1 > 0)
   {
      if(!OrderSelect(g_stack.pending1))
      {
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            ulong ticket = PositionGetTicket(i);
            if(ticket <= 0 || !PositionSelectByTicket(ticket)) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
            if(PositionGetString(POSITION_COMMENT) == (isBuy ? "ENV_E1_BUY" : "ENV_E1_SELL"))
            {
               g_stack.ticket1     = ticket;
               g_stack.pending1    = 0;
               g_stack.entry1Price = PositionGetDouble(POSITION_PRICE_OPEN);
               PrintLog("✅ ENTRY 1 FILLED: #" + IntegerToString((long)ticket) +
                        " @ " + DoubleToString(g_stack.entry1Price, digits) +
                        " | SL=" + DoubleToString(g_stack.sl1, digits) + " | TP=" + DoubleToString(g_stack.tp, digits));
               break;
            }
         }
      }
   }

   // Entry 2 fill detection
   if(g_stack.pending2 > 0)
   {
      if(!OrderSelect(g_stack.pending2))
      {
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            ulong ticket = PositionGetTicket(i);
            if(ticket <= 0 || !PositionSelectByTicket(ticket)) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
            if(PositionGetString(POSITION_COMMENT) == (isBuy ? "ENV_E2_BUY" : "ENV_E2_SELL"))
            {
               g_stack.ticket2 = ticket;
               g_stack.pending2 = 0;
               g_stack.state = 2;
               PrintLog("✅ ENTRY 2 FILLED: #" + IntegerToString((long)ticket) +
                        " | Keeping SL₂ (never change SL)");
               break;
            }
         }
      }
   }

   // Entry 3 fill detection
   if(g_stack.pending3 > 0)
   {
      if(!OrderSelect(g_stack.pending3))
      {
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            ulong ticket = PositionGetTicket(i);
            if(ticket <= 0 || !PositionSelectByTicket(ticket)) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
            if(PositionGetString(POSITION_COMMENT) == (isBuy ? "ENV_E3_BUY" : "ENV_E3_SELL"))
            {
               g_stack.ticket3 = ticket;
               g_stack.pending3 = 0;
               g_stack.state = 3;
               PrintLog("✅ ENTRY 3 FILLED: #" + IntegerToString((long)ticket) +
                        " | Keeping SL₃ (never change SL)");
               break;
            }
         }
      }
   }

   // === TP/SL CHECK ===
   // Each entry runs independently with its own SL. Only reset when ALL are gone.
   bool entry1Gone = (g_stack.ticket1 > 0 && !PositionSelectByTicket(g_stack.ticket1));
   bool entry2Gone = (g_stack.ticket2 > 0 && !PositionSelectByTicket(g_stack.ticket2));
   bool entry3Gone = (g_stack.ticket3 > 0 && !PositionSelectByTicket(g_stack.ticket3));
   bool pending2Gone = (g_stack.pending2 > 0 && !OrderSelect(g_stack.pending2));
   bool pending3Gone = (g_stack.pending3 > 0 && !OrderSelect(g_stack.pending3));

   if(pending2Gone && g_stack.pending2 > 0)
   {
      PrintLog("  Pending E2 removed");
      g_stack.pending2 = 0;
   }
   if(pending3Gone && g_stack.pending3 > 0)
   {
      PrintLog("  Pending E3 removed");
      g_stack.pending3 = 0;
   }

   // If all entries AND all pendings are gone → stack is done
   bool allDone = (g_stack.ticket1 == 0 && g_stack.ticket2 == 0 && g_stack.ticket3 == 0
                && g_stack.pending1 == 0 && g_stack.pending2 == 0 && g_stack.pending3 == 0);

   if(entry1Gone && g_stack.ticket1 > 0)
   {
      PrintLog("  Entry 1 closed — Entry 2/3 remain active");
      g_stack.ticket1 = 0;  // clear ticket so message prints only once
   }
   if(entry2Gone && g_stack.ticket2 > 0)
   {
      PrintLog("  Entry 2 closed");
      g_stack.ticket2 = 0;
   }
   if(entry3Gone && g_stack.ticket3 > 0)
   {
      PrintLog("  Entry 3 closed");
      g_stack.ticket3 = 0;
   }

   if(allDone && g_stack.openTime > 0)
   {
      PrintLog("🏁 All entries closed — stack complete");
      ResetStack();
   }
}

//+------------------------------------------------------------------+
//| Cancel all pending orders for current stack                       |
//+------------------------------------------------------------------+
void CancelPendingOrders()
{
   if(g_stack.pending1 > 0)
   {
      if(OrderSelect(g_stack.pending1))
      {
         trade.OrderDelete(g_stack.pending1);
         PrintLog("  Cancelled pending Entry 1 #" + IntegerToString((long)g_stack.pending1));
      }
      g_stack.pending1 = 0;
   }
   if(g_stack.pending2 > 0)
   {
      if(OrderSelect(g_stack.pending2))
      {
         trade.OrderDelete(g_stack.pending2);
         PrintLog("  Cancelled pending Entry 2 #" + IntegerToString((long)g_stack.pending2));
      }
      g_stack.pending2 = 0;
   }
   if(g_stack.pending3 > 0)
   {
      if(OrderSelect(g_stack.pending3))
      {
         trade.OrderDelete(g_stack.pending3);
         PrintLog("  Cancelled pending Entry 3 #" + IntegerToString((long)g_stack.pending3));
      }
      g_stack.pending3 = 0;
   }
}

//+------------------------------------------------------------------+
//| Close remaining positions in current stack                        |
//+------------------------------------------------------------------+
void CloseRemainingPositions()
{
   if(g_stack.ticket1 > 0 && PositionSelectByTicket(g_stack.ticket1))
   {
      if(trade.PositionClose(g_stack.ticket1))
         PrintLog("  Closed Entry 1 #" + IntegerToString((long)g_stack.ticket1));
   }
   if(g_stack.ticket2 > 0 && PositionSelectByTicket(g_stack.ticket2))
   {
      if(trade.PositionClose(g_stack.ticket2))
         PrintLog("  Closed Entry 2 #" + IntegerToString((long)g_stack.ticket2));
   }
   if(g_stack.ticket3 > 0 && PositionSelectByTicket(g_stack.ticket3))
   {
      if(trade.PositionClose(g_stack.ticket3))
         PrintLog("  Closed Entry 3 #" + IntegerToString((long)g_stack.ticket3));
   }
}

//+------------------------------------------------------------------+
//| Close entire stack at market                                      |
//+------------------------------------------------------------------+
void CloseAllStack()
{
   PrintLog("🛑 CLOSING ENTIRE STACK");
   CancelPendingOrders();
   CloseRemainingPositions();
   ResetStack();
}

//+------------------------------------------------------------------+
//| Reset stack tracking                                              |
//+------------------------------------------------------------------+
void ResetStack()
{
   ZeroMemory(g_stack);
   PrintLog("═══ Stack cleared ═══");
}
