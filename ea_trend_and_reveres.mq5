//+------------------------------------------------------------------+
//|                                BTC_RSI_MeanReversion_Optimized.mq5 |
//|                                  Copyright 2024, Optimized Version |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//--- Constants
const double PATTERN_VOLUME_MULTIPLIER = 1.3;
const double EMA_DIFF_PERCENT_THRESHOLD = 0.3;
const int RSI_EXTREME_THRESHOLD = 75;
const int RSI_EXTREME_LOW = 25;
const double SMALL_WICK_RATIO = 0.3;
const double BROKER_STOP_BUFFER = 1.1;
const int ATR_AVERAGE_PERIOD = 20;
const int MOMENTUM_ADX_BUFFER = 5;

//--- Input Parameters
input group "=== PROFILE SELECTION ==="
input bool InpEnableScalping = true;        // TRUE=Scalping (RSI 7, SL 40, TP 70) | FALSE=Long-Term (RSI 14, SL 80, TP 200)

input group "=== Indicator Settings ==="
input int InpRSIPeriod_Scalp = 7;          // Scalping: Fast RSI
input int InpRSIPeriod_LongTerm = 14;      // Long-Term: Stable RSI
input int InpRSIOversold = 30;
input int InpRSIOverbought = 70;
input bool InpUseRSIConfirmation = true;   // Wait for RSI reversal
input int InpEMAFast = 34;
input int InpEMASlow = 89;
input int InpADXPeriod = 14;
input double InpMinADX = 15;                   // RELAXED: Min ADX for trend (was 20)

input group "=== Volume Filter ==="
input int InpVolumePeriod = 20;
input double InpVolumeMultiplier = 1.0;        // RELAXED: 100% avg volume (was 1.2)

input group "=== Risk Management - SCALPING ==="
input double InpPositionSizePercent = 2.0;    // SAFE: 2% per trade (was 10%)
input int InpStopLossPips_Scalp = 40;         // Scalping: Tight SL (40 pips)
input int InpTakeProfitPips_Scalp = 70;       // Scalping: TP 70 (R:R = 1:1.75)
input int InpBreakevenPips_Scalp = 40;        // Scalping: Activate breakeven at +40
input int InpTrailingActivatePips_Scalp = 40; // Scalping: Activate trailing at +40 pips
input int InpTrailingDistancePips_Scalp = 20; // Scalping: Trail distance 20 pips

input group "=== Risk Management - LONG-TERM ==="
input int InpStopLossPips_LongTerm = 80;      // Long-Term: Wider SL (80 pips)
input int InpTakeProfitPips_LongTerm = 200;   // Long-Term: TP 200 (R:R = 1:2.5)
input int InpBreakevenPips_LongTerm = 100;    // Long-Term: Activate breakeven at +100
input int InpTrailingActivatePips_LongTerm = 80;  // Long-Term: Activate trailing at +80 pips
input int InpTrailingDistancePips_LongTerm = 50;  // Long-Term: Trail distance 50 pips

input bool InpUseTrailingStop = true;         // Enable Trailing Stop
input bool InpUseAutoMaxPositions = true;
input int InpMaxPositions = 3;
input int InpMagicNumber = 123456;

input group "=== Trading Modes ==="
input bool InpAllowTrendingBuy = true;         // Trade BUY in uptrend
input bool InpAllowTrendingSell = true;        // Trade SELL in downtrend
input bool InpAllowSidewayTrade = true;        // NEW: Trade in sideways market

input group "=== Sideways Trading Settings ==="
input int InpSidewayStopLossPips_Scalp = 40;   // Scalping: Match trend SL
input int InpSidewayTakeProfitPips_Scalp = 70; // Scalping: Match trend TP
input int InpSidewayStopLossPips_LongTerm = 80;   // Long-Term: Match trend SL
input int InpSidewayTakeProfitPips_LongTerm = 200; // Long-Term: Match trend TP
input int InpSidewayRangePeriod = 50;          // Bars to calculate range on H4 timeframe
input int InpSidewayMinRangePips = 200;        // Min range size to trade (skip small ranges)
input int InpSidewayMaxDistanceToBoundary = 30; // Max distance from support/resistance (tighter)

