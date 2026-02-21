//+------------------------------------------------------------------+
//|                                              ea_ict_concept.mq5   |
//|                        Copyright 2026, ICT Concept Strategy       |
//|                        v1.1 - ICT Smart Money Concept for Gold    |
//+------------------------------------------------------------------+
//| v1.1 (2026-02-17)                                                |
//| ICT Smart Money Concept EA for Gold (XAUUSD)                     |
//| H4 Structure Detection + M15 Precision Entry                     |
//|                                                                   |
//| Core Concepts Implemented:                                        |
//| 1. Break of Structure (BOS) / Change of Character (ChoCH)       |
//|    - H4 swing point detection (fractal method)                   |
//|    - HH/HL for uptrend, LL/LH for downtrend                     |
//|    - BOS = continuation, ChoCH = reversal                        |
//| 2. Order Blocks (OB)                                             |
//|    - Last opposing candle before impulse move creating BOS       |
//|    - Bullish OB = last bearish candle before up impulse          |
//|    - Bearish OB = last bullish candle before down impulse        |
//| 3. Optimal Trade Entry (OTE)                                     |
//|    - Fibonacci 0.618-0.786 retracement zone after BOS            |
//|    - Best entry when OTE overlaps with Order Block               |
//| 4. Liquidity Sweep                                               |
//|    - Price sweeps beyond swing high/low then reverses            |
//|    - Confirms smart money manipulation before entry              |
//|                                                                   |
//| Entry Flow:                                                       |
//| H4 BOS/ChoCH → Identify OB → Wait M15 retrace to OTE zone      |
//| → Check OB overlap → Liquidity sweep confirmation                |
//| → Candle pattern → Execute with SL below/above OB               |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "1.00"
#property description "ICT Smart Money Concept - Gold XAUUSD"
#property description "H4 Structure + M15 Entry | OB + OTE + Liquidity Sweep"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//+------------------------------------------------------------------+
//| Enums                                                             |
//+------------------------------------------------------------------+
enum ENUM_ICT_BIAS
{
   ICT_BULLISH,      // Bullish bias - look for longs
   ICT_BEARISH,      // Bearish bias - look for shorts
   ICT_NEUTRAL        // No clear bias - no trades
};

enum ENUM_STRUCTURE_TYPE
{
   STRUCTURE_BOS,     // Break of Structure (continuation)
   STRUCTURE_CHOCH    // Change of Character (reversal)
};

//+------------------------------------------------------------------+
//| Structs                                                           |
//+------------------------------------------------------------------+
struct SwingPoint
{
   double   price;       // Swing price level
   datetime time;        // Time of the swing
   int      barIndex;    // Bar index when detected
   bool     isHigh;      // true = swing high, false = swing low
   bool     isValid;     // Still valid (not broken)
};

struct OrderBlock
{
   double   highPrice;    // Upper boundary of OB zone
   double   lowPrice;     // Lower boundary of OB zone
   datetime time;         // Time when OB was created
   int      barIndex;     // H4 bar index of OB candle
   bool     isBullish;    // true = demand zone (bullish OB), false = supply zone (bearish OB)
   bool     isMitigated;  // true = price has passed through, no longer valid
   bool     isValid;      // Active and usable
};

struct StructureBreak
{
   double               breakPrice;   // Price level of the break
   datetime             time;         // When the break occurred
   bool                 isBullish;    // true = bullish break (price broke above)
   ENUM_STRUCTURE_TYPE  type;         // BOS or ChoCH
   double               swingA;       // Start of impulse (swing low for bullish, swing high for bearish)
   double               swingB;       // End of impulse = break level
};

//+------------------------------------------------------------------+
//| Constants                                                         |
//+------------------------------------------------------------------+
const double BROKER_STOP_BUFFER = 1.1;       // Buffer multiplier for broker stop level
const int    MAX_SWING_POINTS = 50;          // Maximum swing points to track
const int    MAX_ORDER_BLOCKS = 10;          // Maximum active order blocks
const double OB_BUFFER_PIPS = 5.0;           // Extra pips beyond OB for SL (wider for XM spread)
const int    ATR_AVERAGE_PERIOD = 20;        // Bars for ATR average calculation

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== H4 Structure Detection ==="
input int    InpSwingLookback = 5;           // Bars left/right for swing point detection
input int    InpMinStructureBars = 3;        // Min bars between swing points
input int    InpMaxSwingAge = 100;           // Max H4 bars age for swing points (expire old ones)

input group "=== Order Block Settings ==="
input int    InpOBMaxAge = 30;               // OB expires after N H4 bars
input double InpOBMinBodyRatio = 0.4;        // Min body/range ratio (skip dojis)
input bool   InpRequireOBOverlapOTE = true;  // OB must overlap with OTE zone for entry

input group "=== Optimal Trade Entry (OTE) ==="
input double InpOTEFibLow = 0.618;           // OTE zone start (Fibonacci level)
input double InpOTEFibHigh = 0.786;          // OTE zone end (Fibonacci level)
input int    InpOTEMaxAgeBars = 30;           // OTE max age (H4 bars, 0=no limit)

input group "=== Liquidity Sweep ==="
input bool   InpRequireLiqSweep = true;      // Require liquidity sweep before entry
input int    InpLiqSweepLookback = 15;       // M15 bars to look back for sweep
input double InpMinSweepPips = 5.0;          // Min pips beyond swing for valid sweep (wider for XM spread)

input group "=== Risk Management ==="
input double InpRiskPercent = 2.0;           // Risk % per trade
input double InpMaxLotSize = 1.5;            // Max lot size (0=no limit)
input bool   InpUseATRBasedSLTP = true;      // Use ATR for adaptive SL/TP
input double InpATRMultiplierSL = 1.5;       // SL = max(OB-based, ATR × this)
input double InpATRMultiplierTP = 3.0;       // TP = ATR × this (or R:R based)
input double InpMinRiskReward = 2.0;         // Minimum Risk:Reward ratio to take trade

input group "=== Fixed SL/TP (Fallback) ==="
input int    InpFixedSLPips = 50;            // Fixed SL in pips (when ATR disabled)
input int    InpFixedTPPips = 150;           // Fixed TP in pips (R:R ≈ 1:3)

input group "=== Position Management ==="
input bool   InpUseTrailingStop = true;      // Enable trailing stop
input bool   InpUseATRTrailing = true;       // ATR-based trailing distance
input double InpTrailingATRMult = 1.0;       // Trail distance = ATR × this
input int    InpTrailingActivatePips = 40;   // Fixed trailing activation (pips)
input int    InpTrailingDistancePips = 20;   // Fixed trailing distance (pips)
input int    InpBreakevenPips = 40;          // Move SL to breakeven at +N pips profit
input bool   InpUsePartialTP = true;         // Enable Partial Take Profit
input double InpPartialTPPercent = 50.0;     // Partial close % of position
input double InpPartialTPRR = 1.0;           // Partial TP at this R:R level

input group "=== Entry Confirmation (M15) ==="
input bool   InpRequireCandlePattern = true; // Require candle pattern for entry
input double InpMinPinbarWickRatio = 2.5;    // Min wick/body ratio for Pinbar
input double InpMinEngulfingRatio = 1.5;     // Min body ratio for Engulfing
input double InpPatternVolumeMultiplier = 1.5; // Volume multiplier for patterns

input group "=== Kill Zones (UTC) ==="
input bool   InpUseKillZones = true;         // Only trade in Kill Zones
input bool   InpUseLondonKZ = true;          // London KZ: 07:00-10:00 UTC
input bool   InpUseNYKZ = true;              // New York KZ: 13:00-16:00 UTC
input bool   InpUseAsianKZ = false;          // Asian KZ: 00:00-04:00 UTC
input int    InpLondonKZStart = 7;           // London Kill Zone start hour (UTC)
input int    InpLondonKZEnd = 10;            // London Kill Zone end hour (UTC)
input int    InpNYKZStart = 13;              // New York Kill Zone start hour (UTC)
input int    InpNYKZEnd = 16;                // New York Kill Zone end hour (UTC)
input int    InpAsianKZStart = 0;            // Asian Kill Zone start hour (UTC)
input int    InpAsianKZEnd = 4;              // Asian Kill Zone end hour (UTC)

input group "=== General Settings ==="
input int    InpMagicNumber = 654321;        // Magic number (unique per EA)
input int    InpMaxPositions = 3;            // Max concurrent positions
input bool   InpUseAutoMaxPositions = true;  // Auto-scale max positions by balance
input int    InpCooldownMinutes = 60;        // Cooldown between trades (minutes)
input int    InpMaxSpreadPips = 6;           // Max spread (Exness~2-3, XM~4-6)
input bool   InpAllowOppositePositions = false; // Allow opposing BUY+SELL simultaneously
input int    InpATRPeriod = 14;              // ATR period

input group "=== Chart Drawing ==="
input bool   InpDrawStructure = true;        // Draw BOS/ChoCH lines & arrows on chart
input bool   InpDrawOrderBlocks = true;      // Draw Order Block rectangles
input bool   InpDrawSwingPoints = true;      // Draw swing high/low markers
input bool   InpDrawOTEZone = true;          // Draw OTE Fibonacci zone
input color  InpColorBOS_Bull = clrDodgerBlue;   // BOS Bullish line color
input color  InpColorBOS_Bear = clrOrangeRed;    // BOS Bearish line color
input color  InpColorChoCH_Bull = clrLime;       // ChoCH Bullish color (reversal)
input color  InpColorChoCH_Bear = clrMagenta;    // ChoCH Bearish color (reversal)
input color  InpColorOB_Demand = clrDodgerBlue;  // Demand OB rectangle color
input color  InpColorOB_Supply = clrOrangeRed;   // Supply OB rectangle color
input color  InpColorOTE = clrGold;              // OTE zone color
input color  InpColorSwingHigh = clrRed;         // Swing High marker color
input color  InpColorSwingLow = clrLimeGreen;    // Swing Low marker color
input int    InpStructureLineWidth = 2;          // BOS/ChoCH line width
input ENUM_LINE_STYLE InpStructureLineStyle = STYLE_DASH; // BOS line style

input group "=== Debug Settings ==="
input bool   InpEnableDetailedLogs = true;   // Enable detailed logging
input bool   InpEnableFileLogging = false;   // Write events to CSV file
input string InpDebugLogFileName = "ICT_DebugLog.csv"; // Log filename

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
datetime g_lastTradeTime = 0;
datetime g_lastH4BarTime = 0;
datetime g_lastM15BarTime = 0;

//--- Indicator handles
int g_handleATR;           // ATR on M15
int g_handleATR_H4;        // ATR on H4 (for structure context)

//--- ICT State
SwingPoint     g_swingPoints[];       // H4 swing point history
OrderBlock     g_orderBlocks[];       // Active order blocks
StructureBreak g_lastStructureBreak;  // Most recent BOS/ChoCH
ENUM_ICT_BIAS  g_currentBias = ICT_NEUTRAL;  // Current market bias from H4

//--- Tracking previous trend for ChoCH detection
bool g_wasUptrend = false;            // Previous trend state
bool g_wasTrendEstablished = false;   // Whether we had a clear trend before

