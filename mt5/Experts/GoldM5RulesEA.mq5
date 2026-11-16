//+------------------------------------------------------------------+
//|                                                GoldM5RulesEA.mq5 |
//|   Rule-based M5 scalper for XAUUSD, modelled on the execution    |
//|   framework of SSRN 7279718 (Masoumian & Shafaei) WITHOUT the    |
//|   XGBoost model. The ML forecast is replaced by a transparent    |
//|   linear-regression extrapolation of the last N closes.          |
//+------------------------------------------------------------------+
#property copyright "Samy-analisys"
#property version   "1.00"
#property description "XAUUSD M5 rule-based EA (paper framework, no ML): regression score + TN/MA/CA/PVT filters,"
#property description "SL at 80% of 5-bar swing, TP 1.5R, fixed $ risk, daily loss/profit limits, session filter."

#include <Trade/Trade.mqh>

//--- inputs
input group "General"
input bool   InpSignalOnly        = false;     // Signals only (no orders)
input ulong  InpMagic             = 26111602;  // Magic number
input bool   InpAlerts            = true;      // Popup alerts
input bool   InpPush              = false;     // Push notifications to phone
input bool   InpTelegram        = false;     // Send messages to Telegram
input string InpTgToken         = "";        // Telegram bot token (from @BotFather)
input string InpTgChatId        = "";        // Telegram chat id
input bool   InpDrawArrows        = true;      // Draw signal arrows on chart
input int    InpSignalCooldown    = 6;         // Signal-only mode: min bars between signals

input group "Primary signal (forecast score)"
input bool   InpUseScore          = true;      // Use regression score (else trend TN only)
input int    InpScoreLookback     = 12;        // Regression lookback (bars) - paper: 12
input int    InpScoreHorizon      = 12;        // Forecast horizon (bars) - paper: 12
input double InpScoreThreshold    = 0.5;       // Score threshold (x ATR) - paper: 0.5

input group "Indicators"
input int    InpMaFastPeriod      = 5;         // MA on close / MA on open period
input int    InpMaTrendPeriod     = 15;        // Trend MA period (TN)
input int    InpPivotPeriod       = 96;        // Pivot MA period (typical price)
input int    InpAtrPeriod         = 14;        // ATR period
input int    InpFractalVolPeriod  = 20;        // Volume average for fractal filter

input group "Confirmation filters"
input int    InpConfirmBars       = 3;         // TN/MA must agree on last N closed bars (paper: 3-row matrix)
input bool   InpUseTN             = true;      // TN: close vs trend MA
input bool   InpUseMA             = true;      // MA: MA(close) vs MA(open)
input bool   InpUseCA             = true;      // CA: candle close position
input bool   InpUsePVT            = true;      // PVT: not stretched from pivot
input double InpPVTMaxATR         = 2.0;       // PVT: max distance from pivot (x ATR)
input bool   InpUsePV             = false;     // PV: price on "cheap" side of pivot (contrarian)
input bool   InpUseFV             = false;     // FV: last fractal (with volume) agrees
input int    InpFVLookback        = 10;        // FV: bars to look back for a fractal
input double InpMaxBodyATR        = 2.0;       // Skip if signal candle body > X * ATR

input group "Stops / targets"
input int    InpStopSwingBars     = 5;         // Swing window for stop (bars)
input double InpStopBuffer        = 0.8;       // Stop at X of swing distance (paper: 0.8)
input double InpMinStopATR        = 0.5;       // Minimum stop distance (x ATR)
input double InpMaxStopATR        = 3.0;       // Skip trade if stop > X * ATR
input double InpRewardRisk        = 1.5;       // Take profit (x stop distance) (paper: 1.5)
input bool   InpUseEarlyExit      = true;      // Close when TN and MA both flip against position

input group "Risk"
input double InpRiskMoney         = 50.0;      // Fixed risk per trade (account currency) (paper: 50)
input double InpMaxLots           = 5.0;       // Maximum lots per trade
input int    InpMaxSpreadPoints   = 50;        // Max spread to open (points, 0 = off)
input int    InpSlippagePoints    = 20;        // Max slippage (points)
input double InpDailyLossLimit    = 200.0;     // Daily loss limit (0 = off) (paper: 200)
input double InpDailyProfitTarget = 400.0;     // Daily profit target (0 = off) (paper: 400)
input bool   InpCloseOnDailyLimit = true;      // Close open position when a daily limit is hit
input int    InpMaxTradesPerDay   = 0;         // Max trades per day (0 = unlimited)

