//+------------------------------------------------------------------+
//|                                           SMC_Liquidity_EA.mq5   |
//|                     Smart Money Concepts - Liquidity Sweep EA     |
//|        Liquidity Sweep + CHoCH/BOS + Order Block + FVG Strategy   |
//+------------------------------------------------------------------+
#property copyright   "SMC Liquidity EA"
#property link        ""
#property version     "1.00"
#property description "Smart Money Concepts: Liquidity Sweep + CHoCH/BOS + OB + FVG Confluence Strategy"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//╔═══════════════════════════════════════════════════════════════════╗
//║                       CONSTANTS                                  ║
//╚═══════════════════════════════════════════════════════════════════╝
#define MAX_SYMBOLS       10
#define MAX_SWINGS        100
#define MAX_LIQUIDITY     50
#define MAX_ENTRIES       10
#define MAX_SETUP_IDS     50
#define EA_TAG            "SMC_"
#define DASH_TAG          "SMC_DASH_"

//╔═══════════════════════════════════════════════════════════════════╗
//║                     ENUMERATIONS                                 ║
//╚═══════════════════════════════════════════════════════════════════╝

enum ENUM_SETUP_STATE
{
   STATE_WAITING_FOR_LIQUIDITY,   // Waiting For Liquidity
   STATE_LIQUIDITY_SWEPT,         // Liquidity Swept
   STATE_WAITING_FOR_CHOCH,       // Waiting For CHoCH
   STATE_CHOCH_CONFIRMED,         // CHoCH Confirmed
   STATE_WAITING_FOR_BOS,         // Waiting For BOS
   STATE_BOS_CONFIRMED,           // BOS Confirmed
   STATE_IDENTIFYING_OB,          // Identifying Order Block
   STATE_IDENTIFYING_FVG,         // Identifying FVG
   STATE_CONFLUENCE_CONFIRMED,    // Confluence Confirmed
   STATE_WAITING_FOR_RETEST,      // Waiting For Retest
   STATE_ORDERS_PLACED,           // Orders Placed
   STATE_POSITION_ACTIVE,         // Position Active
   STATE_TARGET_REACHED,          // Target Reached
   STATE_SETUP_INVALIDATED,       // Setup Invalidated
   STATE_RESET                    // Reset
};

enum ENUM_DIRECTION
{
   DIR_NONE,      // None
   DIR_BULLISH,   // Bullish
   DIR_BEARISH    // Bearish
};

enum ENUM_ENTRY_MODE
{
   ENTRY_PENDING,  // Pending Orders
   ENTRY_MARKET,   // Market Entry
   ENTRY_HYBRID    // Hybrid
};

enum ENUM_TP_MODE
{
   TP_LIQUIDITY,    // Liquidity Target
   TP_RISK_REWARD,  // Risk:Reward Ratio
   TP_FIXED_POINTS, // Fixed Points
   TP_HYBRID        // Hybrid (RR + Liquidity)
};

enum ENUM_SWEEP_MODE
{
   SWEEP_WICK_ONLY,      // Wick Only
   SWEEP_CLOSE_BACK,     // Close Back
   SWEEP_WICK_AND_CLOSE  // Wick And Close
};

enum ENUM_BREAK_METHOD
{
   BREAK_WICK,         // Wick Break
   BREAK_CANDLE_CLOSE, // Candle Close
   BREAK_BODY_CLOSE    // Body Close
};

enum ENUM_VOLUME_DIST
{
   VOL_EQUAL,     // Equal Volume
   VOL_WEIGHTED,  // Weighted (heavier at OB)
   VOL_CUSTOM     // Custom Split
};

//╔═══════════════════════════════════════════════════════════════════╗
//║                       STRUCTURES                                 ║
//╚═══════════════════════════════════════════════════════════════════╝

struct SSwingPoint
{
   double   price;
   datetime time;
   int      barIndex;
   bool     isHigh;  // true = swing high, false = swing low
};

struct SLiquidityLevel
{
   double   price;
   datetime time;
   bool     isBuySide;   // true = buy-side (swing high), false = sell-side
   bool     swept;
   datetime sweepTime;
   double   sweepPrice;
};

struct SSymbolState
{
   // Identity
   string            symbol;
   long              magicNumber;

   // State Machine
   ENUM_SETUP_STATE  currentState;
   ENUM_DIRECTION    bias;

   // Timing
   datetime          htfLastBarTime;
   datetime          ltfLastBarTime;

   // ATR handles
   int               atrHandleLTF;
   int               atrHandleHTF;
   double            currentATR_LTF;

   // HTF Swing Data
   SSwingPoint       htfSwingHighs[MAX_SWINGS];
   int               htfSwingHighCount;
   SSwingPoint       htfSwingLows[MAX_SWINGS];
   int               htfSwingLowCount;

   // HTF Liquidity Levels
   SLiquidityLevel   buySideLiq[MAX_LIQUIDITY];
   int               buySideLiqCount;
   SLiquidityLevel   sellSideLiq[MAX_LIQUIDITY];
   int               sellSideLiqCount;

   // LTF Swing Data
   SSwingPoint       ltfSwingHighs[MAX_SWINGS];
   int               ltfSwingHighCount;
   SSwingPoint       ltfSwingLows[MAX_SWINGS];
   int               ltfSwingLowCount;

   // Active Setup — Sweep
   double            liquidityLevel;
   double            sweepPrice;
   datetime          sweepTime;

   // Active Setup — CHoCH
   double            chochLevel;
   int               chochBar;
   datetime          chochTime;

   // Active Setup — BOS
   double            bosLevel;
   int               bosBar;
   datetime          bosTime;

   // Active Setup — displacement reference bar
   int               displacementBar;

   // Active Setup — Order Block
   double            obHigh;
   double            obLow;
   datetime          obTime;
   ENUM_DIRECTION    obDirection;
   bool              obValid;

   // Active Setup — Fair Value Gap
   double            fvgHigh;
   double            fvgLow;
   datetime          fvgTime;
   ENUM_DIRECTION    fvgDirection;
   bool              fvgValid;

   // Active Setup — Confluence / POI
   double            poiHigh;
   double            poiLow;
   bool              hasConfluence;

   // Entry tracking
   double            entryPrices[MAX_ENTRIES];
   double            entryLots[MAX_ENTRIES];
   int               numPlannedEntries;
   ulong             orderTickets[MAX_ENTRIES];
   int               orderTicketCount;
   double            slPrice;
   double            tpPrice;

   // Expiry
   datetime          setupStartTime;

   // Position management
   bool              partialCloseDone;

   // Daily statistics
   double            dailyPnL;
   int               dailyTradeCount;
   double            dayStartBalance;
   int               todayDate;

   // Duplicate prevention
   string            processedIds[MAX_SETUP_IDS];
   int               processedIdCount;

   // Visualization
   int               objCounter;

   // Target liquidity for TP
   double            targetLiqLevel;
};

//╔═══════════════════════════════════════════════════════════════════╗
//║                    INPUT PARAMETERS                              ║
//╚═══════════════════════════════════════════════════════════════════╝

input group "══════ General ══════"
input long            MagicNumber              = 202409;        // Magic Number
input string          EAComment                = "SMC_LIQ";     // Order Comment

input group "══════ Timeframes ══════"
input ENUM_TIMEFRAMES HTF_Timeframe            = PERIOD_H1;     // Higher Timeframe (Liquidity)
input ENUM_TIMEFRAMES LTF_Timeframe            = PERIOD_M5;     // Lower Timeframe (Execution)

input group "══════ Swing Detection ══════"
input int             SwingLookback            = 100;           // HTF Bars To Scan
input int             HTFSwingStrength         = 5;             // HTF Swing Strength (bars each side)
input int             LTFSwingStrength         = 3;             // LTF Swing Strength (bars each side)
input int             MinSwingDistPoints       = 100;           // Min Swing Distance (points)
input int             LiquidityTolPoints       = 15;            // Equal High/Low Tolerance (points)

input group "══════ Liquidity Sweep ══════"
input int             SweepBufferPoints        = 5;             // Sweep Buffer (points above/below)
input int             MinSweepDistPoints       = 10;            // Min Sweep Penetration (points)
input ENUM_SWEEP_MODE SweepConfirmationMode    = SWEEP_WICK_AND_CLOSE; // Sweep Confirmation

input group "══════ Structure (CHoCH) ══════"
input ENUM_BREAK_METHOD StructureBreakMethod   = BREAK_BODY_CLOSE;  // Break Confirmation Method
input int             MinBreakDistPoints       = 5;             // Min Break Distance (points)
input double          MinDisplacementATR       = 1.0;           // Min Displacement (× ATR)
input int             ATRPeriod                = 14;            // ATR Period

input group "══════ BOS ══════"
input bool            RequireSecondBOS         = false;         // Require Additional BOS
input int             BOSMinDistPoints         = 5;             // BOS Min Distance (points)
input ENUM_BREAK_METHOD BOSBreakMethod         = BREAK_BODY_CLOSE;  // BOS Confirmation Method

input group "══════ Order Block ══════"
input int             OBLookbackCandles        = 10;            // OB Lookback (candles before displacement)
input bool            OBUseBodyOnly            = false;         // Use Body Only (vs Full Candle)
input int             OBMinSizePoints          = 5;             // OB Min Size (points)
input int             OBMaxAgeBars             = 200;           // OB Max Age (LTF bars)

input group "══════ Fair Value Gap ══════"
input int             MinFVGSizePoints         = 5;             // FVG Min Size (points)
input int             MaxFVGSizePoints         = 500;           // FVG Max Size (points)
input double          FVGMitigationPct         = 50.0;          // FVG Mitigation % (invalidation)
input int             FVGExpiryBars            = 100;           // FVG Expiry (LTF bars)

input group "══════ Confluence ══════"
input bool            RequireOBFVGConfluence   = true;          // Require OB+FVG Overlap
input int             MinOverlapPoints         = 3;             // Min Overlap Size (points)
input bool            AllowFVGOnlyEntry        = true;          // Allow FVG-Only Entry

input group "══════ Entry ══════"
input ENUM_ENTRY_MODE EntryMode                = ENTRY_PENDING; // Entry Mode
input int             NumberOfEntries          = 1;             // Number of Split Entries (1-10)
input ENUM_VOLUME_DIST VolumeDist              = VOL_EQUAL;     // Volume Distribution

input group "══════ Stop Loss ══════"
input int             SLBufferPoints           = 10;            // SL Buffer Beyond OB (points)

input group "══════ Take Profit ══════"
input ENUM_TP_MODE    TPMode                   = TP_RISK_REWARD;// TP Mode
input double          RiskRewardRatio          = 2.0;           // Risk:Reward Ratio
input int             FixedTPPoints            = 500;           // Fixed TP (points)

input group "══════ Risk Management ══════"
input double          RiskPercentPerSetup      = 1.0;           // Risk % Per Setup
input double          MaxAccountRiskPct        = 5.0;           // Max Total Account Risk %
input int             MaxOpenTrades            = 3;             // Max Simultaneous Open Trades
input double          MaxDailyLossPct          = 3.0;           // Max Daily Loss %
input int             MaxDailyTrades           = 5;             // Max Daily Trades

input group "══════ Position Management ══════"
input bool            EnablePartialClose       = false;         // Enable Partial Close
input double          PartialClosePct          = 50.0;          // Partial Close % of Volume
input bool            MoveSLToBreakEven        = true;          // Move SL to Break-Even at 1R
input int             TrailingStopPoints       = 0;             // Trailing Stop (points, 0=off)

input group "══════ Session Filter ══════"
input bool            UseSessionFilter         = false;         // Enable Session Filter
input int             SessionStartHour         = 7;             // Session Start Hour (server time)
input int             SessionEndHour           = 20;            // Session End Hour (server time)

input group "══════ News Filter ══════"
input bool            UseNewsFilter            = false;         // Enable News Blackout
input int             News1Hour                = 0;             // News Event 1 Hour (0=off)
input int             News1Minute              = 0;             // News Event 1 Minute
input int             News2Hour                = 0;             // News Event 2 Hour (0=off)
input int             News2Minute              = 0;             // News Event 2 Minute
input int             NewsBlackoutMins         = 30;            // Blackout Window (mins each side)

input group "══════ Protection ══════"
input int             MaxSpreadPoints          = 30;            // Max Allowed Spread (points)
input int             Slippage                 = 10;            // Max Slippage (points)
input double          MinFreeMarginPct         = 50.0;          // Min Free Margin %

input group "══════ Setup Expiry ══════"
input int             SetupExpirationBars      = 100;           // Setup Expiry (LTF bars)

input group "══════ Multi-Symbol ══════"
input bool            EnableMultiSymbol        = false;         // Enable Multi-Symbol
input string          SymbolList               = "";            // Symbols (comma-separated)

input group "══════ Visualization ══════"
input bool            ShowChartObjects         = true;          // Draw Chart Objects
input bool            ShowDebugObjects         = false;         // Draw Debug Objects
input bool            ShowDashboard            = true;          // Show Dashboard Panel

