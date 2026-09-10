//+------------------------------------------------------------------+
//|                     FVG Liquidity Sweep Strategy EA              |
//|                  Dual Path Trading System for MT5                |
//+------------------------------------------------------------------+
#property copyright "FVG Strategy"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade trade;
CPositionInfo posInfo;

//+------------------------------------------------------------------+
//|                    INPUT PARAMETERS                              |
//+------------------------------------------------------------------+

// Session Settings
input int SessionStartHour = 14;           // Session Start Hour (2:30 PM = 14, GMT+0)
input int SessionStartMinute = 30;         // Session Start Minute
input int SessionEndHour = 19;             // Session End Hour (7 PM = 19, GMT+0)
input int SessionEndMinute = 0;            // Session End Minute

// Risk Management
input double RiskPercent = 1.0;            // Risk per trade (% of initial balance)
input double TakeProfit_RR = 2.0;          // Take Profit R:R Multiple
input bool EnableBreakEven = true;         // Enable Break Even
input double BreakEven_RR = 1.0;           // Break Even R:R Ratio

// SL Model Selection
input int SL_Model = 1;                    // 1 = Wick-based, 2 = Body-based (5pips)

// Trading Days & Months
input string TradingDays = "1,2,3,4,5";    // 1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri
input string TradingMonths = "1,2,3,4,5,6,7,8,9,10,11,12"; // 1-12

// Strategy Parameters
input int FVG_Pips = 5;                    // Minimum FVG gap in pips
input bool UsePathOne = true;              // Enable Path 1 (1H FVG + 5M Sweep)
input bool UsePathTwo = true;              // Enable Path 2 (15M Bias Confirmation)

//+------------------------------------------------------------------+
//|                    GLOBAL VARIABLES                              |
//+------------------------------------------------------------------+

struct FVG {
    datetime time;
    double high;
    double low;
    bool isValid;
    int type;  // 1 = Bullish, -1 = Bearish
};

struct BiasLevel {
    double level;
    int type;  // 1 = High, -1 = Low
    datetime time;
};

struct Sweep {
    bool found;
    bool entryValid;
    double sweepLow;
    double sweepHigh;
    double entryPrice;
    int direction;  // 1 = Bullish, -1 = Bearish
};

FVG fvg_1h;
FVG fvg_15m;
BiasLevel biasLevel_15m;
bool dailyBiasConfirmed = false;
int dailyBiasDirection = 0;  // 1 = Bullish, -1 = Bearish
datetime sessionStartTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(123456);
    fvg_1h.isValid = false;
    fvg_15m.isValid = false;
    biasLevel_15m.level = 0;
    biasLevel_15m.type = 0;
    biasLevel_15m.time = 0;
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // Check if we should trade today and this month
    if (!ShouldTradeToday() || !ShouldTradeThisMonth())
        return;

    // Check session time
    if (!IsSessionActive())
        return;

    // Initialize session start time once per day
    if (sessionStartTime == 0 || !IsCurrentDaySession())
        sessionStartTime = iTime(_Symbol, PERIOD_D1, 0);

    // PATH 2: Check and confirm daily bias (15M)
    if (UsePathTwo)
    {
        if (!dailyBiasConfirmed)
        {
            CheckPath2_BiasConfirmation();
        }
        else
        {
            CheckPath2_FVGAndEntry();
        }
    }

    // PATH 1: Check 1H FVG and 5M Sweep Entry
    if (UsePathOne)
    {
        CheckPath1_FVGAndEntry();
    }

    // Check Break Even
    if (EnableBreakEven)
    {
        CheckBreakEven();
    }
}

//+------------------------------------------------------------------+
//|                      PATH 1: 1H FVG + 5M SWEEP                   |
//+------------------------------------------------------------------+
void CheckPath1_FVGAndEntry()
{
    // Detect 1H FVG
    FVG current_fvg = Detect1HFVG();
    
    if (current_fvg.isValid)
    {
        fvg_1h = current_fvg;
    }

    if (!fvg_1h.isValid)
        return;

    // Check if FVG is still valid (not closed past)
    if (!IsFVGValid(fvg_1h, PERIOD_H1))
    {
        fvg_1h.isValid = false;
        return;
    }

    // Check for 5M liquidity sweep
    Sweep sweep_5m = Detect5MSweep(fvg_1h);

    if (sweep_5m.found && sweep_5m.entryValid)
    {
        ExecuteEntry(sweep_5m, fvg_1h.type);
    }
}

