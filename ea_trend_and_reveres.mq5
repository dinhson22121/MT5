//+------------------------------------------------------------------+
//|                                BTC_RSI_MeanReversion_Optimized.mq5 |
//|                                  Copyright 2024, Optimized Version |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//--- Input Parameters
input group "=== Indicator Settings ==="
input int InpRSIPeriod = 14;              // OPTIMIZED: RSI 14 more stable
input int InpRSIOversold = 30;
input int InpRSIOverbought = 70;
input bool InpUseRSIConfirmation = true;   // Wait for RSI reversal
input int InpEMAFast = 34;
input int InpEMASlow = 89;
input int InpADXPeriod = 14;
input double InpMinADX = 20;                   // Min ADX for trend (0=disabled)

input group "=== Volume Filter ==="
input int InpVolumePeriod = 20;
input double InpVolumeMultiplier = 1.2;        // OPTIMIZED: 120% avg volume

input group "=== Risk Management - FIXED PIPS ==="
input double InpPositionSizePercent = 2.0;    // SAFE: 2% per trade (was 10%)
input int InpStopLossPips = 40;               // OPTIMIZED: 15 gia vang / $1500 BTC
input int InpTakeProfitPips = 100;            // IMPROVED: R:R = 1:2.5 (was 80)
input int InpBreakevenPips = 60;              // IMPROVED: 1.5x SL (was 35)
input bool InpUseTrailingStop = true;         // Enable Trailing Stop
input int InpTrailingActivatePips = 50;       // Activate trailing after this profit
input int InpTrailingDistancePips = 30;       // Distance between price and trailing SL
input bool InpUseAutoMaxPositions = true;
input int InpMaxPositions = 3;
input int InpMagicNumber = 123456;

input group "=== Trading Modes ==="
input bool InpAllowTrendingBuy = true;         // Trade BUY in uptrend
input bool InpAllowTrendingSell = true;        // Trade SELL in downtrend
input bool InpAllowSidewayTrade = false;        // NEW: Trade in sideways market

input group "=== Sideways Trading Settings ==="
input int InpSidewayStopLossPips = 50;         // IMPROVED: Tighter SL (was 100)
input int InpSidewayTakeProfitPips = 150;      // TP stays same (R:R = 1:3 now!)
input int InpSidewayRangePeriod = 50;          // Bars to calculate range (H1 or H4)
input int InpSidewayMinRangePips = 200;        // Min range size to trade (skip small ranges)
input int InpSidewayMaxDistanceToBoundary = 50; // Max distance from support/resistance

input group "=== Momentum Trading Settings ==="
input bool InpAllowMomentumTrade = true;       // Enable Momentum (trend-following)
input bool InpUseMomentumConfirmation = true;  // Wait for RSI reversal after extreme
input int InpMomentumStopLossPips = 30;        // Tighter SL for momentum
input int InpMomentumTakeProfitPips = 120;     // Higher TP (R:R = 1:4)

input group "=== Trading Rules ==="
input int InpMinutesBetwenTrades = 120;        // OPTIMIZED: 2 hours cooldown
input bool InpUseTimeFilter = true;            // Enable session filter (auto-disable for crypto)
input bool InpTradeAsianSession = true;        // Asian: 1:00-9:00 UTC (Tokyo)
input bool InpTradeEuropeanSession = true;     // European: 7:00-16:00 UTC (London)
input bool InpTradeUSSession = true;           // US: 13:00-22:00 UTC (New York)

input group "=== Additional Filters ==="
input double InpMinATRMultiplier = 0.8;        // OPTIMIZED: Enable ATR filter
input int InpATRPeriod = 14;
input int InpMaxSpreadPips = 5;                // Max spread in pips (0=disabled)
input bool InpUseCandleConfirmation = true;    // Check candle direction

input group "=== Debug Settings ==="
input bool InpEnableDetailedLogs = true;

