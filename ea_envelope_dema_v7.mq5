//+------------------------------------------------------------------+
//|                                      ea_envelope_dema_v6.mq5     |
//|                                    Copyright 2026                  |
//|  v6.0 — DEMA/SMA Envelope Multi-Stack (M20 Only)                 |
//|  Multi-stack: multiple independent stacks, each with 120min timer|
//|  Symbol: XAUUSDc (Gold) | Attach to M20 chart                   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "6.00"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

const double BROKER_STOP_BUFFER = 1.1;

//--- Stack tracking
struct StackInfo
{
   ulong    ticket1, ticket2, ticket3;
   ulong    pending1, pending2, pending3;
   datetime openTime;      // timer start
   bool     isBuy;
   double   entry1Price;
   double   sl1, sl2, sl3;
   double   tp1, tp2, tp3;
   double   lot1, lot2, lot3;
   int      state;         // 0=idle, 1=active, 2=entry2_filled, 3=all_filled
};

StackInfo g_stacks[];
int       g_stackCount = 0;
datetime  g_lastStackTime = 0;

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Strategy: DEMA/SMA on M20 ==="
input int    InpDEMAPeriod        = 9;
input int    InpSMAPeriod         = 16;
input double InpSpreadMultiplier  = 1.6;
input double InpSpreadMultiplierB = 1.4;    // Path B: relaxed multiplier (DEMA trend confirmed)

input group "=== Entry: Stack Scaling ==="
input double InpEntry1Lot         = 0.01;
input double InpEntry2Lot         = 0.02;
input double InpEntry3Lot         = 0.03;

input group "=== SL/TP: Session-based (GMT+7) ==="
input double InpSLMorning          = 30.0;   // SL pips (7h-13h)
input double InpTPMorning          = 90.0;   // TP pips (7h-13h)
input double InpSLAfternoon        = 30.0;   // SL pips (13h-7h)
input double InpTPAfternoon        = 90.0;   // TP pips (13h-7h)
input double InpEntryBufferPips    = 60.0;   // Entry buffer from midPrice (pips)
input double InpEntryBufferPipsNight = 60.0;   // Entry buffer from midPrice (pips)
input bool   InpUseSmartEntry      = true;   // Use recent low/high for smarter entry
input int    InpSmartEntryBars     = 4;      // Bars to look back for smart entry (1-6)

input group "=== State: Market Sensitivity ==="
input bool   InpAutoState         = true;
input int    InpManualState       = 3;
input int    InpStateATRPeriod    = 20;

input group "=== Risk Management ==="
input double InpMaxRiskPerStack   = 10.0;
input double InpMaxDailyLossPct   = 10.0;
input double InpMaxWeeklyLossPct  = 20.0;
input int    InpCooldownMinutes   = 30;
input int    InpMaxTradeMinutes   = 120;

input group "=== Symbol & Session ==="
input bool   InpTradeXAUUSD       = true;
input int    InpDisabledStartHour  = -1;
input int    InpDisabledEndHour    = -1;  // disabled (duplicate with news window 2)
input int    InpFridayBlockHour    = 0;    // Block Friday all day (GMT+7), 24=disabled
input int    InpNewsStart1Mins     = 720;    // News window 1 start (UTC minutes, 720=12:00)
input int    InpNewsEnd1Mins       = 870;    // News window 1 end   (UTC minutes, 870=14:30)
input int    InpNewsStart2Mins     = 1080;   // News window 2 start (UTC minutes, 1080=18:00)
input int    InpNewsEnd2Mins       = 120;    // News window 2 end   (UTC minutes, 120=02:00, overnight if < start)
input int    InpMagicNumber       = 567890;

input group "=== Debug ==="
input bool   InpEnableFileLogging = true;
input bool   InpEnableDetailedLogs = true;
input string InpLogFolder          = "EA_Logs";

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
int      g_dailyLossDay     = 0;
double   g_dailyStartEquity = 0;
int      g_weeklyLossWeek   = -1;
double   g_weeklyStartEquity = 0;

int g_handleSMA, g_handleATR;
double g_atrHistory[];
int    g_atrHistoryCount = 0;
double g_atrAvg = 0;

//+------------------------------------------------------------------+
//| Utilities                                                         |
//+------------------------------------------------------------------+
bool IsGoldSymbol()
{
   string s = _Symbol;
   return (StringFind(s, "XAU") >= 0 || StringFind(s, "GOLD") >= 0);
}
bool IsSymbolAllowed() { return InpTradeXAUUSD && IsGoldSymbol(); }

