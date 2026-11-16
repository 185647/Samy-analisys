//+------------------------------------------------------------------+
//|                                            GoldTrendFollower.mq5 |
//|   Trend following for XAUUSD (H4 recommended)                    |
//|   Donchian breakout + EMA trend filter + time-series momentum    |
//|   ATR initial stop + chandelier trailing stop + Donchian exit    |
//+------------------------------------------------------------------+
#property copyright "Samy-analisys"
#property version   "1.00"
#property description "Gold trend follower: Donchian breakout, EMA filter, time-series momentum, ATR stops."
#property description "Recommended: XAUUSD, H4. Test in Strategy Tester and on a DEMO account first."

#include <Trade/Trade.mqh>

enum ENUM_RISK_MODE
  {
   RISK_FIXED_MONEY     = 0, // Fixed money per trade
   RISK_PERCENT_BALANCE = 1  // Percent of balance per trade
  };

//--- inputs
input group "General"
input bool   InpSignalOnly      = false;     // Signals only (no orders)
input ulong  InpMagic           = 26111601;  // Magic number
input bool   InpAlerts          = true;      // Popup alerts
input bool   InpPush            = false;     // Push notifications to phone

input group "Entry / exit"
input int    InpEntryChannel    = 20;        // Donchian breakout lookback (bars)
input int    InpExitChannel     = 10;        // Donchian exit lookback (bars)
input int    InpEmaPeriod       = 200;       // EMA trend filter period (0 = off)
input int    InpMomentumDays    = 126;       // Momentum lookback in D1 bars (0 = off)
input bool   InpAllowLong       = true;      // Allow long trades
input bool   InpAllowShort      = true;      // Allow short trades

input group "Stops"
input int    InpAtrPeriod       = 20;        // ATR period
input double InpInitialStopATR  = 3.0;       // Initial stop distance (x ATR)
input double InpTrailStopATR    = 3.0;       // Chandelier trailing stop (x ATR, 0 = off)
input int    InpTrailLookback   = 22;        // Chandelier lookback (bars)

input group "Risk"
input ENUM_RISK_MODE InpRiskMode = RISK_PERCENT_BALANCE; // Risk mode
input double InpRiskMoney       = 50.0;      // Risk per trade (account currency)
input double InpRiskPercent     = 0.5;       // Risk per trade (% of balance)
input double InpMaxLots         = 5.0;       // Maximum lots per trade
input int    InpMaxSpreadPoints = 80;        // Max spread to open (points, 0 = off)
input int    InpSlippagePoints  = 30;        // Max slippage (points)

//--- globals
CTrade   trade;
int      hEma = INVALID_HANDLE;
int      hAtr = INVALID_HANDLE;
datetime gLastBar      = 0;
int      gPendingDir   = 0;    // signal waiting for execution in this bar
double   gPendingAtr   = 0.0;
int      gLastAlertDir = 0;    // signal-only mode: last alerted direction

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpEntryChannel < 2 || InpExitChannel < 2 || InpAtrPeriod < 1)
     {
      Print("Invalid channel/ATR inputs");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpEmaPeriod > 0)
     {
      hEma = iMA(_Symbol, _Period, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(hEma == INVALID_HANDLE)
        {
         Print("Failed to create EMA handle");
         return(INIT_FAILED);
        }
     }
   hAtr = iATR(_Symbol, _Period, InpAtrPeriod);
   if(hAtr == INVALID_HANDLE)
     {
      Print("Failed to create ATR handle");
      return(INIT_FAILED);
     }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   if(_Period != PERIOD_H4)
      Print("Note: GoldTrendFollower was designed for H4. Current timeframe: ", EnumToString(_Period));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hEma != INVALID_HANDLE)
      IndicatorRelease(hEma);
   if(hAtr != INVALID_HANDLE)
      IndicatorRelease(hAtr);
  }

//+------------------------------------------------------------------+
void Notify(const string msg)
  {
   Print(msg);
   if(MQLInfoInteger(MQL_TESTER))
      return;
   if(InpAlerts)
      Alert(msg);
   if(InpPush && TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
      SendNotification(msg);
  }

//+------------------------------------------------------------------+
bool SpreadOk()
  {
   if(InpMaxSpreadPoints <= 0)
      return(true);
   return(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpreadPoints);
  }

//+------------------------------------------------------------------+
double MinStopDistance()
  {
   long lvl    = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return((double)(lvl + spread + 5) * _Point);
  }

//+------------------------------------------------------------------+
int VolumeDigits()
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int d = 0;
   while(step < 1.0 - 1e-9 && d < 8)
     {
      step *= 10.0;
      d++;
     }
   return(d);
  }