//--- Drawing counters
int g_structureDrawCount = 0;         // Counter for unique object names
int g_obDrawCount = 0;                // Counter for OB rectangle names
int g_swingDrawCount = 0;             // Counter for swing point names
string g_objPrefix = "ICT_";          // Prefix for all chart objects

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Create indicator handles
   g_handleATR = iATR(_Symbol, PERIOD_M15, InpATRPeriod);
   g_handleATR_H4 = iATR(_Symbol, PERIOD_H4, InpATRPeriod);
   
   if(g_handleATR == INVALID_HANDLE || g_handleATR_H4 == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handles!");
      return(INIT_FAILED);
   }
   
   //--- Configure trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(100);  // Wider slippage tolerance for XM STP execution
   
   // Auto-detect filling mode (Exness=FOK, XM=IOC/RETURN)
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
   
   //--- Initialize arrays
   ArrayResize(g_swingPoints, 0);
   ArrayResize(g_orderBlocks, 0);
   
   //--- Initialize structure break
   g_lastStructureBreak.breakPrice = 0;
   g_lastStructureBreak.time = 0;
   g_lastStructureBreak.isBullish = false;
   g_lastStructureBreak.type = STRUCTURE_BOS;
   g_lastStructureBreak.swingA = 0;
   g_lastStructureBreak.swingB = 0;
   
   g_currentBias = ICT_NEUTRAL;
   g_wasUptrend = false;
   g_wasTrendEstablished = false;
   
   //--- Initial H4 structure scan
   DetectSwingPoints();
   DetectBOS_ChoCH();
   DetectOrderBlocks();
   
   //--- Print initialization summary
   Print("====================================");
   Print("ICT CONCEPT EA v1.1 INITIALIZED");
   Print("====================================");
   Print("Symbol: ", _Symbol, " | Pip Value: ", DoubleToString(GetPipValue(), _Digits));
   Print("Structure TF: H4 | Entry TF: M15");
   Print("Swing Lookback: ", InpSwingLookback, " bars");
   Print("OB Max Age: ", InpOBMaxAge, " H4 bars");
   Print("OTE Zone: ", DoubleToString(InpOTEFibLow, 3), " - ", DoubleToString(InpOTEFibHigh, 3));
   Print("Require OB+OTE overlap: ", InpRequireOBOverlapOTE ? "YES" : "NO");
   Print("Require Liq Sweep: ", InpRequireLiqSweep ? "YES" : "NO");
   Print("Risk: ", DoubleToString(InpRiskPercent, 1), "% | Max Lot: ", DoubleToString(InpMaxLotSize, 2));
   Print("SL/TP: ", InpUseATRBasedSLTP ? "ATR-Based" : "Fixed Pips");
   Print("Min R:R = 1:", DoubleToString(InpMinRiskReward, 1));
   Print("Kill Zones: ", InpUseKillZones ? "ON" : "OFF",
         " | London: ", InpUseLondonKZ ? "YES" : "NO",
         " | NY: ", InpUseNYKZ ? "YES" : "NO",
         " | Asian: ", InpUseAsianKZ ? "YES" : "NO");
   Print("Cooldown: ", InpCooldownMinutes, " min | Max Spread: ", InpMaxSpreadPips, " pips");
   Print("Candle Pattern Required: ", InpRequireCandlePattern ? "YES" : "NO");
   Print("Trailing: ", InpUseTrailingStop ? "ON" : "OFF",
         " | ATR Trail: ", InpUseATRTrailing ? "YES" : "NO");
   Print("Partial TP: ", InpUsePartialTP ? "ON" : "OFF",
         " | ", DoubleToString(InpPartialTPPercent, 0), "% at ", DoubleToString(InpPartialTPRR, 1), "R");
   Print("OTE Max Age: ", InpOTEMaxAgeBars > 0 ? IntegerToString(InpOTEMaxAgeBars) + " H4 bars" : "Unlimited");
   Print("Opposing Pos: ", InpAllowOppositePositions ? "ALLOWED" : "BLOCKED");
   Print("Initial Bias: ", BiasToString(g_currentBias));
   Print("Swing Points Found: ", ArraySize(g_swingPoints));
   Print("Active OBs: ", CountActiveOrderBlocks());
   Print("====================================");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(g_handleATR);
   IndicatorRelease(g_handleATR_H4);
   
   ArrayFree(g_swingPoints);
   ArrayFree(g_orderBlocks);
   
   // Remove all chart objects created by this EA
   ObjectsDeleteAll(0, g_objPrefix);
   
   Print("====================================");
   Print("ICT EA STOPPED - Reason: ", reason);
   Print("  Chart objects cleaned up (prefix: ", g_objPrefix, ")");
   Print("====================================");
}

//+------------------------------------------------------------------+
//| String helpers                                                    |
//+------------------------------------------------------------------+
string BiasToString(ENUM_ICT_BIAS bias)
{
   switch(bias)
   {
      case ICT_BULLISH: return "BULLISH";
      case ICT_BEARISH: return "BEARISH";
      default:          return "NEUTRAL";
   }
}

string StructureTypeToString(ENUM_STRUCTURE_TYPE stype)
{
   switch(stype)
   {
      case STRUCTURE_BOS:   return "BOS";
      case STRUCTURE_CHOCH: return "ChoCH";
      default:              return "UNKNOWN";
   }
}

//+------------------------------------------------------------------+
//| Symbol Helper Functions (adapted from EA v4.1)                    |
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
double GetPipValue()
{
   string symbol = _Symbol;
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   
   // Gold (XAU)
   if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0)
      return 0.10;
   
   // Bitcoin
   if(StringFind(symbol, "BTC") >= 0)
      return 10.0;
   
   // US30 / Dow Jones
   if(StringFind(symbol, "US30") >= 0 || StringFind(symbol, "DOW") >= 0 || StringFind(symbol, "DJ30") >= 0)
      return 1.0;
   
   // Nikkei 225
   if(StringFind(symbol, "NI225") >= 0 || StringFind(symbol, "NIKKEI") >= 0 || StringFind(symbol, "JPN225") >= 0)
      return 1.0;
   
   // JPY pairs
   if(StringFind(symbol, "JPY") >= 0)
   {
      if(digits == 3 || digits == 2)
         return 0.01;
      else
         return point * 10;
   }
   
   // Standard forex
   if(digits == 5 || digits == 3)
      return point * 10;
   else
      return point;
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
//| Kill Zone Check                                                   |
//+------------------------------------------------------------------+
bool IsInKillZone()
{
   if(!InpUseKillZones)
      return true;
   
   // Auto-disable for crypto
   if(IsCryptoSymbol())
      return true;
   
   MqlDateTime timeNow;
   TimeToStruct(TimeGMT(), timeNow);
   int currentHour = timeNow.hour;
   
   string activeKZ = "";
   
   // London Kill Zone
   if(InpUseLondonKZ && currentHour >= InpLondonKZStart && currentHour < InpLondonKZEnd)
   {
      activeKZ = "LONDON";
      return true;
   }
   
   // New York Kill Zone
   if(InpUseNYKZ && currentHour >= InpNYKZStart && currentHour < InpNYKZEnd)
   {
      activeKZ = "NEW_YORK";
      return true;
   }
   
   // Asian Kill Zone
   if(InpUseAsianKZ && currentHour >= InpAsianKZStart && currentHour < InpAsianKZEnd)
   {
      activeKZ = "ASIAN";
      return true;
   }
   
   if(InpEnableDetailedLogs)
      Print("BLOCKED: Outside Kill Zones (UTC ", currentHour, ":00)");
   return false;
}

//+------------------------------------------------------------------+
//| Get current Kill Zone name for display                             |
//+------------------------------------------------------------------+
string GetCurrentKillZone()
{
   if(!InpUseKillZones) return "ALL";
   if(IsCryptoSymbol()) return "24/7";
   
   MqlDateTime timeNow;
   TimeToStruct(TimeGMT(), timeNow);
   int h = timeNow.hour;
   
   if(InpUseLondonKZ && h >= InpLondonKZStart && h < InpLondonKZEnd) return "LONDON";
   if(InpUseNYKZ && h >= InpNYKZStart && h < InpNYKZEnd) return "NEW_YORK";
   if(InpUseAsianKZ && h >= InpAsianKZStart && h < InpAsianKZEnd) return "ASIAN";
   return "NONE";
}

//+------------------------------------------------------------------+
//| Candle Pattern Detection (adapted from EA v4.1)                   |
//+------------------------------------------------------------------+
bool CheckCandlePattern(bool isBuySignal)
{
   if(!InpRequireCandlePattern)
      return true;
   
   // Get last 2 completed candles on M15
   double open1 = iOpen(_Symbol, PERIOD_M15, 1);
   double close1 = iClose(_Symbol, PERIOD_M15, 1);
   double high1 = iHigh(_Symbol, PERIOD_M15, 1);
   double low1 = iLow(_Symbol, PERIOD_M15, 1);
   
   double open2 = iOpen(_Symbol, PERIOD_M15, 2);
   double close2 = iClose(_Symbol, PERIOD_M15, 2);
   double high2 = iHigh(_Symbol, PERIOD_M15, 2);
   double low2 = iLow(_Symbol, PERIOD_M15, 2);
   
   // Check volume for pattern validity
   long vol[];
   ArraySetAsSeries(vol, true);
   if(CopyTickVolume(_Symbol, PERIOD_M15, 1, 2, vol) < 2)
      return false;
   
   double currentVol = (double)vol[0];
   double prevVol = (double)vol[1];
   double avgVol = (currentVol + prevVol) / 2.0;
   
   if(currentVol < avgVol * InpPatternVolumeMultiplier * 0.5)
   {
      if(InpEnableDetailedLogs)
         Print("PATTERN: Volume too low for confirmation");
      return false;
   }
   
   if(isBuySignal)
   {
      bool isBullish1 = (close1 > open1);
      bool isBearish2 = (close2 < open2);
      double body1 = MathAbs(close1 - open1);
      double body2 = MathAbs(close2 - open2);
      
      // Bullish Engulfing
      if(isBullish1 && isBearish2 && 
         close1 > open2 && open1 < close2 &&
         body1 > body2 * InpMinEngulfingRatio)
      {
         if(InpEnableDetailedLogs)
            Print("✅ BULLISH ENGULFING | Body ratio: ", DoubleToString(body1/MathMax(body2,0.00001), 2));
         return true;
      }
      
      // Bullish Pinbar (Hammer)
      double lowerWick1 = MathMin(open1, close1) - low1;
      double upperWick1 = high1 - MathMax(open1, close1);
      
      if(isBullish1 && body1 > 0 &&
         lowerWick1 > body1 * InpMinPinbarWickRatio &&
         upperWick1 < body1 * 0.3)
      {
         if(InpEnableDetailedLogs)
            Print("✅ BULLISH PINBAR | Wick/Body: ", DoubleToString(lowerWick1/body1, 2));
         return true;
      }
      
      if(InpEnableDetailedLogs)
         Print("PATTERN REJECT: No bullish pattern (Engulfing/Pinbar)");
      return false;
   }
   else
   {
      bool isBearish1 = (close1 < open1);
      bool isBullish2 = (close2 > open2);
      double body1 = MathAbs(close1 - open1);
      double body2 = MathAbs(close2 - open2);
      
      // Bearish Engulfing
      if(isBearish1 && isBullish2 && 
         close1 < open2 && open1 > close2 &&
         body1 > body2 * InpMinEngulfingRatio)
      {
         if(InpEnableDetailedLogs)
            Print("✅ BEARISH ENGULFING | Body ratio: ", DoubleToString(body1/MathMax(body2,0.00001), 2));
         return true;
      }
      
      // Bearish Pinbar (Shooting Star)
      double upperWick1 = high1 - MathMax(open1, close1);
      double lowerWick1 = MathMin(open1, close1) - low1;
      
      if(isBearish1 && body1 > 0 &&
         upperWick1 > body1 * InpMinPinbarWickRatio &&
         lowerWick1 < body1 * 0.3)
      {
         if(InpEnableDetailedLogs)
            Print("✅ BEARISH PINBAR | Wick/Body: ", DoubleToString(upperWick1/body1, 2));
         return true;
      }
      
      if(InpEnableDetailedLogs)
         Print("PATTERN REJECT: No bearish pattern (Engulfing/Pinbar)");
      return false;
   }
}

//+------------------------------------------------------------------+
//| Position counting                                                 |
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
   }
   return count;
}