input group "=== Momentum Trading Settings ==="
input bool InpAllowMomentumTrade = true;       // Enable Momentum (aggressive early entry)
input bool InpUseMomentumConfirmation = false; // Momentum = no confirmation needed
input int InpMomentumStopLossPips_Scalp = 40;   // Scalping: Tight SL
input int InpMomentumTakeProfitPips_Scalp = 70; // Scalping: TP
input int InpMomentumStopLossPips_LongTerm = 80; // Long-Term: Wider SL
input int InpMomentumTakeProfitPips_LongTerm = 200; // Long-Term: TP
input double InpMomentumVolumeMultiplier = 1.5; // HIGH volume required (was global 1.0)
input double InpMomentumATRMultiplier = 1.2;    // HIGH ATR required (was global 0.5)

input group "=== Trading Rules ==="
input int InpMinutesBetwenTrades = 30;        // OPTIMIZED: 2 hours cooldown
input int InpCooldownSeconds = 1800;          // Cooldown in seconds (overrides minutes if >0)
input bool InpAllowOnCurrentBar = false;      // Allow trading on currently forming bar (for testing)
input bool InpUseTimeFilter = false;            // Enable session filter (auto-disable for crypto)
input bool InpTradeAsianSession = true;        // Asian: 1:00-9:00 UTC (Tokyo)
input bool InpTradeEuropeanSession = true;     // European: 7:00-16:00 UTC (London)
input bool InpTradeUSSession = true;           // US: 13:00-22:00 UTC (New York)

input group "=== Additional Filters ==="
input double InpMinATRMultiplier = 0.5;        // RELAXED: Enable ATR filter (was 0.8)
input int InpATRPeriod = 14;
input int InpMaxSpreadPips = 5;                // Max spread in pips (0=disabled)
input bool InpUseCandleConfirmation = true;    // Check candle direction
input bool InpRequireCandlePattern = false;    // RELAXED: Require Engulfing/Pinbar pattern (was true)
input double InpMinPinbarWickRatio = 2.0;      // Min wick/body ratio for Pinbar (2.0 = wick 2x body)
input double InpMinEngulfingRatio = 1.2;       // Min engulfing ratio (1.2 = 120% of prev candle)

input group "=== Debug Settings ==="
input bool InpEnableDetailedLogs = true;
input bool InpEnableFileLogging = true;            // Write signal/trade events to Files\EA_DebugLog.csv
input string InpDebugLogFileName = "EA_DebugLog.csv";  // Filename in MT5 Files folder

//--- Global Variables
datetime g_lastTradeTime = 0;
int g_handleRSI;
int g_handleEMAFast;
int g_handleEMASlow;
int g_handleATR;
int g_handleADX;

//--- Profile helper functions
int GetRSIPeriod() { return InpEnableScalping ? InpRSIPeriod_Scalp : InpRSIPeriod_LongTerm; }
int GetStopLossPips() { return InpEnableScalping ? InpStopLossPips_Scalp : InpStopLossPips_LongTerm; }
int GetTakeProfitPips() { return InpEnableScalping ? InpTakeProfitPips_Scalp : InpTakeProfitPips_LongTerm; }
int GetBreakevenPips() { return InpEnableScalping ? InpBreakevenPips_Scalp : InpBreakevenPips_LongTerm; }
int GetTrailingActivatePips() { return InpEnableScalping ? InpTrailingActivatePips_Scalp : InpTrailingActivatePips_LongTerm; }
int GetTrailingDistancePips() { return InpEnableScalping ? InpTrailingDistancePips_Scalp : InpTrailingDistancePips_LongTerm; }
int GetSidewayStopLossPips() { return InpEnableScalping ? InpSidewayStopLossPips_Scalp : InpSidewayStopLossPips_LongTerm; }
int GetSidewayTakeProfitPips() { return InpEnableScalping ? InpSidewayTakeProfitPips_Scalp : InpSidewayTakeProfitPips_LongTerm; }
int GetMomentumStopLossPips() { return InpEnableScalping ? InpMomentumStopLossPips_Scalp : InpMomentumStopLossPips_LongTerm; }
int GetMomentumTakeProfitPips() { return InpEnableScalping ? InpMomentumTakeProfitPips_Scalp : InpMomentumTakeProfitPips_LongTerm; }