double GetPipValue()
{
   string s = _Symbol;
   double point = SymbolInfoDouble(s, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
   if(point <= 0) point = 0.01;
   if(StringFind(s, "XAU") >= 0 || StringFind(s, "GOLD") >= 0) return 0.10;
   if(StringFind(s, "BTC") >= 0)  return 10.0;
   if(StringFind(s, "JPY") >= 0)  return (digits <= 3) ? 0.01 : point * 10;
   return (digits == 5 || digits == 3) ? point * 10 : point;
}

void UpdateDailyEquityBaseline()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_dailyLossDay) { g_dailyLossDay = dt.day_of_year; g_dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY); }
}
bool IsDailyLossLimitHit()
{
   if(InpMaxDailyLossPct <= 0) return false;
   UpdateDailyEquityBaseline();
   if(g_dailyStartEquity <= 0) return false;
   return ((g_dailyStartEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / g_dailyStartEquity * 100.0 >= InpMaxDailyLossPct);
}

void UpdateWeeklyEquityBaseline()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int weekIndex = dt.day_of_year / 7;
   if(weekIndex != g_weeklyLossWeek) { g_weeklyLossWeek = weekIndex; g_weeklyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY); }
}
bool IsWeeklyLossLimitHit()
{
   if(InpMaxWeeklyLossPct <= 0) return false;
   UpdateWeeklyEquityBaseline();
   if(g_weeklyStartEquity <= 0) return false;
   return ((g_weeklyStartEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / g_weeklyStartEquity * 100.0 >= InpMaxWeeklyLossPct);
}

bool CheckSpread()
{
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / GetPipValue();
   if(spread > 50.0) { if(InpEnableDetailedLogs) PrintLog("BLOCKED: Spread " + DoubleToString(spread,1) + " pips"); return false; }
   return true;
}

//+------------------------------------------------------------------+
//| Logging                                                           |
//+------------------------------------------------------------------+
string _GetDailyLogFileName(string suffix)
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return InpLogFolder + "/EA_Envelope_v6_" + suffix + "_" + IntegerToString(dt.year) + "." + StringFormat("%02d",dt.mon) + "." + StringFormat("%02d",dt.day) + "_" + _Symbol + ".txt";
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
void PrintLog(string msg) { Print(msg); _WriteLogLine(msg); }

//+------------------------------------------------------------------+
//| DEMA Calculation                                                  |
//+------------------------------------------------------------------+
void CalculateDEMA(const double &closePrices[], int period, double &dema[])
{
   int size = ArraySize(closePrices);
   if(size < period + 1) { ArrayResize(dema, size); for(int i=0; i<size; i++) dema[i]=closePrices[i]; return; }
   ArrayResize(dema, size);
   double alpha = 2.0 / (period + 1.0);
   double ema1[]; ArrayResize(ema1, size);
   ema1[size-1] = closePrices[size-1];
   for(int i=size-2; i>=0; i--) ema1[i] = alpha * closePrices[i] + (1.0-alpha) * ema1[i+1];
   double ema2[]; ArrayResize(ema2, size);
   ema2[size-1] = ema1[size-1];
   for(int i=size-2; i>=0; i--) ema2[i] = alpha * ema1[i] + (1.0-alpha) * ema2[i+1];
   for(int i=0; i<size; i++) dema[i] = 2.0 * ema1[i] - ema2[i];
}

//+------------------------------------------------------------------+
//| Market State                                                      |
//+------------------------------------------------------------------+
int GetMarketState()
{
   if(!InpAutoState) return MathMax(1, MathMin(5, InpManualState));
   double atrBuf[]; ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(g_handleATR, 0, 0, 1, atrBuf) < 1) return 3;
   double currentATR = atrBuf[0];
   if(currentATR <= 0) return 3;
   int maxHistory = InpStateATRPeriod * 2;
   if(g_atrHistoryCount < maxHistory) { ArrayResize(g_atrHistory, g_atrHistoryCount+1); g_atrHistory[g_atrHistoryCount++]=currentATR; }
   else { for(int i=0; i<maxHistory-1; i++) g_atrHistory[i]=g_atrHistory[i+1]; g_atrHistory[maxHistory-1]=currentATR; }
   if(g_atrHistoryCount < 5) return 3;
   g_atrAvg = 0; for(int i=0; i<g_atrHistoryCount; i++) g_atrAvg += g_atrHistory[i];
   g_atrAvg /= g_atrHistoryCount;
   if(g_atrAvg <= 0) return 3;
   double ratio = currentATR / g_atrAvg;
   if(ratio < 0.6) return 1; if(ratio < 0.8) return 2;
   if(ratio <= 1.2) return 3; if(ratio <= 1.5) return 4;
   return 5;
}