input group "Session (broker server time)"
input int    InpSessionStartHour  = 8;         // Start hour (paper: 08:00 UTC+2)
input int    InpSessionEndHour    = 20;        // End hour   (paper: 20:00 UTC+2)
input bool   InpCloseAtSessionEnd = false;     // Close open position outside session
input bool   InpTradeMonday       = true;
input bool   InpTradeTuesday      = true;
input bool   InpTradeWednesday    = true;
input bool   InpTradeThursday     = true;
input bool   InpTradeFriday       = true;

//--- globals
CTrade   trade;
#define  EA_NAME "GoldM5RulesEA"
string   gCloseReason = "";
int      hMaC = INVALID_HANDLE, hMaO = INVALID_HANDLE, hMaT = INVALID_HANDLE;
int      hPiv = INVALID_HANDLE, hAtr = INVALID_HANDLE;

MqlRates rates[];
double   maC[], maO[], maT[], piv[], atr[];
int      gNB = 0;

datetime gLastBar       = 0;
datetime gDayStart      = 0;
bool     gHalted        = false;
double   gClosedPnL     = 0.0;
int      gTradesToday   = 0;
int      gLastSignalBarCount = -100000;

int      gPendingDir    = 0;
double   gPendingAtr    = 0.0;
double   gPendingSwingL = 0.0;
double   gPendingSwingH = 0.0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpScoreLookback < 3 || InpConfirmBars < 1 || InpStopSwingBars < 1)
      return(INIT_PARAMETERS_INCORRECT);

   hMaC = iMA(_Symbol, _Period, InpMaFastPeriod, 0, MODE_SMA, PRICE_CLOSE);
   hMaO = iMA(_Symbol, _Period, InpMaFastPeriod, 0, MODE_SMA, PRICE_OPEN);
   hMaT = iMA(_Symbol, _Period, InpMaTrendPeriod, 0, MODE_SMA, PRICE_CLOSE);
   hPiv = iMA(_Symbol, _Period, InpPivotPeriod, 0, MODE_SMA, PRICE_TYPICAL);
   hAtr = iATR(_Symbol, _Period, InpAtrPeriod);
   if(hMaC == INVALID_HANDLE || hMaO == INVALID_HANDLE || hMaT == INVALID_HANDLE ||
      hPiv == INVALID_HANDLE || hAtr == INVALID_HANDLE)
     {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
     }

   gNB = (int)MathMax(InpScoreLookback, MathMax(InpStopSwingBars, InpConfirmBars));
   gNB = (int)MathMax(gNB, InpFVLookback + InpFractalVolPeriod + 6);
   gNB += 10;

   ArraySetAsSeries(rates, true);
   ArraySetAsSeries(maC, true);
   ArraySetAsSeries(maO, true);
   ArraySetAsSeries(maT, true);
   ArraySetAsSeries(piv, true);
   ArraySetAsSeries(atr, true);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(_Period != PERIOD_M5)
      Print("Note: GoldM5RulesEA was designed for M5. Current timeframe: ", EnumToString(_Period));
   RefreshDailyStats();
   if(InpTelegram && !MQLInfoInteger(MQL_TESTER))
      SendTelegram(AccountTag() + " " + EA_NAME + " started on " + _Symbol + " " + EnumToString(_Period) +
                   (InpSignalOnly ? " (signals only)" : " (auto trading)"));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(hMaC);
   IndicatorRelease(hMaO);
   IndicatorRelease(hMaT);
   IndicatorRelease(hPiv);
   IndicatorRelease(hAtr);
  }

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Telegram                                                         |
//| MT5: Tools > Options > Expert Advisors > Allow WebRequest for    |
//| listed URL > add https://api.telegram.org                        |
//+------------------------------------------------------------------+
string UrlEncode(const string s)
  {
   uchar bytes[];
   int n = StringToCharArray(s, bytes, 0, WHOLE_ARRAY, CP_UTF8);
   string out = "";
   for(int i = 0; i < n - 1; i++)
     {
      uchar c = bytes[i];
      if((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
         c == '-' || c == '_' || c == '.' || c == '~')
         out += CharToString(c);
      else
         out += StringFormat("%%%02X", c);
     }
   return(out);
  }

bool SendTelegram(const string text)
  {
   if(!InpTelegram || InpTgToken == "" || InpTgChatId == "")
      return(false);
   if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION))
      return(false);
   string url  = "https://api.telegram.org/bot" + InpTgToken + "/sendMessage";
   string body = "chat_id=" + InpTgChatId + "&text=" + UrlEncode(text);
   char data[];
   char result[];
   string resHeaders;
   int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(len > 0)
      ArrayResize(data, len - 1);          // drop terminating zero
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   ResetLastError();
   int code = WebRequest("POST", url, headers, 5000, data, result, resHeaders);
   if(code == -1)
     {
      PrintFormat("Telegram failed (error %d). Add https://api.telegram.org in Tools > Options > Expert Advisors > Allow WebRequest.", GetLastError());
      return(false);
     }
   if(code != 200)
      PrintFormat("Telegram HTTP %d: %s", code, CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8));
   return(code == 200);
  }

