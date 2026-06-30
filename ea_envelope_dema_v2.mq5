//+------------------------------------------------------------------+
//|                                      ea_envelope_dema_v2.mq5     |
//|                                    Copyright 2026                  |
//|  v2.0 — DEMA/SMA Direction + Cycle Confirmation                  |
//|  Single entry 0.03 lot | SL=40 TP=80 | 150-pip distance filter  |
//|  Symbol: XAUUSDc (Gold)                                          |
//+------------------------------------------------------------------+
//| STRATEGY:                                                         |
//|  20m DEMA(9)/SMA(16) → direction (is_high / is_low)              |
//|  10m DEMA/SMA envelope → n_max/n_min → cycle confirmation        |
//|  5m DEMA/SMA mid-point → LIMIT entry price                       |
//|                                                                   |
//|  SL=40 TP=80 (R:R 2:1)                                           |
//|  No trade: 2AM-6AM GMT+7                                        |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

const double BROKER_STOP_BUFFER = 1.1;

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Strategy ==="
input int    InpDEMAPeriod         = 9;      // DEMA period
input int    InpSMAPeriod          = 16;     // SMA period
input double InpLotSize            = 0.03;   // Fixed lot size

input group "=== Distance Filter ==="
input int    InpMinDistPips        = 250;    // Min distance mid to ref price (pips)

input group "=== Risk Management ==="
input double InpMaxDailyLossPct    = 10.0;   // Daily loss circuit breaker
input double InpMaxWeeklyLossPct   = 20.0;   // Weekly loss circuit breaker
input int    InpCooldownMinutes    = 30;     // Cooldown between trades
input int    InpMaxTradeMinutes    = 60;     // Max trade duration (0=unlimited)
input double InpMaxMarginPct       = 10.0;   // Max margin % per trade

input group "=== Time Filters ==="
input int    InpDisabledStartHour  = 2;      // Block entries from (local)
input int    InpDisabledEndHour    = 6;      // Block entries until (local)
input int    InpGMTOffset          = 7;      // Server → your timezone offset (e.g. +7 for GMT+7)

input group "=== Symbol ==="
input int    InpMagicNumber        = 456789; // EA magic number

input group "=== Debug ==="
input bool   InpEnableFileLogging  = true;
input bool   InpEnableDetailedLogs = true;
input string InpLogFolder          = "EA_Logs";

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
datetime g_lastTradeTime   = 0;
datetime g_tradeOpenTime   = 0;
ulong    g_ticket           = 0;
ulong    g_pendingTicket    = 0;  // LIMIT order before fill
bool     g_isBuy            = false;
double   g_entryPrice       = 0;
double   g_sl               = 0;
double   g_tp               = 0;

int      g_dailyLossDay     = 0;
double   g_dailyStartEquity = 0;
int      g_weeklyLossWeek   = -1;
double   g_weeklyStartEquity = 0;

int g_handleSMA_M20, g_handleSMA_M10, g_handleSMA_M5, g_handleATR_M20;