//+------------------------------------------------------------------+
double RiskMoney()
  {
   if(InpRiskMode == RISK_FIXED_MONEY)
      return(InpRiskMoney);
   return(AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0);
  }

//+------------------------------------------------------------------+
//| Lots so that a stop-out loses ~riskMoney                         |
//+------------------------------------------------------------------+
double CalcLots(const ENUM_ORDER_TYPE type, const double entry, const double sl, const double riskMoney)
  {
   double lossPerLot = 0.0;
   if(!OrderCalcProfit(type, _Symbol, 1.0, entry, sl, lossPerLot))
      return(0.0);
   lossPerLot = MathAbs(lossPerLot);
   if(lossPerLot <= 0.0 || riskMoney <= 0.0)
      return(0.0);

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0)
      step = 0.01;

   double lots = MathFloor((riskMoney / lossPerLot) / step) * step;
   if(lots < minV)
     {
      // allow minimum lot only if it does not exceed risk by more than 20%
      if(minV * lossPerLot <= riskMoney * 1.2)
         lots = minV;
      else
        {
         PrintFormat("Skip: min lot %.2f would risk %.2f (> %.2f)", minV, minV * lossPerLot, riskMoney);
         return(0.0);
        }
     }
   lots = MathMin(lots, MathMin(maxV, InpMaxLots));

   double margin = 0.0;
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   while(lots > minV && OrderCalcMargin(type, _Symbol, lots, entry, margin) && margin > freeMargin * 0.9)
      lots -= step;
   if(OrderCalcMargin(type, _Symbol, lots, entry, margin) && margin > freeMargin * 0.9)
     {
      Print("Skip: not enough free margin");
      return(0.0);
     }
   return(NormalizeDouble(lots, VolumeDigits()));
  }

//+------------------------------------------------------------------+
bool GetMomentum(double &mom)
  {
   mom = 0.0;
   if(InpMomentumDays <= 0)
      return(true);
   double d[];
   int need = InpMomentumDays + 1;
   int n = CopyClose(_Symbol, PERIOD_D1, 1, need, d);   // d[0] oldest, d[n-1] = yesterday
   if(n != need || d[0] <= 0.0)
      return(false);
   mom = d[n - 1] / d[0] - 1.0;
   return(true);
  }

//+------------------------------------------------------------------+
int CountMyPositions()
  {
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic)
         continue;
      cnt++;
     }
   return(cnt);
  }

//+------------------------------------------------------------------+
//| Donchian exit + chandelier trailing                              |
//+------------------------------------------------------------------+
void ManagePositions(const double close1, const double atr, const double exitLow, const double exitHigh)
  {
   double minDist = MinStopDistance();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic)
         continue;

      long   ptype = PositionGetInteger(POSITION_TYPE);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);

      if(ptype == POSITION_TYPE_BUY)
        {
         if(close1 < exitLow)
           {
            if(trade.PositionClose(tk))
               Notify(StringFormat("%s GoldTrendFollower: EXIT LONG (close %.2f < %d-bar low %.2f)", _Symbol, close1, InpExitChannel, exitLow));
            continue;
           }
         if(InpTrailStopATR > 0.0)
           {
            int idx = iHighest(_Symbol, _Period, MODE_HIGH, InpTrailLookback, 1);
            if(idx < 0)
               continue;
            double nsl = NormalizeDouble(iHigh(_Symbol, _Period, idx) - InpTrailStopATR * atr, _Digits);
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            if(nsl > curSL + _Point && nsl < bid - minDist)
               trade.PositionModify(tk, nsl, curTP);
           }
        }
      else
         if(ptype == POSITION_TYPE_SELL)
           {
            if(close1 > exitHigh)
              {
               if(trade.PositionClose(tk))
                  Notify(StringFormat("%s GoldTrendFollower: EXIT SHORT (close %.2f > %d-bar high %.2f)", _Symbol, close1, InpExitChannel, exitHigh));
               continue;
              }
            if(InpTrailStopATR > 0.0)
              {
               int idx = iLowest(_Symbol, _Period, MODE_LOW, InpTrailLookback, 1);
               if(idx < 0)
                  continue;
               double nsl = NormalizeDouble(iLow(_Symbol, _Period, idx) + InpTrailStopATR * atr, _Digits);
               double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               if((curSL == 0.0 || nsl < curSL - _Point) && nsl > ask + minDist)
                  trade.PositionModify(tk, nsl, curTP);
              }
           }
     }
  }