//+------------------------------------------------------------------+
int OnInit()
{
   g_handleRSI = iRSI(_Symbol, PERIOD_M15, GetRSIPeriod(), PRICE_CLOSE);
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
   
   Print("=====================================");
   Print("EA INITIALIZED - PROFILE: ", InpEnableScalping ? "SCALPING" : "LONG-TERM");
   Print("=====================================");
   Print("Symbol: ", _Symbol);
   Print("Pip Value: ", DoubleToString(pipValue, _Digits));
   Print("Position Size: ", InpPositionSizePercent, "%");
   Print("------------------------------------");
   Print("TRENDING MODE:");
   Print("  SL: ", GetStopLossPips(), " pips | TP: ", GetTakeProfitPips(), " pips");
   Print("  R:R = 1:", DoubleToString((double)GetTakeProfitPips()/GetStopLossPips(), 2));
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
      Print("  RSI Levels: Same as trending (30/70)");
      Print("  SL: ", GetSidewayStopLossPips(), " pips | TP: ", GetSidewayTakeProfitPips(), " pips");
      Print("  R:R = 1:", DoubleToString((double)GetSidewayTakeProfitPips()/GetSidewayStopLossPips(), 2));
      Print("  Range Filter: Min ", InpSidewayMinRangePips, " pips over ", InpSidewayRangePeriod, " H4 bars");
      Print("  Boundary Filter: Max ", InpSidewayMaxDistanceToBoundary, " pips from S/R");
   }
   Print("------------------------------------");
   Print("MOMENTUM MODE: ", InpAllowMomentumTrade ? "ENABLED" : "DISABLED");
   if(InpAllowMomentumTrade)
   {
      Print("  Logic: UPTREND+RSI>70=BUY | DOWNTREND+RSI<30=SELL");
      Print("  Confirmation: ", InpUseMomentumConfirmation ? "YES (wait reversal)" : "NO (immediate)");
      Print("  SL: ", GetMomentumStopLossPips(), " pips | TP: ", GetMomentumTakeProfitPips(), " pips");
      Print("  R:R = 1:", DoubleToString((double)GetMomentumTakeProfitPips()/GetMomentumStopLossPips(), 2));
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
      Print("  Momentum SL/TP: ", GetMomentumStopLossPips()/10.0, "/", GetMomentumTakeProfitPips()/10.0, " gia");
      Print("  Sideway SL/TP: ", InpSidewayStopLossPips/10.0, "/", InpSidewayTakeProfitPips/10.0, " gia");
   }
   
   if(StringFind(_Symbol, "BTC") >= 0)
   {
      Print("------------------------------------");
      Print("BTC: 100 pips = $1000");
      Print("  Trend SL/TP: $", InpStopLossPips*10, "/$", InpTakeProfitPips*10);
      Print("  Momentum SL/TP: $", GetMomentumStopLossPips()*10, "/$", GetMomentumTakeProfitPips()*10);
      Print("  Sideway SL/TP: $", InpSidewayStopLossPips*10, "/$", InpSidewayTakeProfitPips*10);
   }
   
   if(StringFind(_Symbol, "US30") >= 0 || StringFind(_Symbol, "DOW") >= 0 || StringFind(_Symbol, "DJ30") >= 0)
   {
      Print("------------------------------------");
      Print("US30 (DOW JONES): 1 pip = 1 point");
      Print("  Trend SL/TP: ", InpStopLossPips, " / ", InpTakeProfitPips, " points");
      Print("  Momentum SL/TP: ", GetMomentumStopLossPips(), " / ", GetMomentumTakeProfitPips(), " points");
      Print("  Sideway SL/TP: ", InpSidewayStopLossPips, " / ", InpSidewayTakeProfitPips, " points");
      Print("  Example: 40 pips SL at 35000 = 34960");
   }
   
   if(StringFind(_Symbol, "NI225") >= 0 || StringFind(_Symbol, "NIKKEI") >= 0 || StringFind(_Symbol, "JPN225") >= 0)
   {
      Print("------------------------------------");
      Print("NIKKEI 225: 1 pip = 1 point");
      Print("  Trend SL/TP: ", InpStopLossPips, " / ", InpTakeProfitPips, " points");
      Print("  Momentum SL/TP: ", GetMomentumStopLossPips(), " / ", GetMomentumTakeProfitPips(), " points");
      Print("  Sideway SL/TP: ", InpSidewayStopLossPips, " / ", InpSidewayTakeProfitPips, " points");
      Print("  Example: 40 pips SL at 33000 = 32960");
   }
   
   if(StringFind(_Symbol, "USDJPY") >= 0)
   {
      Print("------------------------------------");
      Print("USDJPY: 1 pip = 0.01 (or 0.001 for 3-digit)");
      Print("  Trend SL/TP: ", InpStopLossPips, " / ", InpTakeProfitPips, " pips");
      Print("  Momentum SL/TP: ", GetMomentumStopLossPips(), " / ", GetMomentumTakeProfitPips(), " pips");
      Print("  Sideway SL/TP: ", InpSidewayStopLossPips, " / ", InpSidewayTakeProfitPips, " pips");
      Print("  Example: Entry 150.00, SL 40 pips = 149.60, TP 100 pips = 151.00");
   }
   
   if(StringFind(_Symbol, "EURUSD") >= 0)
   {
      Print("------------------------------------");
      Print("EURUSD: 1 pip = 0.0001 (5-digit broker) or 0.00001 (pipette)");
      Print("  Trend SL/TP: ", InpStopLossPips, " / ", InpTakeProfitPips, " pips");
      Print("  Momentum SL/TP: ", GetMomentumStopLossPips(), " / ", GetMomentumTakeProfitPips(), " pips");
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
   
   if(currentVolume <= avgVolume * PATTERN_VOLUME_MULTIPLIER)
   {
      if(InpEnableDetailedLogs)
         Print("PATTERN REJECT: Volume too low (", (int)currentVolume, " vs ", (int)avgVolume, ")");
      return false;
   }
   
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
   bool hasStrongTrend = (InpMinADX > 0) ? (adx >= InpMinADX) : 
                         (MathAbs(emaFast - emaSlow) / ((emaFast + emaSlow) / 2) * 100 > EMA_DIFF_PERCENT_THRESHOLD);
   
   if(!hasStrongTrend)
      return MARKET_SIDEWAYS;
   
   return (emaFast > emaSlow) ? MARKET_UPTREND : MARKET_DOWNTREND;
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
   
   AnalyzeAndTrade(rsi, emaFast[0], emaSlow[0], atr[0], adxMain[0], (double)volume[0]);
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
   int requiredSeconds = (InpCooldownSeconds > 0) ? InpCooldownSeconds : (InpMinutesBetwenTrades * 60);
   
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
// File logging helpers (CSV) for backtest analysis
void DebugLogCSV(string line)
{
   if(!InpEnableFileLogging) return;
   int fh = FileOpen(InpDebugLogFileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(fh == INVALID_HANDLE)
   {
      fh = FileOpen(InpDebugLogFileName, FILE_WRITE|FILE_CSV|FILE_COMMON);
      if(fh == INVALID_HANDLE)
      {
         if(InpEnableDetailedLogs) Print("ERROR: Cannot open debug file ", InpDebugLogFileName);
         return;
      }
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
   string rec = ts + "," + _Symbol + "," + eventType + "," + signalType + "," + marketStateStr + "," + reason + "," + DoubleToString(rsiVal,1) + "," + DoubleToString(avgVol,0) + "," + DoubleToString(currVol,0) + "," + DoubleToString(atrVal,4) + "," + DoubleToString(avgATRVal,4) + "," + DoubleToString(adxVal,1) + "," + IntegerToString(CountOpenPositions()) + "," + IntegerToString(GetMaxPositions());
   DebugLogCSV(rec);
}

void LogTradeEvent(string stage, string comment, bool isBuy, double price, double sl, double tp, double lot, int resultCode, ulong ticket)
{
   if(!InpEnableFileLogging) return;
   string ts = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   string dir = isBuy ? "BUY" : "SELL";
   string ticketStr = (ticket == 0) ? "0" : IntegerToString((int)ticket);
   string rec = ts + "," + _Symbol + ",TRADE," + stage + "," + comment + "," + dir + "," + DoubleToString(price, _Digits) + "," + DoubleToString(sl, _Digits) + "," + DoubleToString(tp, _Digits) + "," + DoubleToString(lot,2) + "," + IntegerToString(resultCode) + "," + ticketStr + "," + IntegerToString(CountOpenPositions()) + "," + IntegerToString(GetMaxPositions());
   DebugLogCSV(rec);
}  

//+------------------------------------------------------------------+
void AnalyzeAndTrade(const double &rsi[], double emaFast, double emaSlow, 
                     double atr, double adx, double currentVolume)
{
   // Calculate average volume (used for pattern confirmation)
   double avgVolume = 0;
   long volumeArray[];
   ArraySetAsSeries(volumeArray, true);
   
   if(CopyTickVolume(_Symbol, PERIOD_M15, 0, InpVolumePeriod, volumeArray) > 0)
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
   
   // Check if we have STRONG MOMENTUM (high vol + high ATR)
   bool hasMomentum = false;
   if(InpAllowMomentumTrade)
   {
      bool isHighVolume = (currentVolume > avgVolume * InpMomentumVolumeMultiplier);
      bool isHighATR = (atr > avgATR * InpMomentumATRMultiplier);
      bool isStrongADX = adx > InpMinADX + MOMENTUM_ADX_BUFFER;
      
      // UPTREND + RSI overbought + HIGH vol + HIGH ATR = Strong buying momentum
      if(marketState == MARKET_UPTREND && rsi[0] > InpRSIOverbought && isHighVolume && isHighATR && isStrongADX)
         hasMomentum = true;
      
      // DOWNTREND + RSI oversold + HIGH vol + HIGH ATR = Strong selling momentum
      if(marketState == MARKET_DOWNTREND && rsi[0] < InpRSIOversold && isHighVolume && isHighATR && isStrongADX)
         hasMomentum = true;
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
      "RSI: ", DoubleToString(rsi[0], 1), " | Vol: ", volumeStatus, " | ATR: ", atrStatus, "\n",
      "Positions: ", CountOpenPositions(), "/", GetMaxPositions(), "\n",
      "Trend (Safe): BUY=", (InpAllowTrendingBuy ? "YES" : "NO"), " SELL=", (InpAllowTrendingSell ? "YES" : "NO"), "\n",
      "Momentum (Aggressive): ", (InpAllowMomentumTrade ? "YES" : "NO"), " | Sideway: ", (InpAllowSidewayTrade ? "YES" : "NO"), "\n",
      "MOMENTUM ACTIVE: ", (hasMomentum ? "YES - HIGH VOL/ATR" : "NO")
   );
   
   // Check common filters - ALWAYS (for all trade types)
   if(!highVolume)
   {
      if(InpEnableDetailedLogs)
         Print("NO SIGNAL: Volume too low (", (int)currentVolume, " vs ", (int)avgVolume, ")");
      LogSignalEvent("REJECT", "VolumeLow", "volume < avg*mult", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
      return;
   }
   
   if(!volatilityOK)
   {
      if(InpEnableDetailedLogs)
         Print("NO SIGNAL: ATR too low");
      LogSignalEvent("REJECT", "ATRLow", "atr < avg*minMult", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
      return;
   }
   
   // Momentum trades skip pattern check only
   if(hasMomentum && InpEnableDetailedLogs)
   {
      Print("⚡ MOMENTUM DETECTED: Candlestick pattern check will be BYPASSED");
   }
   
   // TRENDING SIGNALS (Mean Reversion - Wait for Reversal)
   if(marketState == MARKET_UPTREND && InpAllowTrendingBuy)
   {
      if(rsi[0] < InpRSIOversold)
      {
         // RSI Confirmation: MUST be turning up (reversal started)
         bool rsiConfirmed = !InpUseRSIConfirmation || (rsi[0] > rsi[1] && rsi[1] <= rsi[2]);
         
         if(!rsiConfirmed)
         {
            if(InpEnableDetailedLogs)
               Print("WAITING: TREND BUY - RSI not reversing yet (RSI=", DoubleToString(rsi[0], 1), 
                     " prev=", DoubleToString(rsi[1], 1), ")");
            LogSignalEvent("WAIT", "Trend_Buy", "RSI not reversing", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
            return;
         }
         
         // Pattern Confirmation REQUIRED: Bullish Engulfing
         if(!CheckCandlePattern(true, currentVolume, avgVolume))
         {
            if(!InpAllowOnCurrentBar)
            {
               if(InpEnableDetailedLogs)
                  Print("WAITING: TREND BUY - No bullish engulfing pattern yet");
               LogSignalEvent("REJECT", "Trend_Buy", "PatternMissing", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
               return;
            }
            else
            {
               if(InpEnableDetailedLogs)
                  Print("FORCED: TREND BUY - Pattern bypass due to InpAllowOnCurrentBar");
            }
         }
         
         if(InpEnableDetailedLogs)
            Print("✅ SIGNAL: TREND BUY (Uptrend + RSI Reversal + Bullish Engulfing)");
         LogSignalEvent("SIGNAL", "Trend_Buy", "Confirmed", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
         OpenPosition(true, GetStopLossPips(), GetTakeProfitPips(), "Trend_Buy");
         return;
      }
   }
   
   if(marketState == MARKET_DOWNTREND && InpAllowTrendingSell)
   {
      if(rsi[0] > InpRSIOverbought)
      {
         // RSI Confirmation: MUST be turning down (reversal started)
         bool rsiConfirmed = !InpUseRSIConfirmation || (rsi[0] < rsi[1] && rsi[1] >= rsi[2]);
         
         if(!rsiConfirmed)
         {
            if(InpEnableDetailedLogs)
               Print("WAITING: TREND SELL - RSI not reversing yet (RSI=", DoubleToString(rsi[0], 1), 
                     " prev=", DoubleToString(rsi[1], 1), ")");
            LogSignalEvent("WAIT", "Trend_Sell", "RSI not reversing", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
            return;
         }
         
         // Pattern Confirmation REQUIRED: Bearish Engulfing
         if(!CheckCandlePattern(false, currentVolume, avgVolume))
         {
            if(!InpAllowOnCurrentBar)
            {
               if(InpEnableDetailedLogs)
                  Print("WAITING: TREND SELL - No bearish engulfing pattern yet");
               LogSignalEvent("REJECT", "Trend_Sell", "PatternMissing", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
               return;
            }
            else
            {
               if(InpEnableDetailedLogs)
                  Print("FORCED: TREND SELL - Pattern bypass due to InpAllowOnCurrentBar");
            }
         }
         
         if(InpEnableDetailedLogs)
            Print("✅ SIGNAL: TREND SELL (Downtrend + RSI Reversal + Bearish Engulfing)");
         LogSignalEvent("SIGNAL", "Trend_Sell", "Confirmed", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
         OpenPosition(false, GetStopLossPips(), GetTakeProfitPips(), "Trend_Sell");
         return;
      }
   }
   
   // MOMENTUM SIGNALS (Aggressive - Entry on Strong Moves)
   if(InpAllowMomentumTrade && hasMomentum)
   {
      // UPTREND + RSI overbought + HIGH volume + HIGH ATR -> Strong BUY momentum
      if(marketState == MARKET_UPTREND && InpAllowTrendingBuy && rsi[0] > InpRSIOverbought)
      {
         if(InpEnableDetailedLogs)
         {
            Print("⚡ MOMENTUM BUY DETECTED:");
            Print("  RSI: ", DoubleToString(rsi[0], 1), " (overbought)");
            Print("  Volume: ", DoubleToString(currentVolume/avgVolume, 2), "x avg (HIGH)");
            Print("  ATR: ", DoubleToString(atr/avgATR, 2), "x avg (HIGH)");
            Print("  ADX: ", DoubleToString(adx, 1), " (strong trend)");
            Print("✅ ENTRY: Riding the strong momentum wave!");
         }
         LogSignalEvent("SIGNAL", "Momentum_Buy", "MomentumConfirmed", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
         OpenPosition(true, GetMomentumStopLossPips(), GetMomentumTakeProfitPips(), "Momentum_Buy");
         return;
      }
      
      // DOWNTREND + RSI oversold + HIGH volume + HIGH ATR -> Strong SELL momentum
      if(marketState == MARKET_DOWNTREND && InpAllowTrendingSell && rsi[0] < InpRSIOversold)
      {
         if(InpEnableDetailedLogs)
         {
            Print("⚡ MOMENTUM SELL DETECTED:");
            Print("  RSI: ", DoubleToString(rsi[0], 1), " (oversold)");
            Print("  Volume: ", DoubleToString(currentVolume/avgVolume, 2), "x avg (HIGH)");
            Print("  ATR: ", DoubleToString(atr/avgATR, 2), "x avg (HIGH)");
            Print("  ADX: ", DoubleToString(adx, 1), " (strong trend)");
            Print("✅ ENTRY: Riding the strong momentum wave!");
         }
         LogSignalEvent("SIGNAL", "Momentum_Sell", "MomentumConfirmed", rsi[0], avgVolume, currentVolume, atr, avgATR, adx, marketStateStr);
         OpenPosition(false, GetMomentumStopLossPips(), GetMomentumTakeProfitPips(), "Momentum_Sell");
         return;
      }
   }
   
   // SIDEWAYS SIGNALS (Range Trading with Boundary Confirmation)
   if(marketState == MARKET_SIDEWAYS && InpAllowSidewayTrade)
   {
      // Use same RSI levels as trending modes (30/70)
      int lowerBound = InpRSIOversold;      // 30
      int upperBound = InpRSIOverbought;    // 70
      
      // Calculate recent range using H4 for better range detection
      ENUM_TIMEFRAMES rangeTimeframe = PERIOD_H4;
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
      if(rsi[0] < lowerBound)
      {
         // Filter 1: Must be near range bottom (support)
         if(distanceFromLow > InpSidewayMaxDistanceToBoundary)
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: Sideways BUY too far from support (", 
                     DoubleToString(distanceFromLow, 1), " pips from low)");
            return;
         }
         
         // Filter 2: Price rejection confirmation at support
         if(!CheckPriceRejection(true, rangeLow, rangeHigh))
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: Sideways BUY - no price rejection at support");
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
         
         // Filter 4: Candlestick pattern
         if(!CheckCandlePattern(true, currentVolume, avgVolume))
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: Sideways BUY but no valid candlestick pattern");
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
         OpenPosition(true, GetSidewayStopLossPips(), GetSidewayTakeProfitPips(), "Sideway_Buy");
         return;
      }
      
      // SELL when RSI hits upper bound (overbought in range)
      if(rsi[0] > upperBound)
      {
         // Filter 1: Must be near range top (resistance)
         if(distanceFromHigh > InpSidewayMaxDistanceToBoundary)
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: Sideways SELL too far from resistance (", 
                     DoubleToString(distanceFromHigh, 1), " pips from high)");
            return;
         }
         
         // Filter 2: Price rejection confirmation at resistance
         if(!CheckPriceRejection(false, rangeLow, rangeHigh))
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: Sideways SELL - no price rejection at resistance");
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
         
         // Filter 4: Candlestick pattern
         if(!CheckCandlePattern(false, currentVolume, avgVolume))
         {
            if(InpEnableDetailedLogs)
               Print("BLOCKED: Sideways SELL but no valid candlestick pattern");
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
         OpenPosition(false, GetSidewayStopLossPips(), GetSidewayTakeProfitPips(), "Sideway_Sell");
         return;
      }
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
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmountUSD = balance * (InpPositionSizePercent / 100.0);
   
   // Calculate pip value for 1 lot
   double pipValue = GetPipValue();
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   
   // Calculate money value per pip for 1 lot
   double moneyPerPipPerLot = 0;
   
   string symbol = _Symbol;
   
   // Special calculation for different instrument types
   if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0)
   {
      // Gold: 1 lot = 100 oz, 1 pip = 0.10, value = 100 * 0.10 = $10 per pip
      moneyPerPipPerLot = contractSize * pipValue;  // 100 * 0.10 = $10
   }
   else if(StringFind(symbol, "BTC") >= 0)
   {
      // BTC: 1 lot = 1 BTC, 1 pip = 10.0 (100 pips = $1000)
      // Use contract size to be consistent with other instruments
      moneyPerPipPerLot = contractSize * pipValue;
   }
   
   // Safety guard: avoid division by zero
   if(moneyPerPipPerLot <= 0)
   {
      if(InpEnableDetailedLogs) Print("WARN: moneyPerPipPerLot <= 0 for ", _Symbol, " (pipValue=", DoubleToString(pipValue,2), ", contractSize=", DoubleToString(contractSize,2), "). Falling back to 1.0");
      moneyPerPipPerLot = 1.0;
   }
   else if(StringFind(symbol, "US30") >= 0 || StringFind(symbol, "DOW") >= 0 || 
           StringFind(symbol, "NI225") >= 0 || StringFind(symbol, "NIKKEI") >= 0)
   {
      // Indices: Contract size varies by broker
      moneyPerPipPerLot = contractSize * pipValue;
   }
   else
   {
      // Forex pairs: Calculate based on quote currency
      string quoteCurrency = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
      
      if(quoteCurrency == "USD")
      {
         // Quote is USD (e.g., EURUSD, GBPUSD)
         // 1 lot = 100,000 units, 1 pip = 0.0001
         // Pip value = 100,000 * 0.0001 = $10
         moneyPerPipPerLot = contractSize * pipValue;
      }
      else
      {
         // Quote is not USD (e.g., USDJPY, USDCHF)
         // Need conversion rate
         double conversionRate = 1.0;
         
         if(quoteCurrency == "JPY")
         {
            // For USDJPY: 1 lot, 1 pip movement = 1000 JPY
            // Convert to USD: 1000 / current rate
            conversionRate = 1.0 / entryPrice;
            moneyPerPipPerLot = (contractSize * pipValue) * conversionRate;
         }
         else
         {
            // Generic forex
            moneyPerPipPerLot = contractSize * pipValue;
         }
      }
   }
   
   // Calculate lot size based on risk
   // Risk = SL pips * money per pip * lot size
   // lotSize = Risk / (SL pips * money per pip)
   double lotSize = riskAmountUSD / (slPips * moneyPerPipPerLot);
   
   // Apply broker constraints
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   
   if(lotSize < minLot) lotSize = minLot;
   if(lotSize > maxLot) lotSize = maxLot;
   
   if(InpEnableDetailedLogs)
   {
      Print("LOT SIZE CALCULATION:");
      Print("  Balance: $", DoubleToString(balance, 2));
      Print("  Risk %: ", InpPositionSizePercent, "% = $", DoubleToString(riskAmountUSD, 2));
      Print("  SL Pips: ", slPips);
      Print("  Money per pip (1 lot): $", DoubleToString(moneyPerPipPerLot, 2));
      Print("  Calculated Lot: ", DoubleToString(lotSize, 2));
      Print("  Min/Max Lot: ", minLot, "/", maxLot);
   }
   
   return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
void OpenPosition(bool isBuy, int slPips, int tpPips, string comment)
{
   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = CalculateLotSize(price, slPips);  // Pass slPips parameter
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
      LogTradeEvent("SUCCESS", comment, isBuy, price, sl, tp, lot, trade.ResultRetcode(), trade.ResultOrder());
      g_lastTradeTime = TimeCurrent();
   }
   else
   {
      Print("FAILED: Error ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      LogTradeEvent("FAILED", comment, isBuy, price, sl, tp, lot, trade.ResultRetcode(), 0);
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
      if(InpUseTrailingStop && profitPips >= GetTrailingActivatePips())
      {
         double trailingDistance = GetTrailingDistancePips() * pipValue;
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