input group "══════ Colors ══════"
input color           ClrBuySideLiq            = clrDodgerBlue;    // Buy-Side Liquidity
input color           ClrSellSideLiq           = clrOrangeRed;     // Sell-Side Liquidity
input color           ClrBullishOB             = clrForestGreen;   // Bullish Order Block
input color           ClrBearishOB             = clrCrimson;       // Bearish Order Block
input color           ClrBullishFVG            = clrDeepSkyBlue;   // Bullish FVG
input color           ClrBearishFVG            = clrOrange;        // Bearish FVG
input color           ClrConfluence            = clrMagenta;       // Confluence Zone
input color           ClrSweepMarker           = clrGold;          // Sweep Marker
input color           ClrCHoCH                 = clrLime;          // CHoCH Line
input color           ClrBOS                   = clrAqua;          // BOS Line
input color           ClrDashBG                = C'20,20,35';      // Dashboard Background
input color           ClrDashText              = clrWhite;         // Dashboard Text
input color           ClrDashAccent            = clrGold;          // Dashboard Accent

//╔═══════════════════════════════════════════════════════════════════╗
//║                    GLOBAL VARIABLES                              ║
//╚═══════════════════════════════════════════════════════════════════╝

SSymbolState   g_states[MAX_SYMBOLS];
int            g_symbolCount      = 0;
CTrade         g_trade;
datetime       g_lastDashUpdate   = 0;
bool           g_emergencyStop    = false;

//╔═══════════════════════════════════════════════════════════════════╗
//║                    LOGGER                                        ║
//╚═══════════════════════════════════════════════════════════════════╝

void LogInfo(string msg)    { Print("[SMC] ",msg); }
void LogWarn(string msg)    { Print("[SMC][WARN] ",msg); }
void LogError(string msg)   { Print("[SMC][ERROR] ",msg); }
void LogDebug(string msg)   { if(ShowDebugObjects) Print("[SMC][DEBUG] ",msg); }

//╔═══════════════════════════════════════════════════════════════════╗
//║                 UTILITY FUNCTIONS                                ║
//╚═══════════════════════════════════════════════════════════════════╝

//--- Symbol-safe point and digits
double SymPoint(string sym)
{
   if(sym == _Symbol) return _Point;
   return SymbolInfoDouble(sym, SYMBOL_POINT);
}
int SymDigits(string sym)
{
   if(sym == _Symbol) return _Digits;
   return (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
}

//--- New bar detection
bool IsNewBar(string sym, ENUM_TIMEFRAMES tf, datetime &lastBarTime)
{
   datetime t[];
   if(CopyTime(sym, tf, 0, 1, t) < 1) return false;
   if(t[0] != lastBarTime) { lastBarTime = t[0]; return true; }
   return false;
}

//--- Normalize lot size to broker constraints
double NormalizeLots(string sym, double lots)
{
   double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots / step) * step;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   // Determine precision from step
   int digits = (int)MathMax(0, -MathLog10(step) + 0.5);
   return NormalizeDouble(lots, digits);
}

//--- Get the setup state as a readable string
string StateToString(ENUM_SETUP_STATE s)
{
   switch(s)
   {
      case STATE_WAITING_FOR_LIQUIDITY: return "WAIT_LIQ";
      case STATE_LIQUIDITY_SWEPT:       return "LIQ_SWEPT";
      case STATE_WAITING_FOR_CHOCH:     return "WAIT_CHOCH";
      case STATE_CHOCH_CONFIRMED:       return "CHOCH_OK";
      case STATE_WAITING_FOR_BOS:       return "WAIT_BOS";
      case STATE_BOS_CONFIRMED:         return "BOS_OK";
      case STATE_IDENTIFYING_OB:        return "ID_OB";
      case STATE_IDENTIFYING_FVG:       return "ID_FVG";
      case STATE_CONFLUENCE_CONFIRMED:  return "CONF_OK";
      case STATE_WAITING_FOR_RETEST:    return "WAIT_RETEST";
      case STATE_ORDERS_PLACED:         return "ORDERS";
      case STATE_POSITION_ACTIVE:       return "POS_ACTIVE";
      case STATE_TARGET_REACHED:        return "TARGET";
      case STATE_SETUP_INVALIDATED:     return "INVALID";
      case STATE_RESET:                 return "RESET";
   }
   return "UNKNOWN";
}

string DirectionToString(ENUM_DIRECTION d)
{
   switch(d)
   {
      case DIR_BULLISH: return "BULLISH";
      case DIR_BEARISH: return "BEARISH";
      default:          return "NONE";
   }
}

//--- Generate a unique setup ID string from key parameters
string GenerateSetupId(SSymbolState &st)
{
   return StringFormat("%s_%s_%.5f_%.5f_%d",
      st.symbol, DirectionToString(st.bias),
      st.liquidityLevel, st.chochLevel,
      (int)st.obTime);
}

//--- Check if a setup ID was already processed
bool IsSetupProcessed(SSymbolState &st, string id)
{
   for(int i = 0; i < st.processedIdCount; i++)
      if(st.processedIds[i] == id) return true;
   return false;
}

//--- Mark a setup ID as processed
void MarkSetupProcessed(SSymbolState &st, string id)
{
   if(st.processedIdCount >= MAX_SETUP_IDS)
   {
      // Shift array — remove oldest
      for(int i = 0; i < MAX_SETUP_IDS - 1; i++)
         st.processedIds[i] = st.processedIds[i + 1];
      st.processedIdCount = MAX_SETUP_IDS - 1;
   }
   st.processedIds[st.processedIdCount++] = id;
}

//--- Session filter check
bool IsWithinSession()
{
   if(!UseSessionFilter) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;
   if(SessionStartHour < SessionEndHour)
      return (hour >= SessionStartHour && hour < SessionEndHour);
   else // Wraps midnight
      return (hour >= SessionStartHour || hour < SessionEndHour);
}

//--- News blackout check
bool IsNewsBlackout()
{
   if(!UseNewsFilter) return false;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMins = dt.hour * 60 + dt.min;

   // Check event 1
   if(News1Hour > 0 || News1Minute > 0)
   {
      int eventMins = News1Hour * 60 + News1Minute;
      if(MathAbs(nowMins - eventMins) <= NewsBlackoutMins) return true;
   }
   // Check event 2
   if(News2Hour > 0 || News2Minute > 0)
   {
      int eventMins = News2Hour * 60 + News2Minute;
      if(MathAbs(nowMins - eventMins) <= NewsBlackoutMins) return true;
   }
   return false;
}

//--- Count bars elapsed since a given time
int BarsElapsed(string sym, ENUM_TIMEFRAMES tf, datetime since)
{
   if(since == 0) return 0;
   int bars = Bars(sym, tf, since, TimeCurrent());
   return MathMax(0, bars - 1);
}