//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+
double GetPipValue()
{
   string s = _Symbol;
   double point = SymbolInfoDouble(s, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
   if(point <= 0) point = 0.01;
   if(StringFind(s, "XAU") >= 0 || StringFind(s, "GOLD") >= 0) return 0.10;
   if(StringFind(s, "BTC") >= 0)  return 10.0;
   if(StringFind(s, "JPY") >= 0)  return (digits == 3 || digits == 2) ? 0.01 : point * 10;
   return (digits == 5 || digits == 3) ? point * 10 : point;
}

bool IsGoldSymbol() { return StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0; }

void UpdateDailyEquity()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_dailyLossDay) { g_dailyLossDay = dt.day_of_year; g_dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY); }
}
bool IsDailyLossHit()
{
   if(InpMaxDailyLossPct <= 0) return false;
   UpdateDailyEquity();
   if(g_dailyStartEquity <= 0) return false;
   return ((g_dailyStartEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / g_dailyStartEquity * 100.0 >= InpMaxDailyLossPct);
}
void UpdateWeeklyEquity()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int w = dt.day_of_year / 7;
   if(w != g_weeklyLossWeek) { g_weeklyLossWeek = w; g_weeklyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY); }
}
bool IsWeeklyLossHit()
{
   if(InpMaxWeeklyLossPct <= 0) return false;
   UpdateWeeklyEquity();
   if(g_weeklyStartEquity <= 0) return false;
   return ((g_weeklyStartEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / g_weeklyStartEquity * 100.0 >= InpMaxWeeklyLossPct);
}

//+------------------------------------------------------------------+
//| Logging                                                           |
//+------------------------------------------------------------------+
string _LogFile(string suffix)
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return InpLogFolder + "/EA_v2_" + suffix + "_" + StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day) + "_" + _Symbol + ".txt";
}
void WriteLog(string msg)
{
   if(!InpEnableFileLogging) return;
   int fh = FileOpen(_LogFile("FullLog"), FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON|FILE_SHARE_READ);
   if(fh == INVALID_HANDLE) fh = FileOpen(_LogFile("FullLog"), FILE_WRITE|FILE_TXT|FILE_COMMON|FILE_SHARE_READ);
   if(fh == INVALID_HANDLE) return;
   FileSeek(fh, 0, SEEK_END);
   FileWriteString(fh, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "\t" + msg + "\r\n");
   FileClose(fh);
}
void PrintLog(string msg) { Print(msg); WriteLog(msg); }