string AccountTag()
  {
   string kind = (AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO) ? "DEMO" : "REAL";
   return(StringFormat("[%s %I64d]", kind, AccountInfoInteger(ACCOUNT_LOGIN)));
  }

//+------------------------------------------------------------------+
//| Report every closed position (SL / TP / EA exit) with P/L        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != (long)InpMagic)
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;
   double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   long reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
   string why = gCloseReason;
   if(reason == DEAL_REASON_SL)      why = "stop loss";
   else if(reason == DEAL_REASON_TP) why = "take profit";
   else if(reason == DEAL_REASON_SO) why = "stop out";
   else if(why == "")                why = "manual/other";
   gCloseReason = "";
   Notify(StringFormat("%s %s: position CLOSED @ %.2f (%s)  P/L %.2f %s",
                       _Symbol, EA_NAME, HistoryDealGetDouble(trans.deal, DEAL_PRICE), why, pnl,
                       AccountInfoString(ACCOUNT_CURRENCY)));
  }

void Notify(const string msg)
  {
   Print(msg);
   if(MQLInfoInteger(MQL_TESTER))
      return;
   if(InpAlerts)
      Alert(msg);
   if(InpPush && TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
      SendNotification(msg);
   SendTelegram(AccountTag() + " " + msg);
  }

//+------------------------------------------------------------------+
//| Helpers: time, session, spread                                   |
//+------------------------------------------------------------------+
datetime DayStart(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return(StructToTime(dt));
  }

bool InSession(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   switch(dt.day_of_week)
     {
      case 1: if(!InpTradeMonday)    return(false); break;
      case 2: if(!InpTradeTuesday)   return(false); break;
      case 3: if(!InpTradeWednesday) return(false); break;
      case 4: if(!InpTradeThursday)  return(false); break;
      case 5: if(!InpTradeFriday)    return(false); break;
      default: return(false);
     }
   int h = dt.hour;
   if(InpSessionStartHour == InpSessionEndHour)
      return(true);
   if(InpSessionStartHour < InpSessionEndHour)
      return(h >= InpSessionStartHour && h < InpSessionEndHour);
   return(h >= InpSessionStartHour || h < InpSessionEndHour);   // wraps midnight
  }

bool SpreadOk()
  {
   if(InpMaxSpreadPoints <= 0)
      return(true);
   return(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpreadPoints);
  }

double MinStopDistance()
  {
   long lvl    = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return((double)(lvl + spread + 5) * _Point);
  }

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
//| Fixed-money position sizing                                      |
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
//| Positions / daily P&L                                            |
//+------------------------------------------------------------------+
bool GetMyPosition(ulong &ticket, long &ptype)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic)
         continue;
      ticket = tk;
      ptype  = PositionGetInteger(POSITION_TYPE);
      return(true);
     }
   return(false);
  }