//--- Global Variables
datetime g_lastTradeTime = 0;
int g_handleRSI;
int g_handleEMAFast;
int g_handleEMASlow;
int g_handleATR;
int g_handleADX;

//+------------------------------------------------------------------+
int OnInit()
{
   g_handleRSI = iRSI(_Symbol, PERIOD_M15, InpRSIPeriod, PRICE_CLOSE);
   g_handleEMAFast = iMA(_Symbol, PERIOD_M15, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEMASlow = iMA(_Symbol, PERIOD_M15, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   g_handleATR = iATR(_Symbol, PERIOD_M15, InpATRPeriod);
   g_handleADX = iADX(_Symbol, PERIOD_M15, InpADXPeriod);
   
   if(g_handleRSI == INVALID_HANDLE || g_handleEMAFast == INVALID_HANDLE || 
      g_handleEMASlow == INVALID_HANDLE || g_handleATR == INVALID_HANDLE ||
      g_handleADX == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicators!");
      return(INIT_FAILED);
   }
   
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   double pipValue = GetPipValue();
   
   Print("====================================");
   Print("EA INITIALIZED - OPTIMIZED VERSION 3.0");
   Print("====================================");
   Print("Symbol: ", _Symbol);
   Print("Pip Value: ", DoubleToString(pipValue, _Digits));
   Print("Position Size: ", InpPositionSizePercent, "%");
   Print("------------------------------------");
   Print("TRENDING MODE:");
   Print("  SL: ", InpStopLossPips, " pips | TP: ", InpTakeProfitPips, " pips");
   Print("  R:R = 1:", DoubleToString((double)InpTakeProfitPips/InpStopLossPips, 2));
   Print("  BUY Trend: ", InpAllowTrendingBuy ? "YES" : "NO");
   Print("  SELL Trend: ", InpAllowTrendingSell ? "YES" : "NO");
   Print("------------------------------------");
   Print("POSITION MANAGEMENT:");
   Print("  Breakeven: ", InpBreakevenPips > 0 ? IntegerToString(InpBreakevenPips) + " pips" : "DISABLED");
   Print("  Trailing Stop: ", InpUseTrailingStop ? "ENABLED" : "DISABLED");
   if(InpUseTrailingStop)
   {
      Print("    Activate at: ", InpTrailingActivatePips, " pips profit");
      Print("    Trail distance: ", InpTrailingDistancePips, " pips");
   }
   Print("------------------------------------");
   Print("SIDEWAYS MODE: ", InpAllowSidewayTrade ? "ENABLED" : "DISABLED");
   if(InpAllowSidewayTrade)
   {
      Print("  RSI Levels: Same as trending (30/70)");
      Print("  SL: ", InpSidewayStopLossPips, " pips | TP: ", InpSidewayTakeProfitPips, " pips");
      Print("  R:R = 1:", DoubleToString((double)InpSidewayTakeProfitPips/InpSidewayStopLossPips, 2));
      Print("  Range Filter: Min ", InpSidewayMinRangePips, " pips over ", InpSidewayRangePeriod, " bars");
      Print("  Boundary Filter: Max ", InpSidewayMaxDistanceToBoundary, " pips from S/R");
   }
   Print("------------------------------------");
   Print("MOMENTUM MODE: ", InpAllowMomentumTrade ? "ENABLED" : "DISABLED");
   if(InpAllowMomentumTrade)
   {
      Print("  Logic: UPTREND+RSI>70=BUY | DOWNTREND+RSI<30=SELL");
      Print("  Confirmation: ", InpUseMomentumConfirmation ? "YES (wait reversal)" : "NO (immediate)");
      Print("  SL: ", InpMomentumStopLossPips, " pips | TP: ", InpMomentumTakeProfitPips, " pips");
      Print("  R:R = 1:", DoubleToString((double)InpMomentumTakeProfitPips/InpMomentumStopLossPips, 2));
   }
   Print("------------------------------------");
   Print("FILTERS:");
   Print("  ADX Min: ", InpMinADX, " (", InpMinADX > 0 ? "ENABLED" : "DISABLED", ")");
   Print("  Volume: ", InpVolumeMultiplier, "x avg");
   Print("  ATR: ", InpMinATRMultiplier, "x avg");
   Print("  Spread Max: ", InpMaxSpreadPips > 0 ? IntegerToString(InpMaxSpreadPips) + " pips" : "DISABLED");
   Print("  Cooldown: ", InpMinutesBetwenTrades, " minutes");
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
      Print("  Trend SL/TP: ", InpStopLossPips/10.0, "/", InpTakeProfitPips/10.0, " gia");
      Print("  Momentum SL/TP: ", InpMomentumStopLossPips/10.0, "/", InpMomentumTakeProfitPips/10.0, " gia");
      Print("  Sideway SL/TP: ", InpSidewayStopLossPips/10.0, "/", InpSidewayTakeProfitPips/10.0, " gia");
   }
   
   if(StringFind(_Symbol, "BTC") >= 0)
   {
      Print("------------------------------------");
      Print("BTC: 100 pips = $1000");
      Print("  Trend SL/TP: $", InpStopLossPips*10, "/$", InpTakeProfitPips*10);
      Print("  Momentum SL/TP: $", InpMomentumStopLossPips*10, "/$", InpMomentumTakeProfitPips*10);
      Print("  Sideway SL/TP: $", InpSidewayStopLossPips*10, "/$", InpSidewayTakeProfitPips*10);
   }
   
   if(StringFind(_Symbol, "US30") >= 0 || StringFind(_Symbol, "DOW") >= 0 || StringFind(_Symbol, "DJ30") >= 0)
   {
      Print("------------------------------------");
      Print("US30 (DOW JONES): 1 pip = 1 point");
      Print("  Trend SL/TP: ", InpStopLossPips, " / ", InpTakeProfitPips, " points");
      Print("  Momentum SL/TP: ", InpMomentumStopLossPips, " / ", InpMomentumTakeProfitPips, " points");
      Print("  Sideway SL/TP: ", InpSidewayStopLossPips, " / ", InpSidewayTakeProfitPips, " points");
      Print("  Example: 40 pips SL at 35000 = 34960");
   }
   
   if(StringFind(_Symbol, "NI225") >= 0 || StringFind(_Symbol, "NIKKEI") >= 0 || StringFind(_Symbol, "JPN225") >= 0)
   {
      Print("------------------------------------");
      Print("NIKKEI 225: 1 pip = 1 point");
      Print("  Trend SL/TP: ", InpStopLossPips, " / ", InpTakeProfitPips, " points");
      Print("  Momentum SL/TP: ", InpMomentumStopLossPips, " / ", InpMomentumTakeProfitPips, " points");
      Print("  Sideway SL/TP: ", InpSidewayStopLossPips, " / ", InpSidewayTakeProfitPips, " points");
      Print("  Example: 40 pips SL at 33000 = 32960");
   }
   
   if(StringFind(_Symbol, "USDJPY") >= 0)
   {
      Print("------------------------------------");
      Print("USDJPY: 1 pip = 0.01 (or 0.001 for 3-digit)");
      Print("  Trend SL/TP: ", InpStopLossPips, " / ", InpTakeProfitPips, " pips");
      Print("  Momentum SL/TP: ", InpMomentumStopLossPips, " / ", InpMomentumTakeProfitPips, " pips");
      Print("  Sideway SL/TP: ", InpSidewayStopLossPips, " / ", InpSidewayTakeProfitPips, " pips");
      Print("  Example: Entry 150.00, SL 40 pips = 149.60, TP 100 pips = 151.00");
   }
   
   if(StringFind(_Symbol, "EURUSD") >= 0)
   {
      Print("------------------------------------");
      Print("EURUSD: 1 pip = 0.0001 (5-digit broker) or 0.00001 (pipette)");
      Print("  Trend SL/TP: ", InpStopLossPips, " / ", InpTakeProfitPips, " pips");
      Print("  Momentum SL/TP: ", InpMomentumStopLossPips, " / ", InpMomentumTakeProfitPips, " pips");
      Print("  Sideway SL/TP: ", InpSidewayStopLossPips, " / ", InpSidewayTakeProfitPips, " pips");
      Print("  Example: Entry 1.0500, SL 40 pips = 1.0460, TP 100 pips = 1.0600");
   }
   
   Print("====================================");
   
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
bool CheckCandleConfirmation(bool isBuySignal)
{
   if(!InpUseCandleConfirmation)
      return true;
   
   double open = iOpen(_Symbol, PERIOD_M15, 1);   // Previous candle
   double close = iClose(_Symbol, PERIOD_M15, 1);
   
   if(isBuySignal)
   {
      // For BUY: prefer bullish candle (close > open)
      if(close > open)
         return true;
      else if(InpEnableDetailedLogs)
         Print("INFO: Bearish candle, but BUY signal still valid");
   }
   else
   {
      // For SELL: prefer bearish candle (close < open)
      if(close < open)
         return true;
      else if(InpEnableDetailedLogs)
         Print("INFO: Bullish candle, but SELL signal still valid");
   }
   
   return true;  // Don't block, just inform
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
   double emaDiff = MathAbs(emaFast - emaSlow);
   double emaAvg = (emaFast + emaSlow) / 2;
   double emaDiffPercent = (emaDiff / emaAvg) * 100;
   
   bool hasStrongTrend = (InpMinADX > 0) ? (adx >= InpMinADX) : (emaDiffPercent > 0.3);
   
   if(hasStrongTrend)
   {
      if(emaFast > emaSlow)
         return MARKET_UPTREND;
      else
         return MARKET_DOWNTREND;
   }
   
   return MARKET_SIDEWAYS;
}

//+------------------------------------------------------------------+
void CalculateSLTP_FixedPips(double entryPrice, bool isBuy, int slPips, int tpPips, 
                             double &sl, double &tp)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pipValue = GetPipValue();
   
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
            sl = entryPrice - minDistance * 1.1;
         else
            sl = entryPrice + minDistance * 1.1;
         sl = NormalizeDouble(sl, digits);
      }
      
      if(actualTPDistance < minDistance)
      {
         if(isBuy)
            tp = entryPrice + minDistance * 1.1;
         else
            tp = entryPrice - minDistance * 1.1;
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
void OnTick()
{
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_M15, 0);
   
   if(currentBarTime == lastBarTime)
   {
      ManageOpenPositions();
      return;
   }
   
   lastBarTime = currentBarTime;
   
   if(InpEnableDetailedLogs)
      Print("\n--- NEW BAR: ", TimeToString(currentBarTime), " ---");
   
   double rsi[], emaFast[], emaSlow[], atr[], adxMain[];
   long volume[];
   
   if(!GetIndicatorValues(rsi, emaFast, emaSlow, atr, adxMain, volume))
   {
      Print("WARNING: Failed to get indicator values");
      return;
   }
   
   if(!CheckTradingConditions())
      return;
   
   AnalyzeAndTrade(rsi[0], emaFast[0], emaSlow[0], atr[0], adxMain[0], (double)volume[0]);
}

//+------------------------------------------------------------------+
bool GetIndicatorValues(double &rsi[], double &emaFast[], double &emaSlow[], 
                        double &atr[], double &adxMain[], long &volume[])
{
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(adxMain, true);
   
   if(CopyBuffer(g_handleRSI, 0, 0, 5, rsi) != 5) return false;        // Need more bars for confirmation
   if(CopyBuffer(g_handleEMAFast, 0, 0, 3, emaFast) != 3) return false;
   if(CopyBuffer(g_handleEMASlow, 0, 0, 3, emaSlow) != 3) return false;
   if(CopyBuffer(g_handleATR, 0, 0, 3, atr) != 3) return false;
   if(CopyBuffer(g_handleADX, 0, 0, 3, adxMain) != 3) return false;
   
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
   int requiredSeconds = InpMinutesBetwenTrades * 60;
   
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
   
   if(!CheckSpread())
      return false;
   
   return true;
}

//+------------------------------------------------------------------+
int GetMaxPositions()
{
   if(!InpUseAutoMaxPositions)
      return InpMaxPositions;
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance < 200) return 3;
   else if(balance < 500) return 4;
   else if(balance < 1000) return 5;
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
      
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
void AnalyzeAndTrade(double rsi, double emaFast, double emaSlow, 
                     double atr, double adx, double currentVolume)
{
   // Calculate average volume
   double avgVolume = 0;
   long volumeArray[];
   ArraySetAsSeries(volumeArray, true);
   
   if(CopyTickVolume(_Symbol, PERIOD_M15, 1, InpVolumePeriod, volumeArray) > 0)
   {
      for(int i = 0; i < InpVolumePeriod; i++)
         avgVolume += (double)volumeArray[i];
      avgVolume /= InpVolumePeriod;
   }
   
   bool highVolume = (currentVolume > avgVolume * InpVolumeMultiplier);
   
   // Calculate average ATR
   bool volatilityOK = true;
   double avgATR = 0;
   if(InpMinATRMultiplier > 0)
   {
      double atrArray[];
      ArraySetAsSeries(atrArray, true);
      if(CopyBuffer(g_handleATR, 0, 0, 20, atrArray) > 0)
      {
         for(int i = 0; i < 20; i++)
            avgATR += atrArray[i];
         avgATR /= 20;
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
   
   // Display status
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double positionValue = balance * (InpPositionSizePercent / 100.0);
   
   string volumeStatus = highVolume ? "HIGH" : "LOW";
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
   
   Comment(
      "=== ", _Symbol, " - OPTIMIZED v3.2 ===", "\n",
      "Balance: $", DoubleToString(balance, 2), " | Pos: $", DoubleToString(positionValue, 2), "\n",
      "Session: ", sessionInfo, " | UTC: ", TimeToString(TimeGMT(), TIME_MINUTES), "\n",
      "Market: ", marketStateStr, " | ADX: ", DoubleToString(adx, 1), "\n",
      "RSI: ", DoubleToString(rsi, 1), " | Vol: ", volumeStatus, " | ATR: ", atrStatus, "\n",
      "Positions: ", CountOpenPositions(), "/", GetMaxPositions(), "\n",
      "Mean Reversion: BUY=", (InpAllowTrendingBuy ? "YES" : "NO"), " SELL=", (InpAllowTrendingSell ? "YES" : "NO"), "\n",
      "Momentum: ", (InpAllowMomentumTrade ? "YES" : "NO"), " | Sideway: ", (InpAllowSidewayTrade ? "YES" : "NO")
   );
   
   // Check common filters
   if(!highVolume)
   {
      if(InpEnableDetailedLogs)
         Print("NO SIGNAL: Volume too low (", (int)currentVolume, " vs ", (int)avgVolume, ")");
      return;
   }
   
   if(!volatilityOK)
   {
      if(InpEnableDetailedLogs)
         Print("NO SIGNAL: ATR too low");
      return;
   }
   
   // TRENDING SIGNALS
   if(marketState == MARKET_UPTREND && InpAllowTrendingBuy)
   {
      if(rsi < InpRSIOversold)
      {
         // RSI Confirmation: Check if RSI is turning up
         bool rsiConfirmed = !InpUseRSIConfirmation || (rsi > rsi[1] && rsi[1] <= rsi[2]);
         
         if(!rsiConfirmed)
         {
            if(InpEnableDetailedLogs)
               Print("WAITING: BUY signal but RSI not confirmed (RSI=", DoubleToString(rsi, 1), 
                     " prev=", DoubleToString(rsi[1], 1), ")");
            return;
         }
         
         // Candle Confirmation
         if(!CheckCandleConfirmation(true))
         {
            if(InpEnableDetailedLogs)
               Print("WARNING: BUY signal with bearish candle");
         }
         
         if(InpEnableDetailedLogs)
            Print("SIGNAL: BUY (Uptrend + RSI Oversold + CONFIRMED)");
         OpenPosition(true, InpStopLossPips, InpTakeProfitPips, "Trend_Buy");
         return;
      }
   }
   
   if(marketState == MARKET_DOWNTREND && InpAllowTrendingSell)
   {
      if(rsi > InpRSIOverbought)
      {
         // RSI Confirmation: Check if RSI is turning down
         bool rsiConfirmed = !InpUseRSIConfirmation || (rsi < rsi[1] && rsi[1] >= rsi[2]);
         
         if(!rsiConfirmed)
         {
            if(InpEnableDetailedLogs)
               Print("WAITING: SELL signal but RSI not confirmed (RSI=", DoubleToString(rsi, 1), 
                     " prev=", DoubleToString(rsi[1], 1), ")");
            return;
         }
         
         // Candle Confirmation
         if(!CheckCandleConfirmation(false))
         {
            if(InpEnableDetailedLogs)
               Print("WARNING: SELL signal with bullish candle");
         }
         
         if(InpEnableDetailedLogs)
            Print("SIGNAL: SELL (Downtrend + RSI Overbought + CONFIRMED)");
         OpenPosition(false, InpStopLossPips, InpTakeProfitPips, "Trend_Sell");
         return;
      }
   }
   
   // MOMENTUM SIGNALS (Trend Following)
   if(InpAllowMomentumTrade)
   {
      // UPTREND + RSI overbought (>70) -> BUY with strong momentum
      if(marketState == MARKET_UPTREND && InpAllowTrendingBuy)
      {
         if(rsi > InpRSIOverbought)  // RSI > 70
         {
            // Momentum Confirmation: Check if RSI just crossed above 70 or is pulling back from extreme
            bool momentumConfirmed = true;
            if(InpUseMomentumConfirmation)
            {
               // Option 1: RSI just broke above 70
               bool justBrokeAbove = (rsi > InpRSIOverbought && rsi[1] <= InpRSIOverbought);
               // Option 2: RSI was extreme (>75) and now pulling back slightly but still >70
               bool pullingBackFromExtreme = (rsi > InpRSIOverbought && rsi < rsi[1] && rsi[1] > 75);
               
               momentumConfirmed = justBrokeAbove || pullingBackFromExtreme;
            }
            
            if(!momentumConfirmed)
            {
               if(InpEnableDetailedLogs)
                  Print("WAITING: Momentum BUY but RSI not confirmed (RSI=", 
                        DoubleToString(rsi, 1), " prev=", DoubleToString(rsi[1], 1), ")");
               return;
            }
            
            // Candle Confirmation
            if(!CheckCandleConfirmation(true))
            {
               if(InpEnableDetailedLogs)
                  Print("WARNING: Momentum BUY with bearish candle");
            }
            
            if(InpEnableDetailedLogs)
               Print("SIGNAL: MOMENTUM BUY (Uptrend + RSI>", InpRSIOverbought, " STRONG MOMENTUM + CONFIRMED)");
            OpenPosition(true, InpMomentumStopLossPips, InpMomentumTakeProfitPips, "Momentum_Buy");
            return;
         }
      }
      
      // DOWNTREND + RSI oversold (<30) -> SELL with strong momentum
      if(marketState == MARKET_DOWNTREND && InpAllowTrendingSell)
      {
         if(rsi < InpRSIOversold)  // RSI < 30
         {
            // Momentum Confirmation: Check if RSI just crossed below 30 or is bouncing from extreme
            bool momentumConfirmed = true;
            if(InpUseMomentumConfirmation)
            {
               // Option 1: RSI just broke below 30
               bool justBrokeBelow = (rsi < InpRSIOversold && rsi[1] >= InpRSIOversold);
               // Option 2: RSI was extreme (<25) and now bouncing slightly but still <30
               bool bouncingFromExtreme = (rsi < InpRSIOversold && rsi > rsi[1] && rsi[1] < 25);
               
               momentumConfirmed = justBrokeBelow || bouncingFromExtreme;
            }
            
            if(!momentumConfirmed)
            {
               if(InpEnableDetailedLogs)
                  Print("WAITING: Momentum SELL but RSI not confirmed (RSI=", 
                        DoubleToString(rsi, 1), " prev=", DoubleToString(rsi[1], 1), ")");
               return;
            }
            
            // Candle Confirmation
            if(!CheckCandleConfirmation(false))
            {
               if(InpEnableDetailedLogs)
                  Print("WARNING: Momentum SELL with bullish candle");
            }
            
            if(InpEnableDetailedLogs)
               Print("SIGNAL: MOMENTUM SELL (Downtrend + RSI<", InpRSIOversold, " STRONG MOMENTUM + CONFIRMED)");
            OpenPosition(false, InpMomentumStopLossPips, InpMomentumTakeProfitPips, "Momentum_Sell");
            return;
         }
      }
   }
   
   // SIDEWAYS SIGNALS (Range Trading with Boundary Confirmation)
   if(marketState == MARKET_SIDEWAYS && InpAllowSidewayTrade)
   {
      // Use same RSI levels as trending modes (30/70)
      int lowerBound = InpRSIOversold;      // 30
      int upperBound = InpRSIOverbought;    // 70
      
      // Calculate recent range (use H1 or H4 data for better range detection)
      ENUM_TIMEFRAMES rangeTimeframe = PERIOD_H1;
      int highestBar = iHighest(_Symbol, rangeTimeframe, MODE_HIGH, InpSidewayRangePeriod, 0);
      int lowestBar = iLowest(_Symbol, rangeTimeframe, MODE_LOW, InpSidewayRangePeriod, 0);
      
      double rangeHigh = iHigh(_Symbol, rangeTimeframe, highestBar);
      double rangeLow = iLow(_Symbol, rangeTimeframe, lowestBar);
      double rangeSize = (rangeHigh - rangeLow) / GetPipValue();
      
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
      
      // BUY when RSI hits lower bound (oversold in range)
      if(rsi < lowerBound)
      {
         // Filter 2: Must be near range bottom (support)
         if(distanceFromLow > InpSidewayMaxDistanceToBoundary)
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: Sideways BUY too far from support (", 
                     DoubleToString(distanceFromLow, 1), " pips from low)");
            return;
         }
         
         // RSI Confirmation for sideways
         bool rsiConfirmed = !InpUseRSIConfirmation || (rsi > rsi[1]);
         
         if(!rsiConfirmed)
         {
            if(InpEnableDetailedLogs)
               Print("WAITING: Sideways BUY but RSI not confirmed");
            return;
         }
         
         if(!CheckCandleConfirmation(true))
         {
            if(InpEnableDetailedLogs)
               Print("WARNING: Sideways BUY with bearish candle");
         }
         
         if(InpEnableDetailedLogs)
         {
            Print("SIGNAL: SIDEWAYS BUY (RSI=", DoubleToString(rsi, 1), " < ", lowerBound, ")");
            Print("  Range: ", DoubleToString(rangeLow, _Digits), " - ", DoubleToString(rangeHigh, _Digits), 
                  " (", DoubleToString(rangeSize, 0), " pips)");
            Print("  Distance from support: ", DoubleToString(distanceFromLow, 1), " pips");
         }
         
         OpenPosition(true, InpSidewayStopLossPips, InpSidewayTakeProfitPips, "Sideway_Buy");
         return;
      }
      
      // SELL when RSI hits upper bound (overbought in range)
      if(rsi > upperBound)
      {
         // Filter 2: Must be near range top (resistance)
         if(distanceFromHigh > InpSidewayMaxDistanceToBoundary)
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: Sideways SELL too far from resistance (", 
                     DoubleToString(distanceFromHigh, 1), " pips from high)");
            return;
         }
         
         // RSI Confirmation for sideways
         bool rsiConfirmed = !InpUseRSIConfirmation || (rsi < rsi[1]);
         
         if(!rsiConfirmed)
         {
            if(InpEnableDetailedLogs)
               Print("WAITING: Sideways SELL but RSI not confirmed");
            return;
         }
         
         if(!CheckCandleConfirmation(false))
         {
            if(InpEnableDetailedLogs)
               Print("WARNING: Sideways SELL with bullish candle");
         }
         
         if(InpEnableDetailedLogs)
         {
            Print("SIGNAL: SIDEWAYS SELL (RSI=", DoubleToString(rsi, 1), " > ", upperBound, ")");
            Print("  Range: ", DoubleToString(rangeLow, _Digits), " - ", DoubleToString(rangeHigh, _Digits), 
                  " (", DoubleToString(rangeSize, 0), " pips)");
            Print("  Distance from resistance: ", DoubleToString(distanceFromHigh, 1), " pips");
         }
         
         OpenPosition(false, InpSidewayStopLossPips, InpSidewayTakeProfitPips, "Sideway_Sell");
         return;
      }
   }
   
   if(InpEnableDetailedLogs)
   {
      Print("NO SIGNAL: Market=", marketStateStr, " | RSI=", DoubleToString(rsi, 1), 
            " | ADX=", DoubleToString(adx, 1));
   }
}

//+------------------------------------------------------------------+
double CalculateLotSize(double entryPrice)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double positionValueUSD = balance * (InpPositionSizePercent / 100.0);
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   
   double lotSize = positionValueUSD / (contractSize * entryPrice);
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   
   if(lotSize < minLot) lotSize = minLot;
   if(lotSize > maxLot) lotSize = maxLot;
   
   return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
void OpenPosition(bool isBuy, int slPips, int tpPips, string comment)
{
   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = CalculateLotSize(price);
   double sl, tp;
   
   CalculateSLTP_FixedPips(price, isBuy, slPips, tpPips, sl, tp);
   
   Print("====================================");
   Print("OPENING ", isBuy ? "BUY" : "SELL", " - ", _Symbol);
   Print("Type: ", comment);
   Print("Entry: ", price, " | SL: ", sl, " | TP: ", tp, " | Lot: ", lot);
   Print("====================================");
   
   // Validation
   if(isBuy && (sl >= price || tp <= price))
   {
      Print("ERROR: Invalid BUY SL/TP! Cancelled.");
      return;
   }
   
   if(!isBuy && (sl <= price || tp >= price))
   {
      Print("ERROR: Invalid SELL SL/TP! Cancelled.");
      return;
   }
   
   bool result = false;
   if(isBuy)
      result = trade.Buy(lot, _Symbol, 0, sl, tp, comment);
   else
      result = trade.Sell(lot, _Symbol, 0, sl, tp, comment);
   
   if(result)
   {
      Print("SUCCESS: Order placed | Ticket: ", trade.ResultOrder());
      g_lastTradeTime = TimeCurrent();
   }
   else
   {
      Print("FAILED: Error ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   if(InpBreakevenPips <= 0 && !InpUseTrailingStop)
      return;
   
   double pipValue = GetPipValue();
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
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
      
      // Calculate potential new SL
      double newSL = currentSL;
      bool needsUpdate = false;
      string updateReason = "";
      
      // TRAILING STOP LOGIC (Priority 1)
      if(InpUseTrailingStop && profitPips >= InpTrailingActivatePips)
      {
         double trailingDistance = InpTrailingDistancePips * pipValue;
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
      else if(InpBreakevenPips > 0 && profitPips >= InpBreakevenPips)
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