//--- Get fill type supported by broker
ENUM_ORDER_TYPE_FILLING GetFillType(string sym)
{
   long fillMode = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((fillMode & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((fillMode & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//╔═══════════════════════════════════════════════════════════════════╗
//║               SWING DETECTION (Fractal Method)                   ║
//╚═══════════════════════════════════════════════════════════════════╝

// Detect swing highs and lows using the fractal method.
// A swing high at bar 'center' requires SwingStr bars on each side with
// strictly lower highs. Starts at center = swingStr+1 to avoid bar 0 (current).
// Results are stored into the supplied fixed-size arrays.
// Returns the total count of swings found (highs + lows).
int DetectSwings(MqlRates &rates[], int rateCount, int swingStr,
                 SSwingPoint &highs[], int &highCount,
                 SSwingPoint &lows[],  int &lowCount,
                 double pointVal, int maxSwings)
{
   highCount = 0;
   lowCount  = 0;

   int minCenter = swingStr + 1; // avoid bar 0 (unfinished)
   int maxCenter = rateCount - swingStr;

   for(int c = minCenter; c < maxCenter && (highCount < maxSwings || lowCount < maxSwings); c++)
   {
      bool isHigh = true;
      bool isLow  = true;

      for(int s = 1; s <= swingStr; s++)
      {
         // More recent side (lower index)
         if(rates[c - s].high >= rates[c].high) isHigh = false;
         if(rates[c - s].low  <= rates[c].low)  isLow  = false;
         // Older side (higher index)
         if(rates[c + s].high >= rates[c].high) isHigh = false;
         if(rates[c + s].low  <= rates[c].low)  isLow  = false;

         if(!isHigh && !isLow) break; // Early exit
      }

      if(isHigh && highCount < maxSwings)
      {
         highs[highCount].price    = rates[c].high;
         highs[highCount].time     = rates[c].time;
         highs[highCount].barIndex = c;
         highs[highCount].isHigh   = true;
         highCount++;
      }
      if(isLow && lowCount < maxSwings)
      {
         lows[lowCount].price    = rates[c].low;
         lows[lowCount].time     = rates[c].time;
         lows[lowCount].barIndex = c;
         lows[lowCount].isHigh   = false;
         lowCount++;
      }
   }
   return highCount + lowCount;
}

//╔═══════════════════════════════════════════════════════════════════╗
//║          LIQUIDITY LEVEL DETECTION & SWEEP                       ║
//╚═══════════════════════════════════════════════════════════════════╝

// Build liquidity levels from HTF swing points.
// Buy-side = swing highs + equal highs. Sell-side = swing lows + equal lows.
void BuildLiquidityLevels(SSymbolState &st, double pointVal)
{
   st.buySideLiqCount  = 0;
   st.sellSideLiqCount = 0;
   double tol = LiquidityTolPoints * pointVal;
   double minDist = MinSwingDistPoints * pointVal;

   // Buy-side: significant swing highs
   for(int i = 0; i < st.htfSwingHighCount && st.buySideLiqCount < MAX_LIQUIDITY; i++)
   {
      bool duplicate = false;
      for(int j = 0; j < st.buySideLiqCount; j++)
      {
         if(MathAbs(st.buySideLiq[j].price - st.htfSwingHighs[i].price) < minDist)
         {
            // Equal/near-equal highs — keep the higher one, mark as stronger liquidity
            if(st.htfSwingHighs[i].price > st.buySideLiq[j].price)
               st.buySideLiq[j].price = st.htfSwingHighs[i].price;
            duplicate = true;
            break;
         }
      }
      if(!duplicate)
      {
         int idx = st.buySideLiqCount;
         st.buySideLiq[idx].price     = st.htfSwingHighs[i].price;
         st.buySideLiq[idx].time      = st.htfSwingHighs[i].time;
         st.buySideLiq[idx].isBuySide = true;
         st.buySideLiq[idx].swept     = false;
         st.buySideLiq[idx].sweepTime = 0;
         st.buySideLiq[idx].sweepPrice= 0;
         st.buySideLiqCount++;
      }
   }

   // Sell-side: significant swing lows
   for(int i = 0; i < st.htfSwingLowCount && st.sellSideLiqCount < MAX_LIQUIDITY; i++)
   {
      bool duplicate = false;
      for(int j = 0; j < st.sellSideLiqCount; j++)
      {
         if(MathAbs(st.sellSideLiq[j].price - st.htfSwingLows[i].price) < minDist)
         {
            if(st.htfSwingLows[i].price < st.sellSideLiq[j].price)
               st.sellSideLiq[j].price = st.htfSwingLows[i].price;
            duplicate = true;
            break;
         }
      }
      if(!duplicate)
      {
         int idx = st.sellSideLiqCount;
         st.sellSideLiq[idx].price     = st.htfSwingLows[i].price;
         st.sellSideLiq[idx].time      = st.htfSwingLows[i].time;
         st.sellSideLiq[idx].isBuySide = false;
         st.sellSideLiq[idx].swept     = false;
         st.sellSideLiq[idx].sweepTime = 0;
         st.sellSideLiq[idx].sweepPrice= 0;
         st.sellSideLiqCount++;
      }
   }
}

// Check if any liquidity level has been swept.
// Returns true if a sweep is detected and populates the state with sweep details.
bool CheckLiquiditySweep(SSymbolState &st, MqlRates &htfRates[], int htfCount, double pointVal)
{
   double sweepBuf = SweepBufferPoints * pointVal;
   double minSweep = MinSweepDistPoints * pointVal;

   // Check buy-side sweeps (→ bearish bias)
   for(int l = 0; l < st.buySideLiqCount; l++)
   {
      if(st.buySideLiq[l].swept) continue;
      double level = st.buySideLiq[l].price;

      for(int b = 1; b <= 3 && b < htfCount; b++)
      {
         bool swept = false;
         double penetration = htfRates[b].high - level;
         if(penetration < sweepBuf) continue; // Not enough penetration

         switch(SweepConfirmationMode)
         {
            case SWEEP_WICK_ONLY:
               swept = (htfRates[b].high > level + sweepBuf) &&
                       (htfRates[b].close <= level);
               break;
            case SWEEP_CLOSE_BACK:
               swept = (htfRates[b].high > level + sweepBuf) &&
                       (b >= 2 && htfRates[b-1].close < level);
               break;
            case SWEEP_WICK_AND_CLOSE:
               swept = (htfRates[b].high > level + sweepBuf) &&
                       (htfRates[b].close < level);
               break;
         }

         if(swept)
         {
            st.buySideLiq[l].swept     = true;
            st.buySideLiq[l].sweepTime = htfRates[b].time;
            st.buySideLiq[l].sweepPrice= htfRates[b].high;

            st.bias            = DIR_BEARISH;
            st.liquidityLevel  = level;
            st.sweepPrice      = htfRates[b].high;
            st.sweepTime       = htfRates[b].time;
            st.setupStartTime  = TimeCurrent();

            LogInfo(StringFormat("%s Buy-side liquidity swept at %.5f (high=%.5f)",
                                st.symbol, level, htfRates[b].high));
            return true;
         }
      }
   }

   // Check sell-side sweeps (→ bullish bias)
   for(int l = 0; l < st.sellSideLiqCount; l++)
   {
      if(st.sellSideLiq[l].swept) continue;
      double level = st.sellSideLiq[l].price;

      for(int b = 1; b <= 3 && b < htfCount; b++)
      {
         bool swept = false;
         double penetration = level - htfRates[b].low;
         if(penetration < sweepBuf) continue;

         switch(SweepConfirmationMode)
         {
            case SWEEP_WICK_ONLY:
               swept = (htfRates[b].low < level - sweepBuf) &&
                       (htfRates[b].close >= level);
               break;
            case SWEEP_CLOSE_BACK:
               swept = (htfRates[b].low < level - sweepBuf) &&
                       (b >= 2 && htfRates[b-1].close > level);
               break;
            case SWEEP_WICK_AND_CLOSE:
               swept = (htfRates[b].low < level - sweepBuf) &&
                       (htfRates[b].close > level);
               break;
         }

         if(swept)
         {
            st.sellSideLiq[l].swept     = true;
            st.sellSideLiq[l].sweepTime = htfRates[b].time;
            st.sellSideLiq[l].sweepPrice= htfRates[b].low;

            st.bias            = DIR_BULLISH;
            st.liquidityLevel  = level;
            st.sweepPrice      = htfRates[b].low;
            st.sweepTime       = htfRates[b].time;
            st.setupStartTime  = TimeCurrent();

            LogInfo(StringFormat("%s Sell-side liquidity swept at %.5f (low=%.5f)",
                                st.symbol, level, htfRates[b].low));
            return true;
         }
      }
   }
   return false;
}

//╔═══════════════════════════════════════════════════════════════════╗
//║               CHoCH DETECTION (Change of Character)              ║
//╚═══════════════════════════════════════════════════════════════════╝

// Detect CHoCH on LTF after a liquidity sweep.
// Bearish CHoCH: after buy-side sweep → price breaks below recent LTF swing low
// Bullish CHoCH: after sell-side sweep → price breaks above recent LTF swing high
bool DetectCHoCH(SSymbolState &st, MqlRates &ltfRates[], int ltfCount, double pointVal)
{
   double minBreak = MinBreakDistPoints * pointVal;

   if(st.bias == DIR_BEARISH)
   {
      // Find most recent confirmed LTF swing low
      if(st.ltfSwingLowCount == 0) return false;
      double swingLow  = st.ltfSwingLows[0].price;
      int    swingBar  = st.ltfSwingLows[0].barIndex;

      // Scan for a break below this swing low (bars more recent than the swing)
      for(int b = 1; b < swingBar && b < ltfCount; b++)
      {
         bool broken = false;
         switch(StructureBreakMethod)
         {
            case BREAK_WICK:
               broken = (ltfRates[b].low < swingLow - minBreak);
               break;
            case BREAK_CANDLE_CLOSE:
               broken = (ltfRates[b].close < swingLow - minBreak);
               break;
            case BREAK_BODY_CLOSE:
               broken = (MathMin(ltfRates[b].open, ltfRates[b].close) < swingLow - minBreak);
               break;
         }

         if(broken)
         {
            // Verify displacement size
            bool isBearishCandle = (ltfRates[b].close < ltfRates[b].open);
            double bodySize = MathAbs(ltfRates[b].close - ltfRates[b].open);

            if(isBearishCandle && bodySize >= MinDisplacementATR * st.currentATR_LTF)
            {
               st.chochLevel       = swingLow;
               st.chochBar         = b;
               st.chochTime        = ltfRates[b].time;
               st.displacementBar  = b;

               LogInfo(StringFormat("%s Bearish CHoCH confirmed at %.5f (bar %d, body=%.5f, ATR=%.5f)",
                                    st.symbol, swingLow, b, bodySize, st.currentATR_LTF));
               return true;
            }
         }
      }
   }
   else if(st.bias == DIR_BULLISH)
   {
      // Find most recent confirmed LTF swing high
      if(st.ltfSwingHighCount == 0) return false;
      double swingHigh = st.ltfSwingHighs[0].price;
      int    swingBar  = st.ltfSwingHighs[0].barIndex;

      for(int b = 1; b < swingBar && b < ltfCount; b++)
      {
         bool broken = false;
         switch(StructureBreakMethod)
         {
            case BREAK_WICK:
               broken = (ltfRates[b].high > swingHigh + minBreak);
               break;
            case BREAK_CANDLE_CLOSE:
               broken = (ltfRates[b].close > swingHigh + minBreak);
               break;
            case BREAK_BODY_CLOSE:
               broken = (MathMax(ltfRates[b].open, ltfRates[b].close) > swingHigh + minBreak);
               break;
         }

         if(broken)
         {
            bool isBullishCandle = (ltfRates[b].close > ltfRates[b].open);
            double bodySize = MathAbs(ltfRates[b].close - ltfRates[b].open);

            if(isBullishCandle && bodySize >= MinDisplacementATR * st.currentATR_LTF)
            {
               st.chochLevel       = swingHigh;
               st.chochBar         = b;
               st.chochTime        = ltfRates[b].time;
               st.displacementBar  = b;

               LogInfo(StringFormat("%s Bullish CHoCH confirmed at %.5f (bar %d, body=%.5f, ATR=%.5f)",
                                    st.symbol, swingHigh, b, bodySize, st.currentATR_LTF));
               return true;
            }
         }
      }
   }
   return false;
}

//╔═══════════════════════════════════════════════════════════════════╗
//║                BOS DETECTION (Break of Structure)                ║
//╚═══════════════════════════════════════════════════════════════════╝

// Detect BOS on LTF after CHoCH. Looks for the NEXT structural break
// in the same direction as the bias.
bool DetectBOS(SSymbolState &st, MqlRates &ltfRates[], int ltfCount, double pointVal)
{
   double minBOS = BOSMinDistPoints * pointVal;

   if(st.bias == DIR_BEARISH)
   {
      // After bearish CHoCH, find a new swing low formed AFTER the CHoCH
      // and check if price broke below it
      for(int i = 0; i < st.ltfSwingLowCount; i++)
      {
         // This swing must be more recent than the CHoCH (lower bar index)
         if(st.ltfSwingLows[i].barIndex >= st.chochBar) continue;
         // But it must be older than bar 1 so we can check a break
         if(st.ltfSwingLows[i].barIndex <= 1) continue;

         double swingLow = st.ltfSwingLows[i].price;
         int    swingBar = st.ltfSwingLows[i].barIndex;

         // This swing low must be different from the CHoCH level
         if(MathAbs(swingLow - st.chochLevel) < minBOS) continue;

         for(int b = 1; b < swingBar; b++)
         {
            bool broken = false;
            switch(BOSBreakMethod)
            {
               case BREAK_WICK:
                  broken = (ltfRates[b].low < swingLow - minBOS);
                  break;
               case BREAK_CANDLE_CLOSE:
                  broken = (ltfRates[b].close < swingLow - minBOS);
                  break;
               case BREAK_BODY_CLOSE:
                  broken = (MathMin(ltfRates[b].open, ltfRates[b].close) < swingLow - minBOS);
                  break;
            }

            if(broken)
            {
               bool isBearish = (ltfRates[b].close < ltfRates[b].open);
               double bodySize = MathAbs(ltfRates[b].close - ltfRates[b].open);

               if(isBearish && bodySize >= MinDisplacementATR * st.currentATR_LTF)
               {
                  st.bosLevel         = swingLow;
                  st.bosBar           = b;
                  st.bosTime          = ltfRates[b].time;
                  st.displacementBar  = b; // Update reference to BOS displacement

                  LogInfo(StringFormat("%s Bearish BOS confirmed at %.5f (bar %d)",
                                       st.symbol, swingLow, b));
                  return true;
               }
            }
         }
      }
   }
   else if(st.bias == DIR_BULLISH)
   {
      for(int i = 0; i < st.ltfSwingHighCount; i++)
      {
         if(st.ltfSwingHighs[i].barIndex >= st.chochBar) continue;
         if(st.ltfSwingHighs[i].barIndex <= 1) continue;

         double swingHigh = st.ltfSwingHighs[i].price;
         int    swingBar  = st.ltfSwingHighs[i].barIndex;
         if(MathAbs(swingHigh - st.chochLevel) < minBOS) continue;

         for(int b = 1; b < swingBar; b++)
         {
            bool broken = false;
            switch(BOSBreakMethod)
            {
               case BREAK_WICK:
                  broken = (ltfRates[b].high > swingHigh + minBOS);
                  break;
               case BREAK_CANDLE_CLOSE:
                  broken = (ltfRates[b].close > swingHigh + minBOS);
                  break;
               case BREAK_BODY_CLOSE:
                  broken = (MathMax(ltfRates[b].open, ltfRates[b].close) > swingHigh + minBOS);
                  break;
            }

            if(broken)
            {
               bool isBullish = (ltfRates[b].close > ltfRates[b].open);
               double bodySize = MathAbs(ltfRates[b].close - ltfRates[b].open);

               if(isBullish && bodySize >= MinDisplacementATR * st.currentATR_LTF)
               {
                  st.bosLevel         = swingHigh;
                  st.bosBar           = b;
                  st.bosTime          = ltfRates[b].time;
                  st.displacementBar  = b;

                  LogInfo(StringFormat("%s Bullish BOS confirmed at %.5f (bar %d)",
                                       st.symbol, swingHigh, b));
                  return true;
               }
            }
         }
      }
   }
   return false;
}

//╔═══════════════════════════════════════════════════════════════════╗
//║               ORDER BLOCK DETECTION                              ║
//╚═══════════════════════════════════════════════════════════════════╝

// Identify the Order Block: the last opposite-direction candle before
// the displacement move.
bool DetectOrderBlock(SSymbolState &st, MqlRates &ltfRates[], int ltfCount, double pointVal)
{
   int dispBar = st.displacementBar;
   double minOB = OBMinSizePoints * pointVal;

   if(dispBar < 0 || dispBar >= ltfCount) return false;

   if(st.bias == DIR_BEARISH)
   {
      // Bearish OB: find the last BULLISH candle before the bearish displacement
      for(int i = dispBar + 1; i < dispBar + OBLookbackCandles + 1 && i < ltfCount; i++)
      {
         if(ltfRates[i].close > ltfRates[i].open) // Bullish candle
         {
            double obH = OBUseBodyOnly ? MathMax(ltfRates[i].open, ltfRates[i].close) : ltfRates[i].high;
            double obL = OBUseBodyOnly ? MathMin(ltfRates[i].open, ltfRates[i].close) : ltfRates[i].low;
            double obSize = obH - obL;

            if(obSize >= minOB)
            {
               st.obHigh      = obH;
               st.obLow       = obL;
               st.obTime      = ltfRates[i].time;
               st.obDirection = DIR_BEARISH;
               st.obValid     = true;

               LogInfo(StringFormat("%s Bearish OB: %.5f - %.5f at %s",
                                    st.symbol, obH, obL, TimeToString(ltfRates[i].time)));
               return true;
            }
         }
      }
   }
   else if(st.bias == DIR_BULLISH)
   {
      // Bullish OB: find the last BEARISH candle before the bullish displacement
      for(int i = dispBar + 1; i < dispBar + OBLookbackCandles + 1 && i < ltfCount; i++)
      {
         if(ltfRates[i].close < ltfRates[i].open) // Bearish candle
         {
            double obH = OBUseBodyOnly ? MathMax(ltfRates[i].open, ltfRates[i].close) : ltfRates[i].high;
            double obL = OBUseBodyOnly ? MathMin(ltfRates[i].open, ltfRates[i].close) : ltfRates[i].low;
            double obSize = obH - obL;

            if(obSize >= minOB)
            {
               st.obHigh      = obH;
               st.obLow       = obL;
               st.obTime      = ltfRates[i].time;
               st.obDirection = DIR_BULLISH;
               st.obValid     = true;

               LogInfo(StringFormat("%s Bullish OB: %.5f - %.5f at %s",
                                    st.symbol, obH, obL, TimeToString(ltfRates[i].time)));
               return true;
            }
         }
      }
   }

   LogWarn(StringFormat("%s No valid Order Block found within %d candles of displacement",
                         st.symbol, OBLookbackCandles));
   return false;
}

//╔═══════════════════════════════════════════════════════════════════╗
//║                FVG DETECTION (Fair Value Gap)                     ║
//╚═══════════════════════════════════════════════════════════════════╝

// Detect FVGs (3-candle imbalance) near the displacement bar.
// Scans a range around the displacement bar for the best-matching FVG.
bool DetectFVG(SSymbolState &st, MqlRates &ltfRates[], int ltfCount, double pointVal)
{
   int dispBar   = st.displacementBar;
   double minFVG = MinFVGSizePoints * pointVal;
   double maxFVG = MaxFVGSizePoints * pointVal;

   // Scan range: from 2 bars before to 5 bars after the displacement
   int scanStart = MathMax(2, dispBar - 5);
   int scanEnd   = MathMin(ltfCount - 2, dispBar + 5);

   double bestGapSize = 0;
   bool   found = false;

   for(int c = scanStart; c <= scanEnd; c++)
   {
      // c is the center candle (candle 2); c-1 is newest (candle 3); c+1 is oldest (candle 1)
      if(c - 1 < 1 || c + 1 >= ltfCount) continue;

      if(st.bias == DIR_BEARISH)
      {
         // Bearish FVG: High of candle 3 (c-1) < Low of candle 1 (c+1)
         double gapHigh = ltfRates[c + 1].low;  // Bottom of candle 1
         double gapLow  = ltfRates[c - 1].high; // Top of candle 3
         double gapSize = gapHigh - gapLow;

         if(gapSize >= minFVG && gapSize <= maxFVG && gapSize > bestGapSize)
         {
            st.fvgHigh      = gapHigh;
            st.fvgLow       = gapLow;
            st.fvgTime      = ltfRates[c].time;
            st.fvgDirection = DIR_BEARISH;
            st.fvgValid     = true;
            bestGapSize     = gapSize;
            found           = true;
         }
      }
      else if(st.bias == DIR_BULLISH)
      {
         // Bullish FVG: Low of candle 3 (c-1) > High of candle 1 (c+1)
         double gapHigh = ltfRates[c - 1].low;  // Bottom of candle 3
         double gapLow  = ltfRates[c + 1].high; // Top of candle 1
         double gapSize = gapHigh - gapLow;

         if(gapSize >= minFVG && gapSize <= maxFVG && gapSize > bestGapSize)
         {
            st.fvgHigh      = gapHigh;
            st.fvgLow       = gapLow;
            st.fvgTime      = ltfRates[c].time;
            st.fvgDirection = DIR_BULLISH;
            st.fvgValid     = true;
            bestGapSize     = gapSize;
            found           = true;
         }
      }
   }

   if(found)
      LogInfo(StringFormat("%s %s FVG: %.5f - %.5f (size=%.1f pts)",
                           st.symbol, DirectionToString(st.bias),
                           st.fvgHigh, st.fvgLow,
                           bestGapSize / pointVal));
   else
      LogDebug(StringFormat("%s No valid FVG found near displacement bar %d", st.symbol, dispBar));

   return found;
}

//╔═══════════════════════════════════════════════════════════════════╗
//║               CONFLUENCE ANALYSIS (OB + FVG)                     ║
//╚═══════════════════════════════════════════════════════════════════╝

// Determine the Point of Interest (POI) from OB + FVG overlap.
bool CheckConfluence(SSymbolState &st, double pointVal)
{
   double minOvl = MinOverlapPoints * pointVal;

   if(st.obValid && st.fvgValid)
   {
      // Calculate overlap
      double ovlHigh = MathMin(st.obHigh, st.fvgHigh);
      double ovlLow  = MathMax(st.obLow,  st.fvgLow);
      double ovlSize = ovlHigh - ovlLow;

      if(ovlSize >= minOvl)
      {
         // OB + FVG confluence
         st.poiHigh       = ovlHigh;
         st.poiLow        = ovlLow;
         st.hasConfluence  = true;
         LogInfo(StringFormat("%s OB+FVG confluence: %.5f - %.5f (overlap=%.1f pts)",
                              st.symbol, ovlHigh, ovlLow, ovlSize / pointVal));
         return true;
      }
      else if(AllowFVGOnlyEntry)
      {
         // No overlap but FVG-only allowed
         st.poiHigh       = st.fvgHigh;
         st.poiLow        = st.fvgLow;
         st.hasConfluence  = false;
         LogInfo(StringFormat("%s FVG-only POI (no overlap): %.5f - %.5f",
                              st.symbol, st.fvgHigh, st.fvgLow));
         return true;
      }
      else
      {
         LogWarn(StringFormat("%s Setup rejected: insufficient OB/FVG overlap (%.1f pts < %.1f pts)",
                              st.symbol, ovlSize / pointVal, (double)MinOverlapPoints));
         return false;
      }
   }
   else if(st.fvgValid && AllowFVGOnlyEntry)
   {
      st.poiHigh       = st.fvgHigh;
      st.poiLow        = st.fvgLow;
      st.hasConfluence  = false;
      LogInfo(StringFormat("%s FVG-only POI (no OB): %.5f - %.5f", st.symbol, st.fvgHigh, st.fvgLow));
      return true;
   }
   else if(st.obValid && !RequireOBFVGConfluence)
   {
      st.poiHigh       = st.obHigh;
      st.poiLow        = st.obLow;
      st.hasConfluence  = false;
      LogInfo(StringFormat("%s OB-only POI (no FVG): %.5f - %.5f", st.symbol, st.obHigh, st.obLow));
      return true;
   }

   LogWarn(StringFormat("%s Setup rejected: no valid POI zone", st.symbol));
   return false;
}

//╔═══════════════════════════════════════════════════════════════════╗
//║                    RISK MANAGEMENT                               ║
//╚═══════════════════════════════════════════════════════════════════╝

// Calculate lot size based on risk percentage and SL distance
double CalculateLotSize(string sym, double riskPct, double entryPrice, double slPrice)
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt   = balance * riskPct / 100.0;
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0 || tickValue <= 0)
   {
      LogError(StringFormat("%s Invalid tick size/value: ts=%.10f tv=%.5f", sym, tickSize, tickValue));
      return 0;
   }

   double slDist       = MathAbs(entryPrice - slPrice);
   double slTicks      = slDist / tickSize;
   double lossPerLot   = slTicks * tickValue;

   if(lossPerLot <= 0) return 0;

   double lots = riskAmt / lossPerLot;
   return NormalizeLots(sym, lots);
}

// Count open positions for a given magic number and symbol
int CountPositions(string sym, long magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == magic &&
         PositionGetString(POSITION_SYMBOL) == sym)
         count++;
   }
   return count;
}

// Count all positions across all symbols for this EA
int CountAllPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      for(int s = 0; s < g_symbolCount; s++)
      {
         if(posMagic == g_states[s].magicNumber)
         { count++; break; }
      }
   }
   return count;
}