//+------------------------------------------------------------------+
//| Check Trading Conditions                                          |
//+------------------------------------------------------------------+
bool CheckTradingConditions()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { PrintLog("BLOCKED: Trading not allowed"); return false; }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) { PrintLog("BLOCKED: EA trading not allowed"); return false; }
   if(!IsSymbolAllowed()) { PrintLog("BLOCKED: Symbol not XAUUSD"); return false; }
   if(g_lastStackTime > 0 && (int)(TimeCurrent() - g_lastStackTime) < InpCooldownMinutes * 60)
   { if(InpEnableDetailedLogs) Print("BLOCKED: Cooldown active"); return false; }
   if(IsDailyLossLimitHit()) { PrintLog("BLOCKED: Daily loss limit"); return false; }
   if(IsWeeklyLossLimitHit()) { PrintLog("BLOCKED: Weekly loss limit"); return false; }
   if(!CheckSpread()) return false;
   if(InpDisabledStartHour != InpDisabledEndHour) {
      MqlDateTime dt; TimeToStruct(TimeGMT()+7*3600, dt); int h = dt.hour;
      bool blocked = (InpDisabledStartHour < InpDisabledEndHour) ? (h >= InpDisabledStartHour && h < InpDisabledEndHour) : (h >= InpDisabledStartHour || h < InpDisabledEndHour);
      if(blocked) { PrintLog("BLOCKED: Disabled hours"); return false; }
   }
   // Friday afternoon block (GMT+7)
   if(InpFridayBlockHour >= 0 && InpFridayBlockHour < 24) {
      MqlDateTime dt; TimeToStruct(TimeGMT()+7*3600, dt);
      if(dt.day_of_week == 5 && dt.hour >= InpFridayBlockHour) {
         PrintLog("BLOCKED: Friday after " + IntegerToString(InpFridayBlockHour) + "h"); return false;
      }
   }
   // News windows (UTC, minutes from midnight; if end < start = overnight)
   {  MqlDateTime dt; TimeToStruct(TimeGMT(), dt); int totalMin = dt.hour*60+dt.min;
      bool inWindow = false;
      if(InpNewsStart1Mins != InpNewsEnd1Mins) {
         if(InpNewsStart1Mins < InpNewsEnd1Mins)
            inWindow = (totalMin >= InpNewsStart1Mins && totalMin < InpNewsEnd1Mins);
         else
            inWindow = (totalMin >= InpNewsStart1Mins || totalMin < InpNewsEnd1Mins);
      }
      if(!inWindow && InpNewsStart2Mins != InpNewsEnd2Mins) {
         if(InpNewsStart2Mins < InpNewsEnd2Mins)
            inWindow = (totalMin >= InpNewsStart2Mins && totalMin < InpNewsEnd2Mins);
         else
            inWindow = (totalMin >= InpNewsStart2Mins || totalMin < InpNewsEnd2Mins);
      }
      if(inWindow) { if(InpEnableDetailedLogs) PrintLog("BLOCKED: News window"); return false; }
   }
   return true;
}

//+------------------------------------------------------------------+
//| Stack Array Helpers                                               |
//+------------------------------------------------------------------+
void RemoveStack(int idx)
{
   if(idx < 0 || idx >= g_stackCount) return;
   for(int i = idx; i < g_stackCount - 1; i++) g_stacks[i] = g_stacks[i+1];
   g_stackCount--;
   ArrayResize(g_stacks, g_stackCount);
}