//+------------------------------------------------------------------+
//|                   PATH 2: 15M BIAS CONFIRMATION                  |
//+------------------------------------------------------------------+
void CheckPath2_BiasConfirmation()
{
    // Find closest bullish and bearish 15M FVG
    FVG bullish_fvg = FindClosestFVG(1, PERIOD_M15);
    FVG bearish_fvg = FindClosestFVG(-1, PERIOD_M15);

    // Mark high/low for each
    BiasLevel bullish_level;
    BiasLevel bearish_level;
    
    bullish_level.level = 0;
    bullish_level.type = 0;
    bullish_level.time = 0;
    
    bearish_level.level = 0;
    bearish_level.type = 0;
    bearish_level.time = 0;
    
    if (bullish_fvg.isValid)
    {
        bullish_level = FindNearestHighLow(bullish_fvg, PERIOD_M15);
    }

    if (bearish_fvg.isValid)
    {
        bearish_level = FindNearestHighLow(bearish_fvg, PERIOD_M15);
    }

    // Check if 15M candle closed past the marked level (confirming direction)
    if (bullish_fvg.isValid && bullish_level.type == 1)
    {
        if (iClose(_Symbol, PERIOD_M15, 1) > bullish_level.level)
        {
            dailyBiasConfirmed = true;
            dailyBiasDirection = 1;  // Bullish bias
            biasLevel_15m = bullish_level;
            fvg_15m = bullish_fvg;
            Print("Daily Bias Confirmed: BULLISH at ", biasLevel_15m.level);
        }
    }

    if (bearish_fvg.isValid && bearish_level.type == -1)
    {
        if (iClose(_Symbol, PERIOD_M15, 1) < bearish_level.level)
        {
            dailyBiasConfirmed = true;
            dailyBiasDirection = -1;  // Bearish bias
            biasLevel_15m = bearish_level;
            fvg_15m = bearish_fvg;
            Print("Daily Bias Confirmed: BEARISH at ", biasLevel_15m.level);
        }
    }
}