// Count pending orders for a given magic number and symbol
int CountPendingOrders(string sym, long magic)
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket <= 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) == magic &&
         OrderGetString(ORDER_SYMBOL) == sym)
         count++;
   }
   return count;
}

// Update daily P/L tracking
void UpdateDailyStats(SSymbolState &st)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int today = dt.day_of_year;

   if(st.todayDate != today)
   {
      // New day — reset
      st.todayDate       = today;
      st.dailyPnL        = 0;
      st.dailyTradeCount = 0;
      st.dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   }

   // Calculate current daily P/L from history
   datetime todayStart = StringToTime(StringFormat("%d.%02d.%02d 00:00:00", dt.year, dt.mon, dt.day));
   if(!HistorySelect(todayStart, TimeCurrent())) return;

   double closedPnL = 0;
   int dealsCount = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket <= 0) continue;
      long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);

      // Check if this deal belongs to our EA
      bool ours = false;
      for(int s = 0; s < g_symbolCount; s++)
         if(dealMagic == g_states[s].magicNumber) { ours = true; break; }

      if(ours)
      {
         closedPnL += HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +
                      HistoryDealGetDouble(dealTicket, DEAL_SWAP) +
                      HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
            dealsCount++;
      }
   }

   // Add floating P/L
   double floatingPnL = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || !PositionSelectByTicket(ticket)) continue;
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      bool ours = false;
      for(int s = 0; s < g_symbolCount; s++)
         if(posMagic == g_states[s].magicNumber) { ours = true; break; }
      if(ours) floatingPnL += PositionGetDouble(POSITION_PROFIT);
   }

   st.dailyPnL        = closedPnL + floatingPnL;
   st.dailyTradeCount = dealsCount;
}

// Check if daily loss limit has been reached
bool IsDailyLossExceeded(SSymbolState &st)
{
   if(st.dayStartBalance <= 0) return false;
   double lossPct = -st.dailyPnL / st.dayStartBalance * 100.0;
   return (lossPct >= MaxDailyLossPct && MaxDailyLossPct > 0);
}

// Comprehensive pre-trade checks
bool PreTradeChecks(string sym, double lots, double entryPrice, double slPrice, double tpPrice)
{
   // 1. Emergency stop
   if(g_emergencyStop)
   {
      LogWarn(StringFormat("%s Trade blocked: Emergency stop active", sym));
      return false;
   }

   // 2. Session filter
   if(!IsWithinSession())
   {
      LogDebug(StringFormat("%s Trade blocked: Outside trading session", sym));
      return false;
   }

   // 3. News blackout
   if(IsNewsBlackout())
   {
      LogWarn(StringFormat("%s Trade blocked: News blackout active", sym));
      return false;
   }

   // 4. Spread check
   long spread = SymbolInfoInteger(sym, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints && MaxSpreadPoints > 0)
   {
      LogWarn(StringFormat("%s Trade blocked: Spread too high (%d > %d)", sym, (int)spread, MaxSpreadPoints));
      return false;
   }

   // 5. Max open trades
   int totalPositions = CountAllPositions();
   if(totalPositions >= MaxOpenTrades)
   {
      LogWarn(StringFormat("%s Trade blocked: Max open trades reached (%d)", sym, totalPositions));
      return false;
   }

   // 6. Free margin check
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > 0 && (freeMargin / equity * 100.0) < MinFreeMarginPct)
   {
      LogWarn(StringFormat("%s Trade blocked: Free margin too low (%.1f%%)", sym, freeMargin / equity * 100.0));
      return false;
   }

   // 7. Min stop distance
   int stopsLevel = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   double point   = SymPoint(sym);
   double slDist  = MathAbs(entryPrice - slPrice) / point;
   double tpDist  = MathAbs(entryPrice - tpPrice) / point;
   if(stopsLevel > 0 && (slDist < stopsLevel || tpDist < stopsLevel))
   {
      LogWarn(StringFormat("%s Trade blocked: SL/TP too close (stops level=%d, SL=%.0f, TP=%.0f)",
                           sym, stopsLevel, slDist, tpDist));
      return false;
   }

   // 8. Freeze level
   int freezeLevel = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double priceDist = MathMin(MathAbs(ask - entryPrice), MathAbs(bid - entryPrice)) / point;
   // Only applies to pending orders that are too close to current price
   if(freezeLevel > 0 && priceDist < freezeLevel && EntryMode != ENTRY_MARKET)
   {
      LogDebug(StringFormat("%s Pending order too close to price (freeze level=%d)", sym, freezeLevel));
      // Don't block — the market will move. Just log it.
   }

   // 9. Broker trade permission
   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
   {
      LogError(StringFormat("%s Trade blocked: Symbol not tradeable", sym));
      return false;
   }

   // 10. Lot validation
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(lots < minLot || lots > maxLot)
   {
      LogWarn(StringFormat("%s Trade blocked: Invalid lot size %.4f (min=%.4f, max=%.4f)",
                           sym, lots, minLot, maxLot));
      return false;
   }

   return true;
}

//╔═══════════════════════════════════════════════════════════════════╗
//║                    ENTRY MANAGEMENT                              ║
//╚═══════════════════════════════════════════════════════════════════╝

// Calculate SL price based on OB zone
double CalculateSL(SSymbolState &st, double pointVal)
{
   if(st.bias == DIR_BEARISH)
      return st.obHigh + SLBufferPoints * pointVal;
   else
      return st.obLow - SLBufferPoints * pointVal;
}

// Calculate TP price based on mode
double CalculateTP(SSymbolState &st, double entryPrice, double slPrice, double pointVal)
{
   double slDist = MathAbs(entryPrice - slPrice);

   switch(TPMode)
   {
      case TP_RISK_REWARD:
      {
         if(st.bias == DIR_BEARISH)
            return entryPrice - slDist * RiskRewardRatio;
         else
            return entryPrice + slDist * RiskRewardRatio;
      }

      case TP_FIXED_POINTS:
      {
         if(st.bias == DIR_BEARISH)
            return entryPrice - FixedTPPoints * pointVal;
         else
            return entryPrice + FixedTPPoints * pointVal;
      }

      case TP_LIQUIDITY:
      {
         // Target the nearest opposing liquidity level
         double target = FindLiquidityTarget(st, entryPrice, pointVal);
         if(target > 0) return target;
         // Fallback to RR if no liquidity target found
         if(st.bias == DIR_BEARISH)
            return entryPrice - slDist * RiskRewardRatio;
         else
            return entryPrice + slDist * RiskRewardRatio;
      }

      case TP_HYBRID:
      {
         double liqTarget = FindLiquidityTarget(st, entryPrice, pointVal);
         double rrTarget  = (st.bias == DIR_BEARISH) ?
                            entryPrice - slDist * RiskRewardRatio :
                            entryPrice + slDist * RiskRewardRatio;
         // Use whichever is closer to entry (more conservative)
         if(liqTarget > 0)
         {
            if(st.bias == DIR_BEARISH)
               return MathMax(liqTarget, rrTarget); // Closer = higher for bearish
            else
               return MathMin(liqTarget, rrTarget);
         }
         return rrTarget;
      }
   }
   return 0;
}

