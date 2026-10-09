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
   STATE_WAITING_FOR_LIQUIDITY,   // Waiting For Liquidity (PDH/PDL or Swings)
   STATE_LIQUIDITY_SWEPT,         // Liquidity Swept + Rejected
   STATE_WAITING_FOR_CHOCH,       // Waiting For 15M Displacement / CHoCH
   STATE_CHOCH_CONFIRMED,         // Displacement / CHoCH Confirmed
   STATE_WAITING_FOR_BOS,         // Waiting For BOS
   STATE_BOS_CONFIRMED,           // BOS Confirmed
   STATE_IDENTIFYING_OB,          // Identifying Order Block
   STATE_IDENTIFYING_FVG,         // Identifying FVG
   STATE_CONFLUENCE_CONFIRMED,    // Confluence Confirmed (15M POI established)
   STATE_WAITING_FOR_RETEST,      // Waiting For POI Retest
   STATE_WAITING_FOR_LTF_CONFIRM, // Waiting For 1M/3M/5M Confirmation
   STATE_ORDERS_PLACED,           // Orders Placed
   STATE_POSITION_ACTIVE,         // Position Active
   STATE_TARGET_REACHED,          // Target Reached
   STATE_SETUP_INVALIDATED,       // Setup Invalidated
   STATE_RESET                    // Reset
};

enum ENUM_LIQUIDITY_SOURCE
{
   LIQ_PREVIOUS_DAY_HL,    // Previous Day High/Low (PDH / PDL - Default)
   LIQ_SWING_HIGHS_LOWS,   // HTF Swing Highs & Lows
   LIQ_BOTH                // Both PDH/PDL and HTF Swings
};

enum ENUM_LTF_CONFIRMATION
{
   CONFIRM_LTF_REJECTION,       // POI Rejection Candle (Wick/Engulfing)
   CONFIRM_LTF_CHOCH,           // Micro CHoCH / Market Structure Shift
   CONFIRM_LTF_ANY              // Any (Rejection Candle or Micro CHoCH)
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

enum ENUM_LOT_TYPE
{
   LOT_FIXED,        // Fixed Lot Size (Directly Adjustable)
   LOT_RISK_PERCENT  // Risk-Based Dynamic Lot (% of Account Balance)
};

enum ENUM_TP_MODE
{
   TP_OPPOSING_OB_OR_LIQ, // Opposing 15M OB or Liquidity (Nearest Obstacle - Recommended)
   TP_OPPOSING_15M_OB,    // Opposing 15M Order Block Primary
   TP_LIQUIDITY,          // External Liquidity Target (PDL/PDH / Swings)
   TP_RISK_REWARD,        // Risk:Reward Ratio
   TP_FIXED_POINTS,       // Fixed Points
   TP_HYBRID              // Hybrid (RR + Liquidity)
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
   datetime          d1LastBarTime;
   datetime          htfLastBarTime;
   datetime          ltfLastBarTime;

   // ATR handles
   int               atrHandleLTF;
   int               atrHandleHTF;
   double            currentATR_LTF;
   double            currentATR_HTF;

   // Previous Day High & Low (External Liquidity - Rules 1, 2, 3)
   double            pdhPrice;         // Previous Day High (Buy-Side Liquidity)
   double            pdlPrice;         // Previous Day Low (Sell-Side Liquidity)
   datetime          pdhTime;          // Time of completed D1 candle
   datetime          pdlTime;
   bool              pdhSwept;         // Has PDH been swept
   bool              pdlSwept;         // Has PDL been swept
   datetime          pdhSweepTime;
   datetime          pdlSweepTime;
   bool              pdhConsumed;      // Marked consumed if trade hits SL (Rule 7)
   bool              pdlConsumed;      // Marked consumed if trade hits SL (Rule 7)

   // Anti-Re-Entry After Stop Loss (Rule 7)
   datetime          lastFailedSweepTime;
   double            lastFailedSweepPrice;
   ENUM_DIRECTION    lastFailedBias;

   // POI Retest Tracking (Rule 5)
   bool              poiRetested;
   datetime          poiRetestTime;

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

   // Active Setup — Sweep (Rules 2, 3)
   double            liquidityLevel;
   double            sweepPrice;
   datetime          sweepTime;
   int               sweepBar;
   bool              isPDHSweep;
   bool              isPDLSweep;