double FloatingPnL()
  {
   double pnl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic)
         continue;
      pnl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return(pnl);
  }

void RefreshDailyStats()
  {
   gClosedPnL   = 0.0;
   gTradesToday = 0;
   datetime from = DayStart(TimeCurrent());
   if(!HistorySelect(from, TimeCurrent() + 3600))
      return;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0)
         continue;
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != (long)InpMagic)
         continue;
      if(HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(tk, DEAL_ENTRY) == DEAL_ENTRY_IN)
         gTradesToday++;
      gClosedPnL += HistoryDealGetDouble(tk, DEAL_PROFIT)
                    + HistoryDealGetDouble(tk, DEAL_SWAP)
                    + HistoryDealGetDouble(tk, DEAL_COMMISSION);
     }
  }

void OnTrade()
  {
   RefreshDailyStats();
  }

void CloseMyPosition(const string reason)
  {
   ulong tk = 0;
   long  pt = -1;
   if(!GetMyPosition(tk, pt))
      return;
   gCloseReason = reason;
   if(!trade.PositionClose(tk))
     {
      gCloseReason = "";
      PrintFormat("Close failed: %u %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }

void CheckDailyLimits()
  {
   if(gHalted)
      return;
   double total = gClosedPnL + FloatingPnL();
   bool hitLoss   = (InpDailyLossLimit    > 0.0 && total <= -InpDailyLossLimit);
   bool hitProfit = (InpDailyProfitTarget > 0.0 && total >=  InpDailyProfitTarget);
   if(hitLoss || hitProfit)
     {
      gHalted = true;
      Notify(StringFormat("%s GoldM5RulesEA: daily %s reached (%.2f). Trading halted until tomorrow.",
                          _Symbol, (hitLoss ? "LOSS LIMIT" : "PROFIT TARGET"), total));
      if(InpCloseOnDailyLimit)
         CloseMyPosition("daily limit");
     }
  }

//+------------------------------------------------------------------+
//| Feature functions (index = bar shift, 1 = last closed bar)       |
//+------------------------------------------------------------------+
int TN(const int i)    { return(rates[i].close > maT[i] ? 1 : -1); }

int MAsig(const int i)
  {
   if(maC[i] > maO[i]) return(1);
   if(maC[i] < maO[i]) return(-1);
   return(0);
  }

int CA(const int i)
  {
   double r = rates[i].high - rates[i].low;
   if(r <= 0.0)
      return(0);
   double pos = (rates[i].close - rates[i].low) / r;
   if(rates[i].close > rates[i + 1].close && pos >= 2.0 / 3.0) return(1);
   if(rates[i].close < rates[i + 1].close && pos <= 1.0 / 3.0) return(-1);
   return(0);
  }

int PV(const int i)    { return(rates[i].close > piv[i] ? -1 : 1); }

int PVT(const int i)   { return(MathAbs(rates[i].close - piv[i]) < InpPVTMaxATR * atr[i] ? 1 : 0); }

// Fractal centred on bar c = i + 2 (confirmed by two bars on each side), with volume filter
int FV(const int i)
  {
   int c = i + 2;
   if(c + 2 + InpFractalVolPeriod >= ArraySize(rates))
      return(0);
   double avgVol = 0.0;
   for(int k = c + 1; k <= c + InpFractalVolPeriod; k++)
      avgVol += (double)rates[k].tick_volume;
   avgVol /= InpFractalVolPeriod;
   if((double)rates[c].tick_volume <= avgVol)
      return(0);
   bool lowF  = rates[c].low  < rates[c - 1].low  && rates[c].low  < rates[c - 2].low &&
                rates[c].low  < rates[c + 1].low  && rates[c].low  < rates[c + 2].low;
   bool highF = rates[c].high > rates[c - 1].high && rates[c].high > rates[c - 2].high &&
                rates[c].high > rates[c + 1].high && rates[c].high > rates[c + 2].high;
   if(lowF && !highF)  return(1);
   if(highF && !lowF)  return(-1);
   return(0);
  }

int LatestFV()
  {
   for(int i = 1; i <= InpFVLookback; i++)
     {
      int v = FV(i);
      if(v != 0)
         return(v);
     }
   return(0);
  }

// Stand-in for the paper's ML forecast: linear regression of the last L closes,
// extrapolated to the mean of the next H bars (MPC). Score = (MPC - close) / ATR.
double Score()
  {
   int L = InpScoreLookback;
   int H = InpScoreHorizon;
   double sx = 0, sy = 0, sxx = 0, sxy = 0;
   for(int k = 0; k < L; k++)
     {
      double x = k;                       // 0 = oldest
      double y = rates[L - k].close;      // rates[L] oldest ... rates[1] newest
      sx  += x;
      sy  += y;
      sxx += x * x;
      sxy += x * y;
     }
   double den = L * sxx - sx * sx;
   if(den == 0.0 || atr[1] <= 0.0)
      return(0.0);
   double b   = (L * sxy - sx * sy) / den;
   double a   = (sy - b * sx) / L;
   double mpc = a + b * (L + (H - 1) / 2.0);
   return((mpc - rates[1].close) / atr[1]);
  }

//+------------------------------------------------------------------+
bool LoadData()
  {
   if(CopyRates(_Symbol, _Period, 0, gNB, rates) != gNB) return(false);
   if(CopyBuffer(hMaC, 0, 0, gNB, maC) != gNB)           return(false);
   if(CopyBuffer(hMaO, 0, 0, gNB, maO) != gNB)           return(false);
   if(CopyBuffer(hMaT, 0, 0, gNB, maT) != gNB)           return(false);
   if(CopyBuffer(hPiv, 0, 0, gNB, piv) != gNB)           return(false);
   if(CopyBuffer(hAtr, 0, 0, gNB, atr) != gNB)           return(false);
   return(true);
  }

void DrawArrow(const int dir, const datetime t, const double price)
  {
   if(!InpDrawArrows)
      return;
   string name = StringFormat("GM5_%s_%I64d", (dir > 0 ? "B" : "S"), (long)t);
   ENUM_OBJECT ot = (dir > 0) ? OBJ_ARROW_BUY : OBJ_ARROW_SELL;
   if(ObjectCreate(0, name, ot, 0, t, price))
      ObjectSetInteger(0, name, OBJPROP_COLOR, (dir > 0 ? clrDodgerBlue : clrOrangeRed));
  }

//+------------------------------------------------------------------+
//| Evaluate signal on the last closed bar                           |
//+------------------------------------------------------------------+
int EvaluateSignal(string &why)
  {
   int dir = 0;
   double sc = 0.0;
   if(InpUseScore)
     {
      sc = Score();
      if(sc >  InpScoreThreshold) dir = 1;
      if(sc < -InpScoreThreshold) dir = -1;
     }
   else
      dir = TN(1);
   if(dir == 0)
      return(0);

   for(int k = 1; k <= InpConfirmBars; k++)
     {
      if(InpUseTN && TN(k) != dir)    return(0);
      if(InpUseMA && MAsig(k) != dir) return(0);
     }
   if(InpUseCA  && CA(1) != dir)       return(0);
   if(InpUsePVT && PVT(1) != 1)        return(0);
   if(InpUsePV  && PV(1) != dir)       return(0);
   if(InpUseFV  && LatestFV() != dir)  return(0);
   if(MathAbs(rates[1].open - rates[1].close) > InpMaxBodyATR * atr[1])
      return(0);

   why = StringFormat("score %.2f, ATR %.2f", sc, atr[1]);
   return(dir);
  }

//+------------------------------------------------------------------+
void TryOpen()
  {
   if(gPendingDir == 0)
      return;
   if(!SpreadOk())
      return;   // retry on next tick within this bar

   int    dir   = gPendingDir;
   double price = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double a     = gPendingAtr;
   double swing = (dir > 0) ? price - gPendingSwingL : gPendingSwingH - price;
   double dist  = InpStopBuffer * swing;
   dist = MathMax(dist, InpMinStopATR * a);
   dist = MathMax(dist, MinStopDistance());
   if(dist > InpMaxStopATR * a)
     {
      PrintFormat("Skip: stop %.2f > %.1f x ATR", dist, InpMaxStopATR);
      gPendingDir = 0;
      return;
     }
   double sl = NormalizeDouble((dir > 0) ? price - dist : price + dist, _Digits);
   double tp = NormalizeDouble((dir > 0) ? price + InpRewardRisk * dist : price - InpRewardRisk * dist, _Digits);
   ENUM_ORDER_TYPE type = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double lots = CalcLots(type, price, sl, InpRiskMoney);
   gPendingDir = 0;

   string msg = StringFormat("%s GoldM5RulesEA: %s @ %.2f  SL %.2f  TP %.2f  lots %.2f",
                             _Symbol, (dir > 0 ? "BUY" : "SELL"), price, sl, tp, lots);
   if(InpSignalOnly)
     {
      Notify("[SIGNAL] " + msg);
      DrawArrow(dir, iTime(_Symbol, _Period, 0), price);
      return;
     }
   if(lots <= 0.0)
      return;
   bool ok = (dir > 0) ? trade.Buy(lots, _Symbol, price, sl, tp, "GM5")
                       : trade.Sell(lots, _Symbol, price, sl, tp, "GM5");
   if(ok && (trade.ResultRetcode() == TRADE_RETCODE_DONE || trade.ResultRetcode() == TRADE_RETCODE_PLACED))
     {
      Notify(msg);
      DrawArrow(dir, iTime(_Symbol, _Period, 0), price);
     }
   else
      PrintFormat("Order failed: %u %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now = TimeCurrent();

   //--- new day reset
   datetime ds = DayStart(now);
   if(ds != gDayStart)
     {
      gDayStart = ds;
      gHalted   = false;
      RefreshDailyStats();
     }

   ulong tk  = 0;
   long  pt  = -1;
   bool  hasPos = GetMyPosition(tk, pt);

   if(!InpSignalOnly && hasPos)
      CheckDailyLimits();

   datetime t = iTime(_Symbol, _Period, 0);
   if(t == 0)
      return;

   if(t != gLastBar)
     {
      gLastBar    = t;
      gPendingDir = 0;
      if(Bars(_Symbol, _Period) < MathMax(gNB, InpPivotPeriod) + 5)
         return;
      if(!LoadData())
         return;

      RefreshDailyStats();
      if(!InpSignalOnly)
         CheckDailyLimits();

      hasPos = GetMyPosition(tk, pt);

      //--- session end handling
      if(!InpSignalOnly && hasPos && InpCloseAtSessionEnd && !InSession(now))
        {
         CloseMyPosition("outside session");
         hasPos = false;
        }

      //--- early exit: TN and MA both against the position
      bool earlyExited = false;
      if(!InpSignalOnly && hasPos && InpUseEarlyExit)
        {
         int against = (pt == POSITION_TYPE_BUY) ? -1 : 1;
         if(TN(1) == against && MAsig(1) == against)
           {
            CloseMyPosition("early exit: TN & MA reversed");
            earlyExited = true;
            hasPos = false;
           }
        }

      //--- entry conditions
      if(earlyExited)            return;   // paper: no opposite entry right after a reversal exit
      if(!InSession(now))        return;
      if(!InpSignalOnly && (hasPos || gHalted)) return;
      if(InpMaxTradesPerDay > 0 && gTradesToday >= InpMaxTradesPerDay) return;

      string why = "";
      int dir = EvaluateSignal(why);
      if(dir == 0)
         return;

      if(InpSignalOnly)
        {
         int barCount = Bars(_Symbol, _Period);
         if(barCount - gLastSignalBarCount < InpSignalCooldown)
            return;
         gLastSignalBarCount = barCount;
        }

      double lo = rates[1].low, hi = rates[1].high;
      for(int k = 1; k <= InpStopSwingBars; k++)
        {
         lo = MathMin(lo, rates[k].low);
         hi = MathMax(hi, rates[k].high);
        }
      gPendingDir    = dir;
      gPendingAtr    = atr[1];
      gPendingSwingL = lo;
      gPendingSwingH = hi;
      Print("Signal ", (dir > 0 ? "BUY" : "SELL"), " (", why, ")");
     }

   TryOpen();
  }
//+------------------------------------------------------------------+