// Find the nearest liquidity level as a TP target
double FindLiquidityTarget(SSymbolState &st, double entryPrice, double pointVal)
{
   double bestTarget = 0;
   double bestDist   = DBL_MAX;

   if(st.bias == DIR_BEARISH)
   {
      // Look for sell-side liquidity BELOW entry
      for(int i = 0; i < st.sellSideLiqCount; i++)
      {
         if(st.sellSideLiq[i].price < entryPrice)
         {
            double dist = entryPrice - st.sellSideLiq[i].price;
            if(dist < bestDist && dist > MinSwingDistPoints * pointVal)
            {
               bestDist   = dist;
               bestTarget = st.sellSideLiq[i].price;
            }
         }
      }
   }
   else
   {
      // Look for buy-side liquidity ABOVE entry
      for(int i = 0; i < st.buySideLiqCount; i++)
      {
         if(st.buySideLiq[i].price > entryPrice)
         {
            double dist = st.buySideLiq[i].price - entryPrice;
            if(dist < bestDist && dist > MinSwingDistPoints * pointVal)
            {
               bestDist   = dist;
               bestTarget = st.buySideLiq[i].price;
            }
         }
      }
   }
   st.targetLiqLevel = bestTarget;
   return bestTarget;
}

// Build entry plan: prices and lot sizes for split entries
void BuildEntryPlan(SSymbolState &st, double pointVal)
{
   int entries = MathMax(1, MathMin(NumberOfEntries, MAX_ENTRIES));
   st.numPlannedEntries = entries;

   double poiRange = st.poiHigh - st.poiLow;
   double midPoint = (st.poiHigh + st.poiLow) / 2.0;
   int digits = SymDigits(st.symbol);

   // Calculate entry prices distributed across the POI
   if(entries == 1)
   {
      st.entryPrices[0] = NormalizeDouble(midPoint, digits);
   }
   else
   {
      for(int i = 0; i < entries; i++)
      {
         double ratio = (double)i / (double)(entries - 1); // 0.0 to 1.0
         if(st.bias == DIR_BEARISH)
            // Bearish: entries from high (top of POI) to low
            st.entryPrices[i] = NormalizeDouble(st.poiHigh - ratio * poiRange, digits);
         else
            // Bullish: entries from low (bottom of POI) to high
            st.entryPrices[i] = NormalizeDouble(st.poiLow + ratio * poiRange, digits);
      }
   }

   // Calculate SL/TP based on middle entry
   st.slPrice = NormalizeDouble(CalculateSL(st, pointVal), digits);
   st.tpPrice = NormalizeDouble(CalculateTP(st, midPoint, st.slPrice, pointVal), digits);

   // Calculate lot sizes
   double totalRiskPct = RiskPercentPerSetup;
   double perEntryRisk = totalRiskPct / (double)entries;

   for(int i = 0; i < entries; i++)
   {
      double lots = CalculateLotSize(st.symbol, perEntryRisk, st.entryPrices[i], st.slPrice);

      // Apply volume distribution weighting
      if(VolumeDist == VOL_WEIGHTED && entries > 1)
      {
         // Weight more volume near the OB end
         double weight;
         if(st.bias == DIR_BEARISH)
            weight = 1.0 + (double)i / (double)(entries - 1); // Higher weight at top
         else
            weight = 1.0 + (1.0 - (double)i / (double)(entries - 1)); // Higher weight at bottom
         lots = NormalizeLots(st.symbol, lots * weight / 1.5);
      }

      st.entryLots[i] = lots;
   }
}

// Place pending orders for the setup
bool PlacePendingOrders(SSymbolState &st, double pointVal)
{
   g_trade.SetExpertMagicNumber(st.magicNumber);
   g_trade.SetDeviationInPoints(Slippage);
   g_trade.SetTypeFilling(GetFillType(st.symbol));

   st.orderTicketCount = 0;
   bool anyPlaced = false;

   for(int i = 0; i < st.numPlannedEntries; i++)
   {
      double entryPrice = st.entryPrices[i];
      double lots       = st.entryLots[i];

      if(lots <= 0) continue;
      if(!PreTradeChecks(st.symbol, lots, entryPrice, st.slPrice, st.tpPrice)) continue;

      string comment = StringFormat("%s_%s_%d", EAComment, DirectionToString(st.bias), i + 1);
      bool result = false;

      if(st.bias == DIR_BEARISH)
      {
         result = g_trade.SellLimit(lots, entryPrice, st.symbol,
                                    st.slPrice, st.tpPrice, ORDER_TIME_GTC, 0, comment);
      }
      else
      {
         result = g_trade.BuyLimit(lots, entryPrice, st.symbol,
                                   st.slPrice, st.tpPrice, ORDER_TIME_GTC, 0, comment);
      }

      if(result)
      {
         ulong ticket = g_trade.ResultOrder();
         if(ticket > 0 && st.orderTicketCount < MAX_ENTRIES)
         {
            st.orderTickets[st.orderTicketCount++] = ticket;
            anyPlaced = true;
            LogInfo(StringFormat("%s %s Limit #%d placed: price=%.5f lots=%.4f SL=%.5f TP=%.5f ticket=%d",
                                 st.symbol, DirectionToString(st.bias), i + 1,
                                 entryPrice, lots, st.slPrice, st.tpPrice, ticket));
         }
      }
      else
      {
         LogError(StringFormat("%s Order failed: code=%d comment=%s",
                               st.symbol, g_trade.ResultRetcode(), g_trade.ResultComment()));
      }
   }
   return anyPlaced;
}

// Execute a market entry
bool ExecuteMarketEntry(SSymbolState &st, double pointVal)
{
   g_trade.SetExpertMagicNumber(st.magicNumber);
   g_trade.SetDeviationInPoints(Slippage);
   g_trade.SetTypeFilling(GetFillType(st.symbol));

   double lots = CalculateLotSize(st.symbol, RiskPercentPerSetup, st.entryPrices[0], st.slPrice);
   if(lots <= 0) return false;
   if(!PreTradeChecks(st.symbol, lots, st.entryPrices[0], st.slPrice, st.tpPrice)) return false;

   string comment = StringFormat("%s_%s_MKT", EAComment, DirectionToString(st.bias));
   bool result = false;

   if(st.bias == DIR_BEARISH)
   {
      double bid = SymbolInfoDouble(st.symbol, SYMBOL_BID);
      result = g_trade.Sell(lots, st.symbol, bid, st.slPrice, st.tpPrice, comment);
   }
   else
   {
      double ask = SymbolInfoDouble(st.symbol, SYMBOL_ASK);
      result = g_trade.Buy(lots, st.symbol, ask, st.slPrice, st.tpPrice, comment);
   }

   if(result)
   {
      LogInfo(StringFormat("%s Market %s executed: lots=%.4f SL=%.5f TP=%.5f",
                           st.symbol, DirectionToString(st.bias), lots, st.slPrice, st.tpPrice));
      return true;
   }
   else
   {
      LogError(StringFormat("%s Market order failed: code=%d comment=%s",
                            st.symbol, g_trade.ResultRetcode(), g_trade.ResultComment()));
      return false;
   }
}

// Delete all pending orders for this symbol/magic
void DeletePendingOrders(SSymbolState &st)
{
   g_trade.SetExpertMagicNumber(st.magicNumber);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket <= 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) == st.magicNumber &&
         OrderGetString(ORDER_SYMBOL) == st.symbol)
      {
         if(g_trade.OrderDelete(ticket))
            LogInfo(StringFormat("%s Pending order %d deleted", st.symbol, ticket));
         else
            LogError(StringFormat("%s Failed to delete order %d", st.symbol, ticket));
      }
   }
   st.orderTicketCount = 0;
}

//╔═══════════════════════════════════════════════════════════════════╗
//║                POSITION MANAGEMENT                               ║
//╚═══════════════════════════════════════════════════════════════════╝

// Manage break-even: move SL to entry when profit reaches 1R
void ManageBreakEven(SSymbolState &st)
{
   if(!MoveSLToBreakEven) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != st.magicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != st.symbol) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);
      double point     = SymPoint(st.symbol);
      int    digits    = SymDigits(st.symbol);

      if((int)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         if(currentSL >= openPrice) continue; // Already at BE or better
         double bid = SymbolInfoDouble(st.symbol, SYMBOL_BID);
         double riskDist = openPrice - currentSL;
         if(riskDist <= 0) continue;

         if(bid >= openPrice + riskDist)
         {
            double newSL = NormalizeDouble(openPrice + point, digits);
            g_trade.PositionModify(ticket, newSL, tp);
            LogInfo(StringFormat("%s Buy position %d moved to break-even", st.symbol, ticket));
         }
      }
      else if((int)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
      {
         if(currentSL <= openPrice && currentSL > 0) continue;
         double ask = SymbolInfoDouble(st.symbol, SYMBOL_ASK);
         double riskDist = currentSL - openPrice;
         if(riskDist <= 0) continue;

         if(ask <= openPrice - riskDist)
         {
            double newSL = NormalizeDouble(openPrice - point, digits);
            g_trade.PositionModify(ticket, newSL, tp);
            LogInfo(StringFormat("%s Sell position %d moved to break-even", st.symbol, ticket));
         }
      }
   }
}

// Manage trailing stop
void ManageTrailingStop(SSymbolState &st)
{
   if(TrailingStopPoints <= 0) return;

   double trailDist = TrailingStopPoints * SymPoint(st.symbol);
   int digits = SymDigits(st.symbol);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != st.magicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != st.symbol) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);

      if((int)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         double bid  = SymbolInfoDouble(st.symbol, SYMBOL_BID);
         double newSL = NormalizeDouble(bid - trailDist, digits);
         if(newSL > currentSL && newSL > openPrice)
            g_trade.PositionModify(ticket, newSL, tp);
      }
      else
      {
         double ask  = SymbolInfoDouble(st.symbol, SYMBOL_ASK);
         double newSL = NormalizeDouble(ask + trailDist, digits);
         if((newSL < currentSL || currentSL == 0) && newSL < openPrice)
            g_trade.PositionModify(ticket, newSL, tp);
      }
   }
}

// Manage partial close at 1R profit
void ManagePartialClose(SSymbolState &st)
{
   if(!EnablePartialClose || st.partialCloseDone) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != st.magicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != st.symbol) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double volume    = PositionGetDouble(POSITION_VOLUME);

      double riskDist = MathAbs(openPrice - currentSL);
      if(riskDist <= 0) continue;

      bool inProfit = false;
      if((int)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(st.symbol, SYMBOL_BID);
         inProfit = (bid >= openPrice + riskDist);
      }
      else
      {
         double ask = SymbolInfoDouble(st.symbol, SYMBOL_ASK);
         inProfit = (ask <= openPrice - riskDist);
      }

      if(inProfit)
      {
         double closeVol = NormalizeLots(st.symbol, volume * PartialClosePct / 100.0);
         if(closeVol > 0 && closeVol < volume)
         {
            if(g_trade.PositionClosePartial(ticket, closeVol))
            {
               st.partialCloseDone = true;
               LogInfo(StringFormat("%s Partial close: %.4f lots of position %d", st.symbol, closeVol, ticket));
            }
         }
      }
   }
}

// Check if all positions for this setup have been closed
bool ArePositionsClosed(SSymbolState &st)
{
   return (CountPositions(st.symbol, st.magicNumber) == 0 &&
           CountPendingOrders(st.symbol, st.magicNumber) == 0);
}

//╔═══════════════════════════════════════════════════════════════════╗
//║                  VISUALIZATION MANAGER                           ║
//╚═══════════════════════════════════════════════════════════════════╝

// Helper: determine if chart drawing should proceed (skips in non-visual tester and optimization for speed)
bool ShouldDraw()
{
   if(!ShowChartObjects) return false;
   if(MQLInfoInteger(MQL_OPTIMIZATION)) return false;
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)) return false;
   return true;
}

// Helper: create a unique object name
string ObjName(SSymbolState &st, string label)
{
   st.objCounter++;
   return StringFormat("%s%s_%s_%d", EA_TAG, st.symbol, label, st.objCounter);
}

// Draw a horizontal line for a liquidity level
void DrawLiquidityLevel(SSymbolState &st, double price, bool isBuySide, datetime time)
{
   if(!ShouldDraw()) return;
   if(st.symbol != _Symbol) return; // Only draw on the chart symbol

   string name = ObjName(st, isBuySide ? "BSL" : "SSL");
   ObjectCreate(0, name, OBJ_TREND, 0, time, price, TimeCurrent(), price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, isBuySide ? ClrBuySideLiq : ClrSellSideLiq);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);
   ObjectSetString(0, name, OBJPROP_TEXT, isBuySide ? "BSL" : "SSL");
}