//+------------------------------------------------------------------+
//| DEMA Calculation                                                  |
//+------------------------------------------------------------------+
void CalcDEMA(const double &close[], int period, double &dema[])
{
   int size = ArraySize(close);
   ArrayResize(dema, size);
   if(size < period + 1) { for(int i = 0; i < size; i++) dema[i] = close[i]; return; }

   double alpha = 2.0 / (period + 1.0);
   double ema1[]; ArrayResize(ema1, size);
   ema1[size - 1] = close[size - 1];
   for(int i = size - 2; i >= 0; i--) ema1[i] = alpha * close[i] + (1.0 - alpha) * ema1[i + 1];

   double ema2[]; ArrayResize(ema2, size);
   ema2[size - 1] = ema1[size - 1];
   for(int i = size - 2; i >= 0; i--) ema2[i] = alpha * ema1[i] + (1.0 - alpha) * ema2[i + 1];

   for(int i = 0; i < size; i++) dema[i] = 2.0 * ema1[i] - ema2[i];
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!IsGoldSymbol()) { Print("WARNING: Not XAUUSD. Current: ", _Symbol); }

   g_handleSMA_M20 = iMA(_Symbol, PERIOD_M20, InpSMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   g_handleSMA_M10 = iMA(_Symbol, PERIOD_M10, InpSMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   g_handleSMA_M5  = iMA(_Symbol, PERIOD_M5,  InpSMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   g_handleATR_M20 = iATR(_Symbol, PERIOD_M20, 20);

   if(g_handleSMA_M20 == INVALID_HANDLE || g_handleSMA_M10 == INVALID_HANDLE ||
      g_handleSMA_M5 == INVALID_HANDLE || g_handleATR_M20 == INVALID_HANDLE)
   { Print("FATAL: Indicator handles failed"); return INIT_FAILED; }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(100);
   long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fm & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else trade.SetTypeFilling(ORDER_FILLING_RETURN);

   UpdateDailyEquity(); UpdateWeeklyEquity();

   // Recover existing position
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t <= 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         g_ticket      = t;
         g_isBuy       = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
         g_entryPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
         g_sl          = PositionGetDouble(POSITION_SL);
         g_tp          = PositionGetDouble(POSITION_TP);
         g_tradeOpenTime = (datetime)PositionGetInteger(POSITION_TIME);
         PrintLog("Recovered position #" + IntegerToString((long)t));
         break;
      }
   }

   Print("═══ EA v2.0 DEMA/SMA Direction ═══");
   Print("  Symbol: ", _Symbol, " | Lot: ", DoubleToString(InpLotSize, 2));
   Print("  Distance filter: ≥ ", InpMinDistPips, " pips");
   Print("  Timezone: GMT", (InpGMTOffset >= 0 ? "+" : ""), InpGMTOffset, " | Disabled: ", InpDisabledStartHour, ":00-", InpDisabledEndHour, ":00");
   Print("  Max trade: ", InpMaxTradeMinutes, " min");
   Print("══════════════════════════════════════");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(g_handleSMA_M20); IndicatorRelease(g_handleSMA_M10);
   IndicatorRelease(g_handleSMA_M5);  IndicatorRelease(g_handleATR_M20);
   Comment("");
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipVal = GetPipValue();

   // ── Manage pending LIMIT order (timeout before fill) ──
   if(g_pendingTicket > 0)
   {
      if(OrderSelect(g_pendingTicket))
      {
         // Timeout: cancel pending LIMIT
         if(InpMaxTradeMinutes > 0 && g_tradeOpenTime > 0)
         {
            if((int)(TimeCurrent() - g_tradeOpenTime) >= InpMaxTradeMinutes * 60)
            {
               trade.OrderDelete(g_pendingTicket);
               PrintLog("⏱ Timeout " + IntegerToString(InpMaxTradeMinutes) + " min — cancelled pending LIMIT");
               g_pendingTicket = 0; g_tradeOpenTime = 0; g_lastTradeTime = 0;
               return;
            }
         }
         // Check if filled
         return;  // Still pending, wait
      }
      else
      {
         // Order gone — either filled or cancelled
         g_pendingTicket = 0;
         // Check if it became a position
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            ulong t = PositionGetTicket(i);
            if(t <= 0 || !PositionSelectByTicket(t)) continue;
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            {
               g_ticket = t;
               g_entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
               g_sl = PositionGetDouble(POSITION_SL);
               g_tp = PositionGetDouble(POSITION_TP);
               g_isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
               PrintLog("✅ LIMIT filled: #" + IntegerToString((long)t) + " @ " + DoubleToString(g_entryPrice, digits));
               break;
            }
         }
         if(g_ticket == 0) { g_tradeOpenTime = 0; g_lastTradeTime = 0; }  // cancelled, not filled
      }
   }

   // ── Manage open position (timeout + close detection) ──
   if(g_ticket > 0)
   {
      if(!PositionSelectByTicket(g_ticket))
      {
         PrintLog("Position closed — reset");
         g_ticket = 0; g_tradeOpenTime = 0;
      }
      else
      {
         if(InpMaxTradeMinutes > 0 && g_tradeOpenTime > 0)
         {
            if((int)(TimeCurrent() - g_tradeOpenTime) >= InpMaxTradeMinutes * 60)
            {
               PrintLog("⏱ Timeout " + IntegerToString(InpMaxTradeMinutes) + " min — closing");
               trade.PositionClose(g_ticket);
               g_ticket = 0; g_tradeOpenTime = 0;
            }
         }
      }
      return;
   }

   // New 5m bar
   static datetime lastBar = 0;
   datetime barTime = iTime(_Symbol, PERIOD_M5, 0);
   if(barTime == lastBar) return;
   lastBar = barTime;

   // Disabled hours (adjusted to local timezone)
   MqlDateTime dt; TimeToStruct(TimeCurrent() + InpGMTOffset * 3600, dt);
   if(InpDisabledStartHour != InpDisabledEndHour)
   {
      bool blocked = (InpDisabledStartHour < InpDisabledEndHour)
         ? (dt.hour >= InpDisabledStartHour && dt.hour < InpDisabledEndHour)
         : (dt.hour >= InpDisabledStartHour || dt.hour < InpDisabledEndHour);
      if(blocked) return;
   }

   // Cooldown
   if(g_lastTradeTime > 0 && (int)(TimeCurrent() - g_lastTradeTime) < InpCooldownMinutes * 60)
      return;

   // Loss limits
   if(IsDailyLossHit() || IsWeeklyLossHit()) return;

   // Spread
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / pipVal;
   if(spread > 50) return;

   // ── Fetch 20m data ──
   int needed20 = 30;
   double c20[], h20[], l20[], sma20[], dema20[];
   ArraySetAsSeries(c20, true); ArraySetAsSeries(h20, true); ArraySetAsSeries(l20, true); ArraySetAsSeries(sma20, true);
   if(CopyClose(_Symbol, PERIOD_M20, 0, needed20, c20) < needed20 ||
      CopyHigh(_Symbol, PERIOD_M20, 0, needed20, h20) < needed20 ||
      CopyLow(_Symbol, PERIOD_M20, 0, needed20, l20) < needed20 ||
      CopyBuffer(g_handleSMA_M20, 0, 0, needed20, sma20) < needed20) return;

   CalcDEMA(c20, InpDEMAPeriod, dema20);

   // ── Direction (20m) ──
   double dema20_1 = dema20[1], sma20_1 = sma20[1];
   bool is_high = (dema20_1 > sma20_1);
   bool is_low  = (dema20_1 < sma20_1);

   if(InpEnableDetailedLogs)
      PrintLog("🕐 Bar " + TimeToString(barTime, TIME_MINUTES) + " | DEMA=" + DoubleToString(dema20_1, 2) + " SMA=" + DoubleToString(sma20_1, 2) + " | " + (is_high ? "UP" : (is_low ? "DOWN" : "FLAT")));

   if(!is_high && !is_low) return;

   // ── 4-bar avgLowMin / avgLowMax (20m debug) ──
   double avgMin = 0, avgMax = 0;
   for(int i = 1; i <= 4; i++) { avgMin += l20[i] - MathMin(dema20[i], sma20[i]); avgMax += l20[i] - MathMax(dema20[i], sma20[i]); }
   avgMin /= 4; avgMax /= 4;

   // ── 10m cycle confirmation ──
   int needed10 = 30;
   double c10[], h10[], l10[], sma10[], dema10[];
   ArraySetAsSeries(c10, true); ArraySetAsSeries(h10, true); ArraySetAsSeries(l10, true); ArraySetAsSeries(sma10, true);
   bool inCycle = false;
   double n_min_10 = 0, n_max_10 = 0, price10 = 0;
   if(CopyClose(_Symbol, PERIOD_M10, 0, needed10, c10) >= needed10 &&
      CopyHigh(_Symbol, PERIOD_M10, 0, needed10, h10) >= needed10 &&
      CopyLow(_Symbol, PERIOD_M10, 0, needed10, l10) >= needed10 &&
      CopyBuffer(g_handleSMA_M10, 0, 0, needed10, sma10) >= needed10)
   {
      CalcDEMA(c10, InpDEMAPeriod, dema10);
      n_max_10 = -1e308; n_min_10 = 1e308;
      for(int i = 1; i < 20; i++)
      {
         if((dema10[i] >= l10[i] && dema10[i] <= h10[i]) || (sma10[i] >= l10[i] && sma10[i] <= h10[i]))
         { if(h10[i] > n_max_10) n_max_10 = h10[i]; if(l10[i] < n_min_10) n_min_10 = l10[i]; }
      }
      if(n_max_10 == -1e308) for(int i = 1; i < 20; i++) { if(h10[i] > n_max_10) n_max_10 = h10[i]; }
      if(n_min_10 == 1e308)  for(int i = 1; i < 20; i++) { if(l10[i] < n_min_10) n_min_10 = l10[i]; }
      price10 = c10[1];
      double cycleWidth = (n_max_10 - n_min_10) / pipVal;
      inCycle = (price10 > n_min_10 && price10 < n_max_10 && cycleWidth >= 50.0);
   }
   if(!inCycle)
   {
      if(InpEnableDetailedLogs && n_min_10 > 0)
         PrintLog("  10m: width=" + DoubleToString(MathAbs(n_max_10 - n_min_10) / pipVal, 1) + " pips — too narrow or price outside");
      return;
   }

   // ── 5m entry price ──
   double c5[], sma5[], dema5[];
   ArraySetAsSeries(c5, true); ArraySetAsSeries(sma5, true);
   if(CopyClose(_Symbol, PERIOD_M5, 0, 30, c5) < 30 ||
      CopyBuffer(g_handleSMA_M5, 0, 0, 30, sma5) < 30) return;
   CalcDEMA(c5, InpDEMAPeriod, dema5);
   double midPrice = (dema5[1] + sma5[1]) / 2.0;
   //TODO: CHECK THIS
   double entryTarget = is_high ? (midPrice - 80.0 * pipVal) : (midPrice + 80.0 * pipVal);

   // ── Distance filter (120 pips) ──
   double refPrice, distPips;
   if(is_high)
   {
      refPrice = h20[1]; for(int i = 2; i <= 4; i++) if(h20[i] > refPrice) refPrice = h20[i];
      distPips = (refPrice - entryTarget) / pipVal;
      if(distPips < InpMinDistPips) return;
   }
   else
   {
      refPrice = l20[1]; for(int i = 2; i <= 4; i++) if(l20[i] < refPrice) refPrice = l20[i];
      distPips = (entryTarget - refPrice) / pipVal;
      if(distPips < InpMinDistPips) return;
   }

   double slPips = 40.0;
   double tpPips = 80.0;

   // ── Log ──
   if(InpEnableDetailedLogs)
   {
      PrintLog("--- SIGNAL [" + _Symbol + "] ---");
      PrintLog("  " + StringFormat("DEMA20m=%.3f SMA20m=%.3f", dema20_1, sma20_1));
      PrintLog("  " + StringFormat("DEMA5m=%.3f SMA5m=%.3f Mid=%.3f", dema5[1], sma5[1], midPrice));
      PrintLog("  " + StringFormat("10m: n_min=%.3f n_max=%.3f width=%.0fpips price=%.3f", n_min_10, n_max_10, (n_max_10 - n_min_10) / pipVal, price10));
      PrintLog("  " + StringFormat("Dist=%.0f pips | %s | SL=%d TP=%d", distPips, is_high ? "BUY" : "SELL", (int)slPips, (int)tpPips));
   }

   // ── Open trade ──
   double price = is_high ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool useLimit = is_high ? (entryTarget < price) : (entryTarget > price);
   double entryPrice = useLimit ? entryTarget : price;
   double sl = is_high ? NormalizeDouble(entryPrice - slPips * pipVal, digits) : NormalizeDouble(entryPrice + slPips * pipVal, digits);
   double tp = is_high ? NormalizeDouble(entryPrice + tpPips * pipVal, digits) : NormalizeDouble(entryPrice - tpPips * pipVal, digits);

   // Margin check
   double marginReq;
   if(OrderCalcMargin(is_high ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, InpLotSize, price, marginReq))
   {
      double pct = marginReq / AccountInfoDouble(ACCOUNT_EQUITY) * 100.0;
      if(pct > InpMaxMarginPct) { PrintLog("BLOCKED: margin " + DoubleToString(pct, 1) + "%"); return; }
   }

   bool ok;
   if(useLimit)
      ok = is_high ? trade.BuyLimit(InpLotSize, entryTarget, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "v2")
                   : trade.SellLimit(InpLotSize, entryTarget, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "v2");
   else
      ok = is_high ? trade.Buy(InpLotSize, _Symbol, price, sl, tp, "v2")
                   : trade.Sell(InpLotSize, _Symbol, price, sl, tp, "v2");

   if(!ok) { PrintLog("FAILED: " + IntegerToString((int)trade.ResultRetcode())); return; }

   if(useLimit)
   {
      g_pendingTicket = trade.ResultOrder();
      PrintLog("⏳ LIMIT placed: #" + IntegerToString((long)g_pendingTicket) + " " +
               (is_high ? "BUY" : "SELL") + " @ " + DoubleToString(entryTarget, digits) +
               " SL=" + DoubleToString(sl, digits) + " TP=" + DoubleToString(tp, digits));
   }
   else
   {
      g_ticket        = trade.ResultOrder();
      g_entryPrice    = trade.ResultPrice();
      PrintLog("✅ " + (is_high ? "BUY" : "SELL") + " #" + IntegerToString((long)g_ticket) +
               " Lot=" + DoubleToString(InpLotSize, 2) +
               " @ " + DoubleToString(g_entryPrice, digits) +
               " SL=" + DoubleToString(sl, digits) + " TP=" + DoubleToString(tp, digits) +
               " (" + IntegerToString((int)slPips) + "/" + IntegerToString((int)tpPips) + " pips)");
   }

   g_isBuy        = is_high;
   g_sl           = sl;
   g_tp           = tp;
   g_tradeOpenTime = TimeCurrent();
   g_lastTradeTime = TimeCurrent();
}