//+------------------------------------------------------------------+
void TryOpen()
  {
   if(gPendingDir == 0)
      return;
   if(!InpSignalOnly && CountMyPositions() > 0)
     {
      gPendingDir = 0;
      return;
     }
   if(!SpreadOk())
      return;   // retry on next tick within this bar

   int    dir   = gPendingDir;
   double price = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double dist  = MathMax(InpInitialStopATR * gPendingAtr, MinStopDistance());
   double sl    = NormalizeDouble((dir > 0) ? price - dist : price + dist, _Digits);
   ENUM_ORDER_TYPE type = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double risk  = RiskMoney();
   double lots  = CalcLots(type, price, sl, risk);
   gPendingDir  = 0;

   string side = (dir > 0) ? "BUY" : "SELL";
   string msg  = StringFormat("%s GoldTrendFollower: %s @ %.2f  SL %.2f  lots %.2f  risk %.2f",
                              _Symbol, side, price, sl, lots, risk);
   if(InpSignalOnly)
     {
      Notify("[SIGNAL] " + msg);
      return;
     }
   if(lots <= 0.0)
      return;
   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, price, sl, 0.0, "GTF")
                       : trade.Sell(lots, _Symbol, price, sl, 0.0, "GTF");
   if(ok && (trade.ResultRetcode() == TRADE_RETCODE_DONE || trade.ResultRetcode() == TRADE_RETCODE_PLACED))
      Notify(msg);
   else
      PrintFormat("Order failed: %u %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   datetime t = iTime(_Symbol, _Period, 0);
   if(t == 0)
      return;

   if(t != gLastBar)
     {
      gLastBar    = t;
      gPendingDir = 0;

      double atrBuf[];
      if(CopyBuffer(hAtr, 0, 1, 1, atrBuf) != 1)
         return;
      double atr = atrBuf[0];

      double ema = 0.0;
      if(hEma != INVALID_HANDLE)
        {
         double emaBuf[];
         if(CopyBuffer(hEma, 0, 1, 1, emaBuf) != 1)
            return;
         ema = emaBuf[0];
        }

      if(Bars(_Symbol, _Period) < MathMax(InpEntryChannel, InpTrailLookback) + 5)
         return;

      double close1 = iClose(_Symbol, _Period, 1);
      int iHiE = iHighest(_Symbol, _Period, MODE_HIGH, InpEntryChannel, 2);
      int iLoE = iLowest(_Symbol, _Period, MODE_LOW, InpEntryChannel, 2);
      int iHiX = iHighest(_Symbol, _Period, MODE_HIGH, InpExitChannel, 2);
      int iLoX = iLowest(_Symbol, _Period, MODE_LOW, InpExitChannel, 2);
      if(iHiE < 0 || iLoE < 0 || iHiX < 0 || iLoX < 0)
         return;
      double entryHigh = iHigh(_Symbol, _Period, iHiE);
      double entryLow  = iLow(_Symbol, _Period, iLoE);
      double exitHigh  = iHigh(_Symbol, _Period, iHiX);
      double exitLow   = iLow(_Symbol, _Period, iLoX);

      double mom = 0.0;
      if(!GetMomentum(mom))
         return;

      //--- manage open positions / exit signals
      if(!InpSignalOnly)
         ManagePositions(close1, atr, exitLow, exitHigh);
      else
        {
         if(gLastAlertDir > 0 && close1 < exitLow)
           {
            Notify(StringFormat("[SIGNAL] %s GoldTrendFollower: EXIT LONG (close %.2f < %d-bar low)", _Symbol, close1, InpExitChannel));
            gLastAlertDir = 0;
           }
         if(gLastAlertDir < 0 && close1 > exitHigh)
           {
            Notify(StringFormat("[SIGNAL] %s GoldTrendFollower: EXIT SHORT (close %.2f > %d-bar high)", _Symbol, close1, InpExitChannel));
            gLastAlertDir = 0;
           }
        }

      //--- entry signals on the closed bar
      bool trendUp   = (hEma == INVALID_HANDLE) || close1 > ema;
      bool trendDown = (hEma == INVALID_HANDLE) || close1 < ema;
      bool momUp     = (InpMomentumDays <= 0) || mom > 0.0;
      bool momDown   = (InpMomentumDays <= 0) || mom < 0.0;

      int dir = 0;
      if(InpAllowLong && close1 > entryHigh && trendUp && momUp)
         dir = 1;
      else
         if(InpAllowShort && close1 < entryLow && trendDown && momDown)
            dir = -1;

      if(dir != 0)
        {
         if(InpSignalOnly)
           {
            if(dir == gLastAlertDir)
               dir = 0;          // already alerted this trend
            else
               gLastAlertDir = dir;
           }
         else
            if(CountMyPositions() > 0)
               dir = 0;          // one position at a time
        }
      gPendingDir = dir;
      gPendingAtr = atr;
     }

   TryOpen();
  }
//+------------------------------------------------------------------+