// Draw a rectangle for Order Block
void DrawOrderBlock(SSymbolState &st)
{
   if(!ShouldDraw() || st.symbol != _Symbol) return;
   if(!st.obValid) return;

   string name = ObjName(st, "OB");
   datetime endTime = TimeCurrent() + PeriodSeconds(LTF_Timeframe) * 20;
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, st.obTime, st.obHigh, endTime, st.obLow);
   ObjectSetInteger(0, name, OBJPROP_COLOR,
                    st.obDirection == DIR_BEARISH ? ClrBearishOB : ClrBullishOB);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetString(0, name, OBJPROP_TEXT, "ORDER BLOCK");

   // Label
   if(ShowDebugObjects)
   {
      string lblName = ObjName(st, "OB_LBL");
      ObjectCreate(0, lblName, OBJ_TEXT, 0, st.obTime, st.obHigh);
      ObjectSetString(0, lblName, OBJPROP_TEXT, "ORDER BLOCK");
      ObjectSetInteger(0, lblName, OBJPROP_COLOR,
                       st.obDirection == DIR_BEARISH ? ClrBearishOB : ClrBullishOB);
      ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 8);
   }
}

// Draw a rectangle for FVG
void DrawFVG(SSymbolState &st)
{
   if(!ShouldDraw() || st.symbol != _Symbol) return;
   if(!st.fvgValid) return;

   string name = ObjName(st, "FVG");
   datetime endTime = TimeCurrent() + PeriodSeconds(LTF_Timeframe) * 20;
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, st.fvgTime, st.fvgHigh, endTime, st.fvgLow);
   ObjectSetInteger(0, name, OBJPROP_COLOR,
                    st.fvgDirection == DIR_BEARISH ? ClrBearishFVG : ClrBullishFVG);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetString(0, name, OBJPROP_TEXT, "FVG");

   if(ShowDebugObjects)
   {
      string lblName = ObjName(st, "FVG_LBL");
      ObjectCreate(0, lblName, OBJ_TEXT, 0, st.fvgTime, st.fvgHigh);
      ObjectSetString(0, lblName, OBJPROP_TEXT, "FVG");
      ObjectSetInteger(0, lblName, OBJPROP_COLOR,
                       st.fvgDirection == DIR_BEARISH ? ClrBearishFVG : ClrBullishFVG);
      ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 8);
   }
}

// Draw confluence zone
void DrawConfluence(SSymbolState &st)
{
   if(!ShouldDraw() || st.symbol != _Symbol) return;
   if(st.poiHigh == 0 && st.poiLow == 0) return;

   string name = ObjName(st, "CONF");
   datetime endTime = TimeCurrent() + PeriodSeconds(LTF_Timeframe) * 30;
   datetime startTime = (st.fvgValid) ? st.fvgTime : st.obTime;
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, startTime, st.poiHigh, endTime, st.poiLow);
   ObjectSetInteger(0, name, OBJPROP_COLOR, ClrConfluence);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetString(0, name, OBJPROP_TEXT,
                   st.hasConfluence ? "OB+FVG CONFLUENCE" : "POI ZONE");

   // Label
   string lblName = ObjName(st, "CONF_LBL");
   ObjectCreate(0, lblName, OBJ_TEXT, 0, startTime, st.poiHigh);
   ObjectSetString(0, lblName, OBJPROP_TEXT,
                   st.hasConfluence ? "OB+FVG CONFLUENCE" :
                   (st.fvgValid ? "FVG POI" : "OB POI"));
   ObjectSetInteger(0, lblName, OBJPROP_COLOR, ClrConfluence);
   ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 9);
}

// Draw sweep marker (arrow)
void DrawSweepMarker(SSymbolState &st)
{
   if(!ShouldDraw() || st.symbol != _Symbol) return;

   string name = ObjName(st, "SWEEP");
   ObjectCreate(0, name, OBJ_ARROW, 0, st.sweepTime, st.sweepPrice);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE,
                    st.bias == DIR_BEARISH ? 218 : 217); // Down/Up arrow
   ObjectSetInteger(0, name, OBJPROP_COLOR, ClrSweepMarker);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);

   string lblName = ObjName(st, "SWEEP_LBL");
   ObjectCreate(0, lblName, OBJ_TEXT, 0, st.sweepTime, st.sweepPrice);
   ObjectSetString(0, lblName, OBJPROP_TEXT, "LIQUIDITY SWEPT");
   ObjectSetInteger(0, lblName, OBJPROP_COLOR, ClrSweepMarker);
   ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 9);
}

// Draw CHoCH level
void DrawCHoCHLine(SSymbolState &st)
{
   if(!ShouldDraw() || st.symbol != _Symbol) return;

   string name = ObjName(st, "CHOCH");
   ObjectCreate(0, name, OBJ_TREND, 0,
                st.chochTime - PeriodSeconds(LTF_Timeframe) * 10, st.chochLevel,
                st.chochTime + PeriodSeconds(LTF_Timeframe) * 10, st.chochLevel);
   ObjectSetInteger(0, name, OBJPROP_COLOR, ClrCHoCH);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASHDOTDOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);

   string lblName = ObjName(st, "CHOCH_LBL");
   ObjectCreate(0, lblName, OBJ_TEXT, 0, st.chochTime, st.chochLevel);
   ObjectSetString(0, lblName, OBJPROP_TEXT,
                   StringFormat("%s CHoCH", DirectionToString(st.bias)));
   ObjectSetInteger(0, lblName, OBJPROP_COLOR, ClrCHoCH);
   ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 9);
}

// Draw BOS level
void DrawBOSLine(SSymbolState &st)
{
   if(!ShouldDraw() || st.symbol != _Symbol) return;
   if(st.bosLevel == 0) return;

   string name = ObjName(st, "BOS");
   ObjectCreate(0, name, OBJ_TREND, 0,
                st.bosTime - PeriodSeconds(LTF_Timeframe) * 10, st.bosLevel,
                st.bosTime + PeriodSeconds(LTF_Timeframe) * 10, st.bosLevel);
   ObjectSetInteger(0, name, OBJPROP_COLOR, ClrBOS);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASHDOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);

   string lblName = ObjName(st, "BOS_LBL");
   ObjectCreate(0, lblName, OBJ_TEXT, 0, st.bosTime, st.bosLevel);
   ObjectSetString(0, lblName, OBJPROP_TEXT,
                   StringFormat("%s BOS", DirectionToString(st.bias)));
   ObjectSetInteger(0, lblName, OBJPROP_COLOR, ClrBOS);
   ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 9);
}

// Draw entry level lines
void DrawEntryLevels(SSymbolState &st)
{
   if(!ShouldDraw() || st.symbol != _Symbol) return;

   for(int i = 0; i < st.numPlannedEntries; i++)
   {
      string name = ObjName(st, StringFormat("ENTRY_%d", i));
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, st.entryPrices[i]);
      ObjectSetInteger(0, name, OBJPROP_COLOR, ClrConfluence);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   }

   // SL line
   string slName = ObjName(st, "SL");
   ObjectCreate(0, slName, OBJ_HLINE, 0, 0, st.slPrice);
   ObjectSetInteger(0, slName, OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, slName, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, slName, OBJPROP_WIDTH, 1);

   // TP line
   string tpName = ObjName(st, "TP");
   ObjectCreate(0, tpName, OBJ_HLINE, 0, 0, st.tpPrice);
   ObjectSetInteger(0, tpName, OBJPROP_COLOR, clrLimeGreen);
   ObjectSetInteger(0, tpName, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, tpName, OBJPROP_WIDTH, 1);
}

// Cleanup all EA objects from chart
void CleanupObjects(string sym)
{
   string prefix = EA_TAG + sym + "_";
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
   {
      string objName = ObjectName(0, i);
      if(StringFind(objName, prefix) == 0 || StringFind(objName, EA_TAG) == 0)
         ObjectDelete(0, objName);
   }
   // Also clean dashboard
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
   {
      string objName = ObjectName(0, i);
      if(StringFind(objName, DASH_TAG) == 0)
         ObjectDelete(0, objName);
   }
}

//╔═══════════════════════════════════════════════════════════════════╗
//║                    DASHBOARD PANEL                               ║
//╚═══════════════════════════════════════════════════════════════════╝

// Dashboard label helper
void DashLabel(string name, int x, int y, string text, color clr, int fontSize = 9)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
}

// Create/update the dashboard
void UpdateDashboard(SSymbolState &st)
{
   if(!ShowDashboard) return;
   if(MQLInfoInteger(MQL_OPTIMIZATION)) return;
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)) return;
   if(st.symbol != _Symbol) return; // Only on chart symbol

   // Throttle to 1 update per second
   datetime now = TimeCurrent();
   if(now == g_lastDashUpdate) return;
   g_lastDashUpdate = now;

   int panelX = 10, panelY = 25;
   int panelW = 310, panelH = 390;

   // Background
   string bgName = DASH_TAG + "BG";
   if(ObjectFind(0, bgName) < 0)
   {
      ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bgName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, clrDimGray);
      ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
   }
   ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, panelX);
   ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, panelY);
   ObjectSetInteger(0, bgName, OBJPROP_XSIZE, panelW);
   ObjectSetInteger(0, bgName, OBJPROP_YSIZE, panelH);
   ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, ClrDashBG);

   int x = panelX + 10;
   int y = panelY + 8;
   int lineH = 22;
   int row = 0;

   // Title
   DashLabel(DASH_TAG+"T0", x, y + lineH * row, "╔═ SMC LIQUIDITY EA ═╗", ClrDashAccent, 11);
   row++;

   // Separator
   DashLabel(DASH_TAG+"S0", x, y + lineH * row, "───────────────────────────", clrDimGray, 8);
   row++;

   // Status
   DashLabel(DASH_TAG+"R1", x, y + lineH * row,
             StringFormat("State:  %s", StateToString(st.currentState)),
             ClrDashText);
   row++;

   // Symbol & Bias
   color biasClr = st.bias == DIR_BULLISH ? clrLime :
                   (st.bias == DIR_BEARISH ? clrOrangeRed : clrGray);
   DashLabel(DASH_TAG+"R2", x, y + lineH * row,
             StringFormat("Symbol: %s  │  Bias: %s", st.symbol, DirectionToString(st.bias)),
             biasClr);
   row++;

   // Separator
   DashLabel(DASH_TAG+"S1", x, y + lineH * row, "───────────────────────────", clrDimGray, 8);
   row++;

   // Status indicators
   string liqSt  = (st.currentState > STATE_WAITING_FOR_LIQUIDITY) ? "✓" :  "⏳";
   string chochSt = (st.currentState >= STATE_CHOCH_CONFIRMED) ? "✓" :
                    (st.currentState == STATE_WAITING_FOR_CHOCH ? "⏳" : "—");
   string bosSt  = (st.currentState >= STATE_BOS_CONFIRMED) ? "✓" :
                   (st.currentState == STATE_WAITING_FOR_BOS ? "⏳" : "—");
   string obSt   = st.obValid ? "✓" : "—";
   string fvgSt  = st.fvgValid ? "✓" : "—";
   string confSt = (st.currentState >= STATE_CONFLUENCE_CONFIRMED) ? "✓" : "—";

   DashLabel(DASH_TAG+"R3", x, y + lineH * row,
             StringFormat("Liquidity:  %s  │  CHoCH: %s", liqSt, chochSt),
             ClrDashText);
   row++;
   DashLabel(DASH_TAG+"R4", x, y + lineH * row,
             StringFormat("BOS:        %s  │  OB:    %s", bosSt, obSt),
             ClrDashText);
   row++;
   DashLabel(DASH_TAG+"R5", x, y + lineH * row,
             StringFormat("FVG:        %s  │  Conf:  %s", fvgSt, confSt),
             ClrDashText);
   row++;

   // Separator
   DashLabel(DASH_TAG+"S2", x, y + lineH * row, "───────────────────────────", clrDimGray, 8);
   row++;

   // Key levels
   if(st.poiHigh > 0)
   {
      DashLabel(DASH_TAG+"R6", x, y + lineH * row,
                StringFormat("POI:  %.5f - %.5f", st.poiHigh, st.poiLow),
                ClrConfluence);
      row++;
   }
   if(st.slPrice > 0)
   {
      DashLabel(DASH_TAG+"R7", x, y + lineH * row,
                StringFormat("SL: %.5f  │  TP: %.5f", st.slPrice, st.tpPrice),
                ClrDashText);
      row++;
   }

   // Separator
   DashLabel(DASH_TAG+"S3", x, y + lineH * row, "───────────────────────────", clrDimGray, 8);
   row++;

   // Trade stats
   int openPos = CountPositions(st.symbol, st.magicNumber);
   int pendOrd = CountPendingOrders(st.symbol, st.magicNumber);
   DashLabel(DASH_TAG+"R8", x, y + lineH * row,
             StringFormat("Positions: %d  │  Pending: %d", openPos, pendOrd),
             ClrDashText);
   row++;

   color pnlClr = st.dailyPnL >= 0 ? clrLime : clrOrangeRed;
   DashLabel(DASH_TAG+"R9", x, y + lineH * row,
             StringFormat("Daily P/L: %.2f", st.dailyPnL),
             pnlClr);
   row++;

   DashLabel(DASH_TAG+"R10", x, y + lineH * row,
             StringFormat("Trades Today: %d / %d", st.dailyTradeCount, MaxDailyTrades),
             ClrDashText);
   row++;

   // Spread info
   long spread = SymbolInfoInteger(st.symbol, SYMBOL_SPREAD);
   color spreadClr = (spread <= MaxSpreadPoints || MaxSpreadPoints <= 0) ? ClrDashText : clrOrangeRed;
   DashLabel(DASH_TAG+"R11", x, y + lineH * row,
             StringFormat("Spread: %d pts  │  Max: %d", (int)spread, MaxSpreadPoints),
             spreadClr);
   row++;

   // HTF/LTF info
   DashLabel(DASH_TAG+"R12", x, y + lineH * row,
             StringFormat("HTF: %s  │  LTF: %s",
                          EnumToString(HTF_Timeframe), EnumToString(LTF_Timeframe)),
             clrDimGray);
   row++;

   // Resize panel to fit content
   ObjectSetInteger(0, bgName, OBJPROP_YSIZE, (row + 1) * lineH + 5);

   ChartRedraw(0);
}