void CheckPath2_FVGAndEntry()
{
    // Look for new 15M FVG formed during session in confirmed direction
    FVG new_fvg = DetectSessionFVG(dailyBiasDirection, PERIOD_M15);

    if (new_fvg.isValid)
    {
        fvg_15m = new_fvg;

        // Check for 5M candle entry into this FVG
        if (iClose(_Symbol, PERIOD_M5, 1) > fvg_15m.low && iClose(_Symbol, PERIOD_M5, 1) < fvg_15m.high)
        {
            if (dailyBiasDirection == 1)  // Bullish
            {
                if (iClose(_Symbol, PERIOD_M5, 1) > iOpen(_Symbol, PERIOD_M5, 1))
                {
                    Sweep sweep;
                    sweep.entryPrice = iClose(_Symbol, PERIOD_M5, 1);
                    sweep.sweepLow = iLow(_Symbol, PERIOD_M5, 1);
                    sweep.sweepHigh = iHigh(_Symbol, PERIOD_M5, 1);
                    sweep.direction = 1;
                    sweep.found = true;
                    sweep.entryValid = true;
                    ExecuteEntry(sweep, 1);
                }
            }
            else if (dailyBiasDirection == -1)  // Bearish
            {
                if (iClose(_Symbol, PERIOD_M5, 1) < iOpen(_Symbol, PERIOD_M5, 1))
                {
                    Sweep sweep;
                    sweep.entryPrice = iClose(_Symbol, PERIOD_M5, 1);
                    sweep.sweepLow = iLow(_Symbol, PERIOD_M5, 1);
                    sweep.sweepHigh = iHigh(_Symbol, PERIOD_M5, 1);
                    sweep.direction = -1;
                    sweep.found = true;
                    sweep.entryValid = true;
                    ExecuteEntry(sweep, -1);
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//|                     FVG DETECTION FUNCTIONS                      |
//+------------------------------------------------------------------+

FVG Detect1HFVG()
{
    FVG result;
    result.isValid = false;
    result.time = 0;
    result.high = 0;
    result.low = 0;
    result.type = 0;

    if (iBars(_Symbol, PERIOD_H1) < 3)
        return result;

    // Check last 10 candles for FVG
    for (int i = 2; i < 10; i++)
    {
        double candle1_high = iHigh(_Symbol, PERIOD_H1, i);
        double candle1_low = iLow(_Symbol, PERIOD_H1, i);
        
        double candle2_high = iHigh(_Symbol, PERIOD_H1, i - 1);
        double candle2_low = iLow(_Symbol, PERIOD_H1, i - 1);
        
        double candle3_high = iHigh(_Symbol, PERIOD_H1, i - 2);
        double candle3_low = iLow(_Symbol, PERIOD_H1, i - 2);

        // Bullish FVG: Candle 2 gap up, wicks don't cover body
        if (candle2_low > candle1_high && candle3_low > candle1_high)
        {
            double gap_low = candle1_high;
            double gap_high = candle2_low;
            
            if ((gap_high - gap_low) / _Point / 10 >= FVG_Pips)
            {
                result.low = gap_low;
                result.high = gap_high;
                result.time = iTime(_Symbol, PERIOD_H1, i - 1);
                result.isValid = true;
                result.type = 1;  // Bullish
                return result;
            }
        }

        // Bearish FVG: Candle 2 gap down, wicks don't cover body
        if (candle2_high < candle1_low && candle3_high < candle1_low)
        {
            double gap_high = candle1_low;
            double gap_low = candle2_high;
            
            if ((gap_high - gap_low) / _Point / 10 >= FVG_Pips)
            {
                result.low = gap_low;
                result.high = gap_high;
                result.time = iTime(_Symbol, PERIOD_H1, i - 1);
                result.isValid = true;
                result.type = -1;  // Bearish
                return result;
            }
        }
    }

    return result;
}

FVG FindClosestFVG(int direction, ENUM_TIMEFRAMES timeframe)
{
    FVG result;
    result.isValid = false;
    result.time = 0;
    result.high = 0;
    result.low = 0;
    result.type = 0;

    if (iBars(_Symbol, timeframe) < 3)
        return result;

    // Check last 20 candles
    for (int i = 2; i < 20; i++)
    {
        double candle1_high = iHigh(_Symbol, timeframe, i);
        double candle1_low = iLow(_Symbol, timeframe, i);
        
        double candle2_high = iHigh(_Symbol, timeframe, i - 1);
        double candle2_low = iLow(_Symbol, timeframe, i - 1);
        
        double candle3_high = iHigh(_Symbol, timeframe, i - 2);
        double candle3_low = iLow(_Symbol, timeframe, i - 2);

        if (direction == 1)  // Bullish FVG
        {
            if (candle2_low > candle1_high && candle3_low > candle1_high)
            {
                double gap_low = candle1_high;
                double gap_high = candle2_low;
                
                if ((gap_high - gap_low) / _Point / 10 >= FVG_Pips)
                {
                    result.low = gap_low;
                    result.high = gap_high;
                    result.time = iTime(_Symbol, timeframe, i - 1);
                    result.isValid = true;
                    result.type = 1;
                    return result;
                }
            }
        }
        else if (direction == -1)  // Bearish FVG
        {
            if (candle2_high < candle1_low && candle3_high < candle1_low)
            {
                double gap_high = candle1_low;
                double gap_low = candle2_high;
                
                if ((gap_high - gap_low) / _Point / 10 >= FVG_Pips)
                {
                    result.low = gap_low;
                    result.high = gap_high;
                    result.time = iTime(_Symbol, timeframe, i - 1);
                    result.isValid = true;
                    result.type = -1;
                    return result;
                }
            }
        }
    }

    return result;
}

FVG DetectSessionFVG(int direction, ENUM_TIMEFRAMES timeframe)
{
    FVG result;
    result.isValid = false;
    result.time = 0;
    result.high = 0;
    result.low = 0;
    result.type = 0;

    if (iBars(_Symbol, timeframe) < 3)
        return result;

    // Check only candles formed during current session
    for (int i = 2; i < 20; i++)
    {
        datetime candle_time = iTime(_Symbol, timeframe, i - 1);
        
        if (candle_time < sessionStartTime)
            break;

        double candle1_high = iHigh(_Symbol, timeframe, i);
        double candle1_low = iLow(_Symbol, timeframe, i);
        
        double candle2_high = iHigh(_Symbol, timeframe, i - 1);
        double candle2_low = iLow(_Symbol, timeframe, i - 1);
        
        double candle3_high = iHigh(_Symbol, timeframe, i - 2);
        double candle3_low = iLow(_Symbol, timeframe, i - 2);

        if (direction == 1)  // Bullish FVG
        {
            if (candle2_low > candle1_high && candle3_low > candle1_high)
            {
                double gap_low = candle1_high;
                double gap_high = candle2_low;
                
                if ((gap_high - gap_low) / _Point / 10 >= FVG_Pips)
                {
                    result.low = gap_low;
                    result.high = gap_high;
                    result.time = candle_time;
                    result.isValid = true;
                    result.type = 1;
                    return result;
                }
            }
        }
        else if (direction == -1)  // Bearish FVG
        {
            if (candle2_high < candle1_low && candle3_high < candle1_low)
            {
                double gap_high = candle1_low;
                double gap_low = candle2_high;
                
                if ((gap_high - gap_low) / _Point / 10 >= FVG_Pips)
                {
                    result.low = gap_low;
                    result.high = gap_high;
                    result.time = candle_time;
                    result.isValid = true;
                    result.type = -1;
                    return result;
                }
            }
        }
    }

    return result;
}

//+------------------------------------------------------------------+
//|                  LIQUIDITY SWEEP DETECTION                       |
//+------------------------------------------------------------------+

Sweep Detect5MSweep(FVG fvg)
{
    Sweep result;
    result.found = false;
    result.entryValid = false;
    result.sweepLow = 0;
    result.sweepHigh = 0;
    result.entryPrice = 0;
    result.direction = 0;

    if (iBars(_Symbol, PERIOD_M5) < 2)
        return result;

    // For Bullish FVG: Look for sweep pattern (down then up)
    if (fvg.type == 1)
    {
        // Find if we have a down candle (move down)
        if (iClose(_Symbol, PERIOD_M5, 2) < iOpen(_Symbol, PERIOD_M5, 2))
        {
            double lowest_point = iLow(_Symbol, PERIOD_M5, 2);

            // Check if current candle is up candle (move up) - sweep confirmation
            if (iClose(_Symbol, PERIOD_M5, 1) > iOpen(_Symbol, PERIOD_M5, 1))
            {
                // Check if price went below lowest point of down candle
                if (iLow(_Symbol, PERIOD_M5, 1) < lowest_point)
                {
                    result.found = true;
                    result.sweepLow = MathMin(iLow(_Symbol, PERIOD_M5, 2), iLow(_Symbol, PERIOD_M5, 1));
                    result.sweepHigh = MathMax(iHigh(_Symbol, PERIOD_M5, 2), iHigh(_Symbol, PERIOD_M5, 1));
                    result.direction = 1;  // Bullish entry

                    // Check if current candle closes above entry point (green close)
                    if (iClose(_Symbol, PERIOD_M5, 1) > iOpen(_Symbol, PERIOD_M5, 1))
                    {
                        result.entryValid = true;
                        result.entryPrice = iClose(_Symbol, PERIOD_M5, 1);
                    }
                }
            }
        }
    }

    // For Bearish FVG: Look for sweep pattern (up then down)
    if (fvg.type == -1)
    {
        // Find if we have an up candle (move up)
        if (iClose(_Symbol, PERIOD_M5, 2) > iOpen(_Symbol, PERIOD_M5, 2))
        {
            double highest_point = iHigh(_Symbol, PERIOD_M5, 2);

            // Check if current candle is down candle (move down) - sweep confirmation
            if (iClose(_Symbol, PERIOD_M5, 1) < iOpen(_Symbol, PERIOD_M5, 1))
            {
                // Check if price went above highest point of up candle
                if (iHigh(_Symbol, PERIOD_M5, 1) > highest_point)
                {
                    result.found = true;
                    result.sweepHigh = MathMax(iHigh(_Symbol, PERIOD_M5, 2), iHigh(_Symbol, PERIOD_M5, 1));
                    result.sweepLow = MathMin(iLow(_Symbol, PERIOD_M5, 2), iLow(_Symbol, PERIOD_M5, 1));
                    result.direction = -1;  // Bearish entry

                    // Check if current candle closes below entry point (red close)
                    if (iClose(_Symbol, PERIOD_M5, 1) < iOpen(_Symbol, PERIOD_M5, 1))
                    {
                        result.entryValid = true;
                        result.entryPrice = iClose(_Symbol, PERIOD_M5, 1);
                    }
                }
            }
        }
    }

    return result;
}

//+------------------------------------------------------------------+
//|                 HIGH/LOW DETECTION FOR BIAS                      |
//+------------------------------------------------------------------+

BiasLevel FindNearestHighLow(FVG fvg, ENUM_TIMEFRAMES timeframe)
{
    BiasLevel result;
    result.level = 0;
    result.type = 0;
    result.time = 0;

    if (iBars(_Symbol, timeframe) < 2)
        return result;

    // For bullish FVG, find nearest HIGH (up then down)
    if (fvg.type == 1)
    {
        for (int i = 1; i < 20; i++)
        {
            // Look for green candle followed by red candle (up move then down move)
            if (iClose(_Symbol, timeframe, i) > iOpen(_Symbol, timeframe, i) &&
                iClose(_Symbol, timeframe, i - 1) < iOpen(_Symbol, timeframe, i - 1))
            {
                double highest = MathMax(iHigh(_Symbol, timeframe, i), iHigh(_Symbol, timeframe, i - 1));
                result.level = highest;
                result.type = 1;  // High
                result.time = iTime(_Symbol, timeframe, i);
                return result;
            }
        }
    }

    // For bearish FVG, find nearest LOW (down then up)
    if (fvg.type == -1)
    {
        for (int i = 1; i < 20; i++)
        {
            // Look for red candle followed by green candle (down move then up move)
            if (iClose(_Symbol, timeframe, i) < iOpen(_Symbol, timeframe, i) &&
                iClose(_Symbol, timeframe, i - 1) > iOpen(_Symbol, timeframe, i - 1))
            {
                double lowest = MathMin(iLow(_Symbol, timeframe, i), iLow(_Symbol, timeframe, i - 1));
                result.level = lowest;
                result.type = -1;  // Low
                result.time = iTime(_Symbol, timeframe, i);
                return result;
            }
        }
    }

    return result;
}

//+------------------------------------------------------------------+
//|                      ENTRY EXECUTION                             |
//+------------------------------------------------------------------+

void ExecuteEntry(Sweep &sweep, int direction)
{
    if (PositionSelect(_Symbol))
        return;  // Only one position per symbol

    double entryPrice = sweep.entryPrice;
    double stopLoss = CalculateStopLoss(sweep);
    double takeProfit = CalculateTakeProfit(entryPrice, stopLoss, direction);

    double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercent / 100.0);
    double pipValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double pipsRisk = NormalizeDouble(riskAmount / pipValue, 2);
    double volume = NormalizeDouble(pipsRisk / MathAbs(entryPrice - stopLoss) * _Point, 2);

    // Ensure minimum volume
    double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    volume = MathMax(minVolume, MathMin(volume, maxVolume));

    if (direction == 1)  // Bullish
    {
        trade.Buy(volume, _Symbol, entryPrice, stopLoss, takeProfit, "Path Entry");
    }
    else if (direction == -1)  // Bearish
    {
        trade.Sell(volume, _Symbol, entryPrice, stopLoss, takeProfit, "Path Entry");
    }
}

//+------------------------------------------------------------------+
//|                    STOP LOSS CALCULATION                         |
//+------------------------------------------------------------------+

double CalculateStopLoss(Sweep &sweep)
{
    double sl = 0;

    if (SL_Model == 1)  // Wick-based
    {
        if (sweep.direction == 1)  // Bullish
        {
            sl = sweep.sweepLow;
        }
        else  // Bearish
        {
            sl = sweep.sweepHigh;
        }
    }
    else if (SL_Model == 2)  // Body-based (5 pips fallback to wick)
    {
        double bodySize = MathAbs(iClose(_Symbol, PERIOD_M5, 1) - iOpen(_Symbol, PERIOD_M5, 1)) / _Point / 10;

        if (bodySize > 10)
        {
            if (sweep.direction == 1)  // Bullish
            {
                sl = sweep.entryPrice - 5 * _Point * 10;
            }
            else  // Bearish
            {
                sl = sweep.entryPrice + 5 * _Point * 10;
            }
        }
        else  // Fall back to wick
        {
            if (sweep.direction == 1)  // Bullish
            {
                sl = sweep.sweepLow;
            }
            else  // Bearish
            {
                sl = sweep.sweepHigh;
            }
        }
    }

    return sl;
}

//+------------------------------------------------------------------+
//|                 TAKE PROFIT CALCULATION                          |
//+------------------------------------------------------------------+

double CalculateTakeProfit(double entry, double stopLoss, int direction)
{
    double riskPips = MathAbs(entry - stopLoss) / _Point / 10;
    double profitPips = riskPips * TakeProfit_RR;

    if (direction == 1)  // Bullish
    {
        return entry + (profitPips * _Point * 10);
    }
    else  // Bearish
    {
        return entry - (profitPips * _Point * 10);
    }
}

//+------------------------------------------------------------------+
//|                     BREAK EVEN LOGIC                             |
//+------------------------------------------------------------------+

void CheckBreakEven()
{
    if (!PositionSelect(_Symbol))
        return;

    double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double entry = PositionGetDouble(POSITION_PRICE_OPEN);
    double sl = PositionGetDouble(POSITION_SL);
    double tp = PositionGetDouble(POSITION_TP);
    int posType = (int)PositionGetInteger(POSITION_TYPE);

    double riskPips = MathAbs(entry - sl) / _Point / 10;
    double profitTarget = riskPips * BreakEven_RR;

    if (posType == POSITION_TYPE_BUY)
    {
        double currentProfit = (currentPrice - entry) / _Point / 10;
        
        if (currentProfit >= profitTarget)
        {
            trade.PositionModify(_Symbol, entry + 10 * _Point, tp);
        }
    }
    else if (posType == POSITION_TYPE_SELL)
    {
        double currentProfit = (entry - currentPrice) / _Point / 10;
        
        if (currentProfit >= profitTarget)
        {
            trade.PositionModify(_Symbol, entry - 10 * _Point, tp);
        }
    }
}

//+------------------------------------------------------------------+
//|                   FVG VALIDATION                                 |
//+------------------------------------------------------------------+

bool IsFVGValid(FVG fvg, ENUM_TIMEFRAMES timeframe)
{
    if (!fvg.isValid)
        return false;

    // Check if FVG has been closed past (invalidated)
    for (int i = 0; i < 10; i++)
    {
        if (fvg.type == 1)  // Bullish FVG
        {
            if (iClose(_Symbol, timeframe, i) < fvg.low)
                return false;
        }
        else if (fvg.type == -1)  // Bearish FVG
        {
            if (iClose(_Symbol, timeframe, i) > fvg.high)
                return false;
        }
    }

    return true;
}

//+------------------------------------------------------------------+
//|              SESSION AND TRADING TIME CHECKS                     |
//+------------------------------------------------------------------+

bool IsSessionActive()
{
    MqlDateTime current;
    TimeToStruct(TimeCurrent(), current);

    int currentHour = current.hour;
    int currentMinute = current.min;

    int sessionStartMinutes = SessionStartHour * 60 + SessionStartMinute;
    int sessionEndMinutes = SessionEndHour * 60 + SessionEndMinute;
    int currentMinutes = currentHour * 60 + currentMinute;

    return (currentMinutes >= sessionStartMinutes && currentMinutes < sessionEndMinutes);
}

bool IsCurrentDaySession()
{
    MqlDateTime current;
    TimeToStruct(TimeCurrent(), current);
    
    return (current.day_of_week >= 1 && current.day_of_week <= 5);  // Mon-Fri
}

bool ShouldTradeToday()
{
    MqlDateTime current;
    TimeToStruct(TimeCurrent(), current);

    int dayOfWeek = current.day_of_week;
    if (dayOfWeek == 0) dayOfWeek = 7;  // Convert Sunday to 7

    string daysArray[];
    StringSplit(TradingDays, ',', daysArray);

    for (int i = 0; i < ArraySize(daysArray); i++)
    {
        if (StringToInteger(daysArray[i]) == dayOfWeek)
            return true;
    }

    return false;
}

bool ShouldTradeThisMonth()
{
    MqlDateTime current;
    TimeToStruct(TimeCurrent(), current);

    string monthsArray[];
    StringSplit(TradingMonths, ',', monthsArray);

    for (int i = 0; i < ArraySize(monthsArray); i++)
    {
        if (StringToInteger(monthsArray[i]) == current.mon)
            return true;
    }

    return false;
}

//+------------------------------------------------------------------+
//| END OF EA                                                         |
//+------------------------------------------------------------------+