   // Active Setup — 15M Displacement & Structure (Rule 4)
   double            chochLevel;
   int               chochBar;
   datetime          chochTime;
   double            bosLevel;
   int               bosBar;
   datetime          bosTime;
   int               displacementBar;
   datetime          displacementTime;
   double            displacementSize;

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
   bool              beActivated;      // Has structural break-even been activated (at >= $0.50 profit)
   double            beHighestProfit;  // Highest floating profit recorded for active trade

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

input group "══════ Timeframes (Client Sequence) ══════"
input ENUM_TIMEFRAMES Setup_Timeframe          = PERIOD_M15;    // Setup Timeframe (15M Liquidity Sweep)
input ENUM_TIMEFRAMES Structure_Timeframe      = PERIOD_M5;     // Structure Timeframe (5M CHOCH, Displacement, OB, FVG)
input ENUM_TIMEFRAMES Entry_Timeframe          = PERIOD_M5;     // Entry Confirmation Timeframe (1M, 3M, 5M)

#define HTF_Timeframe Setup_Timeframe
#define LTF_Timeframe Entry_Timeframe

input group "══════ Liquidity Source (PDH / PDL) ══════"
input ENUM_LIQUIDITY_SOURCE LiquiditySource    = LIQ_PREVIOUS_DAY_HL; // Liquidity Source (PDH/PDL or Swings)
input bool            StrictDailySweep         = true;                // Strictly Within Current Daily Candle Sweep
input bool            ShowPDH_PDL_Lines        = true;                // Draw Previous Day High/Low Lines
input color           ClrPDH                   = clrDodgerBlue;       // PDH (Buy-Side Liquidity) Color
input color           ClrPDL                   = clrOrangeRed;        // PDL (Sell-Side Liquidity) Color

input group "══════ Lower-Timeframe Entry (1M/3M/5M) ══════"
input ENUM_LTF_CONFIRMATION LTFConfirmationMethod = CONFIRM_LTF_ANY;  // LTF Confirmation (Rejection/CHoCH/Any)
input int             MaxRetestWaitBars        = 50;                  // Max Bars To Wait For POI Retest

input group "══════ Strict No-Re-Entry Rule (Rule 2) ══════"
input bool            BlockReEntryAfterSL      = true;                // Lock/Consume Setup After Trade (No Re-entry)

input group "══════ Swing Detection ══════"
input int             SwingLookback            = 100;           // HTF Bars To Scan
input int             HTFSwingStrength         = 2;             // HTF Swing Strength (bars each side)
input int             LTFSwingStrength         = 1;             // LTF Swing Strength (bars each side)
input int             MinSwingDistPoints       = 30;            // Min Swing Distance (points)
input int             LiquidityTolPoints       = 10;            // Equal High/Low Tolerance (points)

input group "══════ Liquidity Sweep ══════"
input int             SweepBufferPoints        = 2;             // Sweep Buffer (points above/below)
input int             MinSweepDistPoints       = 3;             // Min Sweep Penetration (points)
input ENUM_SWEEP_MODE SweepConfirmationMode    = SWEEP_WICK_ONLY; // Sweep Confirmation
input int             SweepLookbackBars        = 20;            // Sweep Check Window (HTF bars)

input group "══════ Structure (CHoCH) ══════"
input ENUM_BREAK_METHOD StructureBreakMethod   = BREAK_WICK;        // Break Confirmation Method
input int             MinBreakDistPoints       = 3;             // Min Break Distance (points)
input double          MinDisplacementATR       = 0.1;           // Min Displacement (× ATR)
input int             ATRPeriod                = 14;            // ATR Period

input group "══════ BOS ══════"
input bool            RequireSecondBOS         = false;         // Require Additional BOS
input int             BOSMinDistPoints         = 3;             // BOS Min Distance (points)
input ENUM_BREAK_METHOD BOSBreakMethod         = BREAK_BODY_CLOSE;  // BOS Confirmation Method

input group "══════ Order Block ══════"
input int             OBLookbackCandles        = 10;            // OB Lookback (candles before displacement)
input bool            OBUseBodyOnly            = false;         // Use Body Only (vs Full Candle)
input int             OBMinSizePoints          = 3;             // OB Min Size (points)
input int             OBMaxAgeBars             = 500;           // OB Max Age (LTF bars)

input group "══════ Fair Value Gap ══════"
input int             MinFVGSizePoints         = 3;             // FVG Min Size (points)
input int             MaxFVGSizePoints         = 1000;          // FVG Max Size (points)
input double          FVGMitigationPct         = 70.0;          // FVG Mitigation % (invalidation)
input int             FVGExpiryBars            = 300;           // FVG Expiry (LTF bars)

input group "══════ Confluence ══════"
input bool            RequireOBFVGConfluence   = false;         // Require OB+FVG Overlap
input int             MinOverlapPoints         = 2;             // Min Overlap Size (points)
input bool            AllowFVGOnlyEntry        = true;          // Allow FVG-Only Entry

input group "══════ Entry & Risk Management (Rule 5) ══════"
input ENUM_ENTRY_MODE EntryMode                = ENTRY_MARKET;  // Entry Mode (MARKET, PENDING, HYBRID)
input int             NumberOfEntries          = 1;             // Active Positions Per Setup (Strictly 1 Position)
input ENUM_VOLUME_DIST VolumeDist              = VOL_EQUAL;     // Volume Distribution

input group "══════ Capital Protection ══════"
input int             SLBufferPoints           = 20;            // Protection Buffer Beyond POI (points)

input group "══════ Take Profit (Rule 3) ══════"
input ENUM_TP_MODE    TPMode                   = TP_OPPOSING_OB_OR_LIQ; // TP Target Method (Opposing 15M OB / Liquidity)
input double          RiskRewardRatio          = 2.0;           // Risk:Reward Ratio (Fallback)
input int             FixedTPPoints            = 500;           // Fixed TP (points)

input group "══════ Lot Size & Risk Management (Adjustable) ══════"
input ENUM_LOT_TYPE   LotType                  = LOT_FIXED;     // Lot Mode (Fixed Lot / Risk %)
input double          FixedLotSize             = 0.01;          // Adjustable Lot Size (e.g. 0.01, 0.05, 0.1, 1.0)
input double          RiskPercentPerSetup      = 1.0;           // Risk % Per Trade (if using Risk %)
input bool            UseFixedLot              = true;          // [Legacy] Use Fixed Lot
input double          MaxAccountRiskPct        = 5.0;           // Max Total Account Risk %
input int             MaxOpenTrades            = 10;            // Max Simultaneous Open Trades
input double          DailyRiskLimitPct        = 5.0;           // Daily Risk Limit %
input int             MaxDailyTrades           = 20;            // Max Daily Trades

input group "══════ Structural Break-Even Protection (Rule 4) ══════"
input bool            EnableBreakEvenProtection= true;          // Enable Break-Even Protection
input double          BEProfitUSD              = 0.50;          // Floating Profit Trigger ($ USD, e.g. $0.50)
input ENUM_TIMEFRAMES BE_Structure_Timeframe   = PERIOD_M1;     // Structural Swing Timeframe (1M or 3M)
input int             BEBufferPoints           = 5;             // BE Buffer Points Beyond Entry
input int             BESwingLookback          = 25;            // Structural Swing Lookback Bars
input bool            MoveSLToBreakEven        = true;          // [Legacy] Move SL to Break-Even at 1R
input int             TrailingStopPoints       = 0;             // Trailing Stop (points, 0=off)
input bool            EnablePartialClose       = false;         // Enable Partial Close
input double          PartialClosePct          = 50.0;          // Partial Close % of Volume

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
input int             MaxSpreadPoints          = 0;             // Max Allowed Spread (points, 0=off)
input int             Slippage                 = 10;            // Max Slippage (points)
input double          MinFreeMarginPct         = 50.0;          // Min Free Margin %

input group "══════ Setup Expiry ══════"
input int             SetupExpirationBars      = 2000;          // Setup Expiry (LTF bars)

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
      case STATE_WAITING_FOR_CHOCH:     return "WAIT_15M_DISP";
      case STATE_CHOCH_CONFIRMED:       return "DISP_OK";
      case STATE_WAITING_FOR_BOS:       return "WAIT_BOS";
      case STATE_BOS_CONFIRMED:         return "BOS_OK";
      case STATE_IDENTIFYING_OB:        return "ID_OB";
      case STATE_IDENTIFYING_FVG:       return "ID_FVG";
      case STATE_CONFLUENCE_CONFIRMED:  return "POI_READY";
      case STATE_WAITING_FOR_RETEST:    return "WAIT_RETEST";
      case STATE_WAITING_FOR_LTF_CONFIRM: return "WAIT_LTF_CONF";
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

//--- Forward declarations
void DrawPreviousDayHLLevels(SSymbolState &st);

//+------------------------------------------------------------------+
//| Update Previous Day High & Low from completed Daily candle (bar 1)|
//| Rule 1: High/Low of completed Daily candle = External Liquidity   |
//+------------------------------------------------------------------+
void UpdatePreviousDayHL(SSymbolState &st)
{
   MqlRates d1Rates[];
   ArraySetAsSeries(d1Rates, true);
   // Copy bar 1 on Daily (completed daily candle)
   if(CopyRates(st.symbol, PERIOD_D1, 1, 2, d1Rates) >= 1)
   {
      if(d1Rates[0].time != st.pdhTime)
      {
         st.pdhPrice     = d1Rates[0].high;
         st.pdlPrice     = d1Rates[0].low;
         st.pdhTime      = d1Rates[0].time;
         st.pdlTime      = d1Rates[0].time;
         st.pdhSwept     = false;
         st.pdlSwept     = false;
         st.pdhConsumed  = false;
         st.pdlConsumed  = false;
         st.lastFailedSweepTime = 0;

         LogInfo(StringFormat("%s [D1 Liquidity Updated] PDH (Buy-Side Liq)=%.5f | PDL (Sell-Side Liq)=%.5f (Date: %s)",
                              st.symbol, st.pdhPrice, st.pdlPrice, TimeToString(st.pdhTime, TIME_DATE)));

         if(ShowPDH_PDL_Lines && st.symbol == _Symbol)
            DrawPreviousDayHLLevels(st);
      }
   }
}

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
// Rules 1, 2, 3: 15M sweep of Previous Day High / Low with rejection.
// Returns true if a sweep + rejection is detected and populates setup details.
// IMPORTANT: The sweep itself does NOT trigger an entry!
bool CheckLiquiditySweep(SSymbolState &st, MqlRates &htfRates[], int htfCount, double pointVal)
{
   double sweepBuf = SweepBufferPoints * pointVal;
   double minSweep = MinSweepDistPoints * pointVal;

   datetime currentDayStart = iTime(st.symbol, PERIOD_D1, 0);
   if(currentDayStart == 0)
      currentDayStart = st.d1LastBarTime + PeriodSeconds(PERIOD_D1);

   // 1. Check Previous Day High & Low (External Liquidity - Primary Client Method)
   if(LiquiditySource == LIQ_PREVIOUS_DAY_HL || LiquiditySource == LIQ_BOTH)
   {
      // Check Buy-Side Liquidity Sweep (PDH) -> SELL SETUP
      if(st.pdhPrice > 0)
      {
         double level = st.pdhPrice;
         for(int b = 1; b <= SweepLookbackBars && b < htfCount; b++)
         {
            // Strict Daily Filter: Must be within current daily candle
            if(StrictDailySweep && htfRates[b].time < currentDayStart) break;

            if(BlockReEntryAfterSL)
            {
               // Skip the exact candle that caused the failed trade
               if(st.lastFailedSweepTime == htfRates[b].time) continue;
               // If PDH was already consumed, require a brand new higher sweep above the failed sweep extreme
               if(st.pdhConsumed && (st.lastFailedSweepPrice > 0 && htfRates[b].high <= st.lastFailedSweepPrice + minSweep)) continue;
            }

            double penetration = htfRates[b].high - level;
            if(penetration < sweepBuf) continue;

            bool sweptAndRejected = false;
            // Sweep + rejection: wicks above PDH, and closes back below PDH
            if(htfRates[b].high > level + sweepBuf && htfRates[b].close <= level)
               sweptAndRejected = true;
            else if(b >= 2 && htfRates[b].high > level + sweepBuf && htfRates[b - 1].close < level)
               sweptAndRejected = true;

            if(sweptAndRejected)
            {
               st.bias           = DIR_BEARISH;
               st.liquidityLevel = level;
               st.sweepPrice     = htfRates[b].high;
               st.sweepTime      = htfRates[b].time;
               st.sweepBar       = b;
               st.isPDHSweep     = true;
               st.isPDLSweep     = false;
               st.pdhSwept       = true;
               st.pdhConsumed    = false; // Reset on valid new sweep
               st.setupStartTime = TimeCurrent();

               LogInfo(StringFormat("%s [15M PDH SWEEP (TODAY)] Buy-side swept at %.5f (high=%.5f, bar=%d, time=%s) -> SELL SETUP (Waiting for 5M Displacement & POI)",
                                    st.symbol, level, htfRates[b].high, b, TimeToString(htfRates[b].time, TIME_MINUTES)));
               return true;
            }
         }
      }

      // Check Sell-Side Liquidity Sweep (PDL) -> BUY SETUP
      if(st.pdlPrice > 0)
      {
         double level = st.pdlPrice;
         for(int b = 1; b <= SweepLookbackBars && b < htfCount; b++)
         {
            // Strict Daily Filter: Must be within current daily candle
            if(StrictDailySweep && htfRates[b].time < currentDayStart) break;

            if(BlockReEntryAfterSL)
            {
               // Skip the exact candle that caused the failed trade
               if(st.lastFailedSweepTime == htfRates[b].time) continue;
               // If PDL was already consumed, require a brand new lower sweep below the failed sweep extreme
               if(st.pdlConsumed && (st.lastFailedSweepPrice > 0 && htfRates[b].low >= st.lastFailedSweepPrice - minSweep)) continue;
            }

            double penetration = level - htfRates[b].low;
            if(penetration < sweepBuf) continue;

            bool sweptAndRejected = false;
            // Sweep + rejection: wicks below PDL, and closes back above PDL
            if(htfRates[b].low < level - sweepBuf && htfRates[b].close >= level)
               sweptAndRejected = true;
            else if(b >= 2 && htfRates[b].low < level - sweepBuf && htfRates[b - 1].close > level)
               sweptAndRejected = true;

            if(sweptAndRejected)
            {
               st.bias           = DIR_BULLISH;
               st.liquidityLevel = level;
               st.sweepPrice     = htfRates[b].low;
               st.sweepTime      = htfRates[b].time;
               st.sweepBar       = b;
               st.isPDHSweep     = false;
               st.isPDLSweep     = true;
               st.pdlSwept       = true;
               st.pdlConsumed    = false; // Reset on valid new sweep
               st.setupStartTime = TimeCurrent();

               LogInfo(StringFormat("%s [15M PDL SWEEP + REJECTION] Sell-side swept at %.5f (low=%.5f, bar=%d) -> BUY SETUP (Waiting for 15M Displacement)",
                                    st.symbol, level, htfRates[b].low, b));
               return true;
            }
         }
      }
   }

   // 2. Check Swing Highs / Lows if configured
   if(LiquiditySource == LIQ_SWING_HIGHS_LOWS || (LiquiditySource == LIQ_BOTH && st.bias == DIR_NONE))
   {
      // Check buy-side sweeps (→ bearish bias)
      for(int l = 0; l < st.buySideLiqCount; l++)
      {
         if(st.buySideLiq[l].swept) continue;
         double level = st.buySideLiq[l].price;

         for(int b = 1; b <= SweepLookbackBars && b < htfCount; b++)
         {
            if(StrictDailySweep && htfRates[b].time < currentDayStart) break;
            if(BlockReEntryAfterSL && st.lastFailedSweepTime == htfRates[b].time) continue;
            double penetration = htfRates[b].high - level;
            if(penetration < sweepBuf) continue;

            bool swept = (htfRates[b].high > level + sweepBuf) && (htfRates[b].close <= level);
            if(swept)
            {
               st.buySideLiq[l].swept     = true;
               st.buySideLiq[l].sweepTime = htfRates[b].time;
               st.buySideLiq[l].sweepPrice= htfRates[b].high;

               st.bias            = DIR_BEARISH;
               st.liquidityLevel  = level;
               st.sweepPrice      = htfRates[b].high;
               st.sweepTime       = htfRates[b].time;
               st.sweepBar        = b;
               st.isPDHSweep      = false;
               st.isPDLSweep      = false;
               st.setupStartTime  = TimeCurrent();

               LogInfo(StringFormat("%s Buy-side swing swept at %.5f (high=%.5f)",
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

         for(int b = 1; b <= SweepLookbackBars && b < htfCount; b++)
         {
            if(StrictDailySweep && htfRates[b].time < currentDayStart) break;
            if(BlockReEntryAfterSL && st.lastFailedSweepTime == htfRates[b].time) continue;
            double penetration = level - htfRates[b].low;
            if(penetration < sweepBuf) continue;

            bool swept = (htfRates[b].low < level - sweepBuf) && (htfRates[b].close >= level);
            if(swept)
            {
               st.sellSideLiq[l].swept     = true;
               st.sellSideLiq[l].sweepTime = htfRates[b].time;
               st.sellSideLiq[l].sweepPrice= htfRates[b].low;

               st.bias            = DIR_BULLISH;
               st.liquidityLevel  = level;
               st.sweepPrice      = htfRates[b].low;
               st.sweepTime       = htfRates[b].time;
               st.sweepBar        = b;
               st.isPDHSweep      = false;
               st.isPDLSweep      = false;
               st.setupStartTime  = TimeCurrent();

               LogInfo(StringFormat("%s Sell-side swing swept at %.5f (low=%.5f)",
                                   st.symbol, level, htfRates[b].low));
               return true;
            }
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Detect Structure Displacement & POI (OB / FVG / CHoCH) (Rule 1)   |
//| Evaluates on Structure_Timeframe (e.g. 5M CHOCH, Displacement)   |
//+------------------------------------------------------------------+
bool DetectStructureDisplacementAndPOI(SSymbolState &st, ENUM_TIMEFRAMES tf, double pointVal)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int needed = 60;
   int count = CopyRates(st.symbol, tf, 0, needed, rates);
   if(count < 5) return false;

   // Calculate ATR on structure timeframe
   double sumATR = 0;
   int atrPeriod = MathMin(14, count - 2);
   for(int i = 1; i <= atrPeriod; i++)
   {
      double tr = MathMax(rates[i].high - rates[i].low, 
                  MathMax(MathAbs(rates[i].high - rates[i + 1].close), 
                          MathAbs(rates[i].low - rates[i + 1].close)));
      sumATR += tr;
   }
   double tfATR = (atrPeriod > 0) ? (sumATR / (double)atrPeriod) : (10 * pointVal);
   double minDisp = MinDisplacementATR * tfATR;
   if(minDisp <= 0) minDisp = 3 * pointVal;

   // Scan bars formed after or during the sweep (rates[b].time >= st.sweepTime)
   int startBar = -1;
   for(int i = 1; i < count; i++)
   {
      if(rates[i].time <= st.sweepTime)
      {
         startBar = i;
         break;
      }
   }
   if(startBar < 1) startBar = MathMin(count - 2, 20);

   for(int b = startBar; b >= 1; b--)
   {
      if(st.bias == DIR_BEARISH)
      {
         bool isBearish = (rates[b].close < rates[b].open);
         double bodySize = rates[b].open - rates[b].close;

         if(isBearish && (bodySize >= minDisp || bodySize >= 3 * pointVal))
         {
            // Structural displacement check (breaking previous low / MSS / CHOCH)
            double refLow = (b + 1 < count) ? rates[b + 1].low : rates[b].open;
            if(b + 2 < count && rates[b + 2].low < refLow) refLow = rates[b + 2].low;

            // Check FVG creation
            bool createdFVG = false;
            if(b + 1 < count && b - 1 >= 0)
            {
               double gapH = rates[b + 1].low;
               double gapL = rates[b - 1].high;
               if(gapH > gapL + MinFVGSizePoints * pointVal)
               {
                  createdFVG = true;
                  st.fvgHigh = gapH;
                  st.fvgLow  = gapL;
                  st.fvgTime = rates[b].time;
                  st.fvgDirection = DIR_BEARISH;
                  st.fvgValid = true;
               }
            }

            // Check Order Block creation (last bullish candle before displacement)
            bool createdOB = false;
            for(int obIdx = b + 1; obIdx <= b + OBLookbackCandles && obIdx < count; obIdx++)
            {
               if(rates[obIdx].close > rates[obIdx].open)
               {
                  st.obHigh      = OBUseBodyOnly ? MathMax(rates[obIdx].open, rates[obIdx].close) : rates[obIdx].high;
                  st.obLow       = OBUseBodyOnly ? MathMin(rates[obIdx].open, rates[obIdx].close) : rates[obIdx].low;
                  st.obTime      = rates[obIdx].time;
                  st.obDirection = DIR_BEARISH;
                  st.obValid     = true;
                  createdOB      = true;
                  break;
               }
            }

            // Fallback OB
            if(!createdOB && b + 1 < count)
            {
               st.obHigh      = rates[b + 1].high;
               st.obLow       = rates[b + 1].low;
               st.obTime      = rates[b + 1].time;
               st.obDirection = DIR_BEARISH;
               st.obValid     = true;
               createdOB      = true;
            }

            st.displacementBar  = b;
            st.displacementTime = rates[b].time;
            st.displacementSize = bodySize;
            st.chochBar         = b;
            st.chochTime        = rates[b].time;
            st.chochLevel       = refLow;

            // Establish POI
            if(st.obValid && st.fvgValid)
            {
               st.poiHigh = MathMin(st.obHigh, st.fvgHigh);
               st.poiLow  = MathMax(st.obLow,  st.fvgLow);
               if(st.poiHigh <= st.poiLow)
               {
                  st.poiHigh = MathMax(st.obHigh, st.fvgHigh);
                  st.poiLow  = MathMin(st.obLow,  st.fvgLow);
               }
               st.hasConfluence = true;
            }
            else if(st.obValid)
            {
               st.poiHigh = st.obHigh;
               st.poiLow  = st.obLow;
               st.hasConfluence = false;
            }
            else if(st.fvgValid)
            {
               st.poiHigh = st.fvgHigh;
               st.poiLow  = st.fvgLow;
               st.hasConfluence = false;
            }
            else
            {
               st.poiHigh = rates[b].open;
               st.poiLow  = (rates[b].open + rates[b].close) / 2.0;
               st.hasConfluence = false;
            }

            LogInfo(StringFormat("%s [%s BEARISH DISPLACEMENT & CHOCH] Bar %d body=%.3f (min=%.3f). POI [%.5f - %.5f]",
                                 st.symbol, EnumToString(tf), b, bodySize, minDisp, st.poiLow, st.poiHigh));
            return true;
         }
      }
      else if(st.bias == DIR_BULLISH)
      {
         bool isBullish = (rates[b].close > rates[b].open);
         double bodySize = rates[b].close - rates[b].open;

         if(isBullish && (bodySize >= minDisp || bodySize >= 3 * pointVal))
         {
            // Structural displacement check (breaking previous high / MSS / CHOCH)
            double refHigh = (b + 1 < count) ? rates[b + 1].high : rates[b].open;
            if(b + 2 < count && rates[b + 2].high > refHigh) refHigh = rates[b + 2].high;

            // Check FVG creation
            bool createdFVG = false;
            if(b + 1 < count && b - 1 >= 0)
            {
               double gapH = rates[b - 1].low;
               double gapL = rates[b + 1].high;
               if(gapH > gapL + MinFVGSizePoints * pointVal)
               {
                  createdFVG = true;
                  st.fvgHigh = gapH;
                  st.fvgLow  = gapL;
                  st.fvgTime = rates[b].time;
                  st.fvgDirection = DIR_BULLISH;
                  st.fvgValid = true;
               }
            }

            // Check Order Block creation (last bearish candle before displacement)
            bool createdOB = false;
            for(int obIdx = b + 1; obIdx <= b + OBLookbackCandles && obIdx < count; obIdx++)
            {
               if(rates[obIdx].close < rates[obIdx].open)
               {
                  st.obHigh      = OBUseBodyOnly ? MathMax(rates[obIdx].open, rates[obIdx].close) : rates[obIdx].high;
                  st.obLow       = OBUseBodyOnly ? MathMin(rates[obIdx].open, rates[obIdx].close) : rates[obIdx].low;
                  st.obTime      = rates[obIdx].time;
                  st.obDirection = DIR_BULLISH;
                  st.obValid     = true;
                  createdOB      = true;
                  break;
               }
            }

            // Fallback OB
            if(!createdOB && b + 1 < count)
            {
               st.obHigh      = rates[b + 1].high;
               st.obLow       = rates[b + 1].low;
               st.obTime      = rates[b + 1].time;
               st.obDirection = DIR_BULLISH;
               st.obValid     = true;
               createdOB      = true;
            }

            st.displacementBar  = b;
            st.displacementTime = rates[b].time;
            st.displacementSize = bodySize;
            st.chochBar         = b;
            st.chochTime        = rates[b].time;
            st.chochLevel       = refHigh;

            // Establish POI
            if(st.obValid && st.fvgValid)
            {
               st.poiHigh = MathMin(st.obHigh, st.fvgHigh);
               st.poiLow  = MathMax(st.obLow,  st.fvgLow);
               if(st.poiHigh <= st.poiLow)
               {
                  st.poiHigh = MathMax(st.obHigh, st.fvgHigh);
                  st.poiLow  = MathMin(st.obLow,  st.fvgLow);
               }
               st.hasConfluence = true;
            }
            else if(st.obValid)
            {
               st.poiHigh = st.obHigh;
               st.poiLow  = st.obLow;
               st.hasConfluence = false;
            }
            else if(st.fvgValid)
            {
               st.poiHigh = st.fvgHigh;
               st.poiLow  = st.fvgLow;
               st.hasConfluence = false;
            }
            else
            {
               st.poiHigh = (rates[b].open + rates[b].close) / 2.0;
               st.poiLow  = rates[b].open;
               st.hasConfluence = false;
            }

            LogInfo(StringFormat("%s [%s BULLISH DISPLACEMENT & CHOCH] Bar %d body=%.3f (min=%.3f). POI [%.5f - %.5f]",
                                 st.symbol, EnumToString(tf), b, bodySize, minDisp, st.poiLow, st.poiHigh));
            return true;
         }
      }
   }
   return false;
}

// Backward-compatibility wrapper
bool Detect15MDisplacementAndPOI(SSymbolState &st, MqlRates &htfRates[], int htfCount, double pointVal)
{
   return DetectStructureDisplacementAndPOI(st, Structure_Timeframe, pointVal);
}

//+------------------------------------------------------------------+
//| Check if price has returned to the 15M POI (Rule 5)              |
//+------------------------------------------------------------------+
bool CheckPOIRetest(SSymbolState &st, double bid, double ask, double pointVal)
{
   if(st.poiHigh <= 0 || st.poiLow <= 0) return false;

   double poiTolerance = 2 * pointVal;

   if(st.bias == DIR_BEARISH)
   {
      // Bearish setup: price retraces up into POI
      if(ask >= st.poiLow - poiTolerance)
         return true;
   }
   else if(st.bias == DIR_BULLISH)
   {
      // Bullish setup: price retraces down into POI
      if(bid <= st.poiHigh + poiTolerance)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Refined Lower Timeframe Confirmation (1M/3M/5M) (Rule 6)          |
//+------------------------------------------------------------------+
bool CheckLTFConfirmation(SSymbolState &st, MqlRates &ltfRates[], int ltfCount, double pointVal)
{
   if(ltfCount < 3) return false;

   double high1  = ltfRates[1].high;
   double low1   = ltfRates[1].low;
   double open1  = ltfRates[1].open;
   double close1 = ltfRates[1].close;
   double range1 = high1 - low1;
   if(range1 <= 0) range1 = pointVal;

   if(st.bias == DIR_BEARISH)
   {
      // Candle must interact with the POI
      if(high1 < st.poiLow - 5 * pointVal) return false;

      // Rejection check: upper wick >= 25% or bearish engulfing or close in lower half
      double upperWick = high1 - MathMax(open1, close1);
      bool isBearish   = (close1 < open1);
      bool wickRej     = (upperWick >= range1 * 0.25);
      bool engulfing   = (isBearish && close1 < ltfRates[2].low);
      bool lowerHalf   = (close1 <= low1 + range1 * 0.5);

      bool rejOk       = (wickRej || engulfing || (isBearish && lowerHalf));

      // Micro CHoCH / MSS check: bar 1 closed below bar 2 low
      bool chochOk     = (close1 < ltfRates[2].low - pointVal);

      switch(LTFConfirmationMethod)
      {
         case CONFIRM_LTF_REJECTION: return rejOk;
         case CONFIRM_LTF_CHOCH:     return chochOk;
         case CONFIRM_LTF_ANY:       return (rejOk || chochOk);
      }
   }
   else if(st.bias == DIR_BULLISH)
   {
      // Candle must interact with the POI
      if(low1 > st.poiHigh + 5 * pointVal) return false;

      // Rejection check: lower wick >= 25% or bullish engulfing or close in upper half
      double lowerWick = MathMin(open1, close1) - low1;
      bool isBullish   = (close1 > open1);
      bool wickRej     = (lowerWick >= range1 * 0.25);
      bool engulfing   = (isBullish && close1 > ltfRates[2].high);
      bool upperHalf   = (close1 >= low1 + range1 * 0.5);

      bool rejOk       = (wickRej || engulfing || (isBullish && upperHalf));

      // Micro CHoCH / MSS check: bar 1 closed above bar 2 high
      bool chochOk     = (close1 > ltfRates[2].high + pointVal);

      switch(LTFConfirmationMethod)
      {
         case CONFIRM_LTF_REJECTION: return rejOk;
         case CONFIRM_LTF_CHOCH:     return chochOk;
         case CONFIRM_LTF_ANY:       return (rejOk || chochOk);
      }
   }
   return false;
}

//╔═══════════════════════════════════════════════════════════════════╗
//║               CHoCH DETECTION (Change of Character)              ║
//╚═══════════════════════════════════════════════════════════════════╝

// Detect CHoCH on LTF after a liquidity sweep.
// SIMPLE & AGGRESSIVE: Check if bar 1 made a lower low (bearish) or higher high (bullish)
// compared to recent bars. Uses small lookback for frequent signals on Gold.
bool DetectCHoCH(SSymbolState &st, MqlRates &ltfRates[], int ltfCount, double pointVal)
{
   double minBreak = MinBreakDistPoints * pointVal;
   if(ltfCount < 5) return false;

   double reqBody = MinDisplacementATR * st.currentATR_LTF;
   if(reqBody <= 0) reqBody = 5 * pointVal;

   if(st.bias == DIR_BEARISH)
   {
      // Method 1: Bar 1 made a lower low than bars 2-5 (new 5-bar low)
      for(int ref = 2; ref <= MathMin(5, ltfCount - 1); ref++)
      {
         if(ltfRates[1].low < ltfRates[ref].low - minBreak)
         {
            bool isBearish = (ltfRates[1].close < ltfRates[1].open);
            double bodySize = MathAbs(ltfRates[1].close - ltfRates[1].open);

            if(isBearish && (bodySize >= reqBody || bodySize >= 2 * pointVal))
            {
               st.chochLevel       = ltfRates[ref].low;
               st.chochBar         = 1;
               st.chochTime        = ltfRates[1].time;
               st.displacementBar  = 1;

               LogInfo(StringFormat("%s BEARISH CHoCH: bar1 low=%.3f broke below bar%d low=%.3f (body=%.3f)",
                                    st.symbol, ltfRates[1].low, ref, ltfRates[ref].low, bodySize));
               return true;
            }
         }
      }
      
      // Method 2: Bar 2 made a lower low than bars 3-6 
      for(int ref = 3; ref <= MathMin(6, ltfCount - 1); ref++)
      {
         if(ltfRates[2].low < ltfRates[ref].low - minBreak)
         {
            bool isBearish = (ltfRates[2].close < ltfRates[2].open);
            double bodySize = MathAbs(ltfRates[2].close - ltfRates[2].open);

            if(isBearish && (bodySize >= reqBody || bodySize >= 2 * pointVal))
            {
               st.chochLevel       = ltfRates[ref].low;
               st.chochBar         = 2;
               st.chochTime        = ltfRates[2].time;
               st.displacementBar  = 2;

               LogInfo(StringFormat("%s BEARISH CHoCH: bar2 low=%.3f broke below bar%d low=%.3f",
                                    st.symbol, ltfRates[2].low, ref, ltfRates[ref].low));
               return true;
            }
         }
      }

      // Method 3: Break of recent confirmed LTF swing low
      for(int s = 0; s < st.ltfSwingLowCount; s++)
      {
         if(st.ltfSwingLows[s].barIndex >= 2 && st.ltfSwingLows[s].barIndex <= 25)
         {
            double swLow = st.ltfSwingLows[s].price;
            if(ltfRates[1].low < swLow - minBreak || ltfRates[2].low < swLow - minBreak)
            {
               int bIdx = (ltfRates[1].low < swLow - minBreak) ? 1 : 2;
               st.chochLevel       = swLow;
               st.chochBar         = bIdx;
               st.chochTime        = ltfRates[bIdx].time;
               st.displacementBar  = bIdx;

               LogInfo(StringFormat("%s BEARISH CHoCH (swing): bar%d low broke below swing low %.3f",
                                    st.symbol, bIdx, swLow));
               return true;
            }
         }
      }
   }
   else if(st.bias == DIR_BULLISH)
   {
      // Method 1: Bar 1 made a higher high than bars 2-5
      for(int ref = 2; ref <= MathMin(5, ltfCount - 1); ref++)
      {
         if(ltfRates[1].high > ltfRates[ref].high + minBreak)
         {
            bool isBullish = (ltfRates[1].close > ltfRates[1].open);
            double bodySize = MathAbs(ltfRates[1].close - ltfRates[1].open);

            if(isBullish && (bodySize >= reqBody || bodySize >= 2 * pointVal))
            {
               st.chochLevel       = ltfRates[ref].high;
               st.chochBar         = 1;
               st.chochTime        = ltfRates[1].time;
               st.displacementBar  = 1;

               LogInfo(StringFormat("%s BULLISH CHoCH: bar1 high=%.3f broke above bar%d high=%.3f (body=%.3f)",
                                    st.symbol, ltfRates[1].high, ref, ltfRates[ref].high, bodySize));
               return true;
            }
         }
      }
      
      // Method 2: Bar 2 made a higher high than bars 3-6
      for(int ref = 3; ref <= MathMin(6, ltfCount - 1); ref++)
      {
         if(ltfRates[2].high > ltfRates[ref].high + minBreak)
         {
            bool isBullish = (ltfRates[2].close > ltfRates[2].open);
            double bodySize = MathAbs(ltfRates[2].close - ltfRates[2].open);

            if(isBullish && (bodySize >= reqBody || bodySize >= 2 * pointVal))
            {
               st.chochLevel       = ltfRates[ref].high;
               st.chochBar         = 2;
               st.chochTime        = ltfRates[2].time;
               st.displacementBar  = 2;

               LogInfo(StringFormat("%s BULLISH CHoCH: bar2 high=%.3f broke above bar%d high=%.3f",
                                    st.symbol, ltfRates[2].high, ref, ltfRates[ref].high));
               return true;
            }
         }
      }

      // Method 3: Break of recent confirmed LTF swing high
      for(int s = 0; s < st.ltfSwingHighCount; s++)
      {
         if(st.ltfSwingHighs[s].barIndex >= 2 && st.ltfSwingHighs[s].barIndex <= 25)
         {
            double swHigh = st.ltfSwingHighs[s].price;
            if(ltfRates[1].high > swHigh + minBreak || ltfRates[2].high > swHigh + minBreak)
            {
               int bIdx = (ltfRates[1].high > swHigh + minBreak) ? 1 : 2;
               st.chochLevel       = swHigh;
               st.chochBar         = bIdx;
               st.chochTime        = ltfRates[bIdx].time;
               st.displacementBar  = bIdx;

               LogInfo(StringFormat("%s BULLISH CHoCH (swing): bar%d high broke above swing high %.3f",
                                    st.symbol, bIdx, swHigh));
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

         // Scan only bars OUTSIDE the swing's confirmation window
         int scanLimit = swingBar - LTFSwingStrength;
         if(scanLimit <= 1) continue;

         for(int b = 1; b < scanLimit; b++)
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

         // Scan only bars OUTSIDE the swing's confirmation window
         int scanLimit = swingBar - LTFSwingStrength;
         if(scanLimit <= 1) continue;

         for(int b = 1; b < scanLimit; b++)
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

      // Fallback: Use the highest candle before displacement as the OB zone
      double highestP = 0;
      int highIdx = -1;
      for(int i = dispBar + 1; i < dispBar + OBLookbackCandles + 1 && i < ltfCount; i++)
      {
         if(ltfRates[i].high > highestP)
         {
            highestP = ltfRates[i].high;
            highIdx = i;
         }
      }
      if(highIdx > 0)
      {
         st.obHigh      = ltfRates[highIdx].high;
         st.obLow       = ltfRates[highIdx].low;
         st.obTime      = ltfRates[highIdx].time;
         st.obDirection = DIR_BEARISH;
         st.obValid     = true;
         LogInfo(StringFormat("%s Bearish OB (pivot fallback): %.5f - %.5f at %s",
                              st.symbol, st.obHigh, st.obLow, TimeToString(ltfRates[highIdx].time)));
         return true;
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

      // Fallback: Use the lowest candle before displacement as the OB zone
      double lowestP = DBL_MAX;
      int lowIdx = -1;
      for(int i = dispBar + 1; i < dispBar + OBLookbackCandles + 1 && i < ltfCount; i++)
      {
         if(ltfRates[i].low < lowestP)
         {
            lowestP = ltfRates[i].low;
            lowIdx = i;
         }
      }
      if(lowIdx > 0)
      {
         st.obHigh      = ltfRates[lowIdx].high;
         st.obLow       = ltfRates[lowIdx].low;
         st.obTime      = ltfRates[lowIdx].time;
         st.obDirection = DIR_BULLISH;
         st.obValid     = true;
         LogInfo(StringFormat("%s Bullish OB (pivot fallback): %.5f - %.5f at %s",
                              st.symbol, st.obHigh, st.obLow, TimeToString(ltfRates[lowIdx].time)));
         return true;
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
      else
      {
         // No overlap: default to Order Block as primary POI zone
         st.poiHigh       = st.obHigh;
         st.poiLow        = st.obLow;
         st.hasConfluence  = false;
         LogInfo(StringFormat("%s OB primary POI (no overlap with FVG): %.5f - %.5f",
                              st.symbol, st.obHigh, st.obLow));
         return true;
      }
   }
   else if(st.obValid)
   {
      st.poiHigh       = st.obHigh;
      st.poiLow        = st.obLow;
      st.hasConfluence  = false;
      LogInfo(StringFormat("%s OB-only POI: %.5f - %.5f", st.symbol, st.obHigh, st.obLow));
      return true;
   }
   else if(st.fvgValid)
   {
      st.poiHigh       = st.fvgHigh;
      st.poiLow        = st.fvgLow;
      st.hasConfluence  = false;
      LogInfo(StringFormat("%s FVG-only POI: %.5f - %.5f", st.symbol, st.fvgHigh, st.fvgLow));
      return true;
   }

   LogWarn(StringFormat("%s Setup rejected: no valid POI zone found", st.symbol));
   return false;
}

//╔═══════════════════════════════════════════════════════════════════╗
//║                    RISK MANAGEMENT                               ║
//╚═══════════════════════════════════════════════════════════════════╝

// Calculate lot size based on risk percentage and SL distance
double CalculateLotSize(string sym, double riskPct, double entryPrice, double slPrice)
{
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   if(minLot <= 0) minLot = 0.01;

   if((LotType == LOT_FIXED || UseFixedLot) && FixedLotSize > 0)
      return NormalizeLots(sym, FixedLotSize);

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0) balance = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance <= 0) return NormalizeLots(sym, minLot);

   double riskAmt   = balance * riskPct / 100.0;
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);

   double slDist = MathAbs(entryPrice - slPrice);
   if(slDist <= 0) return NormalizeLots(sym, minLot);

   if(tickSize <= 0 || tickValue <= 0)
   {
      double point = SymPoint(sym);
      if(point > 0)
      {
         double slPoints = slDist / point;
         if(slPoints > 0)
         {
            double estLots = riskAmt / (slPoints * point * 100.0);
            return NormalizeLots(sym, MathMax(minLot, estLots));
         }
      }
      return NormalizeLots(sym, minLot);
   }

   double slTicks    = slDist / tickSize;
   double lossPerLot = slTicks * tickValue;

   if(lossPerLot <= 0) return NormalizeLots(sym, minLot);

   double lots = riskAmt / lossPerLot;
   if(lots < minLot) lots = minLot;
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

// Check if daily risk limit has been reached
bool IsDailyLossExceeded(SSymbolState &st)
{
   if(st.dayStartBalance <= 0) return false;
   double lossPct = -st.dailyPnL / st.dayStartBalance * 100.0;
   return (lossPct >= DailyRiskLimitPct && DailyRiskLimitPct > 0);
}

// Comprehensive pre-trade checks
bool PreTradeChecks(string sym, double lots, double entryPrice, double &slPrice, double &tpPrice)
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
   // In Strategy Tester, spread is simulated; NEVER block backtests due to spread!
   if(!MQLInfoInteger(MQL_TESTER))
   {
      // If user is trading Gold (XAU/GOLD), normal spread is 150-350 points.
      // If MaxSpreadPoints was left at an old default (e.g. 30), do not block.
      bool isGold = (StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0 || 
                     StringFind(sym, "xau") >= 0 || StringFind(sym, "gold") >= 0);
      int effectiveMaxSpread = MaxSpreadPoints;
      if(isGold && effectiveMaxSpread > 0 && effectiveMaxSpread < 100)
         effectiveMaxSpread = 350; // Auto-scale for Gold points

      if(spread > effectiveMaxSpread && effectiveMaxSpread > 0)
      {
         LogWarn(StringFormat("%s Trade blocked: Spread too high (%d > %d)", sym, (int)spread, effectiveMaxSpread));
         return false;
      }
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
   double tpDist  = (tpPrice > 0) ? MathAbs(entryPrice - tpPrice) / point : 999999;
   if(stopsLevel > 0 && (slDist < stopsLevel || tpDist < stopsLevel))
   {
      double pad = (stopsLevel + 10) * point;
      if(slDist < stopsLevel)
      {
         if(entryPrice > slPrice) slPrice = entryPrice - pad;
         else slPrice = entryPrice + pad;
      }
      if(tpPrice > 0 && tpDist < stopsLevel)
      {
         if(entryPrice < tpPrice) tpPrice = entryPrice + pad;
         else tpPrice = entryPrice - pad;
      }
      LogInfo(StringFormat("%s SL/TP auto-padded to broker stopsLevel (%d pts) -> SL: %.5f, TP: %.5f",
                           sym, stopsLevel, slPrice, tpPrice));
   }

   // 8. Freeze level
   int freezeLevel = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double priceDist = MathMin(MathAbs(ask - entryPrice), MathAbs(bid - entryPrice)) / point;
   // Only applies to pending orders that are too close to current price
   if(freezeLevel > 0 && priceDist < freezeLevel && EntryMode == ENTRY_PENDING)
   {
      LogDebug(StringFormat("%s Pending order too close to price (freeze level=%d)", sym, freezeLevel));
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

// Calculate SL price based on POI and OB bounds
double CalculateSL(SSymbolState &st, double pointVal)
{
   double refHigh = (st.poiHigh > 0) ? st.poiHigh : (st.obHigh > 0 ? st.obHigh : st.fvgHigh);
   double refLow  = (st.poiLow > 0)  ? st.poiLow  : (st.obLow > 0  ? st.obLow  : st.fvgLow);

   if(st.sweepPrice > 0)
   {
      if(st.bias == DIR_BEARISH && st.sweepPrice > refHigh) refHigh = st.sweepPrice;
      if(st.bias == DIR_BULLISH && st.sweepPrice < refLow && st.sweepPrice > 0) refLow = st.sweepPrice;
   }
   if(st.obValid && st.obHigh > refHigh) refHigh = st.obHigh;
   if(st.obValid && st.obLow < refLow && st.obLow > 0) refLow = st.obLow;

   bool isGold = (StringFind(st.symbol, "XAU") >= 0 || StringFind(st.symbol, "GOLD") >= 0 || 
                  StringFind(st.symbol, "xau") >= 0 || StringFind(st.symbol, "gold") >= 0);
   int buffer = SLBufferPoints;
   if(isGold && buffer < 100) buffer = 150; // Minimum 15 cents buffer on Gold
   if(buffer < 20) buffer = 20;

   if(st.bias == DIR_BEARISH)
      return refHigh + buffer * pointVal;
   else
      return refLow - buffer * pointVal;
}

// Find the next opposing 15M Order Block as a TP target / obstacle (Rule 3)
double FindOpposing15MOrderBlock(string sym, ENUM_DIRECTION tradeBias, double entryPrice, double pointVal)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(sym, PERIOD_M15, 0, 100, rates);
   if(copied < 10) return 0;

   double minDistance = 25 * pointVal;

   if(tradeBias == DIR_BEARISH)
   {
      // SELL trade: Look below entryPrice for nearest opposing Bullish 15M OB
      double nearestTarget = 0;
      double nearestDist   = DBL_MAX;

      for(int i = 2; i < copied - 2; i++)
      {
         if(rates[i].close < rates[i].open) // Down-close candle
         {
            // Expansion upward after this candle
            bool expandedUp = false;
            for(int f = i - 1; f >= MathMax(1, i - 4); f--)
            {
               if(rates[f].close > rates[i].high) { expandedUp = true; break; }
            }

            if(expandedUp)
            {
               double obHigh = rates[i].high;
               if(obHigh < entryPrice - minDistance)
               {
                  double dist = entryPrice - obHigh;
                  if(dist < nearestDist)
                  {
                     nearestDist   = dist;
                     nearestTarget = obHigh;
                  }
               }
            }
         }
      }
      return nearestTarget;
   }
   else if(tradeBias == DIR_BULLISH)
   {
      // BUY trade: Look above entryPrice for nearest opposing Bearish 15M OB
      double nearestTarget = 0;
      double nearestDist   = DBL_MAX;

      for(int i = 2; i < copied - 2; i++)
      {
         if(rates[i].close > rates[i].open) // Up-close candle
         {
            // Expansion downward after this candle
            bool expandedDown = false;
            for(int f = i - 1; f >= MathMax(1, i - 4); f--)
            {
               if(rates[f].close < rates[i].low) { expandedDown = true; break; }
            }

            if(expandedDown)
            {
               double obLow = rates[i].low;
               if(obLow > entryPrice + minDistance)
               {
                  double dist = obLow - entryPrice;
                  if(dist < nearestDist)
                  {
                     nearestDist   = dist;
                     nearestTarget = obLow;
                  }
               }
            }
         }
      }
      return nearestTarget;
   }
   return 0;
}

// Calculate TP price based on mode (Rule 3)
double CalculateTP(SSymbolState &st, double entryPrice, double slPrice, double pointVal)
{
   double slDist = MathAbs(entryPrice - slPrice);

   // 1. Check opposing 15M Order Block target
   double obTarget = FindOpposing15MOrderBlock(st.symbol, st.bias, entryPrice, pointVal);

   // 2. Check external liquidity target (opposing PDL/PDH or swing H/L)
   double liqTarget = 0;
   if(st.bias == DIR_BEARISH && st.pdlPrice > 0 && st.pdlPrice < entryPrice)
      liqTarget = st.pdlPrice;
   else if(st.bias == DIR_BULLISH && st.pdhPrice > 0 && st.pdhPrice > entryPrice)
      liqTarget = st.pdhPrice;
   else
      liqTarget = FindLiquidityTarget(st, entryPrice, pointVal);

   switch(TPMode)
   {
      case TP_OPPOSING_OB_OR_LIQ:
      {
         // Rule 3: Choose valid target in direction of trade; do NOT place TP beyond a nearer opposing obstacle
         if(st.bias == DIR_BEARISH)
         {
            if(obTarget > 0 && liqTarget > 0)
               return MathMax(obTarget, liqTarget); // Higher price is the nearer obstacle below entry
            if(obTarget > 0)  return obTarget;
            if(liqTarget > 0) return liqTarget;
            return entryPrice - slDist * RiskRewardRatio;
         }
         else // DIR_BULLISH
         {
            if(obTarget > 0 && liqTarget > 0)
               return MathMin(obTarget, liqTarget); // Lower price is the nearer obstacle above entry
            if(obTarget > 0)  return obTarget;
            if(liqTarget > 0) return liqTarget;
            return entryPrice + slDist * RiskRewardRatio;
         }
      }

      case TP_OPPOSING_15M_OB:
      {
         if(obTarget > 0) return obTarget;
         if(liqTarget > 0) return liqTarget;
         return (st.bias == DIR_BEARISH) ? (entryPrice - slDist * RiskRewardRatio) : (entryPrice + slDist * RiskRewardRatio);
      }

      case TP_LIQUIDITY:
      {
         if(liqTarget > 0) return liqTarget;
         if(obTarget > 0) return obTarget;
         return (st.bias == DIR_BEARISH) ? (entryPrice - slDist * RiskRewardRatio) : (entryPrice + slDist * RiskRewardRatio);
      }

      case TP_RISK_REWARD:
      {
         return (st.bias == DIR_BEARISH) ? (entryPrice - slDist * RiskRewardRatio) : (entryPrice + slDist * RiskRewardRatio);
      }

      case TP_FIXED_POINTS:
      {
         return (st.bias == DIR_BEARISH) ? (entryPrice - FixedTPPoints * pointVal) : (entryPrice + FixedTPPoints * pointVal);
      }

      case TP_HYBRID:
      {
         double rrTarget = (st.bias == DIR_BEARISH) ? (entryPrice - slDist * RiskRewardRatio) : (entryPrice + slDist * RiskRewardRatio);
         double target = (obTarget > 0) ? obTarget : liqTarget;
         if(target > 0)
         {
            return (st.bias == DIR_BEARISH) ? MathMax(target, rrTarget) : MathMin(target, rrTarget);
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
            st.entryPrices[i] = NormalizeDouble(st.poiHigh - ratio * poiRange, digits);
         else
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

      if(VolumeDist == VOL_WEIGHTED && entries > 1)
      {
         double weight;
         if(st.bias == DIR_BEARISH)
            weight = 1.0 + (double)i / (double)(entries - 1);
         else
            weight = 1.0 + (1.0 - (double)i / (double)(entries - 1));
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

   double curAsk = SymbolInfoDouble(st.symbol, SYMBOL_ASK);
   double curBid = SymbolInfoDouble(st.symbol, SYMBOL_BID);
   int digits = SymDigits(st.symbol);

   for(int i = 0; i < st.numPlannedEntries; i++)
   {
      double entryPrice = st.entryPrices[i];
      double lots       = st.entryLots[i];

      if(lots <= 0) continue;

      string comment = StringFormat("%s_%s_%d", EAComment, DirectionToString(st.bias), i + 1);

      // If price has already reached or crossed this limit entry level:
      // Execute immediately as Market Order so the setup entry is NEVER skipped!
      bool alreadyCrossed = (st.bias == DIR_BEARISH && entryPrice <= curAsk) ||
                            (st.bias == DIR_BULLISH && entryPrice >= curBid);

      if(alreadyCrossed)
      {
         double mktPrice = (st.bias == DIR_BEARISH) ? curBid : curAsk;
         double orderSL  = st.slPrice;
         double orderTP  = st.tpPrice;

         // Ensure SL is strictly valid for market entry
         int stopsLevel = (int)SymbolInfoInteger(st.symbol, SYMBOL_TRADE_STOPS_LEVEL);
         double minDist = (stopsLevel + 10) * pointVal;
         if(st.bias == DIR_BEARISH && orderSL <= mktPrice + minDist)
            orderSL = NormalizeDouble(mktPrice + MathMax(minDist, 50 * pointVal), digits);
         else if(st.bias == DIR_BULLISH && (orderSL >= mktPrice - minDist || orderSL <= 0))
            orderSL = NormalizeDouble(mktPrice - MathMax(minDist, 50 * pointVal), digits);

         if(!PreTradeChecks(st.symbol, lots, mktPrice, orderSL, orderTP)) continue;

         bool mktRes = (st.bias == DIR_BEARISH) ?
                       g_trade.Sell(lots, st.symbol, mktPrice, orderSL, orderTP, comment) :
                       g_trade.Buy(lots, st.symbol, mktPrice, orderSL, orderTP, comment);
         if(mktRes)
         {
            ulong tkt = g_trade.ResultOrder();
            if(tkt > 0 && st.orderTicketCount < MAX_ENTRIES)
            {
               st.orderTickets[st.orderTicketCount++] = tkt;
               anyPlaced = true;
               LogInfo(StringFormat("%s %s Market (replaces crossed Limit #%d) filled: price=%.5f lots=%.4f ticket=%d",
                                    st.symbol, DirectionToString(st.bias), i + 1, mktPrice, lots, tkt));
            }
         }
         continue;
      }

      double limitSL = st.slPrice;
      double limitTP = st.tpPrice;
      if(!PreTradeChecks(st.symbol, lots, entryPrice, limitSL, limitTP)) continue;

      bool result = false;
      if(st.bias == DIR_BEARISH)
      {
         result = g_trade.SellLimit(lots, entryPrice, st.symbol,
                                    limitSL, limitTP, ORDER_TIME_GTC, 0, comment);
      }
      else
      {
         result = g_trade.BuyLimit(lots, entryPrice, st.symbol,
                                   limitSL, limitTP, ORDER_TIME_GTC, 0, comment);
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
                                 entryPrice, lots, limitSL, limitTP, ticket));
         }
      }
      else
      {
         LogError(StringFormat("%s Order failed: code=%d comment=%s",
                               st.symbol, g_trade.ResultRetcode(), g_trade.ResultComment()));
      }
   }

   if(anyPlaced)
   {
      string setupId = GenerateSetupId(st);
      MarkSetupProcessed(st, setupId);
   }

   return anyPlaced;
}

// Execute a market entry with strictly valid SL/TP
bool ExecuteMarketEntry(SSymbolState &st, double pointVal)
{
   g_trade.SetExpertMagicNumber(st.magicNumber);
   g_trade.SetDeviationInPoints(Slippage);
   g_trade.SetTypeFilling(GetFillType(st.symbol));

   int digits = SymDigits(st.symbol);
   int stopsLevel = (int)SymbolInfoInteger(st.symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = (stopsLevel + 5) * pointVal;

   double entryPrice = (st.bias == DIR_BEARISH) ? SymbolInfoDouble(st.symbol, SYMBOL_BID) : SymbolInfoDouble(st.symbol, SYMBOL_ASK);
   if(entryPrice <= 0) return false;

   // Ensure SL is strictly valid for market entry
   double slPrice = st.slPrice;
   if(st.bias == DIR_BEARISH)
   {
      if(slPrice <= entryPrice + minDist)
         slPrice = entryPrice + MathMax(minDist, (st.currentATR_LTF > 0 ? st.currentATR_LTF : 50 * pointVal));
   }
   else
   {
      if(slPrice >= entryPrice - minDist || slPrice <= 0)
         slPrice = entryPrice - MathMax(minDist, (st.currentATR_LTF > 0 ? st.currentATR_LTF : 50 * pointVal));
   }
   slPrice = NormalizeDouble(slPrice, digits);

   // Calculate TP strictly relative to actual entryPrice and RR
   double slDist = MathAbs(entryPrice - slPrice);
   double tpPrice = 0;
   if(st.bias == DIR_BEARISH)
      tpPrice = entryPrice - slDist * RiskRewardRatio;
   else
      tpPrice = entryPrice + slDist * RiskRewardRatio;
   tpPrice = NormalizeDouble(tpPrice, digits);

   // Update state SL/TP
   st.slPrice = slPrice;
   st.tpPrice = tpPrice;

   double lots = CalculateLotSize(st.symbol, RiskPercentPerSetup, entryPrice, slPrice);
   if(lots <= 0) lots = SymbolInfoDouble(st.symbol, SYMBOL_VOLUME_MIN);

   if(!PreTradeChecks(st.symbol, lots, entryPrice, slPrice, tpPrice))
   {
      LogWarn(StringFormat("%s PreTradeChecks blocked Market Entry (price=%.5f SL=%.5f TP=%.5f lots=%.4f)",
                           st.symbol, entryPrice, slPrice, tpPrice, lots));
      return false;
   }

   string comment = StringFormat("%s_%s_MKT", EAComment, DirectionToString(st.bias));
   bool result = false;

   if(st.bias == DIR_BEARISH)
      result = g_trade.Sell(lots, st.symbol, entryPrice, slPrice, tpPrice, comment);
   else
      result = g_trade.Buy(lots, st.symbol, entryPrice, slPrice, tpPrice, comment);

   if(result)
   {
      string setupId = GenerateSetupId(st);
      MarkSetupProcessed(st, setupId);
      LogInfo(StringFormat("%s Market %s executed: lots=%.4f price=%.5f SL=%.5f TP=%.5f",
                           st.symbol, DirectionToString(st.bias), lots, entryPrice, slPrice, tpPrice));
      return true;
   }
   else
   {
      LogError(StringFormat("%s Market order failed: code=%d comment=%s",
                            st.symbol, g_trade.ResultRetcode(), g_trade.ResultComment()));
      return false;
   }
}

// Execute a hybrid entry: Market entry + Grid Limit orders inside the POI
bool ExecuteHybridEntry(SSymbolState &st, double pointVal)
{
   // 1. Execute immediate market entry so the trade is never missed
   bool mktOk = ExecuteMarketEntry(st, pointVal);
   if(!mktOk) return false;

   // 2. If NumberOfEntries > 1, place additional Limit orders inside POI as grid re-entries
   if(st.numPlannedEntries > 1)
   {
      double curAsk = SymbolInfoDouble(st.symbol, SYMBOL_ASK);
      double curBid = SymbolInfoDouble(st.symbol, SYMBOL_BID);

      for(int i = 1; i < st.numPlannedEntries; i++)
      {
         double entryPrice = st.entryPrices[i];
         double lots       = st.entryLots[i];
         if(lots <= 0) continue;

         bool valid = (st.bias == DIR_BEARISH) ? (entryPrice > curAsk) : (entryPrice < curBid);
         if(!valid) continue;

         if(!PreTradeChecks(st.symbol, lots, entryPrice, st.slPrice, st.tpPrice)) continue;

         string comment = StringFormat("%s_%s_G%d", EAComment, DirectionToString(st.bias), i + 1);
         bool res = false;
         if(st.bias == DIR_BEARISH)
            res = g_trade.SellLimit(lots, entryPrice, st.symbol, st.slPrice, st.tpPrice, ORDER_TIME_GTC, 0, comment);
         else
            res = g_trade.BuyLimit(lots, entryPrice, st.symbol, st.slPrice, st.tpPrice, ORDER_TIME_GTC, 0, comment);

         if(res)
         {
            ulong tkt = g_trade.ResultOrder();
            if(tkt > 0 && st.orderTicketCount < MAX_ENTRIES)
               st.orderTickets[st.orderTicketCount++] = tkt;
            LogInfo(StringFormat("%s Grid Limit #%d placed: price=%.5f lots=%.4f", st.symbol, i + 1, entryPrice, lots));
         }
      }
   }
   return true;
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

// Manage break-even protection using 1M or 3M structure (Rule 4)
void ManageBreakEven(SSymbolState &st)
{
   if(!EnableBreakEvenProtection && !MoveSLToBreakEven) return;

   double point  = SymPoint(st.symbol);
   int    digits = SymDigits(st.symbol);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != st.magicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != st.symbol) continue;

      double profit    = PositionGetDouble(POSITION_PROFIT);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);
      long   posType   = PositionGetInteger(POSITION_TYPE);

      // Track highest floating profit
      if(profit > st.beHighestProfit) st.beHighestProfit = profit;

      // Condition: Once floating profit reaches at least BEProfitUSD (default $0.50)
      if(!st.beActivated)
      {
         if(profit >= BEProfitUSD)
         {
            st.beActivated = true;
            LogInfo(StringFormat("%s [BE TRIGGER] Position %d floating profit reached $%.2f (>= $%.2f) — Activating structural break-even protection",
                                 st.symbol, ticket, profit, BEProfitUSD));
         }
      }

      // Preserve original SL until break-even condition is met
      if(!st.beActivated) continue;

      double beBuffer = BEBufferPoints * point;

      // Copy closed candles from 1M or 3M (confirmed structure)
      MqlRates beRates[];
      ArraySetAsSeries(beRates, true);
      int copied = CopyRates(st.symbol, BE_Structure_Timeframe, 1, BESwingLookback + 5, beRates);

      if(posType == POSITION_TYPE_BUY)
      {
         // Base break-even: entry price + buffer
         double targetSL = openPrice + beBuffer;

         // For a BUY trade, use confirmed swing lows on closed candles
         if(copied >= 5)
         {
            double bestSwingLow = 0;
            for(int k = 1; k < copied - 1; k++)
            {
               // Confirmed swing low on closed bar k
               if(beRates[k].low < beRates[k - 1].low && beRates[k].low < beRates[k + 1].low)
               {
                  if(beRates[k].low > openPrice)
                  {
                     bestSwingLow = beRates[k].low;
                     break; // Most recent confirmed swing low
                  }
               }
            }

            if(bestSwingLow > 0)
            {
               double structSL = bestSwingLow - beBuffer;
               if(structSL > targetSL)
                  targetSL = structSL;
            }
         }

         targetSL = NormalizeDouble(targetSL, digits);

         // Move SL up only, ensuring at least break-even
         if(targetSL > currentSL && targetSL >= openPrice)
         {
            if(g_trade.PositionModify(ticket, targetSL, tp))
            {
               LogInfo(StringFormat("%s [BE PROTECT] Buy pos %d SL moved to %.5f (entry=%.5f, profit=$%.2f)",
                                    st.symbol, ticket, targetSL, openPrice, profit));
            }
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         // Base break-even: entry price - buffer
         double targetSL = openPrice - beBuffer;

         // For a SELL trade, use confirmed swing highs on closed candles
         if(copied >= 5)
         {
            double bestSwingHigh = 0;
            for(int k = 1; k < copied - 1; k++)
            {
               // Confirmed swing high on closed bar k
               if(beRates[k].high > beRates[k - 1].high && beRates[k].high > beRates[k + 1].high)
               {
                  if(beRates[k].high < openPrice)
                  {
                     bestSwingHigh = beRates[k].high;
                     break; // Most recent confirmed swing high
                  }
               }
            }

            if(bestSwingHigh > 0)
            {
               double structSL = bestSwingHigh + beBuffer;
               if(structSL < targetSL)
                  targetSL = structSL;
            }
         }

         targetSL = NormalizeDouble(targetSL, digits);

         // Move SL down only, ensuring at least break-even
         if((currentSL == 0 || targetSL < currentSL) && targetSL <= openPrice)
         {
            if(g_trade.PositionModify(ticket, targetSL, tp))
            {
               LogInfo(StringFormat("%s [BE PROTECT] Sell pos %d SL moved to %.5f (entry=%.5f, profit=$%.2f)",
                                    st.symbol, ticket, targetSL, openPrice, profit));
            }
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

// Draw Previous Day High & Low lines (Rule 1)
void DrawPreviousDayHLLevels(SSymbolState &st)
{
   if(!ShouldDraw() || st.symbol != _Symbol) return;
   if(st.pdhPrice <= 0 || st.pdlPrice <= 0) return;

   // 1. Draw PDH (Buy-Side Liquidity)
   string pdhName = EA_TAG + st.symbol + "_PDH_LINE";
   ObjectDelete(0, pdhName);
   ObjectCreate(0, pdhName, OBJ_TREND, 0, st.pdhTime, st.pdhPrice, TimeCurrent() + 86400, st.pdhPrice);
   ObjectSetInteger(0, pdhName, OBJPROP_COLOR, ClrPDH);
   ObjectSetInteger(0, pdhName, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, pdhName, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, pdhName, OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(0, pdhName, OBJPROP_BACK, true);
   ObjectSetString(0, pdhName, OBJPROP_TEXT, "PDH [Buy-Side Liquidity]");

   // 2. Draw PDL (Sell-Side Liquidity)
   string pdlName = EA_TAG + st.symbol + "_PDL_LINE";
   ObjectDelete(0, pdlName);
   ObjectCreate(0, pdlName, OBJ_TREND, 0, st.pdlTime, st.pdlPrice, TimeCurrent() + 86400, st.pdlPrice);
   ObjectSetInteger(0, pdlName, OBJPROP_COLOR, ClrPDL);
   ObjectSetInteger(0, pdlName, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, pdlName, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, pdlName, OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(0, pdlName, OBJPROP_BACK, true);
   ObjectSetString(0, pdlName, OBJPROP_TEXT, "PDL [Sell-Side Liquidity]");
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
}

// Draw CHoCH line on chart
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
   int panelW = 310, panelH = 410;

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

   // External Liquidity (PDH / PDL - Rule 1)
   DashLabel(DASH_TAG+"PDH_PDL", x, y + lineH * row,
             StringFormat("PDH: %.2f  │  PDL: %.2f", st.pdhPrice, st.pdlPrice),
             clrGold);
   row++;

   // Separator
   DashLabel(DASH_TAG+"S1", x, y + lineH * row, "───────────────────────────", clrDimGray, 8);
   row++;

   // 7-Step Sequence indicators
   string liqSt   = (st.currentState > STATE_WAITING_FOR_LIQUIDITY) ? "✓" :  "⏳";
   string dispSt  = (st.currentState >= STATE_CHOCH_CONFIRMED) ? "✓" :
                    (st.currentState == STATE_WAITING_FOR_CHOCH ? "⏳" : "—");
   string poiSt   = (st.poiHigh > 0) ? "✓" : "—";
   string retSt   = st.poiRetested ? "✓" :
                    (st.currentState == STATE_WAITING_FOR_RETEST ? "⏳" : "—");
   string ltfSt   = (st.currentState >= STATE_ORDERS_PLACED) ? "✓" :
                    (st.currentState == STATE_WAITING_FOR_LTF_CONFIRM ? "⏳" : "—");

   DashLabel(DASH_TAG+"R3", x, y + lineH * row,
             StringFormat("Liq Sweep:  %s  │  15M Disp: %s", liqSt, dispSt),
             ClrDashText);
   row++;
   DashLabel(DASH_TAG+"R4", x, y + lineH * row,
             StringFormat("15M POI:    %s  │  Retest:   %s", poiSt, retSt),
             ClrDashText);
   row++;
   DashLabel(DASH_TAG+"R5", x, y + lineH * row,
             StringFormat("LTF Confirm:%s  │  Trade:    %s", ltfSt, (st.currentState == STATE_POSITION_ACTIVE ? "ACTIVE" : "—")),
             ClrDashText);
   row++;

   // Anti-Re-Entry status (Rule 7)
   if(BlockReEntryAfterSL && (st.pdhConsumed || st.pdlConsumed))
   {
      string consumedSide = st.pdhConsumed ? "PDH" : "PDL";
      DashLabel(DASH_TAG+"SL_CONS", x, y + lineH * row,
                StringFormat("Setup Consumed: %s (Wait New Sweep)", consumedSide),
                clrOrangeRed);
      row++;
   }

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
             StringFormat("Setup: %s  │  Entry: %s",
                          EnumToString(Setup_Timeframe), EnumToString(Entry_Timeframe)),
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
// persistent data (daily stats, processed IDs, counters, anti-re-entry flags).
void ResetSetup(SSymbolState &st)
{
   st.currentState     = STATE_WAITING_FOR_LIQUIDITY;
   st.bias             = DIR_NONE;
   st.liquidityLevel   = 0;
   st.sweepPrice       = 0;
   st.sweepTime        = 0;
   st.sweepBar         = -1;
   st.isPDHSweep       = false;
   st.isPDLSweep       = false;
   st.chochLevel       = 0;
   st.chochBar         = 0;
   st.chochTime        = 0;
   st.bosLevel         = 0;
   st.bosBar           = 0;
   st.bosTime          = 0;
   st.displacementBar  = -1;
   st.displacementTime = 0;
   st.displacementSize = 0;
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
   st.poiRetested      = false;
   st.poiRetestTime    = 0;
   st.numPlannedEntries= 0;
   st.orderTicketCount = 0;
   st.slPrice          = 0;
   st.tpPrice          = 0;
   st.setupStartTime   = 0;
   st.partialCloseDone = false;
   st.targetLiqLevel   = 0;
   st.beActivated      = false;
   st.beHighestProfit  = 0;
   // NOTE: We deliberately do NOT reset pdhConsumed, pdlConsumed, lastFailedSweepTime, lastFailedSweepPrice!
   // Those persist across reset so that Rule 7 (No immediate re-entry after SL) is strictly enforced.
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

   // Rule 1: Update Previous Day High & Low external liquidity
   UpdatePreviousDayHL(g_states[si]);
   if(ShowPDH_PDL_Lines && sym == _Symbol)
      DrawPreviousDayHLLevels(g_states[si]);

   // Check daily risk limit
   if(IsDailyLossExceeded(g_states[si]))
   {
      if(g_states[si].currentState == STATE_ORDERS_PLACED)
      {
         DeletePendingOrders(g_states[si]);
         g_states[si].currentState = STATE_SETUP_INVALIDATED;
         LogWarn(StringFormat("%s Daily risk limit reached — orders cancelled", sym));
      }
      else if(g_states[si].currentState < STATE_POSITION_ACTIVE)
      {
         g_states[si].currentState = STATE_SETUP_INVALIDATED;
      }
      // Don't close active positions on daily risk limit — just prevent new ones
   }

   // New bar checks
   bool newHTFBar = IsNewBar(sym, Setup_Timeframe, g_states[si].htfLastBarTime);
   bool newLTFBar = IsNewBar(sym, Entry_Timeframe, g_states[si].ltfLastBarTime);

   // Copy Setup Timeframe (15M) rates
   MqlRates htfRates[];
   int htfCount = 0;
   ArraySetAsSeries(htfRates, true);
   int htfNeeded = SwingLookback + HTFSwingStrength + 15;
   htfCount = CopyRates(sym, Setup_Timeframe, 0, htfNeeded, htfRates);

   // Copy Entry Timeframe (1M, 3M, or 5M) rates
   MqlRates ltfRates[];
   int ltfCount = 0;
   ArraySetAsSeries(ltfRates, true);
   int ltfNeeded = SwingLookback + LTFSwingStrength + 15;
   ltfCount = CopyRates(sym, Entry_Timeframe, 0, ltfNeeded, ltfRates);

   // Update ATR on Setup Timeframe (15M)
   if(g_states[si].atrHandleHTF != INVALID_HANDLE && htfCount > 0)
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(g_states[si].atrHandleHTF, 0, 0, 3, atrBuf) >= 1)
         g_states[si].currentATR_HTF = atrBuf[1];
   }

   // Update ATR on Entry Timeframe (LTF)
   if(g_states[si].atrHandleLTF != INVALID_HANDLE && ltfCount > 0)
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(g_states[si].atrHandleLTF, 0, 0, 3, atrBuf) >= 1)
         g_states[si].currentATR_LTF = atrBuf[1];
   }

   // State machine with fall-through for multi-step transitions
   bool stateChanged = true;
   int maxIterations = 10;

   while(stateChanged && maxIterations-- > 0)
   {
      stateChanged = false;

      switch(g_states[si].currentState)
      {
         //───────────────────────────────────────────────────
         // STEP 1, 2, 3: Previous Day H/L & 15M Liquidity Sweep + Rejection
         //───────────────────────────────────────────────────
         case STATE_WAITING_FOR_LIQUIDITY:
         {
            if(htfCount < 5) break;

            // Swings for alternative / secondary liquidity if enabled
            if(LiquiditySource == LIQ_SWING_HIGHS_LOWS || LiquiditySource == LIQ_BOTH)
            {
               DetectSwings(htfRates, htfCount, HTFSwingStrength,
                            g_states[si].htfSwingHighs, g_states[si].htfSwingHighCount,
                            g_states[si].htfSwingLows,  g_states[si].htfSwingLowCount,
                            point, MAX_SWINGS);
               BuildLiquidityLevels(g_states[si], point);

               if(ShowChartObjects && sym == _Symbol)
               {
                  for(int l = 0; l < g_states[si].buySideLiqCount; l++)
                     DrawLiquidityLevel(g_states[si], g_states[si].buySideLiq[l].price,
                                        true, g_states[si].buySideLiq[l].time);
                  for(int l = 0; l < g_states[si].sellSideLiqCount; l++)
                     DrawLiquidityLevel(g_states[si], g_states[si].sellSideLiq[l].price,
                                        false, g_states[si].sellSideLiq[l].time);
               }
            }

            // Check for 15M sweep + rejection against PDH / PDL
            if(CheckLiquiditySweep(g_states[si], htfRates, htfCount, point))
            {
               g_states[si].currentState = STATE_LIQUIDITY_SWEPT;
               stateChanged = true;
            }
            break;
         }

         //───────────────────────────────────────────────────
         // STEP 3 Confirmation: Sweep & Rejection OK -> Mark chart, NO entry yet!
         //───────────────────────────────────────────────────
         case STATE_LIQUIDITY_SWEPT:
         {
            DrawSweepMarker(g_states[si]);
            // Sweep confirmed — strictly wait for 15M displacement
            g_states[si].currentState = STATE_WAITING_FOR_CHOCH;
            stateChanged = true;
            break;
         }

         //───────────────────────────────────────────────────
         // STEP 4: Structure Displacement & POI (OB / FVG) Creation (Rule 1)
         //───────────────────────────────────────────────────
         case STATE_WAITING_FOR_CHOCH:
         {
            int age = BarsElapsed(sym, Setup_Timeframe, g_states[si].setupStartTime);
            if(age > SetupExpirationBars)
            {
               LogInfo(StringFormat("%s Setup expired while waiting for %s displacement (age=%d bars)",
                                    sym, EnumToString(Structure_Timeframe), age));
               g_states[si].currentState = STATE_SETUP_INVALIDATED;
               stateChanged = true;
               break;
            }

            // Detect strong displacement opposite to sweep, creating OB / FVG / CHoCH on Structure_Timeframe (5M)
            if(DetectStructureDisplacementAndPOI(g_states[si], Structure_Timeframe, point))
            {
               DrawCHoCHLine(g_states[si]);
               if(g_states[si].obValid)  DrawOrderBlock(g_states[si]);
               if(g_states[si].fvgValid) DrawFVG(g_states[si]);
               DrawConfluence(g_states[si]);

               g_states[si].currentState = STATE_CONFLUENCE_CONFIRMED;
               stateChanged = true;
            }
            break;
         }

         //───────────────────────────────────────────────────
         // STEP 5 preparation: Build Entry Plan & Calculate SL/TP
         //───────────────────────────────────────────────────
         case STATE_CONFLUENCE_CONFIRMED:
         {
            BuildEntryPlan(g_states[si], point);

            string setupId = GenerateSetupId(g_states[si]);
            if(IsSetupProcessed(g_states[si], setupId))
            {
               LogDebug(StringFormat("%s Duplicate setup rejected: %s", sym, setupId));
               g_states[si].currentState = STATE_SETUP_INVALIDATED;
               stateChanged = true;
               break;
            }

            LogInfo(StringFormat("%s [15M POI CREATED] %s POI=[%.5f - %.5f] SL=%.5f TP=%.5f -> Waiting for Retest",
                                 sym, DirectionToString(g_states[si].bias),
                                 g_states[si].poiLow, g_states[si].poiHigh,
                                 g_states[si].slPrice, g_states[si].tpPrice));

            g_states[si].poiRetested   = false;
            g_states[si].poiRetestTime = 0;
            g_states[si].currentState  = STATE_WAITING_FOR_RETEST;
            stateChanged = true;
            break;
         }

         //───────────────────────────────────────────────────
         // STEP 5: Wait for POI Retest (Price must return to 15M POI)
         //───────────────────────────────────────────────────
         case STATE_WAITING_FOR_RETEST:
         {
            int age = BarsElapsed(sym, Setup_Timeframe, g_states[si].displacementTime);
            if(age > MaxRetestWaitBars)
            {
               LogInfo(StringFormat("%s POI retest wait expired (%d bars > %d max)", sym, age, MaxRetestWaitBars));
               g_states[si].currentState = STATE_SETUP_INVALIDATED;
               stateChanged = true;
               break;
            }

            double bid = SymbolInfoDouble(sym, SYMBOL_BID);
            double ask = SymbolInfoDouble(sym, SYMBOL_ASK);

            // Invalidation check: price blows through POI / sweep level
            if(g_states[si].bias == DIR_BEARISH)
            {
               if(ask > g_states[si].slPrice)
               {
                  LogInfo(StringFormat("%s POI invalidated: ask %.5f broke above SL %.5f", sym, ask, g_states[si].slPrice));
                  g_states[si].currentState = STATE_SETUP_INVALIDATED;
                  stateChanged = true;
                  break;
               }
            }
            else if(g_states[si].bias == DIR_BULLISH)
            {
               if(bid < g_states[si].slPrice)
               {
                  LogInfo(StringFormat("%s POI invalidated: bid %.5f broke below SL %.5f", sym, bid, g_states[si].slPrice));
                  g_states[si].currentState = STATE_SETUP_INVALIDATED;
                  stateChanged = true;
                  break;
               }
            }

            // Check if price touched / returned to the 15M POI zone
            if(CheckPOIRetest(g_states[si], bid, ask, point))
            {
               g_states[si].poiRetested   = true;
               g_states[si].poiRetestTime = TimeCurrent();
               LogInfo(StringFormat("%s [POI RETESTED] Price returned to 15M POI [%.5f - %.5f] -> Waiting for %s confirmation",
                                    sym, g_states[si].poiLow, g_states[si].poiHigh, EnumToString(Entry_Timeframe)));
               g_states[si].currentState = STATE_WAITING_FOR_LTF_CONFIRM;
               stateChanged = true;
            }
            break;
         }

         //───────────────────────────────────────────────────
         // STEP 6: Refined Entry on 1M, 3M, or 5M
         //───────────────────────────────────────────────────
         case STATE_WAITING_FOR_LTF_CONFIRM:
         {
            int age = BarsElapsed(sym, Entry_Timeframe, g_states[si].poiRetestTime);
            if(age > SetupExpirationBars)
            {
               LogInfo(StringFormat("%s LTF confirmation wait expired (%d bars)", sym, age));
               g_states[si].currentState = STATE_SETUP_INVALIDATED;
               stateChanged = true;
               break;
            }

            if(!newLTFBar || ltfCount < 3) break;

            if(CheckLTFConfirmation(g_states[si], ltfRates, ltfCount, point))
            {
               LogInfo(StringFormat("%s [LTF CONFIRMED ON %s] Executing entry (%s)",
                                    sym, EnumToString(Entry_Timeframe), EnumToString(EntryMode)));
               DrawEntryLevels(g_states[si]);

               bool entered = false;
               if(EntryMode == ENTRY_PENDING)
               {
                  if(PlacePendingOrders(g_states[si], point))
                  {
                     g_states[si].currentState = STATE_ORDERS_PLACED;
                     stateChanged = true;
                     entered = true;
                  }
                  else if(ExecuteMarketEntry(g_states[si], point))
                  {
                     g_states[si].currentState = STATE_POSITION_ACTIVE;
                     stateChanged = true;
                     entered = true;
                  }
                  else
                  {
                     g_states[si].currentState = STATE_SETUP_INVALIDATED;
                     stateChanged = true;
                  }
               }
               else if(EntryMode == ENTRY_HYBRID)
               {
                  if(ExecuteHybridEntry(g_states[si], point))
                  {
                     g_states[si].currentState = STATE_POSITION_ACTIVE;
                     stateChanged = true;
                     entered = true;
                  }
                  else
                  {
                     g_states[si].currentState = STATE_SETUP_INVALIDATED;
                     stateChanged = true;
                  }
               }
               else // ENTRY_MARKET
               {
                  if(ExecuteMarketEntry(g_states[si], point))
                  {
                     g_states[si].currentState = STATE_POSITION_ACTIVE;
                     stateChanged = true;
                     entered = true;
                  }
                  else
                  {
                     g_states[si].currentState = STATE_SETUP_INVALIDATED;
                     stateChanged = true;
                  }
               }

               if(entered)
               {
                  // Rules 2 & 5: Lock setup immediately upon entry. Mark as consumed so no second entry or re-entry can occur!
                  if(g_states[si].isPDHSweep) g_states[si].pdhConsumed = true;
                  if(g_states[si].isPDLSweep) g_states[si].pdlConsumed = true;
                  g_states[si].lastFailedSweepTime  = g_states[si].sweepTime;
                  g_states[si].lastFailedSweepPrice = g_states[si].sweepPrice;
                  g_states[si].lastFailedBias       = g_states[si].bias;
                  LogInfo(StringFormat("%s [SETUP LOCKED] Entry executed. Sweep setup marked consumed. Re-entry strictly locked.", sym));
               }
            }
            break;
         }

         //───────────────────────────────────────────────────
         // PENDING ORDERS MANAGEMENT
         //───────────────────────────────────────────────────
         case STATE_ORDERS_PLACED:
         {
            int age = BarsElapsed(sym, Entry_Timeframe, g_states[si].setupStartTime);
            if(age > SetupExpirationBars)
            {
               LogInfo(StringFormat("%s Setup expired with pending orders", sym));
               DeletePendingOrders(g_states[si]);
               g_states[si].currentState = STATE_SETUP_INVALIDATED;
               stateChanged = true;
               break;
            }

            // Check if any orders have been filled
            if(CountPositions(sym, g_states[si].magicNumber) > 0)
            {
               LogInfo(StringFormat("%s Pending order filled — position active", sym));
               g_states[si].currentState = STATE_POSITION_ACTIVE;
               stateChanged = true;
            }
            else if(CountPendingOrders(sym, g_states[si].magicNumber) == 0)
            {
               LogWarn(StringFormat("%s All pending orders removed externally", sym));
               g_states[si].currentState = STATE_SETUP_INVALIDATED;
               stateChanged = true;
            }
            break;
         }

         //───────────────────────────────────────────────────
         // STEP 7: Position active & Anti-Re-Entry after Stop Loss
         //───────────────────────────────────────────────────
         case STATE_POSITION_ACTIVE:
         {
            // Delete remaining pending orders if any
            if(CountPendingOrders(sym, g_states[si].magicNumber) > 0)
               DeletePendingOrders(g_states[si]);

            // Trade management
            ManageBreakEven(g_states[si]);
            ManagePartialClose(g_states[si]);
            ManageTrailingStop(g_states[si]);

            // Check if all positions closed
            if(CountPositions(sym, g_states[si].magicNumber) == 0)
            {
               // Check closed deal profit for this setup
               datetime fromTime = g_states[si].setupStartTime > 0 ? g_states[si].setupStartTime : TimeCurrent() - 86400;
               HistorySelect(fromTime, TimeCurrent());
               int totalDeals = HistoryDealsTotal();
               double setupProfit = 0;
               int dealsFound = 0;
               for(int d = totalDeals - 1; d >= 0; d--)
               {
                  ulong dealTicket = HistoryDealGetTicket(d);
                  if(dealTicket > 0)
                  {
                     if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == g_states[si].magicNumber &&
                        HistoryDealGetString(dealTicket, DEAL_SYMBOL) == sym &&
                        HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
                     {
                        setupProfit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +
                                       HistoryDealGetDouble(dealTicket, DEAL_SWAP) +
                                       HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
                        dealsFound++;
                     }
                  }
               }

               if(dealsFound > 0 && setupProfit < 0)
               {
                  // STOP LOSS / LOSS HIT — Rule 2: Invalidate setup & strictly block re-entry
                  g_states[si].lastFailedSweepTime  = g_states[si].sweepTime;
                  g_states[si].lastFailedSweepPrice = g_states[si].sweepPrice;
                  g_states[si].lastFailedBias       = g_states[si].bias;
                  if(g_states[si].isPDHSweep) g_states[si].pdhConsumed = true;
                  if(g_states[si].isPDLSweep) g_states[si].pdlConsumed = true;

                  LogWarn(StringFormat("%s [SL HIT - STRICT NO RE-ENTRY (RULE 2)] Trade closed with LOSS (%.2f). Setup marked CONSUMED. Immediate re-entry blocked. Waiting for completely new sweep.",
                                       sym, setupProfit));
                  g_states[si].currentState = STATE_SETUP_INVALIDATED;
                  stateChanged = true;
               }
               else
               {
                  // TARGET REACHED / PROFIT — Rule 2: Setup marked CONSUMED, no re-entry from same sweep
                  g_states[si].lastFailedSweepTime  = g_states[si].sweepTime;
                  g_states[si].lastFailedSweepPrice = g_states[si].sweepPrice;
                  g_states[si].lastFailedBias       = g_states[si].bias;
                  if(g_states[si].isPDHSweep) g_states[si].pdhConsumed = true;
                  if(g_states[si].isPDLSweep) g_states[si].pdlConsumed = true;

                  LogInfo(StringFormat("%s [TARGET REACHED - STRICT NO RE-ENTRY (RULE 2)] Trade closed in PROFIT (%.2f). Setup marked CONSUMED. Waiting for brand new sweep.",
                                       sym, setupProfit));
                  g_states[si].currentState = STATE_TARGET_REACHED;
                  stateChanged = true;
               }
            }
            break;
         }

         case STATE_TARGET_REACHED:
         {
            LogInfo(StringFormat("%s ═══ Setup cycle complete ═══", sym));
            g_states[si].currentState = STATE_RESET;
            stateChanged = true;
            break;
         }

         case STATE_SETUP_INVALIDATED:
         {
            DeletePendingOrders(g_states[si]);
            LogInfo(StringFormat("%s Setup invalidated — resetting state", sym));
            g_states[si].currentState = STATE_RESET;
            stateChanged = true;
            break;
         }

         case STATE_RESET:
         {
            ResetSetup(g_states[si]);
            LogDebug(StringFormat("%s State reset — scanning for new sweep", sym));
            stateChanged = true;
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

   if(MQLInfoInteger(MQL_TESTER))
   {
      LogInfo(StringFormat("═══ SMC EA [TESTER MODE ACTIVE] ═══ Sym: %s | HTF: %s | LTF: %s | Mode: %s | SpreadLimit: %d (tester bypass: ON) | Lots: %.2f",
                           _Symbol, EnumToString(HTF_Timeframe), EnumToString(LTF_Timeframe),
                           EnumToString(EntryMode), MaxSpreadPoints,
                           (UseFixedLot ? FixedLotSize : 0.01)));
   }
   else
   {
      LogInfo(StringFormat("═══ SMC Liquidity EA initialized ═══ Symbols: %d | HTF: %s | LTF: %s | Mode: %s",
                           g_symbolCount, EnumToString(HTF_Timeframe), EnumToString(LTF_Timeframe), EnumToString(EntryMode)));
   }

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