//╔═══════════════════════════════════════════════════════════════════╗
//║                 STATE MACHINE — RESET                            ║
//╚═══════════════════════════════════════════════════════════════════╝

// Reset all active setup data in the state, keeping symbol identity and
// persistent data (daily stats, processed IDs, counters).
void ResetSetup(SSymbolState &st)
{
   st.currentState     = STATE_WAITING_FOR_LIQUIDITY;
   st.bias             = DIR_NONE;
   st.liquidityLevel   = 0;
   st.sweepPrice       = 0;
   st.sweepTime        = 0;
   st.chochLevel       = 0;
   st.chochBar         = 0;
   st.chochTime        = 0;
   st.bosLevel         = 0;
   st.bosBar           = 0;
   st.bosTime          = 0;
   st.displacementBar  = -1;
   st.obHigh           = 0;
   st.obLow            = 0;
   st.obTime           = 0;
   st.obDirection      = DIR_NONE;
   st.obValid          = false;
   st.fvgHigh          = 0;
   st.fvgLow           = 0;
   st.fvgTime          = 0;
   st.fvgDirection     = DIR_NONE;
   st.fvgValid         = false;
   st.poiHigh          = 0;
   st.poiLow           = 0;
   st.hasConfluence    = false;
   st.numPlannedEntries= 0;
   st.orderTicketCount = 0;
   st.slPrice          = 0;
   st.tpPrice          = 0;
   st.setupStartTime   = 0;
   st.partialCloseDone = false;
   st.targetLiqLevel   = 0;
}

//╔═══════════════════════════════════════════════════════════════════╗
//║           MAIN STATE MACHINE — ProcessSymbol()                   ║
//╚═══════════════════════════════════════════════════════════════════╝

void ProcessSymbol(int si)
{
   string sym   = g_states[si].symbol;
   double point = SymPoint(sym);
   int    digits= SymDigits(sym);

   // Update daily stats
   UpdateDailyStats(g_states[si]);

   // Check daily loss
   if(IsDailyLossExceeded(g_states[si]))
   {
      if(g_states[si].currentState == STATE_ORDERS_PLACED)
      {
         DeletePendingOrders(g_states[si]);
         g_states[si].currentState = STATE_SETUP_INVALIDATED;
         LogWarn(StringFormat("%s Daily loss limit reached — orders cancelled", sym));
      }
      else if(g_states[si].currentState < STATE_POSITION_ACTIVE)
      {
         g_states[si].currentState = STATE_SETUP_INVALIDATED;
      }
      // Don't close active positions on daily loss — just prevent new ones
   }

   // New bar checks
   bool newHTFBar = IsNewBar(sym, HTF_Timeframe, g_states[si].htfLastBarTime);
   bool newLTFBar = IsNewBar(sym, LTF_Timeframe, g_states[si].ltfLastBarTime);

   // Copy HTF rates (on new HTF bar or when needed)
   MqlRates htfRates[];
   int htfCount = 0;
   ArraySetAsSeries(htfRates, true);
   if(newHTFBar || g_states[si].currentState == STATE_WAITING_FOR_LIQUIDITY)
   {
      htfCount = CopyRates(sym, HTF_Timeframe, 0, SwingLookback + HTFSwingStrength + 10, htfRates);
   }

   // Copy LTF rates
   MqlRates ltfRates[];
   int ltfCount = 0;
   ArraySetAsSeries(ltfRates, true);
   if(newLTFBar || g_states[si].currentState >= STATE_WAITING_FOR_CHOCH)
   {
      int ltfBarsNeeded = SwingLookback + LTFSwingStrength + 10;
      ltfCount = CopyRates(sym, LTF_Timeframe, 0, ltfBarsNeeded, ltfRates);
   }

   // Get ATR value on LTF
   if(g_states[si].atrHandleLTF != INVALID_HANDLE && ltfCount > 0)
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(g_states[si].atrHandleLTF, 0, 0, 3, atrBuf) >= 1)
         g_states[si].currentATR_LTF = atrBuf[1]; // Use last completed bar's ATR
   }

   // State machine — process with fall-through for instantaneous transitions
   bool stateChanged = true;
   int maxIterations = 10; // Prevent infinite loops

   while(stateChanged && maxIterations-- > 0)
   {
      stateChanged = false;

      switch(g_states[si].currentState)
      {
         //───────────────────────────────────────────────────
         case STATE_WAITING_FOR_LIQUIDITY:
         {
            if(htfCount < HTFSwingStrength * 2 + 5) break;

            // Detect HTF swings
            DetectSwings(htfRates, htfCount, HTFSwingStrength,
                         g_states[si].htfSwingHighs, g_states[si].htfSwingHighCount,
                         g_states[si].htfSwingLows,  g_states[si].htfSwingLowCount,
                         point, MAX_SWINGS);

            if(g_states[si].htfSwingHighCount == 0 && g_states[si].htfSwingLowCount == 0) break;

            // Build liquidity levels
            BuildLiquidityLevels(g_states[si], point);

            // Draw liquidity levels on chart
            if(ShowChartObjects && sym == _Symbol)
            {
               for(int l = 0; l < g_states[si].buySideLiqCount; l++)
                  DrawLiquidityLevel(g_states[si], g_states[si].buySideLiq[l].price,
                                     true, g_states[si].buySideLiq[l].time);
               for(int l = 0; l < g_states[si].sellSideLiqCount; l++)
                  DrawLiquidityLevel(g_states[si], g_states[si].sellSideLiq[l].price,
                                     false, g_states[si].sellSideLiq[l].time);
            }

            // Check for sweep
            if(CheckLiquiditySweep(g_states[si], htfRates, htfCount, point))
            {
               g_states[si].currentState = STATE_LIQUIDITY_SWEPT;
               stateChanged = true;
            }
            break;
         }

         //───────────────────────────────────────────────────
         case STATE_LIQUIDITY_SWEPT:
         {
            // Draw sweep marker
            DrawSweepMarker(g_states[si]);

            // Immediately transition to waiting for CHoCH
            g_states[si].currentState = STATE_WAITING_FOR_CHOCH;
            stateChanged = true;
            break;
         }

         //───────────────────────────────────────────────────
         case STATE_WAITING_FOR_CHOCH:
         {
            if(!newLTFBar || ltfCount < LTFSwingStrength * 2 + 5) break;

            // Check expiry
            int age = BarsElapsed(sym, LTF_Timeframe, g_states[si].setupStartTime);
            if(age > SetupExpirationBars)
            {
               LogInfo(StringFormat("%s Setup expired while waiting for CHoCH (age=%d bars)", sym, age));
               g_states[si].currentState = STATE_SETUP_INVALIDATED;
               stateChanged = true;
               break;
            }

            // Detect LTF swings
            DetectSwings(ltfRates, ltfCount, LTFSwingStrength,
                         g_states[si].ltfSwingHighs, g_states[si].ltfSwingHighCount,
                         g_states[si].ltfSwingLows,  g_states[si].ltfSwingLowCount,
                         point, MAX_SWINGS);

            // Check for CHoCH
            if(DetectCHoCH(g_states[si], ltfRates, ltfCount, point))
            {
               g_states[si].currentState = STATE_CHOCH_CONFIRMED;
               stateChanged = true;
            }
            break;
         }

         //───────────────────────────────────────────────────
         case STATE_CHOCH_CONFIRMED:
         {
            DrawCHoCHLine(g_states[si]);

            if(RequireSecondBOS)
            {
               g_states[si].currentState = STATE_WAITING_FOR_BOS;
               LogInfo(StringFormat("%s Waiting for BOS confirmation", sym));
            }
            else
            {
               g_states[si].currentState = STATE_BOS_CONFIRMED;
               LogInfo(StringFormat("%s BOS not required — proceeding to OB detection", sym));
            }
            stateChanged = true;
            break;
         }

         //───────────────────────────────────────────────────
         case STATE_WAITING_FOR_BOS:
         {
            if(!newLTFBar || ltfCount < LTFSwingStrength * 2 + 5) break;

            int age = BarsElapsed(sym, LTF_Timeframe, g_states[si].setupStartTime);
            if(age > SetupExpirationBars)
            {
               LogInfo(StringFormat("%s Setup expired while waiting for BOS", sym));
               g_states[si].currentState = STATE_SETUP_INVALIDATED;
               stateChanged = true;
               break;
            }

            // Re-detect LTF swings
            DetectSwings(ltfRates, ltfCount, LTFSwingStrength,
                         g_states[si].ltfSwingHighs, g_states[si].ltfSwingHighCount,
                         g_states[si].ltfSwingLows,  g_states[si].ltfSwingLowCount,
                         point, MAX_SWINGS);

            if(DetectBOS(g_states[si], ltfRates, ltfCount, point))
            {
               g_states[si].currentState = STATE_BOS_CONFIRMED;
               stateChanged = true;
            }
            break;
         }

         //───────────────────────────────────────────────────
         case STATE_BOS_CONFIRMED:
         {
            DrawBOSLine(g_states[si]);
            g_states[si].currentState = STATE_IDENTIFYING_OB;
            stateChanged = true;
            break;
         }

         //───────────────────────────────────────────────────
         case STATE_IDENTIFYING_OB:
         {
            // Need LTF rates for OB detection
            if(ltfCount < 5)
            {
               int needed = SwingLookback + LTFSwingStrength + 10;
               ltfCount = CopyRates(sym, LTF_Timeframe, 0, needed, ltfRates);
               ArraySetAsSeries(ltfRates, true);
            }

            if(DetectOrderBlock(g_states[si], ltfRates, ltfCount, point))
            {
               // Validate OB age
               int obAge = BarsElapsed(sym, LTF_Timeframe, g_states[si].obTime);
               if(obAge <= OBMaxAgeBars)
               {
                  DrawOrderBlock(g_states[si]);
                  g_states[si].currentState = STATE_IDENTIFYING_FVG;
                  stateChanged = true;
               }
               else
               {
                  LogWarn(StringFormat("%s OB too old (%d bars > %d max)", sym, obAge, OBMaxAgeBars));
                  g_states[si].obValid = false;
                  g_states[si].currentState = STATE_SETUP_INVALIDATED;
                  stateChanged = true;
               }
            }
            else
            {
               g_states[si].currentState = STATE_SETUP_INVALIDATED;
               stateChanged = true;
            }
            break;
         }

         //───────────────────────────────────────────────────
         case STATE_IDENTIFYING_FVG:
         {
            if(ltfCount < 5)
            {
               int needed = SwingLookback + LTFSwingStrength + 10;
               ltfCount = CopyRates(sym, LTF_Timeframe, 0, needed, ltfRates);
               ArraySetAsSeries(ltfRates, true);
            }

            bool fvgFound = DetectFVG(g_states[si], ltfRates, ltfCount, point);
            if(fvgFound) DrawFVG(g_states[si]);

            // Check confluence
            if(CheckConfluence(g_states[si], point))
            {
               DrawConfluence(g_states[si]);
               g_states[si].currentState = STATE_CONFLUENCE_CONFIRMED;
               stateChanged = true;
            }
            else
            {
               g_states[si].currentState = STATE_SETUP_INVALIDATED;
               stateChanged = true;
            }
            break;
         }

         //───────────────────────────────────────────────────
         case STATE_CONFLUENCE_CONFIRMED:
         {
            // Build entry plan
            BuildEntryPlan(g_states[si], point);

            // Generate and check setup ID for duplicates
            string setupId = GenerateSetupId(g_states[si]);
            if(IsSetupProcessed(g_states[si], setupId))
            {
               LogDebug(StringFormat("%s Duplicate setup rejected: %s", sym, setupId));
               g_states[si].currentState = STATE_SETUP_INVALIDATED;
               stateChanged = true;
               break;
            }
            MarkSetupProcessed(g_states[si], setupId);

            LogInfo(StringFormat("%s Setup confirmed: %s POI=%.5f-%.5f SL=%.5f TP=%.5f",
                                 sym, DirectionToString(g_states[si].bias),
                                 g_states[si].poiHigh, g_states[si].poiLow,
                                 g_states[si].slPrice, g_states[si].tpPrice));

            g_states[si].currentState = STATE_WAITING_FOR_RETEST;
            stateChanged = true;
            break;
         }

         //───────────────────────────────────────────────────
         case STATE_WAITING_FOR_RETEST:
         {
            // Check expiry
            int age = BarsElapsed(sym, LTF_Timeframe, g_states[si].setupStartTime);
            if(age > SetupExpirationBars)
            {
               LogInfo(StringFormat("%s Setup expired while waiting for retest", sym));
               g_states[si].currentState = STATE_SETUP_INVALIDATED;
               stateChanged = true;
               break;
            }

            // Check if POI has been invalidated (price broke through OB in wrong direction)
            double bid = SymbolInfoDouble(sym, SYMBOL_BID);
            double ask = SymbolInfoDouble(sym, SYMBOL_ASK);

            if(g_states[si].bias == DIR_BEARISH)
            {
               // If price goes significantly above the OB, invalidate
               if(ask > g_states[si].obHigh + SLBufferPoints * point * 2)
               {
                  LogInfo(StringFormat("%s POI invalidated: price above OB", sym));
                  g_states[si].currentState = STATE_SETUP_INVALIDATED;
                  stateChanged = true;
                  break;
               }
            }
            else
            {
               if(bid < g_states[si].obLow - SLBufferPoints * point * 2)
               {
                  LogInfo(StringFormat("%s POI invalidated: price below OB", sym));
                  g_states[si].currentState = STATE_SETUP_INVALIDATED;
                  stateChanged = true;
                  break;
               }
            }

            // Entry logic based on mode
            if(EntryMode == ENTRY_PENDING || EntryMode == ENTRY_HYBRID)
            {
               DrawEntryLevels(g_states[si]);
               if(PlacePendingOrders(g_states[si], point))
               {
                  g_states[si].currentState = STATE_ORDERS_PLACED;
                  stateChanged = true;
               }
               else
               {
                  LogWarn(StringFormat("%s Failed to place pending orders", sym));
                  g_states[si].currentState = STATE_SETUP_INVALIDATED;
                  stateChanged = true;
               }
            }
            else // ENTRY_MARKET
            {
               // Wait for price to enter the POI zone
               bool priceInZone = false;
               if(g_states[si].bias == DIR_BEARISH)
                  priceInZone = (bid >= g_states[si].poiLow && bid <= g_states[si].poiHigh);
               else
                  priceInZone = (ask >= g_states[si].poiLow && ask <= g_states[si].poiHigh);

               if(priceInZone)
               {
                  DrawEntryLevels(g_states[si]);
                  if(ExecuteMarketEntry(g_states[si], point))
                  {
                     g_states[si].currentState = STATE_POSITION_ACTIVE;
                     stateChanged = true;
                  }
                  else
                  {
                     g_states[si].currentState = STATE_SETUP_INVALIDATED;
                     stateChanged = true;
                  }
               }
            }
            break;
         }

         //───────────────────────────────────────────────────
         case STATE_ORDERS_PLACED:
         {
            // Check expiry
            int age = BarsElapsed(sym, LTF_Timeframe, g_states[si].setupStartTime);
            if(age > SetupExpirationBars)
            {
               LogInfo(StringFormat("%s Setup expired with pending orders", sym));
               DeletePendingOrders(g_states[si]);
               g_states[si].currentState = STATE_SETUP_INVALIDATED;
               stateChanged = true;
               break;
            }

            // Check if POI invalidated
            double bid = SymbolInfoDouble(sym, SYMBOL_BID);
            double ask = SymbolInfoDouble(sym, SYMBOL_ASK);

            if(g_states[si].bias == DIR_BEARISH &&
               ask > g_states[si].obHigh + SLBufferPoints * point * 2)
            {
               LogInfo(StringFormat("%s POI invalidated — deleting pending orders", sym));
               DeletePendingOrders(g_states[si]);
               g_states[si].currentState = STATE_SETUP_INVALIDATED;
               stateChanged = true;
               break;
            }
            else if(g_states[si].bias == DIR_BULLISH &&
                    bid < g_states[si].obLow - SLBufferPoints * point * 2)
            {
               LogInfo(StringFormat("%s POI invalidated — deleting pending orders", sym));
               DeletePendingOrders(g_states[si]);
               g_states[si].currentState = STATE_SETUP_INVALIDATED;
               stateChanged = true;
               break;
            }

            // Check if any orders have been filled (positions exist)
            if(CountPositions(sym, g_states[si].magicNumber) > 0)
            {
               LogInfo(StringFormat("%s Pending order filled — position active", sym));
               g_states[si].currentState = STATE_POSITION_ACTIVE;
               stateChanged = true;
            }
            // Check if all pending orders are gone (deleted externally)
            else if(CountPendingOrders(sym, g_states[si].magicNumber) == 0)
            {
               LogWarn(StringFormat("%s All pending orders removed externally", sym));
               g_states[si].currentState = STATE_SETUP_INVALIDATED;
               stateChanged = true;
            }
            break;
         }

         //───────────────────────────────────────────────────
         case STATE_POSITION_ACTIVE:
         {
            // Delete remaining pending orders if any
            if(CountPendingOrders(sym, g_states[si].magicNumber) > 0)
               DeletePendingOrders(g_states[si]);

            // Manage active positions
            ManageBreakEven(g_states[si]);
            ManagePartialClose(g_states[si]);
            ManageTrailingStop(g_states[si]);

            // Check if all positions are closed
            if(CountPositions(sym, g_states[si].magicNumber) == 0)
            {
               // Determine if target was reached or SL hit
               // Use the daily P/L change as a proxy
               LogInfo(StringFormat("%s All positions closed — setup complete", sym));
               g_states[si].currentState = STATE_TARGET_REACHED;
               stateChanged = true;
            }
            break;
         }

         //───────────────────────────────────────────────────
         case STATE_TARGET_REACHED:
         {
            LogInfo(StringFormat("%s ═══ Setup cycle complete ═══", sym));
            g_states[si].currentState = STATE_RESET;
            stateChanged = true;
            break;
         }

         //───────────────────────────────────────────────────
         case STATE_SETUP_INVALIDATED:
         {
            // Clean up any pending orders
            DeletePendingOrders(g_states[si]);
            LogInfo(StringFormat("%s Setup invalidated — resetting", sym));
            g_states[si].currentState = STATE_RESET;
            stateChanged = true;
            break;
         }

         //───────────────────────────────────────────────────
         case STATE_RESET:
         {
            ResetSetup(g_states[si]);
            LogDebug(StringFormat("%s State machine reset — scanning for new setup", sym));
            // Don't set stateChanged — let the next tick handle the new scan
            break;
         }
      }
   }

   // Update dashboard
   UpdateDashboard(g_states[si]);
}