//+------------------------------------------------------------------+
//| Check if there's an open position in a specific direction         |
//+------------------------------------------------------------------+
bool HasPositionInDirection(bool isBuy)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(isBuy && posType == POSITION_TYPE_BUY) return true;
      if(!isBuy && posType == POSITION_TYPE_SELL) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
int GetMaxPositions()
{
   if(!InpUseAutoMaxPositions)
      return InpMaxPositions;
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance < 200) return 2;
   else if(balance < 500) return 3;
   else if(balance < 1000) return 4;
   else return 5;
}

//+------------------------------------------------------------------+
int CountActiveOrderBlocks()
{
   int count = 0;
   for(int i = 0; i < ArraySize(g_orderBlocks); i++)
   {
      if(g_orderBlocks[i].isValid && !g_orderBlocks[i].isMitigated)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| ===== H4 STRUCTURE DETECTION FUNCTIONS =====                      |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Detect Swing Points on H4 (Fractal Method)                       |
//+------------------------------------------------------------------+
void DetectSwingPoints()
{
   int barsNeeded = InpMaxSwingAge + InpSwingLookback + 1;  // enough bars
   int available = iBars(_Symbol, PERIOD_H4);
   if(available < barsNeeded) barsNeeded = available - 1;
   if(barsNeeded < InpSwingLookback * 2 + 1) return;
   
   // Get H4 OHLC data
   double high[], low[];
   datetime time[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(time, true);
   
   if(CopyHigh(_Symbol, PERIOD_H4, 0, barsNeeded, high) != barsNeeded) return;
   if(CopyLow(_Symbol, PERIOD_H4, 0, barsNeeded, low) != barsNeeded) return;
   if(CopyTime(_Symbol, PERIOD_H4, 0, barsNeeded, time) != barsNeeded) return;
   
   // Clear and rebuild swing points
   ArrayResize(g_swingPoints, 0);
   
   // Scan for swing points (skip first/last InpSwingLookback bars)
   for(int i = InpSwingLookback; i < barsNeeded - InpSwingLookback; i++)
   {
      // Check if this is a swing high
      bool isSwingHigh = true;
      for(int j = 1; j <= InpSwingLookback; j++)
      {
         if(high[i] <= high[i - j] || high[i] <= high[i + j])
         {
            isSwingHigh = false;
            break;
         }
      }
      
      // Check if this is a swing low
      bool isSwingLow = true;
      for(int j = 1; j <= InpSwingLookback; j++)
      {
         if(low[i] >= low[i - j] || low[i] >= low[i + j])
         {
            isSwingLow = false;
            break;
         }
      }
      
      if(isSwingHigh)
      {
         SwingPoint sp;
         sp.price = high[i];
         sp.time = time[i];
         sp.barIndex = i;
         sp.isHigh = true;
         sp.isValid = true;
         
         int size = ArraySize(g_swingPoints);
         // Ensure we don't add dups or too-close swing points
         if(size > 0)
         {
            SwingPoint lastSP = g_swingPoints[size - 1];
            if(lastSP.isHigh && MathAbs(lastSP.barIndex - i) < InpMinStructureBars)
            {
               // Too close - keep the higher one
               if(sp.price > lastSP.price)
                  g_swingPoints[size - 1] = sp;
               continue;
            }
         }
         
         ArrayResize(g_swingPoints, size + 1);
         g_swingPoints[size] = sp;
      }
      
      if(isSwingLow)
      {
         SwingPoint sp;
         sp.price = low[i];
         sp.time = time[i];
         sp.barIndex = i;
         sp.isHigh = false;
         sp.isValid = true;
         
         int size = ArraySize(g_swingPoints);
         if(size > 0)
         {
            SwingPoint lastSP = g_swingPoints[size - 1];
            if(!lastSP.isHigh && MathAbs(lastSP.barIndex - i) < InpMinStructureBars)
            {
               // Too close - keep the lower one
               if(sp.price < lastSP.price)
                  g_swingPoints[size - 1] = sp;
               continue;
            }
         }
         
         ArrayResize(g_swingPoints, size + 1);
         g_swingPoints[size] = sp;
      }
   }
   
   // Limit array size
   if(ArraySize(g_swingPoints) > MAX_SWING_POINTS)
   {
      int excess = ArraySize(g_swingPoints) - MAX_SWING_POINTS;
      // Remove oldest (highest bar indices since series is reversed)
      SwingPoint temp[];
      ArrayResize(temp, MAX_SWING_POINTS);
      for(int i = 0; i < MAX_SWING_POINTS; i++)
         temp[i] = g_swingPoints[i];
      ArrayResize(g_swingPoints, MAX_SWING_POINTS);
      for(int i = 0; i < MAX_SWING_POINTS; i++)
         g_swingPoints[i] = temp[i];
   }
   
   if(InpEnableDetailedLogs)
   {
      Print("H4 SWING DETECTION: Found ", ArraySize(g_swingPoints), " swing points");
      // Print last 6 swing points for reference
      int total = ArraySize(g_swingPoints);
      int start = MathMax(0, total - 6);
      for(int i = start; i < total; i++)
      {
         Print("  ", g_swingPoints[i].isHigh ? "SH" : "SL", ": ",
               DoubleToString(g_swingPoints[i].price, _Digits),
               " @ ", TimeToString(g_swingPoints[i].time));
      }
   }
}

//+------------------------------------------------------------------+
//| Detect BOS / ChoCH from swing point sequence                      |
//+------------------------------------------------------------------+
void DetectBOS_ChoCH()
{
   int total = ArraySize(g_swingPoints);
   if(total < 4) 
   {
      g_currentBias = ICT_NEUTRAL;
      return;
   }
   
   // Get H4 close for current bar to check structure breaks
   double h4Close[];
   ArraySetAsSeries(h4Close, true);
   if(CopyClose(_Symbol, PERIOD_H4, 0, 1, h4Close) != 1) return;
   double currentClose = h4Close[0];
   
   // Find the last few significant swing highs and swing lows
   // We need at least 2 swing highs and 2 swing lows for structure
   double lastSH1 = 0, lastSH2 = 0;  // Most recent and second-most-recent Swing Highs
   double lastSL1 = 0, lastSL2 = 0;  // Most recent and second-most-recent Swing Lows
   datetime timeSH1 = 0, timeSL1 = 0;
   
   int shCount = 0, slCount = 0;
   
   // Traverse from most recent (index 0 = most recent swing found near current bars)
   // Since we added them in order of bar index (high index = old), index 0 = oldest
   // So we traverse from end to start
   for(int i = total - 1; i >= 0; i--)
   {
      if(g_swingPoints[i].isHigh && shCount < 2)
      {
         if(shCount == 0) { lastSH1 = g_swingPoints[i].price; timeSH1 = g_swingPoints[i].time; }
         else             { lastSH2 = g_swingPoints[i].price; }
         shCount++;
      }
      if(!g_swingPoints[i].isHigh && slCount < 2)
      {
         if(slCount == 0) { lastSL1 = g_swingPoints[i].price; timeSL1 = g_swingPoints[i].time; }
         else             { lastSL2 = g_swingPoints[i].price; }
         slCount++;
      }
      if(shCount >= 2 && slCount >= 2) break;
   }
   
   if(shCount < 2 || slCount < 2) 
   {
      g_currentBias = ICT_NEUTRAL;
      return;
   }
   
   // Determine current structure
   // Uptrend: Higher Highs (lastSH1 > lastSH2) AND Higher Lows (lastSL1 > lastSL2)
   // Downtrend: Lower Lows (lastSL1 < lastSL2) AND Lower Highs (lastSH1 < lastSH2)
   bool isCurrentUptrend = (lastSH1 > lastSH2) && (lastSL1 > lastSL2);
   bool isCurrentDowntrend = (lastSH1 < lastSH2) && (lastSL1 < lastSL2);
   
   ENUM_ICT_BIAS previousBias = g_currentBias;
   
   // --- Check for BOS (continuation) ---
   // Bullish BOS: In uptrend, price breaks above last swing high
   if(isCurrentUptrend && currentClose > lastSH1)
   {
      if(g_wasTrendEstablished && g_wasUptrend)
      {
         // Continuation BOS
         UpdateStructureBreak(lastSH1, true, STRUCTURE_BOS, lastSL1, lastSH1);
      }
      else
      {
         // First establishment or ChoCH from bearish
         if(g_wasTrendEstablished && !g_wasUptrend)
            UpdateStructureBreak(lastSH1, true, STRUCTURE_CHOCH, lastSL1, lastSH1);
         else
            UpdateStructureBreak(lastSH1, true, STRUCTURE_BOS, lastSL1, lastSH1);
      }
      g_currentBias = ICT_BULLISH;
      g_wasUptrend = true;
      g_wasTrendEstablished = true;
   }
   // Bearish BOS: In downtrend, price breaks below last swing low
   else if(isCurrentDowntrend && currentClose < lastSL1)
   {
      if(g_wasTrendEstablished && !g_wasUptrend)
      {
         UpdateStructureBreak(lastSL1, false, STRUCTURE_BOS, lastSH1, lastSL1);
      }
      else
      {
         if(g_wasTrendEstablished && g_wasUptrend)
            UpdateStructureBreak(lastSL1, false, STRUCTURE_CHOCH, lastSH1, lastSL1);
         else
            UpdateStructureBreak(lastSL1, false, STRUCTURE_BOS, lastSH1, lastSL1);
      }
      g_currentBias = ICT_BEARISH;
      g_wasUptrend = false;
      g_wasTrendEstablished = true;
   }
   // --- Check for ChoCH (reversal) ---
   // Bearish ChoCH: Was uptrend, price breaks below last higher low
   else if(g_wasUptrend && g_wasTrendEstablished && currentClose < lastSL1)
   {
      UpdateStructureBreak(lastSL1, false, STRUCTURE_CHOCH, lastSH1, lastSL1);
      g_currentBias = ICT_BEARISH;
      g_wasUptrend = false;
   }
   // Bullish ChoCH: Was downtrend, price breaks above last lower high
   else if(!g_wasUptrend && g_wasTrendEstablished && currentClose > lastSH1)
   {
      UpdateStructureBreak(lastSH1, true, STRUCTURE_CHOCH, lastSL1, lastSH1);
      g_currentBias = ICT_BULLISH;
      g_wasUptrend = true;
   }
   // No clear break - maintain current state
   else if(isCurrentUptrend)
   {
      g_currentBias = ICT_BULLISH;
      g_wasUptrend = true;
      g_wasTrendEstablished = true;
   }
   else if(isCurrentDowntrend)
   {
      g_currentBias = ICT_BEARISH;
      g_wasUptrend = false;
      g_wasTrendEstablished = true;
   }
   // Mixed structure = neutral
   else
   {
      g_currentBias = ICT_NEUTRAL;
   }
   
   // Log bias change
   if(previousBias != g_currentBias && InpEnableDetailedLogs)
   {
      Print("H4 BIAS CHANGE: ", BiasToString(previousBias), " → ", BiasToString(g_currentBias));
      Print("  Last SH: ", DoubleToString(lastSH1, _Digits), " / ", DoubleToString(lastSH2, _Digits));
      Print("  Last SL: ", DoubleToString(lastSL1, _Digits), " / ", DoubleToString(lastSL2, _Digits));
      if(g_lastStructureBreak.breakPrice > 0)
         Print("  Structure: ", StructureTypeToString(g_lastStructureBreak.type),
               " @ ", DoubleToString(g_lastStructureBreak.breakPrice, _Digits));
   }
}

//+------------------------------------------------------------------+
//| Update the last structure break                                    |
//+------------------------------------------------------------------+
void UpdateStructureBreak(double breakPrice, bool isBullish, ENUM_STRUCTURE_TYPE stype,
                          double swingA, double swingB)
{
   ENUM_STRUCTURE_TYPE prevType = g_lastStructureBreak.type;
   double prevBreakPrice = g_lastStructureBreak.breakPrice;
   
   g_lastStructureBreak.breakPrice = breakPrice;
   g_lastStructureBreak.time = TimeCurrent();
   g_lastStructureBreak.isBullish = isBullish;
   g_lastStructureBreak.type = stype;
   g_lastStructureBreak.swingA = swingA;  // Start of impulse
   g_lastStructureBreak.swingB = swingB;  // End of impulse / break level
   
   // === Enhanced Logging ===
   string typeStr = StructureTypeToString(stype);
   string dirStr = isBullish ? "BULLISH ↑" : "BEARISH ↓";
   double range = MathAbs(swingB - swingA);
   double rangePips = range / GetPipValue();
   
   Print("╔══════════════════════════════════════════╗");
   Print("║  ", typeStr, " DETECTED - ", dirStr);
   Print("╠══════════════════════════════════════════╣");
   Print("║  Break Price : ", DoubleToString(breakPrice, _Digits));
   Print("║  Swing A     : ", DoubleToString(swingA, _Digits), " (", isBullish ? "Low" : "High", ")");
   Print("║  Swing B     : ", DoubleToString(swingB, _Digits), " (", isBullish ? "High" : "Low", ")");
   Print("║  Impulse     : ", DoubleToString(rangePips, 1), " pips");
   Print("║  Time        : ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
   if(prevBreakPrice > 0)
      Print("║  Prev Break  : ", StructureTypeToString(prevType), " @ ", DoubleToString(prevBreakPrice, _Digits));
   Print("║  New Bias    : ", BiasToString(isBullish ? ICT_BULLISH : ICT_BEARISH));
   Print("╚══════════════════════════════════════════╝");
   
   // === Send Alert for ChoCH (reversal is high-value event) ===
   if(stype == STRUCTURE_CHOCH)
   {
      string alertMsg = "ICT " + typeStr + " " + dirStr + " @ " + 
                        DoubleToString(breakPrice, _Digits) + " on " + _Symbol;
      Alert(alertMsg);
      Print("🔔 ALERT: ", alertMsg);
   }
   
   // === Draw on Chart ===
   DrawStructureBreak(breakPrice, isBullish, stype, swingA, swingB);
   
   // After structure break, detect new order blocks
   DetectOrderBlocks();
}

//+------------------------------------------------------------------+
//| ===== CHART DRAWING FUNCTIONS =====                               |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Draw BOS/ChoCH structure break on chart                           |
//+------------------------------------------------------------------+
void DrawStructureBreak(double breakPrice, bool isBullish, ENUM_STRUCTURE_TYPE stype,
                        double swingA, double swingB)
{
   if(!InpDrawStructure) return;
   
   g_structureDrawCount++;
   string typeStr = StructureTypeToString(stype);
   string dirStr = isBullish ? "Bull" : "Bear";
   
   // --- 1. Horizontal line at break level ---
   string lineName = g_objPrefix + "BRK_" + IntegerToString(g_structureDrawCount);
   color lineColor;
   
   if(stype == STRUCTURE_CHOCH)
      lineColor = isBullish ? InpColorChoCH_Bull : InpColorChoCH_Bear;
   else
      lineColor = isBullish ? InpColorBOS_Bull : InpColorBOS_Bear;
   
   // Use trend line from swing point time to current time
   datetime breakTime = TimeCurrent();
   datetime lineEndTime = breakTime + 20 * PeriodSeconds(PERIOD_H4);  // Extend 20 H4 bars forward
   
   ObjectCreate(0, lineName, OBJ_TREND, 0, breakTime, breakPrice, lineEndTime, breakPrice);
   ObjectSetInteger(0, lineName, OBJPROP_COLOR, lineColor);
   ObjectSetInteger(0, lineName, OBJPROP_WIDTH, InpStructureLineWidth);
   ObjectSetInteger(0, lineName, OBJPROP_STYLE, stype == STRUCTURE_CHOCH ? STYLE_SOLID : InpStructureLineStyle);
   ObjectSetInteger(0, lineName, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, lineName, OBJPROP_BACK, true);
   ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, false);
   
   // --- 2. Text label at break level ---
   string labelName = g_objPrefix + "LBL_" + IntegerToString(g_structureDrawCount);
   string labelText = typeStr + " " + (isBullish ? "↑" : "↓");
   
   ObjectCreate(0, labelName, OBJ_TEXT, 0, breakTime, breakPrice);
   ObjectSetString(0, labelName, OBJPROP_TEXT, labelText);
   ObjectSetInteger(0, labelName, OBJPROP_COLOR, lineColor);
   ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, stype == STRUCTURE_CHOCH ? 12 : 10);
   ObjectSetString(0, labelName, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, isBullish ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, labelName, OBJPROP_SELECTABLE, false);
   
   // --- 3. Arrow at break point ---
   string arrowName = g_objPrefix + "ARR_" + IntegerToString(g_structureDrawCount);
   int arrowCode = isBullish ? 233 : 234;  // 233=arrow up, 234=arrow down
   
   // Place arrow slightly offset from break price
   double arrowOffset = 5 * GetPipValue();
   double arrowPrice = isBullish ? (breakPrice - arrowOffset) : (breakPrice + arrowOffset);
   
   ObjectCreate(0, arrowName, OBJ_ARROW, 0, breakTime, arrowPrice);
   ObjectSetInteger(0, arrowName, OBJPROP_ARROWCODE, arrowCode);
   ObjectSetInteger(0, arrowName, OBJPROP_COLOR, lineColor);
   ObjectSetInteger(0, arrowName, OBJPROP_WIDTH, stype == STRUCTURE_CHOCH ? 3 : 2);
   ObjectSetInteger(0, arrowName, OBJPROP_SELECTABLE, false);
   
   // --- 4. Vertical dashed line for impulse leg (swingA → swingB) ---
   if(stype == STRUCTURE_CHOCH)
   {
      // For ChoCH, draw a connecting line from swing A to B to show the impulse
      string impulseName = g_objPrefix + "IMP_" + IntegerToString(g_structureDrawCount);
      
      // Find approximate time of swing A from swing point history
      datetime swingATime = breakTime - 10 * PeriodSeconds(PERIOD_H4);  // Approximate
      for(int i = ArraySize(g_swingPoints) - 1; i >= 0; i--)
      {
         if(MathAbs(g_swingPoints[i].price - swingA) < GetPipValue())
         {
            swingATime = g_swingPoints[i].time;
            break;
         }
      }
      
      ObjectCreate(0, impulseName, OBJ_TREND, 0, swingATime, swingA, breakTime, swingB);
      ObjectSetInteger(0, impulseName, OBJPROP_COLOR, lineColor);
      ObjectSetInteger(0, impulseName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, impulseName, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, impulseName, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, impulseName, OBJPROP_BACK, true);
      ObjectSetInteger(0, impulseName, OBJPROP_SELECTABLE, false);
   }
   
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Draw Order Block rectangle on chart                               |
//+------------------------------------------------------------------+
void DrawOrderBlock(const OrderBlock &ob)
{
   if(!InpDrawOrderBlocks) return;
   
   g_obDrawCount++;
   string name = g_objPrefix + "OB_" + IntegerToString(g_obDrawCount);
   
   // Rectangle from OB time to future
   datetime endTime = ob.time + InpOBMaxAge * PeriodSeconds(PERIOD_H4);
   
   color obColor = ob.isBullish ? InpColorOB_Demand : InpColorOB_Supply;
   
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, ob.time, ob.lowPrice, endTime, ob.highPrice);
   ObjectSetInteger(0, name, OBJPROP_COLOR, obColor);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   
   // Semi-transparent fill
   int alpha = 40;  // Low alpha = more transparent
   int r = (int)((obColor >> 0) & 0xFF);
   int g = (int)((obColor >> 8) & 0xFF);
   int b = (int)((obColor >> 16) & 0xFF);
   // MQL5 uses ARGB for some properties but OBJ_RECTANGLE color is just RGB
   // The FILL property handles the visual fill
   
   // Label inside the OB
   string lblName = g_objPrefix + "OBL_" + IntegerToString(g_obDrawCount);
   string lblText = ob.isBullish ? "DEM" : "SUP";
   double midPrice = (ob.highPrice + ob.lowPrice) / 2.0;
   
   ObjectCreate(0, lblName, OBJ_TEXT, 0, ob.time, midPrice);
   ObjectSetString(0, lblName, OBJPROP_TEXT, lblText);
   ObjectSetInteger(0, lblName, OBJPROP_COLOR, obColor);
   ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, lblName, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, lblName, OBJPROP_SELECTABLE, false);
   
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Draw Swing Points on chart                                        |
//+------------------------------------------------------------------+
void DrawSwingPoints()
{
   if(!InpDrawSwingPoints) return;
   
   // Remove old swing objects first
   ObjectsDeleteAll(0, g_objPrefix + "SW_");
   g_swingDrawCount = 0;
   
   for(int i = 0; i < ArraySize(g_swingPoints); i++)
   {
      g_swingDrawCount++;
      string name = g_objPrefix + "SW_" + IntegerToString(g_swingDrawCount);
      
      int arrowCode = g_swingPoints[i].isHigh ? 159 : 159;  // Diamond
      color arrowColor = g_swingPoints[i].isHigh ? InpColorSwingHigh : InpColorSwingLow;
      double offset = 3 * GetPipValue();
      double drawPrice = g_swingPoints[i].isHigh ? 
                         (g_swingPoints[i].price + offset) : 
                         (g_swingPoints[i].price - offset);
      
      ObjectCreate(0, name, OBJ_ARROW, 0, g_swingPoints[i].time, drawPrice);
      ObjectSetInteger(0, name, OBJPROP_ARROWCODE, g_swingPoints[i].isHigh ? 218 : 217);
      ObjectSetInteger(0, name, OBJPROP_COLOR, arrowColor);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      
      // Price label next to swing point
      string lblName = g_objPrefix + "SWL_" + IntegerToString(g_swingDrawCount);
      ObjectCreate(0, lblName, OBJ_TEXT, 0, g_swingPoints[i].time, drawPrice);
      ObjectSetString(0, lblName, OBJPROP_TEXT, 
                      (g_swingPoints[i].isHigh ? "SH " : "SL ") + 
                      DoubleToString(g_swingPoints[i].price, _Digits));
      ObjectSetInteger(0, lblName, OBJPROP_COLOR, arrowColor);
      ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 7);
      ObjectSetInteger(0, lblName, OBJPROP_ANCHOR, 
                       g_swingPoints[i].isHigh ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, lblName, OBJPROP_SELECTABLE, false);
   }
   
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Draw OTE Zone on chart                                            |
//+------------------------------------------------------------------+
void DrawOTEZone(double oteUpper, double oteLower)
{
   if(!InpDrawOTEZone) return;
   if(oteUpper <= 0 || oteLower <= 0) return;
   
   // Remove previous OTE
   ObjectsDeleteAll(0, g_objPrefix + "OTE_");
   
   string name = g_objPrefix + "OTE_ZONE";
   datetime startTime = TimeCurrent() - 10 * PeriodSeconds(PERIOD_H4);
   datetime endTime = TimeCurrent() + 20 * PeriodSeconds(PERIOD_H4);
   
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, startTime, oteLower, endTime, oteUpper);
   ObjectSetInteger(0, name, OBJPROP_COLOR, InpColorOTE);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   
   // Labels for Fib levels
   string lbl618 = g_objPrefix + "OTE_618";
   ObjectCreate(0, lbl618, OBJ_TEXT, 0, endTime, oteLower);
   ObjectSetString(0, lbl618, OBJPROP_TEXT, "0.618");
   ObjectSetInteger(0, lbl618, OBJPROP_COLOR, InpColorOTE);
   ObjectSetInteger(0, lbl618, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, lbl618, OBJPROP_SELECTABLE, false);
   
   string lbl786 = g_objPrefix + "OTE_786";
   ObjectCreate(0, lbl786, OBJ_TEXT, 0, endTime, oteUpper);
   ObjectSetString(0, lbl786, OBJPROP_TEXT, "0.786");
   ObjectSetInteger(0, lbl786, OBJPROP_COLOR, InpColorOTE);
   ObjectSetInteger(0, lbl786, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, lbl786, OBJPROP_SELECTABLE, false);
   
   string lblOTE = g_objPrefix + "OTE_LBL";
   double midOTE = (oteUpper + oteLower) / 2.0;
   ObjectCreate(0, lblOTE, OBJ_TEXT, 0, startTime, midOTE);
   ObjectSetString(0, lblOTE, OBJPROP_TEXT, "OTE ZONE");
   ObjectSetInteger(0, lblOTE, OBJPROP_COLOR, InpColorOTE);
   ObjectSetInteger(0, lblOTE, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, lblOTE, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, lblOTE, OBJPROP_SELECTABLE, false);
   
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Remove mitigated OB drawings from chart                           |
//+------------------------------------------------------------------+
void RemoveMitigatedOBDrawings()
{
   // Simple approach: redraw all active OBs
   ObjectsDeleteAll(0, g_objPrefix + "OB_");
   ObjectsDeleteAll(0, g_objPrefix + "OBL_");
   g_obDrawCount = 0;
   
   for(int i = 0; i < ArraySize(g_orderBlocks); i++)
   {
      if(g_orderBlocks[i].isValid && !g_orderBlocks[i].isMitigated)
         DrawOrderBlock(g_orderBlocks[i]);
   }
}

//+------------------------------------------------------------------+
//| Detect Order Blocks after BOS/ChoCH                               |
//+------------------------------------------------------------------+
void DetectOrderBlocks()
{
   if(g_lastStructureBreak.breakPrice <= 0) return;
   
   // Get H4 candle data to find the last opposing candle before the impulse
   int barsToCheck = InpOBMaxAge + 5;
   double open[], close[], high[], low[];
   datetime time[];
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(time, true);
   
   if(CopyOpen(_Symbol, PERIOD_H4, 0, barsToCheck, open) != barsToCheck) return;
   if(CopyClose(_Symbol, PERIOD_H4, 0, barsToCheck, close) != barsToCheck) return;
   if(CopyHigh(_Symbol, PERIOD_H4, 0, barsToCheck, high) != barsToCheck) return;
   if(CopyLow(_Symbol, PERIOD_H4, 0, barsToCheck, low) != barsToCheck) return;
   if(CopyTime(_Symbol, PERIOD_H4, 0, barsToCheck, time) != barsToCheck) return;
   
   if(g_lastStructureBreak.isBullish)
   {
      // Bullish BOS → look for DEMAND (bullish) Order Block
      // Find the last bearish candle (close < open) before the impulse move up
      // The impulse move ends at/above g_lastStructureBreak.breakPrice
      
      // Find impulse start: walk back from recent bars to find where price was below break level
      int impulseStartBar = -1;
      for(int i = 1; i < barsToCheck - 1; i++)
      {
         if(close[i] < g_lastStructureBreak.breakPrice && high[i] < g_lastStructureBreak.breakPrice)
         {
            impulseStartBar = i;
            break;
         }
      }
      
      if(impulseStartBar < 0) impulseStartBar = 5;  // Fallback
      
      // Now find the last bearish candle at or before impulseStartBar
      for(int i = impulseStartBar; i < barsToCheck; i++)
      {
         if(close[i] < open[i])  // Bearish candle
         {
            double body = MathAbs(close[i] - open[i]);
            double range = high[i] - low[i];
            
            // Validate: body must be significant (not a doji)
            if(range > 0 && body / range >= InpOBMinBodyRatio)
            {
               // Check if this OB already exists
               bool exists = false;
               for(int j = 0; j < ArraySize(g_orderBlocks); j++)
               {
                  if(MathAbs(g_orderBlocks[j].highPrice - high[i]) < GetPipValue() &&
                     MathAbs(g_orderBlocks[j].lowPrice - low[i]) < GetPipValue())
                  {
                     exists = true;
                     break;
                  }
               }
               
               if(!exists)
               {
                  OrderBlock ob;
                  ob.highPrice = high[i];
                  ob.lowPrice = low[i];
                  ob.time = time[i];
                  ob.barIndex = i;
                  ob.isBullish = true;   // Demand zone
                  ob.isMitigated = false;
                  ob.isValid = true;
                  
                  int size = ArraySize(g_orderBlocks);
                  ArrayResize(g_orderBlocks, size + 1);
                  g_orderBlocks[size] = ob;
                  
                  if(InpEnableDetailedLogs)
                     Print("NEW DEMAND OB: ", DoubleToString(ob.lowPrice, _Digits),
                           " - ", DoubleToString(ob.highPrice, _Digits),
                           " @ ", TimeToString(ob.time));
                  
                  DrawOrderBlock(ob);
               }
               break;  // Only take the most relevant OB
            }
         }
      }
   }
   else
   {
      // Bearish BOS → look for SUPPLY (bearish) Order Block
      // Find the last bullish candle before the impulse move down
      
      int impulseStartBar = -1;
      for(int i = 1; i < barsToCheck - 1; i++)
      {
         if(close[i] > g_lastStructureBreak.breakPrice && low[i] > g_lastStructureBreak.breakPrice)
         {
            impulseStartBar = i;
            break;
         }
      }
      
      if(impulseStartBar < 0) impulseStartBar = 5;
      
      for(int i = impulseStartBar; i < barsToCheck; i++)
      {
         if(close[i] > open[i])  // Bullish candle
         {
            double body = MathAbs(close[i] - open[i]);
            double range = high[i] - low[i];
            
            if(range > 0 && body / range >= InpOBMinBodyRatio)
            {
               bool exists = false;
               for(int j = 0; j < ArraySize(g_orderBlocks); j++)
               {
                  if(MathAbs(g_orderBlocks[j].highPrice - high[i]) < GetPipValue() &&
                     MathAbs(g_orderBlocks[j].lowPrice - low[i]) < GetPipValue())
                  {
                     exists = true;
                     break;
                  }
               }
               
               if(!exists)
               {
                  OrderBlock ob;
                  ob.highPrice = high[i];
                  ob.lowPrice = low[i];
                  ob.time = time[i];
                  ob.barIndex = i;
                  ob.isBullish = false;  // Supply zone
                  ob.isMitigated = false;
                  ob.isValid = true;
                  
                  int size = ArraySize(g_orderBlocks);
                  ArrayResize(g_orderBlocks, size + 1);
                  g_orderBlocks[size] = ob;
                  
                  if(InpEnableDetailedLogs)
                     Print("NEW SUPPLY OB: ", DoubleToString(ob.lowPrice, _Digits),
                           " - ", DoubleToString(ob.highPrice, _Digits),
                           " @ ", TimeToString(ob.time));
                  
                  DrawOrderBlock(ob);
               }
               break;
            }
         }
      }
   }
   
   // Expire old order blocks and limit size
   CleanupOrderBlocks();
}

//+------------------------------------------------------------------+
//| Cleanup old/mitigated order blocks                                |
//+------------------------------------------------------------------+
void CleanupOrderBlocks()
{
   datetime currentH4Time = iTime(_Symbol, PERIOD_H4, 0);
   double pipValue = GetPipValue();
   
   // Mark expired OBs
   for(int i = ArraySize(g_orderBlocks) - 1; i >= 0; i--)
   {
      // Bar age check: approximate using H4 bar period (4 hours)
      int barAge = (int)((currentH4Time - g_orderBlocks[i].time) / (4 * 3600));
      if(barAge > InpOBMaxAge)
      {
         g_orderBlocks[i].isValid = false;
         if(InpEnableDetailedLogs)
            Print("OB EXPIRED: ", DoubleToString(g_orderBlocks[i].lowPrice, _Digits),
                  " - ", DoubleToString(g_orderBlocks[i].highPrice, _Digits),
                  " (age: ", barAge, " H4 bars)");
      }
   }
   
   // Remove invalid and mitigated OBs, keep only active ones
   OrderBlock temp[];
   int validCount = 0;
   
   for(int i = 0; i < ArraySize(g_orderBlocks); i++)
   {
      if(g_orderBlocks[i].isValid && !g_orderBlocks[i].isMitigated)
      {
         ArrayResize(temp, validCount + 1);
         temp[validCount] = g_orderBlocks[i];
         validCount++;
      }
   }
   
   // Limit to max OBs
   if(validCount > MAX_ORDER_BLOCKS)
      validCount = MAX_ORDER_BLOCKS;
   
   ArrayResize(g_orderBlocks, validCount);
   for(int i = 0; i < validCount; i++)
      g_orderBlocks[i] = temp[i];
}

//+------------------------------------------------------------------+
//| Check if any OB has been mitigated by current price               |
//+------------------------------------------------------------------+
void CheckOBMitigation()
{
   // Use last completed M15 candle close for proper mitigation (not tick/wick)
   double closePrice = iClose(_Symbol, PERIOD_M15, 1);
   if(closePrice <= 0) return;
   
   for(int i = 0; i < ArraySize(g_orderBlocks); i++)
   {
      if(!g_orderBlocks[i].isValid || g_orderBlocks[i].isMitigated)
         continue;
      
      // Bullish OB (demand) mitigated when candle CLOSES below OB low
      if(g_orderBlocks[i].isBullish && closePrice < g_orderBlocks[i].lowPrice)
      {
         g_orderBlocks[i].isMitigated = true;
         if(InpEnableDetailedLogs)
            Print("OB MITIGATED (Demand): ", DoubleToString(g_orderBlocks[i].lowPrice, _Digits),
                  " - ", DoubleToString(g_orderBlocks[i].highPrice, _Digits),
                  " | M15 Close: ", DoubleToString(closePrice, _Digits));
      }
      
      // Bearish OB (supply) mitigated when candle CLOSES above OB high
      if(!g_orderBlocks[i].isBullish && closePrice > g_orderBlocks[i].highPrice)
      {
         g_orderBlocks[i].isMitigated = true;
         if(InpEnableDetailedLogs)
            Print("OB MITIGATED (Supply): ", DoubleToString(g_orderBlocks[i].lowPrice, _Digits),
                  " - ", DoubleToString(g_orderBlocks[i].highPrice, _Digits),
                  " | M15 Close: ", DoubleToString(closePrice, _Digits));
      }
   }
}

//+------------------------------------------------------------------+
//| ===== M15 ENTRY LOGIC FUNCTIONS =====                             |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Calculate OTE Zone (Fibonacci 0.618-0.786 retracement)            |
//+------------------------------------------------------------------+
bool CalculateOTEZone(double &oteUpper, double &oteLower)
{
   if(g_lastStructureBreak.breakPrice <= 0) return false;
   if(g_lastStructureBreak.swingA <= 0 || g_lastStructureBreak.swingB <= 0) return false;
   
   // Check OTE zone expiry
   if(InpOTEMaxAgeBars > 0)
   {
      int ageBars = (int)((TimeCurrent() - g_lastStructureBreak.time) / (4 * 3600));
      if(ageBars > InpOTEMaxAgeBars)
      {
         if(InpEnableDetailedLogs)
            Print("OTE EXPIRED: Structure break is ", ageBars, " H4 bars old (max: ", InpOTEMaxAgeBars, ")");
         return false;
      }
   }
   
   double swingA = g_lastStructureBreak.swingA;  // Start of impulse
   double swingB = g_lastStructureBreak.swingB;  // End of impulse
   
   if(g_lastStructureBreak.isBullish)
   {
      // Bullish: A=swing low, B=swing high → retracement goes down
      // OTE zone is where price retraces to between 61.8%-78.6% from B back toward A
      double range = swingB - swingA;
      if(range <= 0) return false;
      
      oteUpper = swingB - range * InpOTEFibLow;    // 0.618 (higher price)
      oteLower = swingB - range * InpOTEFibHigh;   // 0.786 (lower price)
   }
   else
   {
      // Bearish: A=swing high, B=swing low → retracement goes up
      double range = swingA - swingB;
      if(range <= 0) return false;
      
      oteLower = swingB + range * InpOTEFibLow;    // 0.618 (lower price) 
      oteUpper = swingB + range * InpOTEFibHigh;   // 0.786 (higher price)
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Check if an Order Block overlaps with OTE zone                     |
//+------------------------------------------------------------------+
bool CheckOBOverlapsOTE(const OrderBlock &ob, double oteUpper, double oteLower)
{
   // Two ranges overlap if one starts before the other ends AND vice versa
   return (ob.lowPrice <= oteUpper && ob.highPrice >= oteLower);
}

//+------------------------------------------------------------------+
//| Check for Liquidity Sweep on M15                                  |
//+------------------------------------------------------------------+
bool CheckLiquiditySweep(bool lookForBullish)
{
   if(!InpRequireLiqSweep)
      return true;  // Not required, skip
   
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   int bars = InpLiqSweepLookback + 2;
   if(CopyHigh(_Symbol, PERIOD_M15, 0, bars, high) != bars) return false;
   if(CopyLow(_Symbol, PERIOD_M15, 0, bars, low) != bars) return false;
   if(CopyClose(_Symbol, PERIOD_M15, 0, bars, close) != bars) return false;
   
   double pipValue = GetPipValue();
   double minSweepDistance = InpMinSweepPips * pipValue;
   
   if(lookForBullish)
   {
      // Bullish setup: Look for SELL-SIDE liquidity sweep
      // Price should have wicked below a recent swing low then closed back above
      
      // Find the most recent M15 swing low (fractal: lower than 2 bars each side)
      double recentSwingLow = 0;
      for(int i = 3; i < bars - 2; i++)
      {
         if(low[i] < low[i-1] && low[i] < low[i-2] &&
            low[i] < low[i+1] && low[i] < low[i+2])
         {
            recentSwingLow = low[i];  // Most recent swing low (nearest to current price)
            break;
         }
      }
      
      // Fallback: use H4 swing low nearest below current price
      if(recentSwingLow == 0)
      {
         double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double bestDist = DBL_MAX;
         for(int i = 0; i < ArraySize(g_swingPoints); i++)
         {
            if(!g_swingPoints[i].isHigh)
            {
               double dist = currentBid - g_swingPoints[i].price;
               if(dist > 0 && dist < bestDist)
               {
                  bestDist = dist;
                  recentSwingLow = g_swingPoints[i].price;
               }
            }
         }
      }
      
      if(recentSwingLow == 0)
      {
         if(InpEnableDetailedLogs)
            Print("NO sell-side liquidity sweep: No swing low reference found");
         return false;
      }
      
      // Check if any recent bar wicked below the swing low and closed back above
      for(int i = 1; i <= MathMin(5, InpLiqSweepLookback); i++)
      {
         if(low[i] < recentSwingLow - minSweepDistance && close[i] > recentSwingLow)
         {
            if(InpEnableDetailedLogs)
               Print("✅ SELL-SIDE LIQUIDITY SWEEP: Bar ", i,
                     " | Low: ", DoubleToString(low[i], _Digits),
                     " swept below ", DoubleToString(recentSwingLow, _Digits),
                     " | Close: ", DoubleToString(close[i], _Digits));
            return true;
         }
      }
      
      if(InpEnableDetailedLogs)
         Print("NO sell-side liquidity sweep detected (lookback: ", InpLiqSweepLookback, " M15 bars)");
      return false;
   }
   else
   {
      // Bearish setup: Look for BUY-SIDE liquidity sweep
      // Price should have wicked above a recent swing high then closed back below
      
      // Find the most recent M15 swing high (fractal: higher than 2 bars each side)
      double recentSwingHigh = 0;
      for(int i = 3; i < bars - 2; i++)
      {
         if(high[i] > high[i-1] && high[i] > high[i-2] &&
            high[i] > high[i+1] && high[i] > high[i+2])
         {
            recentSwingHigh = high[i];  // Most recent swing high
            break;
         }
      }
      
      // Fallback: use H4 swing high nearest above current price
      if(recentSwingHigh == 0)
      {
         double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double bestDist = DBL_MAX;
         for(int i = 0; i < ArraySize(g_swingPoints); i++)
         {
            if(g_swingPoints[i].isHigh)
            {
               double dist = g_swingPoints[i].price - currentBid;
               if(dist > 0 && dist < bestDist)
               {
                  bestDist = dist;
                  recentSwingHigh = g_swingPoints[i].price;
               }
            }
         }
      }
      
      if(recentSwingHigh == 0)
      {
         if(InpEnableDetailedLogs)
            Print("NO buy-side liquidity sweep: No swing high reference found");
         return false;
      }
      
      for(int i = 1; i <= MathMin(5, InpLiqSweepLookback); i++)
      {
         if(high[i] > recentSwingHigh + minSweepDistance && close[i] < recentSwingHigh)
         {
            if(InpEnableDetailedLogs)
               Print("✅ BUY-SIDE LIQUIDITY SWEEP: Bar ", i,
                     " | High: ", DoubleToString(high[i], _Digits),
                     " swept above ", DoubleToString(recentSwingHigh, _Digits),
                     " | Close: ", DoubleToString(close[i], _Digits));
            return true;
         }
      }
      
      if(InpEnableDetailedLogs)
         Print("NO buy-side liquidity sweep detected (lookback: ", InpLiqSweepLookback, " M15 bars)");
      return false;
   }
}

//+------------------------------------------------------------------+
//| Find the best matching Order Block for entry                      |
//+------------------------------------------------------------------+
int FindBestOrderBlock(bool isBullish, double oteUpper, double oteLower, bool requireOTEOverlap)
{
   int bestIdx = -1;
   double bestScore = -1;
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   for(int i = 0; i < ArraySize(g_orderBlocks); i++)
   {
      if(!g_orderBlocks[i].isValid || g_orderBlocks[i].isMitigated)
         continue;
      
      if(g_orderBlocks[i].isBullish != isBullish)
         continue;
      
      bool overlapsOTE = CheckOBOverlapsOTE(g_orderBlocks[i], oteUpper, oteLower);
      
      if(requireOTEOverlap && !overlapsOTE)
         continue;
      
      // Check if price is actually near/in this OB
      bool priceInOB = false;
      if(isBullish)
      {
         // For demand OB: price should be at or just above OB zone
         priceInOB = (currentPrice >= g_orderBlocks[i].lowPrice && 
                      currentPrice <= g_orderBlocks[i].highPrice + (10 * GetPipValue()));
      }
      else
      {
         // For supply OB: price should be at or just below OB zone
         priceInOB = (currentPrice <= g_orderBlocks[i].highPrice && 
                      currentPrice >= g_orderBlocks[i].lowPrice - (10 * GetPipValue()));
      }
      
      if(!priceInOB) continue;
      
      // Score: prefer OBs that overlap OTE and are closer in time
      double score = 0;
      if(overlapsOTE) score += 100;
      
      // Freshness bonus (newer = better)
      int ageBars = (int)((TimeCurrent() - g_orderBlocks[i].time) / (4 * 3600));
      score += (InpOBMaxAge - ageBars);
      
      if(score > bestScore)
      {
         bestScore = score;
         bestIdx = i;
      }
   }
   
   return bestIdx;
}

//+------------------------------------------------------------------+
//| ===== SIGNAL GENERATION =====                                     |
//+------------------------------------------------------------------+
void AnalyzeAndTrade()
{
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Get ATR for various calculations
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_handleATR, 0, 0, ATR_AVERAGE_PERIOD + 1, atr) < ATR_AVERAGE_PERIOD + 1)
   {
      Print("WARNING: Failed to get ATR values");
      return;
   }
   
   double currentATR = atr[0];
   
   // Calculate average ATR
   double avgATR = 0;
   for(int i = 1; i <= ATR_AVERAGE_PERIOD; i++)
      avgATR += atr[i];
   avgATR /= ATR_AVERAGE_PERIOD;
   
   // === STEP 1: Check H4 Bias ===
   if(g_currentBias == ICT_NEUTRAL)
   {
      UpdateChartComment(currentPrice, currentATR, avgATR, 0, 0, "No H4 bias");
      if(InpEnableDetailedLogs)
         Print("SKIP: No clear H4 bias (NEUTRAL)");
      return;
   }
   
   // === STEP 2: Calculate OTE Zone ===
   double oteUpper = 0, oteLower = 0;
   bool hasOTE = CalculateOTEZone(oteUpper, oteLower);
   
   if(!hasOTE)
   {
      UpdateChartComment(currentPrice, currentATR, avgATR, 0, 0, "No OTE zone");
      if(InpEnableDetailedLogs)
         Print("SKIP: Cannot calculate OTE zone");
      return;
   }
   
   // Draw OTE zone on chart
   DrawOTEZone(oteUpper, oteLower);
   
   // === STEP 3: Check if price is in OTE zone ===
   bool priceInOTE = (currentPrice >= oteLower && currentPrice <= oteUpper);
   
   // === STEP 4: Generate signal based on bias ===
   bool isBuySignal = false;
   bool isSellSignal = false;
   int obIndex = -1;
   string signalReason = "";
   
   if(g_currentBias == ICT_BULLISH)
   {
      // Look for BUY setup
      obIndex = FindBestOrderBlock(true, oteUpper, oteLower, InpRequireOBOverlapOTE);
      
      if(obIndex >= 0 && priceInOTE)
      {
         // Check liquidity sweep
         if(CheckLiquiditySweep(true))
         {
            // Check candle pattern
            if(CheckCandlePattern(true))
            {
               isBuySignal = true;
               signalReason = "ICT_BUY";
               
               if(g_lastStructureBreak.type == STRUCTURE_CHOCH)
                  signalReason += "_ChoCH";
               else
                  signalReason += "_BOS";
               
               signalReason += "_OB+OTE";
               
               if(InpRequireLiqSweep)
                  signalReason += "_LiqSweep";
            }
            else
            {
               if(InpEnableDetailedLogs) Print("ICT BUY REJECT: No candle pattern");
            }
         }
      }
      else
      {
         if(obIndex < 0 && InpEnableDetailedLogs)
            Print("ICT BUY REJECT: No valid demand OB near price",
                  InpRequireOBOverlapOTE ? " (require OTE overlap)" : "");
         if(!priceInOTE && InpEnableDetailedLogs)
            Print("ICT BUY REJECT: Price ", DoubleToString(currentPrice, _Digits),
                  " not in OTE zone [", DoubleToString(oteLower, _Digits),
                  " - ", DoubleToString(oteUpper, _Digits), "]");
      }
   }
   else if(g_currentBias == ICT_BEARISH)
   {
      // Look for SELL setup
      obIndex = FindBestOrderBlock(false, oteUpper, oteLower, InpRequireOBOverlapOTE);
      
      if(obIndex >= 0 && priceInOTE)
      {
         if(CheckLiquiditySweep(false))
         {
            if(CheckCandlePattern(false))
            {
               isSellSignal = true;
               signalReason = "ICT_SELL";
               
               if(g_lastStructureBreak.type == STRUCTURE_CHOCH)
                  signalReason += "_ChoCH";
               else
                  signalReason += "_BOS";
               
               signalReason += "_OB+OTE";
               
               if(InpRequireLiqSweep)
                  signalReason += "_LiqSweep";
            }
            else
            {
               if(InpEnableDetailedLogs) Print("ICT SELL REJECT: No candle pattern");
            }
         }
      }
      else
      {
         if(obIndex < 0 && InpEnableDetailedLogs)
            Print("ICT SELL REJECT: No valid supply OB near price",
                  InpRequireOBOverlapOTE ? " (require OTE overlap)" : "");
         if(!priceInOTE && InpEnableDetailedLogs)
            Print("ICT SELL REJECT: Price ", DoubleToString(currentPrice, _Digits),
                  " not in OTE zone [", DoubleToString(oteLower, _Digits),
                  " - ", DoubleToString(oteUpper, _Digits), "]");
      }
   }
   
   // === STEP 5: Conflicting Position Check ===
   if(!InpAllowOppositePositions)
   {
      if(isBuySignal && HasPositionInDirection(false))
      {
         if(InpEnableDetailedLogs)
            Print("BLOCKED: Cannot open BUY - opposing SELL position exists");
         isBuySignal = false;
      }
      if(isSellSignal && HasPositionInDirection(true))
      {
         if(InpEnableDetailedLogs)
            Print("BLOCKED: Cannot open SELL - opposing BUY position exists");
         isSellSignal = false;
      }
   }
   
   // === STEP 6: Execute Trade ===
   if(isBuySignal && obIndex >= 0)
   {
      OpenICTPosition(true, g_orderBlocks[obIndex], currentATR, signalReason);
   }
   else if(isSellSignal && obIndex >= 0)
   {
      OpenICTPosition(false, g_orderBlocks[obIndex], currentATR, signalReason);
   }
   
   // === Update Chart Comment ===
   UpdateChartComment(currentPrice, currentATR, avgATR, oteUpper, oteLower, 
                      isBuySignal ? signalReason : (isSellSignal ? signalReason : "Waiting..."));
   
   // Log signal event
   if(InpEnableFileLogging && (isBuySignal || isSellSignal))
   {
      LogSignalEvent(isBuySignal ? "BUY_SIGNAL" : "SELL_SIGNAL", signalReason,
                     currentPrice, currentATR, oteUpper, oteLower);
   }
}

//+------------------------------------------------------------------+
//| ===== POSITION EXECUTION =====                                    |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Calculate lot size based on risk (adapted from EA v4.1)            |
//+------------------------------------------------------------------+
double CalculateLotSize(double entryPrice, double slPips)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmountUSD = balance * (InpRiskPercent / 100.0);
   
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double pipValue = GetPipValue();
   string symbol = _Symbol;
   
   // Get tick value from broker (most accurate method)
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   
   double moneyPerPipPerLot = 0;
   
   if(tickSize > 0 && tickValue > 0)
   {
      moneyPerPipPerLot = tickValue * (pipValue / tickSize);
   }
   else
   {
      // Fallback calculations per symbol type
      if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0)
         moneyPerPipPerLot = contractSize * pipValue;
      else if(StringFind(symbol, "BTC") >= 0)
         moneyPerPipPerLot = contractSize * pipValue;
      else if(StringFind(symbol, "US30") >= 0 || StringFind(symbol, "DOW") >= 0 ||
              StringFind(symbol, "DJ30") >= 0 || StringFind(symbol, "NI225") >= 0 ||
              StringFind(symbol, "NIKKEI") >= 0 || StringFind(symbol, "JPN225") >= 0)
         moneyPerPipPerLot = contractSize * pipValue;
      else
      {
         string quoteCurrency = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
         if(quoteCurrency == "JPY" && entryPrice > 0)
         {
            double jpy_per_pip = contractSize * pipValue;
            moneyPerPipPerLot = jpy_per_pip / entryPrice;
         }
         else
            moneyPerPipPerLot = contractSize * pipValue;
      }
   }
   
   if(moneyPerPipPerLot <= 0)
   {
      Print("ERROR: Could not calculate pip value for ", _Symbol);
      moneyPerPipPerLot = contractSize * pipValue;
      if(moneyPerPipPerLot <= 0) moneyPerPipPerLot = 1.0;
   }
   
   // Calculate lot size: Risk = SL pips × $ per pip × lot size
   double lotSize = riskAmountUSD / (slPips * moneyPerPipPerLot);
   
   // Apply user max lot limit
   if(InpMaxLotSize > 0 && lotSize > InpMaxLotSize)
   {
      if(InpEnableDetailedLogs)
         Print("⚠️ Lot capped: ", DoubleToString(lotSize, 2), " → ", InpMaxLotSize);
      lotSize = InpMaxLotSize;
   }
   
   // Normalize to broker lot step
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   
   // Apply broker min/max
   if(lotSize < minLot) lotSize = minLot;
   if(lotSize > maxLot) lotSize = maxLot;
   
   // Safety: Never risk more than 5%
   double maxRiskAmount = balance * 0.05;
   double actualRiskAmount = lotSize * slPips * moneyPerPipPerLot;
   
   if(actualRiskAmount > maxRiskAmount)
   {
      double safeLotSize = maxRiskAmount / (slPips * moneyPerPipPerLot);
      safeLotSize = MathFloor(safeLotSize / lotStep) * lotStep;
      Print("🛑 SAFETY: Risk $", DoubleToString(actualRiskAmount, 2),
            " > 5% ($", DoubleToString(maxRiskAmount, 2), ") → Lot: ", DoubleToString(safeLotSize, 2));
      lotSize = safeLotSize;
   }
   
   if(InpEnableDetailedLogs)
   {
      Print("LOT CALC: Balance=$", DoubleToString(balance, 2),
            " | Risk=", DoubleToString(InpRiskPercent, 1), "%=$", DoubleToString(riskAmountUSD, 2),
            " | SL=", DoubleToString(slPips, 1), " pips",
            " | $/pip=$", DoubleToString(moneyPerPipPerLot, 3),
            " | Lot=", DoubleToString(lotSize, 2));
   }
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Open ICT Position with OB-based SL                                |
//+------------------------------------------------------------------+
void OpenICTPosition(bool isBuy, const OrderBlock &ob, double currentATR, string comment)
{
   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pipValue = GetPipValue();
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   double sl = 0, tp = 0;
   double slPips = 0, tpPips = 0;
   
   // === SL Placement: Below/Above Order Block ===
   double obBuffer = OB_BUFFER_PIPS * pipValue;
   
   if(isBuy)
   {
      // SL below the demand OB low
      sl = ob.lowPrice - obBuffer;
      slPips = (price - sl) / pipValue;
   }
   else
   {
      // SL above the supply OB high
      sl = ob.highPrice + obBuffer;
      slPips = (sl - price) / pipValue;
   }
   
   // ATR-based SL adjustment: use the larger of OB-based or ATR-based
   if(InpUseATRBasedSLTP && currentATR > 0)
   {
      double atrSLDistance = currentATR * InpATRMultiplierSL;
      double atrSLPips = atrSLDistance / pipValue;
      
      if(atrSLPips > slPips)
      {
         if(InpEnableDetailedLogs)
            Print("SL adjusted: OB-based ", DoubleToString(slPips, 1),
                  " pips → ATR-based ", DoubleToString(atrSLPips, 1), " pips");
         slPips = atrSLPips;
         if(isBuy)
            sl = price - atrSLDistance;
         else
            sl = price + atrSLDistance;
      }
   }
   
   // Fixed SL fallback (minimum floor)
   if(slPips < InpFixedSLPips)
   {
      slPips = InpFixedSLPips;
      double slDistance = slPips * pipValue;
      if(isBuy) sl = price - slDistance;
      else      sl = price + slDistance;
   }
   
   // === TP Placement ===
   if(InpUseATRBasedSLTP && currentATR > 0)
   {
      double atrTPDistance = currentATR * InpATRMultiplierTP;
      tpPips = atrTPDistance / pipValue;
   }
   else
   {
      tpPips = InpFixedTPPips;
   }
   
   // Ensure minimum R:R
   double actualRR = tpPips / slPips;
   if(actualRR < InpMinRiskReward)
   {
      tpPips = slPips * InpMinRiskReward;
      if(InpEnableDetailedLogs)
         Print("TP adjusted for min R:R: ", DoubleToString(actualRR, 2),
               " → ", DoubleToString(InpMinRiskReward, 2),
               " | TP = ", DoubleToString(tpPips, 1), " pips");
   }
   
   // Calculate TP price
   double tpDistance = tpPips * pipValue;
   if(isBuy) tp = price + tpDistance;
   else      tp = price - tpDistance;
   
   // Normalize
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   
   // Enforce broker stop level
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDistance = stopLevel * point;
   
   if(minDistance > 0)
   {
      if(MathAbs(price - sl) < minDistance)
      {
         if(isBuy) sl = price - minDistance * BROKER_STOP_BUFFER;
         else      sl = price + minDistance * BROKER_STOP_BUFFER;
         sl = NormalizeDouble(sl, digits);
         slPips = MathAbs(price - sl) / pipValue;
      }
      if(MathAbs(price - tp) < minDistance)
      {
         if(isBuy) tp = price + minDistance * BROKER_STOP_BUFFER;
         else      tp = price - minDistance * BROKER_STOP_BUFFER;
         tp = NormalizeDouble(tp, digits);
      }
   }
   
   // Calculate lot size
   double lot = CalculateLotSize(price, slPips);
   
   // Validation
   Print("====================================");
   Print("ICT ", isBuy ? "BUY" : "SELL", " - ", _Symbol);
   Print("Signal: ", comment);
   Print("OB Zone: ", DoubleToString(ob.lowPrice, digits), " - ", DoubleToString(ob.highPrice, digits));
   Print("Entry: ", DoubleToString(price, digits),
         " | SL: ", DoubleToString(sl, digits), " (", DoubleToString(slPips, 1), " pips)",
         " | TP: ", DoubleToString(tp, digits), " (", DoubleToString(tpPips, 1), " pips)");
   Print("R:R = 1:", DoubleToString(tpPips / MathMax(slPips, 0.1), 2), " | Lot: ", DoubleToString(lot, 2));
   Print("====================================");
   
   if(isBuy && (sl >= price || tp <= price))
   {
      Print("ERROR: Invalid BUY SL/TP! Cancelled.");
      LogTradeEvent("CANCEL", comment, isBuy, price, sl, tp, lot, -1);
      return;
   }
   if(!isBuy && (sl <= price || tp >= price))
   {
      Print("ERROR: Invalid SELL SL/TP! Cancelled.");
      LogTradeEvent("CANCEL", comment, isBuy, price, sl, tp, lot, -1);
      return;
   }
   
   // Execute
   LogTradeEvent("ATTEMPT", comment, isBuy, price, sl, tp, lot, -1);
   
   bool result = false;
   if(isBuy)
      result = trade.Buy(lot, _Symbol, 0, sl, tp, comment);
   else
      result = trade.Sell(lot, _Symbol, 0, sl, tp, comment);
   
   if(result)
   {
      Print("SUCCESS: ICT Order placed | Ticket: ", trade.ResultOrder());
      LogTradeEvent("SUCCESS", comment, isBuy, price, sl, tp, lot, (int)trade.ResultRetcode());
      g_lastTradeTime = TimeCurrent();
   }
   else
   {
      Print("FAILED: Error ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      LogTradeEvent("FAILED", comment, isBuy, price, sl, tp, lot, (int)trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
//| ===== TRADING CONDITIONS =====                                    |
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
   
   // Kill Zone filter
   if(!IsInKillZone())
      return false;
   
   // Cooldown
   int secondsSinceLastTrade = (int)(TimeCurrent() - g_lastTradeTime);
   int requiredSeconds = InpCooldownMinutes * 60;
   
   if(g_lastTradeTime > 0 && secondsSinceLastTrade < requiredSeconds)
   {
      if(InpEnableDetailedLogs)
         Print("BLOCKED: Cooldown - ", (requiredSeconds - secondsSinceLastTrade) / 60, " min remaining");
      return false;
   }
   
   // Max positions
   int currentPositions = CountOpenPositions();
   int maxPositions = GetMaxPositions();
   
   if(currentPositions >= maxPositions)
   {
      if(InpEnableDetailedLogs)
         Print("BLOCKED: Max positions ", currentPositions, "/", maxPositions);
      return false;
   }
   
   // Spread
   if(!CheckSpread())
      return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| ===== POSITION MANAGEMENT =====                                   |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   if(InpBreakevenPips <= 0 && !InpUseTrailingStop)
      return;
   
   double pipValue = GetPipValue();
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
      
      double newSL = currentSL;
      bool needsUpdate = false;
      string updateReason = "";
      
      // --- PARTIAL TAKE PROFIT (Priority 0) ---
      if(InpUsePartialTP)
      {
         double slDistance = MathAbs(openPrice - currentSL);
         double slPipsOriginal = slDistance / pipValue;
         
         if(currentSL > 0 && slPipsOriginal > 0 && profitPips >= slPipsOriginal * InpPartialTPRR)
         {
            // Only partial close if SL hasn't been moved to breakeven yet (= not already closed partial)
            bool alreadyPartial = false;
            if(posType == POSITION_TYPE_BUY && currentSL >= openPrice) alreadyPartial = true;
            if(posType == POSITION_TYPE_SELL && currentSL > 0 && currentSL <= openPrice) alreadyPartial = true;
            
            if(!alreadyPartial)
            {
               double currentLot = PositionGetDouble(POSITION_VOLUME);
               double partialLot = currentLot * (InpPartialTPPercent / 100.0);
               double lotStepPT = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
               partialLot = MathFloor(partialLot / lotStepPT) * lotStepPT;
               double minLotPT = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
               
               if(partialLot >= minLotPT && (currentLot - partialLot) >= minLotPT)
               {
                  if(trade.PositionClosePartial(ticket, partialLot))
                  {
                     Print("PARTIAL TP: #", ticket, " | Closed ", DoubleToString(partialLot, 2),
                           " lots at ", DoubleToString(profitPips, 1), " pips profit (",
                           DoubleToString(profitPips / slPipsOriginal, 1), "R)");
                     // Move SL to breakeven for remaining position
                     newSL = NormalizeDouble(openPrice, digits);
                     needsUpdate = true;
                     updateReason = "PARTIAL_TP+BE";
                  }
               }
               else if(InpEnableDetailedLogs)
               {
                  Print("PARTIAL TP SKIP: Lot too small to split | Current: ",
                        DoubleToString(currentLot, 2), " | Partial: ", DoubleToString(partialLot, 2));
               }
            }
         }
      }
      
      // --- TRAILING STOP (Priority 1) ---
      int trailActivate = InpTrailingActivatePips;
      int trailDistance = InpTrailingDistancePips;
      
      if(InpUseATRTrailing && currentATR > 0)
      {
         trailDistance = (int)MathRound((currentATR * InpTrailingATRMult) / pipValue);
         trailActivate = (int)MathRound((currentATR * InpTrailingATRMult * 1.5) / pipValue);
         if(trailDistance < 20) trailDistance = 20;
         if(trailActivate < 30) trailActivate = 30;
      }
      
      if(InpUseTrailingStop && profitPips >= trailActivate)
      {
         double trailingDist = trailDistance * pipValue;
         double potentialSL = 0;
         
         if(posType == POSITION_TYPE_BUY)
         {
            potentialSL = currentPrice - trailingDist;
            if(potentialSL > currentSL)
            {
               newSL = NormalizeDouble(potentialSL, digits);
               needsUpdate = true;
               updateReason = "TRAILING";
            }
         }
         else
         {
            potentialSL = currentPrice + trailingDist;
            if(potentialSL < currentSL || currentSL == 0)
            {
               newSL = NormalizeDouble(potentialSL, digits);
               needsUpdate = true;
               updateReason = "TRAILING";
            }
         }
      }
      // --- BREAKEVEN (Priority 2) ---
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
         bool validSL = false;
         if(posType == POSITION_TYPE_BUY && newSL < currentPrice && newSL > currentSL)
            validSL = true;
         else if(posType == POSITION_TYPE_SELL && newSL > currentPrice && (newSL < currentSL || currentSL == 0))
            validSL = true;
         
         if(validSL)
         {
            if(InpEnableDetailedLogs)
               Print(updateReason, ": #", ticket,
                     " | Profit: ", DoubleToString(profitPips, 1), " pips",
                     " | SL: ", DoubleToString(currentSL, digits),
                     " → ", DoubleToString(newSL, digits));
            
            if(trade.PositionModify(ticket, newSL, currentTP))
            {
               if(InpEnableDetailedLogs) Print("SUCCESS: ", updateReason, " applied");
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
//| ===== MAIN OnTick =====                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // === H4 New Bar Detection → Structure Update ===
   datetime currentH4Bar = iTime(_Symbol, PERIOD_H4, 0);
   if(currentH4Bar != g_lastH4BarTime)
   {
      g_lastH4BarTime = currentH4Bar;
      
      if(InpEnableDetailedLogs)
         Print("\n=== NEW H4 BAR: ", TimeToString(currentH4Bar), " ===");
      
      DetectSwingPoints();
      DrawSwingPoints();
      DetectBOS_ChoCH();
      CheckOBMitigation();
      RemoveMitigatedOBDrawings();
   }
   
   // === M15 New Bar Detection → Entry Logic ===
   datetime currentM15Bar = iTime(_Symbol, PERIOD_M15, 0);
   if(currentM15Bar != g_lastM15BarTime)
   {
      g_lastM15BarTime = currentM15Bar;
      
      if(InpEnableDetailedLogs)
         Print("\n--- NEW M15 BAR: ", TimeToString(currentM15Bar), " ---");
      
      // Check OB mitigation on M15 bars too (more frequent check)
      CheckOBMitigation();
      RemoveMitigatedOBDrawings();
      
      // Check trading conditions and generate signals
      if(CheckTradingConditions())
      {
         AnalyzeAndTrade();
      }
   }
   
   // === Every Tick: Position Management ===
   ManageOpenPositions();
}

//+------------------------------------------------------------------+
//| ===== CHART DISPLAY =====                                         |
//+------------------------------------------------------------------+
void UpdateChartComment(double currentPrice, double currentATR, double avgATR,
                        double oteUpper, double oteLower, string signalStatus)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / GetPipValue();
   int positions = CountOpenPositions();
   int maxPos = GetMaxPositions();
   
   string obInfo = "";
   int activeOBs = 0;
   for(int i = 0; i < ArraySize(g_orderBlocks); i++)
   {
      if(g_orderBlocks[i].isValid && !g_orderBlocks[i].isMitigated)
      {
         activeOBs++;
         if(activeOBs <= 3)  // Show max 3 OBs
         {
            obInfo += (g_orderBlocks[i].isBullish ? "  DEM: " : "  SUP: ") +
                      DoubleToString(g_orderBlocks[i].lowPrice, _Digits) + " - " +
                      DoubleToString(g_orderBlocks[i].highPrice, _Digits) + "\n";
         }
      }
   }
   
   // Last swing points
   string swingInfo = "";
   int totalSP = ArraySize(g_swingPoints);
   double lastSH = 0, lastSL = 0;
   for(int i = totalSP - 1; i >= 0; i--)
   {
      if(g_swingPoints[i].isHigh && lastSH == 0) lastSH = g_swingPoints[i].price;
      if(!g_swingPoints[i].isHigh && lastSL == 0) lastSL = g_swingPoints[i].price;
      if(lastSH > 0 && lastSL > 0) break;
   }
   
   string structureInfo = "None";
   if(g_lastStructureBreak.breakPrice > 0)
      structureInfo = StructureTypeToString(g_lastStructureBreak.type) + " " +
                      (g_lastStructureBreak.isBullish ? "↑" : "↓") + " @ " +
                      DoubleToString(g_lastStructureBreak.breakPrice, _Digits);
   
   MqlDateTime timeNow;
   TimeToStruct(TimeGMT(), timeNow);
   
   string commentText = StringFormat(
      "=== %s - ICT v1.0 ===\n"
      "UTC: %02d:%02d | KZ: %s\n"
      "Balance: $%.2f | Risk: %.1f%%\n"
      "────────────────────────\n"
      "H4 Bias: %s | Structure: %s\n"
      "Swing H: %s | Swing L: %s\n"
      "OTE Zone: %s - %s\n"
      "Price in OTE: %s\n"
      "────────────────────────\n"
      "Active OBs: %d\n"
      "%s"
      "────────────────────────\n"
      "ATR: %s | Avg: %s\n"
      "Spread: %.1f pips\n"
      "Positions: %d/%d\n"
      "Signal: %s",
      _Symbol,
      timeNow.hour, timeNow.min, GetCurrentKillZone(),
      balance, InpRiskPercent,
      BiasToString(g_currentBias), structureInfo,
      lastSH > 0 ? DoubleToString(lastSH, _Digits) : "N/A",
      lastSL > 0 ? DoubleToString(lastSL, _Digits) : "N/A",
      oteUpper > 0 ? DoubleToString(oteLower, _Digits) : "N/A",
      oteUpper > 0 ? DoubleToString(oteUpper, _Digits) : "N/A",
      (currentPrice >= oteLower && currentPrice <= oteUpper && oteUpper > 0) ? "YES ✅" : "NO",
      activeOBs,
      obInfo != "" ? obInfo : "  None\n",
      DoubleToString(currentATR, _Digits), DoubleToString(avgATR, _Digits),
      spread,
      positions, maxPos,
      signalStatus
   );
   
   Comment(commentText);
}

//+------------------------------------------------------------------+
//| ===== LOGGING =====                                               |
//+------------------------------------------------------------------+
void DebugLogCSV(string line)
{
   if(!InpEnableFileLogging) return;
   int fh = FileOpen(InpDebugLogFileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(fh == INVALID_HANDLE)
   {
      fh = FileOpen(InpDebugLogFileName, FILE_WRITE|FILE_CSV|FILE_COMMON);
      if(fh == INVALID_HANDLE) return;
   }
   FileSeek(fh, 0, SEEK_END);
   FileWriteString(fh, line);
   FileWriteString(fh, "\r\n");
   FileClose(fh);
}

void LogSignalEvent(string eventType, string signalReason, double price,
                    double atr, double oteUpper, double oteLower)
{
   if(!InpEnableFileLogging) return;
   string ts = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   string rec = ts + "," + _Symbol + "," + eventType + "," + signalReason + "," +
                BiasToString(g_currentBias) + "," +
                DoubleToString(price, _Digits) + "," +
                DoubleToString(atr, _Digits) + "," +
                DoubleToString(oteLower, _Digits) + "," +
                DoubleToString(oteUpper, _Digits) + "," +
                IntegerToString(CountOpenPositions()) + "," +
                IntegerToString(CountActiveOrderBlocks());
   DebugLogCSV(rec);
}

void LogTradeEvent(string action, string comment, bool isBuy, double price,
                   double sl, double tp, double lot, int retcode)
{
   if(!InpEnableFileLogging) return;
   string ts = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   string rec = ts + "," + _Symbol + "," + action + "," + comment + "," +
                (isBuy ? "BUY" : "SELL") + "," +
                DoubleToString(price, _Digits) + "," +
                DoubleToString(sl, _Digits) + "," +
                DoubleToString(tp, _Digits) + "," +
                DoubleToString(lot, 2) + "," +
                IntegerToString(retcode);
   DebugLogCSV(rec);
}
//+------------------------------------------------------------------+