int CountActiveStacks()
{
   int count = 0;
   for(int i = 0; i < g_stackCount; i++)
      if(g_stacks[i].state > 0) count++;
   return count;
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!IsGoldSymbol()) { Print("WARNING: EA for XAUUSD. Attach to XAUUSDc M20."); }
   g_handleSMA = iMA(_Symbol, PERIOD_M20, InpSMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   g_handleATR = iATR(_Symbol, PERIOD_M20, InpStateATRPeriod);
   if(g_handleSMA == INVALID_HANDLE || g_handleATR == INVALID_HANDLE) { Print("FATAL: Indicator handles failed"); return INIT_FAILED; }
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(100);
   long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fm & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else trade.SetTypeFilling(ORDER_FILLING_RETURN);
   UpdateDailyEquityBaseline(); UpdateWeeklyEquityBaseline();
   ArrayResize(g_stacks, 0); g_stackCount = 0;
   RecoverStacks();
   Print("══════════════════════════════════════════");
   Print("  EA v6.0 — Multi-Stack DEMA/SMA (M20)");
   Print("  Stacks recovered: ", g_stackCount);
   Print("  Timer: ", InpMaxTradeMinutes, " min per stack");
   Print("  Magic: ", InpMagicNumber);
   Print("══════════════════════════════════════════");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Recover stacks from existing positions/orders                      |
//+------------------------------------------------------------------+
void RecoverStacks()
{
   // Collect all tickets by comment tag
   struct TicketInfo { ulong ticket; string tag; bool isPosition; };
   TicketInfo items[];
   int itemCount = 0;

   // Scan positions
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(t <= 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      ArrayResize(items, itemCount+1);
      items[itemCount].ticket = t; items[itemCount].tag = PositionGetString(POSITION_COMMENT);
      items[itemCount].isPosition = true; itemCount++;
   }
   // Scan pending orders
   for(int i = OrdersTotal()-1; i >= 0; i--) {
      ulong t = OrderGetTicket(i);
      if(t <= 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      long ot = OrderGetInteger(ORDER_TYPE);
      if(ot != ORDER_TYPE_BUY_LIMIT && ot != ORDER_TYPE_SELL_LIMIT) continue;
      ArrayResize(items, itemCount+1);
      items[itemCount].ticket = t; items[itemCount].tag = OrderGetString(ORDER_COMMENT);
      items[itemCount].isPosition = false; itemCount++;
   }
   if(itemCount == 0) return;

   // Group by stack: find E1 tickets, then collect associated E2/E3
   // Simple approach: each unique E1 creates a stack, E2/E3 matched by direction tag pattern
   for(int i = 0; i < itemCount; i++) {
      string tag = items[i].tag;
      if(tag != "ENV_E1_BUY" && tag != "ENV_E1_SELL") continue;

      ArrayResize(g_stacks, g_stackCount+1);
      StackInfo s; ZeroMemory(s);
      s.state = 1;
      string dirSuffix = (tag == "ENV_E1_BUY") ? "BUY" : "SELL";
      s.isBuy = (tag == "ENV_E1_BUY");

      if(items[i].isPosition) {
         PositionSelectByTicket(items[i].ticket);
         s.ticket1 = items[i].ticket;
         s.entry1Price = PositionGetDouble(POSITION_PRICE_OPEN);
         s.sl1 = PositionGetDouble(POSITION_SL);
         s.tp1 = PositionGetDouble(POSITION_TP);
         s.lot1 = PositionGetDouble(POSITION_VOLUME);
         s.openTime = (datetime)PositionGetInteger(POSITION_TIME);
      } else {
         if(OrderSelect(items[i].ticket)) {
            s.pending1 = items[i].ticket;
            s.entry1Price = OrderGetDouble(ORDER_PRICE_OPEN);
            s.sl1 = OrderGetDouble(ORDER_SL);
            s.tp1 = OrderGetDouble(ORDER_TP);
            s.lot1 = OrderGetDouble(ORDER_VOLUME_INITIAL);
            s.openTime = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
         }
      }

      // Find E2, E3
      string e2tag = "ENV_E2_" + dirSuffix, e3tag = "ENV_E3_" + dirSuffix;
      for(int j = 0; j < itemCount; j++)
      {
         if(items[j].tag == e2tag)
         {
            if(items[j].isPosition)
            {
               PositionSelectByTicket(items[j].ticket);
               s.ticket2 = items[j].ticket;
               s.sl2 = PositionGetDouble(POSITION_SL);
               s.tp2 = PositionGetDouble(POSITION_TP);
               s.lot2 = PositionGetDouble(POSITION_VOLUME);
               s.state = MathMax(s.state, 2);
               datetime t = (datetime)PositionGetInteger(POSITION_TIME);
               if(t < s.openTime) s.openTime = t;
            }
            else if(OrderSelect(items[j].ticket))
            {
               s.pending2 = items[j].ticket;
               s.sl2 = OrderGetDouble(ORDER_SL);
               s.tp2 = OrderGetDouble(ORDER_TP);
               s.lot2 = OrderGetDouble(ORDER_VOLUME_INITIAL);
               datetime t = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
               if(t < s.openTime) s.openTime = t;
            }
         }
         if(items[j].tag == e3tag)
         {
            if(items[j].isPosition)
            {
               PositionSelectByTicket(items[j].ticket);
               s.ticket3 = items[j].ticket;
               s.sl3 = PositionGetDouble(POSITION_SL);
               s.tp3 = PositionGetDouble(POSITION_TP);
               s.lot3 = PositionGetDouble(POSITION_VOLUME);
               s.state = 3;
               datetime t = (datetime)PositionGetInteger(POSITION_TIME);
               if(t < s.openTime) s.openTime = t;
            }
            else if(OrderSelect(items[j].ticket))
            {
               s.pending3 = items[j].ticket;
               s.sl3 = OrderGetDouble(ORDER_SL);
               s.tp3 = OrderGetDouble(ORDER_TP);
               s.lot3 = OrderGetDouble(ORDER_VOLUME_INITIAL);
               datetime t = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
               if(t < s.openTime) s.openTime = t;
            }
         }
      }
      g_stacks[g_stackCount] = s;
      g_stackCount++;
      PrintLog("Recovered stack #" + IntegerToString(g_stackCount) + " " + dirSuffix + " | state=" + IntegerToString(s.state));
   }
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(g_handleSMA); IndicatorRelease(g_handleATR);
   Comment(""); Print("EA v6.0 STOPPED. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   ManageAllStacks();

   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_M20, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   // Always evaluate signals (multi-stack, no block)
   int state = GetMarketState();
   int neededBars = InpDEMAPeriod + InpSMAPeriod + 10;
   double closes[], highs[], lows[];
   ArraySetAsSeries(closes, true); ArraySetAsSeries(highs, true); ArraySetAsSeries(lows, true);
   if(CopyClose(_Symbol, PERIOD_M20, 0, neededBars, closes) < neededBars ||
      CopyHigh(_Symbol, PERIOD_M20, 0, neededBars, highs) < neededBars ||
      CopyLow(_Symbol, PERIOD_M20, 0, neededBars, lows) < neededBars) { if(InpEnableDetailedLogs) Print("WARN: Copy M20 failed"); return; }

   double dema[]; CalculateDEMA(closes, InpDEMAPeriod, dema);
   double sma[]; ArraySetAsSeries(sma, true);
   if(CopyBuffer(g_handleSMA, 0, 0, neededBars, sma) < neededBars) { if(InpEnableDetailedLogs) Print("WARN: SMA failed"); return; }

   double demaNow = dema[1], smaNow = sma[1];
   bool is_high = (demaNow > smaNow), is_low = (demaNow < smaNow);
   if(!is_high && !is_low) { if(InpEnableDetailedLogs) PrintLog("SIDEWAYS"); return; }

   double midPrice = (demaNow + smaNow) / 2.0;
   if(InpEnableDetailedLogs)
      PrintLog("--- M20 [" + _Symbol + "] S=" + IntegerToString(state) +
               " DEMA=" + DoubleToString(demaNow,_Digits) + " SMA=" + DoubleToString(smaNow,_Digits) +
               " Mid=" + DoubleToString(midPrice,_Digits) + " Dir=" + (is_high?"UP":"DOWN") + " Stacks=" + IntegerToString(CountActiveStacks()));

   if(!CheckTradingConditions()) return;

   bool buySignal = false, sellSignal = false;
   double d1 = dema[1]-sma[1], d2 = dema[2]-sma[2], d3 = dema[3]-sma[3], d4 = dema[4]-sma[4];
   if(InpEnableDetailedLogs) PrintLog("  Spread: d1="+DoubleToString(d1,2)+" d2="+DoubleToString(d2,2)+" d3="+DoubleToString(d3,2)+" d4="+DoubleToString(d4,2));

   if(is_high && d1>d2 && d2>d3 && d3>d4 && d4>0 && d1>=d4*InpSpreadMultiplier) { buySignal = true;
      if(InpEnableDetailedLogs) PrintLog("  BUY: rising "+DoubleToString(d1/d4,2)+"x OK"); }
   if(is_low && d1<d2 && d2<d3 && d3<d4 && d4<0 && MathAbs(d1)>=MathAbs(d4)*InpSpreadMultiplier) { sellSignal = true;
      if(InpEnableDetailedLogs) PrintLog("  SELL: falling "+DoubleToString(MathAbs(d1)/MathAbs(d4),2)+"x OK"); }

   // Path B: DEMA trend confirmed, relaxed multiplier (set 0 to disable)
   if(InpSpreadMultiplierB > 0 && !buySignal && is_high && d4>0
      && dema[1]>dema[2] && dema[2]>dema[3] && dema[3]>dema[4]  // DEMA rising 4 bars
      && sma[1]>sma[2]  // SMA also rising
      && d1>=d4*InpSpreadMultiplierB)
   {
      buySignal = true;
      if(InpEnableDetailedLogs) PrintLog("  BUY (path B): DEMA rising, spread "+DoubleToString(d1/d4,2)+"x ≥ "+DoubleToString(InpSpreadMultiplierB,1)+"x OK");
   }
   if(InpSpreadMultiplierB > 0 && !sellSignal && is_low && d4<0
      && dema[1]<dema[2] && dema[2]<dema[3] && dema[3]<dema[4]  // DEMA falling 4 bars
      && sma[1]<sma[2]  // SMA also falling
      && MathAbs(d1)>=MathAbs(d4)*InpSpreadMultiplierB)
   {
      sellSignal = true;
      if(InpEnableDetailedLogs) PrintLog("  SELL (path B): DEMA falling, spread "+DoubleToString(MathAbs(d1)/MathAbs(d4),2)+"x ≥ "+DoubleToString(InpSpreadMultiplierB,1)+"x OK");
   }

   if(!buySignal && !sellSignal && InpEnableDetailedLogs)
   {
      string reason = "";
      if(is_high) {
         if(d4 <= 0) reason = "d4≤0 (not all positive)";
         else if(!(d1>d2 && d2>d3 && d3>d4)) reason = "ordering fail ("+DoubleToString(d1,2)+">"+DoubleToString(d2,2)+">"+DoubleToString(d3,2)+">"+DoubleToString(d4,2)+")";
         else if(d1/d4 < InpSpreadMultiplier) reason = DoubleToString(d1/d4,2)+"x < "+DoubleToString(InpSpreadMultiplier,1)+"x";
         else reason = "path B: DEMA not rising";
      }
      else if(is_low) {
         if(d4 >= 0) reason = "d4≥0 (not all negative)";
         else if(!(d1<d2 && d2<d3 && d3<d4)) reason = "ordering fail ("+DoubleToString(d1,2)+"<"+DoubleToString(d2,2)+"<"+DoubleToString(d3,2)+"<"+DoubleToString(d4,2)+")";
         else if(MathAbs(d1)/MathAbs(d4) < InpSpreadMultiplier) reason = DoubleToString(MathAbs(d1)/MathAbs(d4),2)+"x < "+DoubleToString(InpSpreadMultiplier,1)+"x";
         else reason = "path B: DEMA not falling";
      }
      PrintLog("  NO SIGNAL: " + reason);
   }

   if(buySignal) { PrintLog(">>> BUY | Mid="+DoubleToString(midPrice,_Digits)); OpenStack(true, midPrice, highs, lows); }
   else if(sellSignal) { PrintLog(">>> SELL | Mid="+DoubleToString(midPrice,_Digits)); OpenStack(false, midPrice, highs, lows); }
}

//+------------------------------------------------------------------+
//| Open Stack                                                        |
//+------------------------------------------------------------------+
void OpenStack(bool isBuy, double midPrice, const double &highs[], const double &lows[])
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT), pipVal = GetPipValue();
   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   price = NormalizeDouble(price, digits);

   midPrice = NormalizeDouble(midPrice, digits);

   // Session-based buffer
   MqlDateTime dt; TimeToStruct(TimeGMT()+7*3600, dt);
   double bufPips = (dt.hour >= 7 && dt.hour < 13) ? InpEntryBufferPips : InpEntryBufferPipsNight;
   double entryTarget = isBuy ? NormalizeDouble(midPrice - bufPips*pipVal, digits) : NormalizeDouble(midPrice + bufPips*pipVal, digits);

   // Smart entry: use recent low/high to place limit near natural support/resistance
   if(InpUseSmartEntry)
   {
      int lookback = MathMin(InpSmartEntryBars, MathMin(ArraySize(highs), ArraySize(lows)) - 1);
      if(lookback >= 2)
      {
         if(isBuy)
         {
            double minLow = lows[1];
            for(int i = 2; i <= lookback; i++)
               if(lows[i] < minLow) minLow = lows[i];
            // Entry at the higher of: midPrice-buffer vs recent low
            entryTarget = MathMax(entryTarget, NormalizeDouble(minLow, digits));
         }
         else
         {
            double maxHigh = highs[1];
            for(int i = 2; i <= lookback; i++)
               if(highs[i] > maxHigh) maxHigh = highs[i];
            // Entry at the lower of: midPrice+buffer vs recent high
            entryTarget = MathMin(entryTarget, NormalizeDouble(maxHigh, digits));
         }
      }
   }

   bool useLimit = (isBuy && entryTarget < price) || (!isBuy && entryTarget > price);
   double entry1Price = useLimit ? entryTarget : price;
   string entryType = useLimit ? "LIMIT" : "MARKET";

   double slPips = (dt.hour >= 7 && dt.hour < 13) ? InpSLMorning : InpSLAfternoon;
   double tpPips = (dt.hour >= 7 && dt.hour < 13) ? InpTPMorning : InpTPAfternoon;
   double slDist = slPips*pipVal, tpDist = tpPips*pipVal;

   double sl1, sl2, sl3, tp1, tp2, tp3;
   if(isBuy) {
      sl1 = NormalizeDouble(entry1Price - slDist, digits); sl2 = NormalizeDouble(sl1 - slDist, digits); sl3 = NormalizeDouble(sl2 - slDist, digits);
      tp1 = NormalizeDouble(entry1Price + tpDist, digits); tp2 = NormalizeDouble(sl1 + tpDist, digits); tp3 = NormalizeDouble(sl2 + tpDist, digits);
   } else {
      sl1 = NormalizeDouble(entry1Price + slDist, digits); sl2 = NormalizeDouble(sl1 + slDist, digits); sl3 = NormalizeDouble(sl2 + slDist, digits);
      tp1 = NormalizeDouble(entry1Price - tpDist, digits); tp2 = NormalizeDouble(sl1 - tpDist, digits); tp3 = NormalizeDouble(sl2 - tpDist, digits);
   }

   PrintLog("════════════════════════════════════");
   PrintLog("  📐 " + (isBuy?"BUY":"SELL") + " STACK | E1=" + entryType + " @" + DoubleToString(entry1Price,digits));
   PrintLog("  Mid=" + DoubleToString(midPrice,digits) + " Target=" + DoubleToString(entryTarget,digits) + " Mkt=" + DoubleToString(price,digits));
   PrintLog("  E1: SL=" + DoubleToString(sl1,digits) + " TP=" + DoubleToString(tp1,digits));
   PrintLog("  E2: SL=" + DoubleToString(sl2,digits) + " TP=" + DoubleToString(tp2,digits));
   PrintLog("  E3: SL=" + DoubleToString(sl3,digits) + " TP=" + DoubleToString(tp3,digits));

   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL)*point*BROKER_STOP_BUFFER;
   if(slDist < minDist || tpDist < minDist) { PrintLog("BLOCKED: Stop too small"); return; }

   double totalLot = InpEntry1Lot+InpEntry2Lot+InpEntry3Lot, marginReq = 0;
   if(OrderCalcMargin(isBuy?ORDER_TYPE_BUY:ORDER_TYPE_SELL, _Symbol, totalLot, price, marginReq)) {
      double mPct = (AccountInfoDouble(ACCOUNT_EQUITY)>0) ? (marginReq/AccountInfoDouble(ACCOUNT_EQUITY)*100.0) : 100.0;
      if(mPct > InpMaxRiskPerStack) { PrintLog("BLOCKED: Margin " + DoubleToString(mPct,1) + "% > " + DoubleToString(InpMaxRiskPerStack,1) + "%"); return; }
   }

   bool result;
   if(useLimit) {
      if(isBuy) result = trade.BuyLimit(InpEntry1Lot, entryTarget, _Symbol, sl1, tp1, ORDER_TIME_GTC, 0, "ENV_E1_BUY");
      else result = trade.SellLimit(InpEntry1Lot, entryTarget, _Symbol, sl1, tp1, ORDER_TIME_GTC, 0, "ENV_E1_SELL");
   } else {
      if(isBuy) result = trade.Buy(InpEntry1Lot, _Symbol, price, sl1, tp1, "ENV_E1_BUY");
      else result = trade.Sell(InpEntry1Lot, _Symbol, price, sl1, tp1, "ENV_E1_SELL");
   }
   if(!result) { PrintLog("FAILED E1: " + IntegerToString((int)trade.ResultRetcode())); return; }

   datetime now = TimeCurrent();

   // Append new stack
   ArrayResize(g_stacks, g_stackCount+1);
   StackInfo s; ZeroMemory(s);
   s.openTime = now; s.isBuy = isBuy; s.state = 1;
   s.sl1=sl1; s.sl2=sl2; s.sl3=sl3; s.tp1=tp1; s.tp2=tp2; s.tp3=tp3;
   s.lot1=InpEntry1Lot; s.lot2=InpEntry2Lot; s.lot3=InpEntry3Lot;

   ulong ticket1 = trade.ResultOrder();
   ulong deal = trade.ResultDeal();
   bool isFilled = (deal > 0);
   if(useLimit && !isFilled) { s.pending1 = ticket1; s.entry1Price = entryTarget; }
   else {
      s.ticket1 = ticket1; s.entry1Price = trade.ResultPrice();
      PrintLog("✅ E1 FILLED #" + IntegerToString((long)ticket1) + " " + (isBuy?"BUY":"SELL") + " @ " + DoubleToString(s.entry1Price,digits));
   }

   // E2 pending
   if(isBuy) trade.BuyLimit(InpEntry2Lot, sl1, _Symbol, sl2, tp2, ORDER_TIME_GTC, 0, "ENV_E2_BUY");
   else trade.SellLimit(InpEntry2Lot, sl1, _Symbol, sl2, tp2, ORDER_TIME_GTC, 0, "ENV_E2_SELL");
   ulong p2 = trade.ResultOrder();
   if(p2 > 0) { s.pending2 = p2; PrintLog("  ⏳ E2 @" + DoubleToString(sl1,digits) + " SL=" + DoubleToString(sl2,digits) + " TP=" + DoubleToString(tp2,digits)); }
   else PrintLog("  ⚠️ E2 FAILED");

   // E3 pending
   if(isBuy) trade.BuyLimit(InpEntry3Lot, sl2, _Symbol, sl3, tp3, ORDER_TIME_GTC, 0, "ENV_E3_BUY");
   else trade.SellLimit(InpEntry3Lot, sl2, _Symbol, sl3, tp3, ORDER_TIME_GTC, 0, "ENV_E3_SELL");
   ulong p3 = trade.ResultOrder();
   if(p3 > 0) { s.pending3 = p3; PrintLog("  ⏳ E3 @" + DoubleToString(sl2,digits) + " SL=" + DoubleToString(sl3,digits) + " TP=" + DoubleToString(tp3,digits)); }
   else PrintLog("  ⚠️ E3 FAILED");

   g_stacks[g_stackCount] = s;
   g_stackCount++;
   g_lastStackTime = now;
   PrintLog("  ⏱ Timer: " + IntegerToString(InpMaxTradeMinutes) + " min | Total stacks: " + IntegerToString(CountActiveStacks()));
   PrintLog("════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| Manage All Stacks                                                 |
//+------------------------------------------------------------------+
void ManageAllStacks()
{
   for(int idx = g_stackCount - 1; idx >= 0; idx--)
   {
      if(g_stacks[idx].state == 0) { RemoveStack(idx); continue; }
      ManageOneStack(idx);
      // If stack was cleared (state=0), remove it
      if(g_stacks[idx].state == 0) RemoveStack(idx);
   }
}

void ManageOneStack(int idx)
{
   StackInfo s = g_stacks[idx];
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // === TIME LIMIT ===
   if(InpMaxTradeMinutes > 0 && s.openTime > 0) {
      int elapsed = (int)(TimeCurrent() - s.openTime);
      if(elapsed >= InpMaxTradeMinutes * 60) {
         PrintLog("⏱ TIMEOUT stack #" + IntegerToString(idx) + ": cancelling pending");
         if(s.pending1 > 0 && OrderSelect(s.pending1)) trade.OrderDelete(s.pending1);
         if(s.pending2 > 0 && OrderSelect(s.pending2)) trade.OrderDelete(s.pending2);
         if(s.pending3 > 0 && OrderSelect(s.pending3)) trade.OrderDelete(s.pending3);
         s.pending1 = s.pending2 = s.pending3 = 0;
         s.openTime = 0;  // prevent re-trigger every tick
         bool hasPos = (s.ticket1>0 && PositionSelectByTicket(s.ticket1)) || (s.ticket2>0 && PositionSelectByTicket(s.ticket2)) || (s.ticket3>0 && PositionSelectByTicket(s.ticket3));
         if(!hasPos) { s.state = 0; PrintLog("  Stack #" + IntegerToString(idx) + " complete"); }
         else PrintLog("  Pending cancelled. Positions remain.");
         g_stacks[idx] = s;
         return;
      }
   }

   // === PENDING FILL DETECTION ===
   if(s.pending1 > 0) {
      if(!OrderSelect(s.pending1)) {
         for(int i = PositionsTotal()-1; i >= 0; i--) {
            ulong t = PositionGetTicket(i);
            if(t<=0 || !PositionSelectByTicket(t)) continue;
            if(PositionGetString(POSITION_SYMBOL)!=_Symbol || PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
            if(PositionGetString(POSITION_COMMENT) == (s.isBuy?"ENV_E1_BUY":"ENV_E1_SELL")) {
               s.ticket1 = t; s.pending1 = 0; s.entry1Price = PositionGetDouble(POSITION_PRICE_OPEN);
               PrintLog("✅ E1 FILLED #" + IntegerToString((long)t) + " @" + DoubleToString(s.entry1Price,digits));
               break;
            }
         }
      }
   }
   if(s.pending2 > 0) {
      if(!OrderSelect(s.pending2)) {
         for(int i = PositionsTotal()-1; i >= 0; i--) {
            ulong t = PositionGetTicket(i);
            if(t<=0 || !PositionSelectByTicket(t)) continue;
            if(PositionGetString(POSITION_SYMBOL)!=_Symbol || PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
            if(PositionGetString(POSITION_COMMENT) == (s.isBuy?"ENV_E2_BUY":"ENV_E2_SELL")) {
               s.ticket2=t; s.pending2=0; s.state=MathMax(s.state,2);
               PrintLog("✅ E2 FILLED #" + IntegerToString((long)t)); break;
            }
         }
      }
   }
   if(s.pending3 > 0) {
      if(!OrderSelect(s.pending3)) {
         for(int i = PositionsTotal()-1; i >= 0; i--) {
            ulong t = PositionGetTicket(i);
            if(t<=0 || !PositionSelectByTicket(t)) continue;
            if(PositionGetString(POSITION_SYMBOL)!=_Symbol || PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
            if(PositionGetString(POSITION_COMMENT) == (s.isBuy?"ENV_E3_BUY":"ENV_E3_SELL")) {
               s.ticket3=t; s.pending3=0; s.state=3;
               PrintLog("✅ E3 FILLED #" + IntegerToString((long)t)); break;
            }
         }
      }
   }

   // === TP/SL CHECK ===
   bool e1gone = (s.ticket1>0 && !PositionSelectByTicket(s.ticket1));
   bool e2gone = (s.ticket2>0 && !PositionSelectByTicket(s.ticket2));
   bool e3gone = (s.ticket3>0 && !PositionSelectByTicket(s.ticket3));
   bool p2gone = (s.pending2>0 && !OrderSelect(s.pending2));
   bool p3gone = (s.pending3>0 && !OrderSelect(s.pending3));

   if(p2gone) { PrintLog("  Pending E2 removed"); s.pending2 = 0; }
   if(p3gone) { PrintLog("  Pending E3 removed"); s.pending3 = 0; }
   if(e1gone) { PrintLog("  Entry 1 closed"); s.ticket1 = 0; }
   if(e2gone) { PrintLog("  Entry 2 closed"); s.ticket2 = 0; }
   if(e3gone) { PrintLog("  Entry 3 closed"); s.ticket3 = 0; }

   bool allDone = (s.ticket1==0 && s.ticket2==0 && s.ticket3==0 && s.pending1==0 && s.pending2==0 && s.pending3==0);
   if(allDone) { PrintLog("🏁 Stack #" + IntegerToString(idx) + " complete"); s.state = 0; }

   g_stacks[idx] = s;
}