//╔═══════════════════════════════════════════════════════════════════╗
//║                    EVENT HANDLERS                                ║
//╚═══════════════════════════════════════════════════════════════════╝

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   // Validate inputs
   if(HTF_Timeframe <= LTF_Timeframe)
   {
      LogError("HTF must be greater than LTF timeframe");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(RiskPercentPerSetup <= 0 || RiskPercentPerSetup > 100)
   {
      LogError("Invalid RiskPercentPerSetup");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(NumberOfEntries < 1 || NumberOfEntries > MAX_ENTRIES)
   {
      LogError(StringFormat("NumberOfEntries must be 1-%d", MAX_ENTRIES));
      return INIT_PARAMETERS_INCORRECT;
   }

   // Initialize symbol list
   g_symbolCount = 0;

   // Always include chart symbol
   g_states[0].symbol = _Symbol;
   g_states[0].magicNumber = MagicNumber;
   g_symbolCount = 1;

   // Parse additional symbols if multi-symbol enabled
   if(EnableMultiSymbol && StringLen(SymbolList) > 0)
   {
      string symbols[];
      int count = StringSplit(SymbolList, ',', symbols);
      for(int i = 0; i < count && g_symbolCount < MAX_SYMBOLS; i++)
      {
         string sym = symbols[i];
         StringTrimLeft(sym);
         StringTrimRight(sym);
         if(StringLen(sym) == 0) continue;
         if(sym == _Symbol) continue; // Already added

         // Verify symbol exists
         if(!SymbolSelect(sym, true))
         {
            LogWarn(StringFormat("Symbol %s not found — skipping", sym));
            continue;
         }

         g_states[g_symbolCount].symbol      = sym;
         g_states[g_symbolCount].magicNumber  = MagicNumber + g_symbolCount * 100;
         g_symbolCount++;
      }
   }

   // Initialize each symbol state
   for(int i = 0; i < g_symbolCount; i++)
   {
      ResetSetup(g_states[i]);
      g_states[i].htfLastBarTime    = 0;
      g_states[i].ltfLastBarTime    = 0;
      g_states[i].htfSwingHighCount = 0;
      g_states[i].htfSwingLowCount  = 0;
      g_states[i].ltfSwingHighCount = 0;
      g_states[i].ltfSwingLowCount  = 0;
      g_states[i].buySideLiqCount   = 0;
      g_states[i].sellSideLiqCount  = 0;
      g_states[i].dailyPnL          = 0;
      g_states[i].dailyTradeCount   = 0;
      g_states[i].dayStartBalance   = AccountInfoDouble(ACCOUNT_BALANCE);
      g_states[i].todayDate         = 0;
      g_states[i].processedIdCount  = 0;
      g_states[i].objCounter        = 0;

      // Create ATR handles
      g_states[i].atrHandleLTF = iATR(g_states[i].symbol, LTF_Timeframe, ATRPeriod);
      g_states[i].atrHandleHTF = iATR(g_states[i].symbol, HTF_Timeframe, ATRPeriod);

      if(g_states[i].atrHandleLTF == INVALID_HANDLE ||
         g_states[i].atrHandleHTF == INVALID_HANDLE)
      {
         LogError(StringFormat("Failed to create ATR handle for %s", g_states[i].symbol));
         return INIT_FAILED;
      }

      LogInfo(StringFormat("Initialized %s (magic=%d)", g_states[i].symbol, g_states[i].magicNumber));
   }

   // Configure trade object
   g_trade.SetExpertMagicNumber(MagicNumber);
   g_trade.SetDeviationInPoints(Slippage);
   g_trade.SetTypeFilling(GetFillType(_Symbol));
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   // Set timer for multi-symbol processing and dashboard updates
   EventSetMillisecondTimer(500);

   LogInfo(StringFormat("═══ SMC Liquidity EA initialized ═══ Symbols: %d | HTF: %s | LTF: %s",
                         g_symbolCount, EnumToString(HTF_Timeframe), EnumToString(LTF_Timeframe)));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   // Release indicator handles
   for(int i = 0; i < g_symbolCount; i++)
   {
      if(g_states[i].atrHandleLTF != INVALID_HANDLE)
         IndicatorRelease(g_states[i].atrHandleLTF);
      if(g_states[i].atrHandleHTF != INVALID_HANDLE)
         IndicatorRelease(g_states[i].atrHandleHTF);
   }

   // Clean up chart objects
   CleanupObjects(_Symbol);

   LogInfo(StringFormat("═══ SMC Liquidity EA removed (reason=%d) ═══", reason));
}

//+------------------------------------------------------------------+
//| Expert tick handler                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   if(g_emergencyStop) return;

   // Process chart symbol on every tick
   ProcessSymbol(0);
}

//+------------------------------------------------------------------+
//| Timer handler — multi-symbol processing and dashboard             |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(g_emergencyStop) return;

   // Process additional symbols (if multi-symbol enabled)
   for(int i = 1; i < g_symbolCount; i++)
      ProcessSymbol(i);
}

//+------------------------------------------------------------------+
//| Trade transaction handler                                         |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   // Log significant trade events
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      // A deal was added — check if it's ours
      ulong dealTicket = trans.deal;
      if(dealTicket > 0)
      {
         HistoryDealSelect(dealTicket);
         long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);

         for(int s = 0; s < g_symbolCount; s++)
         {
            if(dealMagic == g_states[s].magicNumber)
            {
               double dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
               ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
               string dealSymbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);

               if(dealEntry == DEAL_ENTRY_IN)
                  LogInfo(StringFormat("%s Position opened (deal %d)", dealSymbol, dealTicket));
               else if(dealEntry == DEAL_ENTRY_OUT)
                  LogInfo(StringFormat("%s Position closed (deal %d, profit=%.2f)",
                                       dealSymbol, dealTicket, dealProfit));
               break;
            }
         }
      }
   }
   else if(trans.type == TRADE_TRANSACTION_ORDER_DELETE)
   {
      // An order was deleted or expired
      LogDebug(StringFormat("Order %d deleted/expired", trans.order));
   }
}
//+------------------------------------------------------------------+
