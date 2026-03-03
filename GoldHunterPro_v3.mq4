//+------------------------------------------------------------------+
//|                                        GoldHunterPro_v3.mq4     |
//|                Bot de trading automatique XAUUSD — Version 3.0  |
//|                                                                  |
//|  AMÉLIORATIONS v3 (basées sur audit + simulation 12 mois) :     |
//|                                                                  |
//|  1. Timeframe M5 (3× plus de signaux que M15)                   |
//|  2. Filtre tendance H1 uniquement (H4 trop restrictif)          |
//|  3. TROIS types de signaux :                                     |
//|     - Signal A: Croisement EMA 8/21 sur M5 dans direction H1    |
//|     - Signal B: RSI pullback/rebond en direction de tendance     |
//|     - Signal C: Breakout session London open (Asian range)       |
//|  4. Breakeven automatique à 1.0× ATR                            |
//|  5. Clôture partielle 50% à 1.0× ATR                            |
//|  6. Trailing stop uniquement après breakeven                     |
//|  7. Profit target journalier (3%)                               |
//|  8. MaxOpenTrades = 4                                           |
//|  9. Vendredi matin autorisé (coupe à 14h GMT)                   |
//|  10. Cooldown 20 min entre signaux du même type                  |
//|                                                                  |
//|  OBJECTIF : 3+ trades/jour | Capital initial : 500€             |
//+------------------------------------------------------------------+

#property copyright "GoldHunterPro v3"
#property version   "3.00"
#property strict

//--- Séparateurs visuels des paramètres
input string   _S0               = "====== STRATÉGIE M5 ======";
input int      EMA_Fast          = 8;          // EMA rapide M5 (signal)
input int      EMA_Slow          = 21;         // EMA lente M5 (signal)
input int      EMA_Trend_H1      = 50;         // EMA tendance H1
input int      EMA_Filter_H1     = 200;        // EMA filtre H1 (structure longue)
input int      RSI_Period        = 14;         // Période RSI (M5)
input double   RSI_BuyZone_Low   = 35.0;       // RSI: zone d'achat bas (pullback)
input double   RSI_BuyZone_High  = 55.0;       // RSI: zone d'achat haut (pullback)
input double   RSI_SellZone_Low  = 45.0;       // RSI: zone de vente bas (pullback)
input double   RSI_SellZone_High = 65.0;       // RSI: zone de vente haut (pullback)
input int      ATR_Period        = 14;         // Période ATR (M5)
input double   ATR_SL_Mult       = 1.2;        // Multiplicateur ATR → Stop Loss
input double   ATR_TP_Mult       = 2.5;        // Multiplicateur ATR → Take Profit
input double   ATR_BE_Mult       = 1.0;        // Multiplicateur ATR → Breakeven
input double   ATR_TP1_Mult      = 1.0;        // Multiplicateur ATR → Clôture partielle

input string   _S1               = "====== RISQUE ======";
input double   RiskPercent       = 0.8;        // Risque par trade (% solde)
input double   MaxSpreadPts      = 35.0;       // Spread max autorisé (points)
input int      MaxOpenTrades     = 4;          // Trades simultanés max
input double   MaxDailyLossPct   = 3.0;        // Perte journalière max (%)
input double   DailyProfitPct    = 3.0;        // Profit journalier cible (%)
input double   PartialClosePct   = 50.0;       // % de la position à fermer à TP1
input double   MinLotSize        = 0.01;
input double   MaxLotSize        = 5.0;
input int      CooldownMinutes   = 20;         // Cooldown entre 2 signaux du même type

input string   _S2               = "====== SESSION ======";
input bool     UseSessionFilter  = true;
input int      SessionStart      = 6;          // Heure début (GMT)
input int      SessionEnd        = 21;         // Heure fin (GMT)
input bool     TradeMonday       = true;
input bool     TradeFriday       = true;       // Vendredi autorisé (coupe à 14h)
input int      FridayCutHour     = 14;         // Heure de coupure vendredi (GMT)
input bool     LondonBreakout    = true;       // Activer signal London breakout
input int      AsianStart        = 1;          // Heure début session asiatique (GMT)
input int      AsianEnd          = 8;          // Heure fin session asiatique / London open

input string   _S3               = "====== GÉNÉRAL ======";
input int      MagicNumber       = 202500;
input string   Comment_EA        = "GHP3_XAUUSD";
input bool     ShowDashboard     = true;
input bool     EnableAlerts      = true;

//--- Constantes des types de signaux
#define SIG_NONE      0
#define SIG_EMA       1
#define SIG_RSI       2
#define SIG_BREAKOUT  3

//--- Variables globales
double   g_DayStartBal   = 0;
double   g_DailyPnL      = 0;
datetime g_LastBarM5     = 0;
int      g_TotalTrades   = 0;
double   g_TotalProfit   = 0;
int      g_TradesDay     = 0;

// Cooldowns par type de signal (timestamp dernier signal)
datetime g_LastSig_EMA_Buy       = 0;
datetime g_LastSig_EMA_Sell      = 0;
datetime g_LastSig_RSI_Buy       = 0;
datetime g_LastSig_RSI_Sell      = 0;
datetime g_LastSig_Break_Buy     = 0;
datetime g_LastSig_Break_Sell    = 0;

// Range session asiatique pour London breakout
double   g_AsianHigh     = 0;
double   g_AsianLow      = 0;
datetime g_AsianRangeDay = 0;

// Cache indicateurs (calcul unique par barre)
double   c_ATR           = 0;
double   c_RSI           = 0;
double   c_EMA_Fast      = 0;
double   c_EMA_Slow      = 0;
double   c_EMA_Fast_P    = 0; // valeur précédente
double   c_EMA_Slow_P    = 0;
double   c_TrendH1       = 0;
double   c_FilterH1      = 0;

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   if (Symbol() != "XAUUSD" && Symbol() != "GOLD" && Symbol() != "XAUUSDm" &&
       Symbol() != "XAUUSDc" && Symbol() != "XAUUSD.")
      Alert("[GHP3] Bot optimisé pour XAUUSD. Symbole actuel: ", Symbol());

   if (Period() != PERIOD_M5)
      Alert("[GHP3] Timeframe requis: M5. Actuel: ", Period());

   g_DayStartBal = AccountBalance();
   g_LastBarM5   = 0;

   Print("[GHP3] v3.0 initialisé | Solde: ", DoubleToString(AccountBalance(), 2),
         " ", AccountCurrency(), " | Magic: ", MagicNumber);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnTick principal                                                  |
//+------------------------------------------------------------------+
void OnTick()
{
   // Gestion tick-par-tick (trailing + breakeven sur toutes les bougies)
   ManageOpenTrades();
   if (ShowDashboard) DrawDashboard();

   // Logique d'entrée uniquement à chaque nouvelle bougie M5
   datetime barTime = iTime(Symbol(), PERIOD_M5, 0);
   if (barTime == g_LastBarM5) return;
   g_LastBarM5 = barTime;

   // Mise à jour suivi journalier
   UpdateDailyTracking();

   // Calcul du range asiatique si on est en session London
   UpdateAsianRange();

   // Calcul des indicateurs (cache unique par barre)
   ComputeIndicators();

   // Filtres globaux
   if (!IsTradeAllowed())     return;
   if (IsSpreadTooHigh())     return;
   if (IsSessionClosed())     return;
   if (IsDailyLossHit())      return;
   if (IsDailyProfitHit())    return;
   if (CountMyTrades() >= MaxOpenTrades) return;

   // Détection tendance H1
   bool trendUp   = (c_TrendH1 > c_FilterH1) && (Close[1] > c_TrendH1);
   bool trendDown = (c_TrendH1 < c_FilterH1) && (Close[1] < c_TrendH1);

   // ─────────────────────────────────────────────
   // SIGNAL A : Croisement EMA sur M5
   // ─────────────────────────────────────────────
   bool emaCrossBull = (c_EMA_Fast_P <= c_EMA_Slow_P) && (c_EMA_Fast > c_EMA_Slow);
   bool emaCrossBear = (c_EMA_Fast_P >= c_EMA_Slow_P) && (c_EMA_Fast < c_EMA_Slow);

   if (emaCrossBull && trendUp && !InCooldown(SIG_EMA, OP_BUY))
   {
      if (OpenTrade(OP_BUY, SIG_EMA, "EMA_CROSS"))
         g_LastSig_EMA_Buy = TimeCurrent();
   }

   if (emaCrossBear && trendDown && !InCooldown(SIG_EMA, OP_SELL))
   {
      if (OpenTrade(OP_SELL, SIG_EMA, "EMA_CROSS"))
         g_LastSig_EMA_Sell = TimeCurrent();
   }

   // ─────────────────────────────────────────────
   // SIGNAL B : RSI Pullback en direction de tendance
   // ─────────────────────────────────────────────
   // Achat: tendance haussière + RSI revient dans la zone 35-55 (pullback)
   bool rsiBuyPullback  = trendUp && (c_RSI >= RSI_BuyZone_Low)  && (c_RSI <= RSI_BuyZone_High);
   // Vente: tendance baissière + RSI revient dans la zone 45-65 (pullback)
   bool rsiSellPullback = trendDown && (c_RSI >= RSI_SellZone_Low) && (c_RSI <= RSI_SellZone_High);

   if (rsiBuyPullback && c_EMA_Fast > c_EMA_Slow && !InCooldown(SIG_RSI, OP_BUY))
   {
      if (OpenTrade(OP_BUY, SIG_RSI, "RSI_PULL"))
         g_LastSig_RSI_Buy = TimeCurrent();
   }

   if (rsiSellPullback && c_EMA_Fast < c_EMA_Slow && !InCooldown(SIG_RSI, OP_SELL))
   {
      if (OpenTrade(OP_SELL, SIG_RSI, "RSI_PULL"))
         g_LastSig_RSI_Sell = TimeCurrent();
   }

   // ─────────────────────────────────────────────
   // SIGNAL C : London Breakout (cassure du range asiatique)
   // ─────────────────────────────────────────────
   if (LondonBreakout && IsLondonOpenWindow())
   {
      if (g_AsianHigh > 0 && g_AsianLow > 0)
      {
         double breakBuf = c_ATR * 0.3; // marge anti-faux breakout

         // Cassure haussière du range asiatique
         if (Ask > g_AsianHigh + breakBuf && trendUp && !InCooldown(SIG_BREAKOUT, OP_BUY))
         {
            if (OpenTrade(OP_BUY, SIG_BREAKOUT, "LONDON_BREAK"))
               g_LastSig_Break_Buy = TimeCurrent();
         }

         // Cassure baissière du range asiatique
         if (Bid < g_AsianLow - breakBuf && trendDown && !InCooldown(SIG_BREAKOUT, OP_SELL))
         {
            if (OpenTrade(OP_SELL, SIG_BREAKOUT, "LONDON_BREAK"))
               g_LastSig_Break_Sell = TimeCurrent();
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calcul des indicateurs (cache par barre M5)                      |
//+------------------------------------------------------------------+
void ComputeIndicators()
{
   c_ATR        = iATR(NULL, PERIOD_M5, ATR_Period, 1);
   c_RSI        = iRSI(NULL, PERIOD_M5, RSI_Period, PRICE_CLOSE, 1);
   c_EMA_Fast   = iMA(NULL, PERIOD_M5, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE, 1);
   c_EMA_Slow   = iMA(NULL, PERIOD_M5, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE, 1);
   c_EMA_Fast_P = iMA(NULL, PERIOD_M5, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE, 2);
   c_EMA_Slow_P = iMA(NULL, PERIOD_M5, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE, 2);
   c_TrendH1    = iMA(NULL, PERIOD_H1, EMA_Trend_H1,  0, MODE_EMA, PRICE_CLOSE, 1);
   c_FilterH1   = iMA(NULL, PERIOD_H1, EMA_Filter_H1, 0, MODE_EMA, PRICE_CLOSE, 1);
}

//+------------------------------------------------------------------+
//| Calcul et mise à jour du range asiatique                         |
//+------------------------------------------------------------------+
void UpdateAsianRange()
{
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if (g_AsianRangeDay == today) return; // Déjà calculé aujourd'hui

   int hourGMT = TimeHour(TimeGMT());

   // Calculer le range asiatique uniquement quand London ouvre (08:00 GMT)
   if (hourGMT < AsianEnd) return;

   g_AsianHigh = 0;
   g_AsianLow  = 999999;

   // Remonter les bougies M5 de la session asiatique (AsianStart → AsianEnd)
   for (int i = 1; i < 200; i++)
   {
      datetime t = iTime(Symbol(), PERIOD_M5, i);
      int h = TimeHour(t + TimeGMTOffset());

      // On ne prend que les bougies dans la fenêtre asiatique du jour courant
      if (TimeDay(t) != TimeDay(TimeCurrent())) continue;
      if (h < AsianStart || h >= AsianEnd)      continue;

      double hi = iHigh(Symbol(), PERIOD_M5, i);
      double lo = iLow(Symbol(),  PERIOD_M5, i);
      if (hi > g_AsianHigh) g_AsianHigh = hi;
      if (lo < g_AsianLow)  g_AsianLow  = lo;
   }

   if (g_AsianLow == 999999) g_AsianLow = 0;
   g_AsianRangeDay = today;

   if (g_AsianHigh > 0)
      Print("[GHP3] Range asiatique: H=", g_AsianHigh, " L=", g_AsianLow,
            " Amplitude=", DoubleToString((g_AsianHigh - g_AsianLow) / Point, 0), " pts");
}

//+------------------------------------------------------------------+
//| Fenêtre de London open (08:00-10:00 GMT)                         |
//+------------------------------------------------------------------+
bool IsLondonOpenWindow()
{
   int h = TimeHour(TimeGMT());
   return (h >= AsianEnd && h < AsianEnd + 2); // 08:00-10:00 GMT
}

//+------------------------------------------------------------------+
//| Gestion des trades ouverts (breakeven + clôture partielle)       |
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
   if (c_ATR <= 0) return;

   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderMagicNumber() != MagicNumber)           continue;
      if (OrderSymbol()      != Symbol())              continue;

      int    ticket    = OrderTicket();
      int    type      = OrderType();
      double openPrice = OrderOpenPrice();
      double currentSL = OrderStopLoss();
      double currentTP = OrderTakeProfit();
      double lots      = OrderLots();

      double atr       = c_ATR > 0 ? c_ATR : iATR(NULL, PERIOD_M5, ATR_Period, 1);
      double beDist    = atr * ATR_BE_Mult;
      double tp1Dist   = atr * ATR_TP1_Mult;
      double trailDist = atr * 1.0;

      if (type == OP_BUY)
      {
         double profit = Bid - openPrice;

         // Clôture partielle à TP1 (si pas encore fermé partiellement)
         if (profit >= tp1Dist && lots > MinLotSize * 1.5)
         {
            double closeVol = NormalizeDouble(lots * PartialClosePct / 100.0, 2);
            closeVol = MathMax(MinLotSize, closeVol);
            if (closeVol < lots)
            {
               if (OrderClose(ticket, closeVol, Bid, 3, clrYellow))
                  Print("[GHP3] Clôture partielle #", ticket, " Vol:", closeVol);
            }
         }

         // Breakeven: SL vers ouverture quand profit >= beDist
         if (profit >= beDist && currentSL < openPrice)
         {
            double newSL = NormalizeDouble(openPrice + Point, Digits);
            if (newSL > currentSL)
               OrderModify(ticket, openPrice, newSL, currentTP, 0, clrCyan);
         }

         // Trailing stop (uniquement si SL déjà au breakeven)
         if (currentSL >= openPrice)
         {
            double trailSL = NormalizeDouble(Bid - trailDist, Digits);
            if (trailSL > currentSL + 5 * Point && trailSL < Bid)
               OrderModify(ticket, openPrice, trailSL, currentTP, 0, clrYellow);
         }
      }
      else if (type == OP_SELL)
      {
         double profit = openPrice - Ask;

         // Clôture partielle à TP1
         if (profit >= tp1Dist && lots > MinLotSize * 1.5)
         {
            double closeVol = NormalizeDouble(lots * PartialClosePct / 100.0, 2);
            closeVol = MathMax(MinLotSize, closeVol);
            if (closeVol < lots)
            {
               if (OrderClose(ticket, closeVol, Ask, 3, clrYellow))
                  Print("[GHP3] Clôture partielle #", ticket, " Vol:", closeVol);
            }
         }

         // Breakeven
         if (profit >= beDist && (currentSL > openPrice || currentSL == 0))
         {
            double newSL = NormalizeDouble(openPrice - Point, Digits);
            if (currentSL == 0 || newSL < currentSL)
               OrderModify(ticket, openPrice, newSL, currentTP, 0, clrCyan);
         }

         // Trailing stop
         if (currentSL > 0 && currentSL <= openPrice)
         {
            double trailSL = NormalizeDouble(Ask + trailDist, Digits);
            if (trailSL < currentSL - 5 * Point && trailSL > Ask)
               OrderModify(ticket, openPrice, trailSL, currentTP, 0, clrYellow);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Ouverture d'un trade avec validation complète                    |
//+------------------------------------------------------------------+
bool OpenTrade(int type, int sigType, string reason)
{
   if (c_ATR <= 0) return false;

   double slDist  = c_ATR * ATR_SL_Mult;
   double tpDist  = c_ATR * ATR_TP_Mult;
   double lots    = CalculateLotSize(slDist);
   double price   = (type == OP_BUY) ? Ask : Bid;

   double sl, tp;
   if (type == OP_BUY)
   {
      sl = NormalizeDouble(price - slDist, Digits);
      tp = NormalizeDouble(price + tpDist, Digits);
   }
   else
   {
      sl = NormalizeDouble(price + slDist, Digits);
      tp = NormalizeDouble(price - tpDist, Digits);
   }

   // Vérification stoplevel broker
   int    minStop    = (int)MarketInfo(Symbol(), MODE_STOPLEVEL);
   double minStopPts = minStop * Point * 1.5;
   if (type == OP_BUY)
   {
      if (price - sl < minStopPts) sl = price - minStopPts;
      if (tp - price < minStopPts) tp = price + minStopPts;
   }
   else
   {
      if (sl - price < minStopPts) sl = price + minStopPts;
      if (price - tp < minStopPts) tp = price - minStopPts;
   }

   string cmt   = Comment_EA + "|S" + IntegerToString(sigType) + "|" + reason;
   color  arrow = (type == OP_BUY) ? clrLime : clrRed;

   int ticket = OrderSend(Symbol(), type, lots, price, 3, sl, tp, cmt, MagicNumber, 0, arrow);

   if (ticket < 0)
   {
      int err = GetLastError();
      Print("[GHP3] ERREUR OrderSend #", err, " | Type:", type, " | Lots:", lots,
            " | SL:", sl, " | TP:", tp);
      if (EnableAlerts && err != 130) Alert("[GHP3] Erreur trade #", err);
      return false;
   }

   g_TotalTrades++;
   g_TradesDay++;
   Print("[GHP3] Trade ouvert #", ticket, " | ", (type==OP_BUY?"BUY":"SELL"),
         " | Lots:", lots, " | SL:", sl, " | TP:", tp, " | ", reason);
   return true;
}

//+------------------------------------------------------------------+
//| Calcul taille de lot basé sur risque % du solde                  |
//+------------------------------------------------------------------+
double CalculateLotSize(double sl_dist)
{
   if (sl_dist <= 0) return MinLotSize;

   double balance   = AccountBalance();
   double risk      = balance * RiskPercent / 100.0;
   double tickVal   = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSz    = MarketInfo(Symbol(), MODE_TICKSIZE);

   if (tickVal <= 0 || tickSz <= 0) return MinLotSize;

   double slTicks = sl_dist / tickSz;
   double lots    = risk / (slTicks * tickVal);

   double step = MarketInfo(Symbol(), MODE_LOTSTEP);
   if (step > 0) lots = MathFloor(lots / step) * step;

   return NormalizeDouble(MathMax(MinLotSize, MathMin(MaxLotSize, lots)), 2);
}

//+------------------------------------------------------------------+
//| Cooldown: vérifie si on est encore en période d'attente          |
//+------------------------------------------------------------------+
bool InCooldown(int sigType, int direction)
{
   datetime last    = 0;
   int      cd_secs = CooldownMinutes * 60;

   if (sigType == SIG_EMA  && direction == OP_BUY)  last = g_LastSig_EMA_Buy;
   if (sigType == SIG_EMA  && direction == OP_SELL) last = g_LastSig_EMA_Sell;
   if (sigType == SIG_RSI  && direction == OP_BUY)  last = g_LastSig_RSI_Buy;
   if (sigType == SIG_RSI  && direction == OP_SELL) last = g_LastSig_RSI_Sell;
   if (sigType == SIG_BREAKOUT && direction == OP_BUY)  last = g_LastSig_Break_Buy;
   if (sigType == SIG_BREAKOUT && direction == OP_SELL) last = g_LastSig_Break_Sell;

   return (TimeCurrent() - last < cd_secs);
}

//+------------------------------------------------------------------+
//| Compte les trades ouverts de ce bot                              |
//+------------------------------------------------------------------+
int CountMyTrades()
{
   int n = 0;
   for (int i = 0; i < OrdersTotal(); i++)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol()) n++;
   }
   return n;
}

//+------------------------------------------------------------------+
//| Mise à jour du suivi journalier                                  |
//+------------------------------------------------------------------+
void UpdateDailyTracking()
{
   static datetime lastDay = 0;
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));

   if (today != lastDay)
   {
      lastDay        = today;
      g_DayStartBal  = AccountBalance();
      g_DailyPnL     = 0;
      g_TradesDay    = 0;
      g_AsianHigh    = 0;
      g_AsianLow     = 0;
      g_AsianRangeDay = 0;
      Print("[GHP3] Nouveau jour | Solde: ", DoubleToString(g_DayStartBal, 2));
   }

   double floatPL = 0;
   for (int i = 0; i < OrdersTotal(); i++)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderMagicNumber() != MagicNumber) continue;
      floatPL += OrderProfit() + OrderSwap() + OrderCommission();
   }
   g_DailyPnL = (AccountBalance() - g_DayStartBal) + floatPL;
}

//+------------------------------------------------------------------+
//| Filtres de protection                                            |
//+------------------------------------------------------------------+
bool IsSpreadTooHigh()
{
   double sp = MarketInfo(Symbol(), MODE_SPREAD);
   if (sp > MaxSpreadPts)
   {
      static datetime lw = 0;
      if (TimeCurrent() - lw > 60)
      { Print("[GHP3] Spread: ", sp, " > max ", MaxSpreadPts); lw = TimeCurrent(); }
      return true;
   }
   return false;
}

bool IsSessionClosed()
{
   if (!UseSessionFilter) return false;
   int h   = TimeHour(TimeGMT());
   int dow = TimeDayOfWeek(TimeCurrent());

   if (dow == 0 || dow == 6)                    return true;
   if (dow == 1 && !TradeMonday)                return true;
   if (dow == 5 && !TradeFriday)                return true;
   if (dow == 5 && h >= FridayCutHour)          return true; // coupure vendredi
   if (h < SessionStart || h >= SessionEnd)     return true;
   return false;
}

bool IsDailyLossHit()
{
   if (g_DayStartBal <= 0) return false;
   double pct = -g_DailyPnL / g_DayStartBal * 100.0;
   if (pct >= MaxDailyLossPct)
   {
      static datetime lw = 0;
      if (TimeCurrent() - lw > 300)
      {
         Print("[GHP3] Perte jour atteinte: ", DoubleToString(pct, 2), "%");
         if (EnableAlerts) Alert("[GHP3] Stop journalier perte: ", DoubleToString(pct, 2), "%");
         lw = TimeCurrent();
      }
      return true;
   }
   return false;
}

bool IsDailyProfitHit()
{
   if (g_DayStartBal <= 0) return false;
   double pct = g_DailyPnL / g_DayStartBal * 100.0;
   if (pct >= DailyProfitPct)
   {
      static datetime lw = 0;
      if (TimeCurrent() - lw > 300)
      {
         Print("[GHP3] Objectif journalier atteint: +", DoubleToString(pct, 2), "%");
         if (EnableAlerts) Alert("[GHP3] Objectif journalier atteint: +", DoubleToString(pct, 2), "%");
         lw = TimeCurrent();
      }
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Tableau de bord                                                   |
//+------------------------------------------------------------------+
void DrawDashboard()
{
   static datetime lastDraw = 0;
   if (TimeCurrent() - lastDraw < 3) return; // throttle: redessine max /3s
   lastDraw = TimeCurrent();

   string  p    = "GHP3_";
   color   gold = clrGold;
   color   grn  = clrLimeGreen;
   color   red  = clrTomato;
   color   wht  = clrWhite;
   color   gry  = C'160,160,160';

   double  bal  = AccountBalance();
   double  eq   = AccountEquity();
   double  fl   = eq - bal;
   double  sp   = MarketInfo(Symbol(), MODE_SPREAD);

   double  lossPct   = (g_DayStartBal > 0 && g_DailyPnL < 0) ? -g_DailyPnL / g_DayStartBal * 100.0 : 0;
   double  profPct   = (g_DayStartBal > 0 && g_DailyPnL > 0) ?  g_DailyPnL / g_DayStartBal * 100.0 : 0;

   string  trend_str = "NEUTRE";
   color   tc        = clrYellow;
   if (c_TrendH1 > c_FilterH1 && Close[1] > c_TrendH1) { trend_str = "HAUSSIERE"; tc = grn; }
   if (c_TrendH1 < c_FilterH1 && Close[1] < c_TrendH1) { trend_str = "BAISSIERE"; tc = red; }

   // Identifie le signal actif du moment
   bool lo = IsLondonOpenWindow();
   string sig_str = "";
   if (lo && LondonBreakout) sig_str = "LONDON BREAKOUT";
   else if (c_EMA_Fast > c_EMA_Slow) sig_str = "EMA BULL";
   else sig_str = "EMA BEAR";

   int y = 15;
   int dy = 19;
   Lbl(p+"t0", "  GoldHunterPro  v3.0  ",  10, y,      gold, 11, true); y+=dy+4;
   Lbl(p+"t1", "Solde  : " + DoubleToString(bal, 2) + " " + AccountCurrency(), 10, y, wht, 9); y+=dy;
   Lbl(p+"t2", "Equity : " + DoubleToString(eq,  2) + " " + AccountCurrency(), 10, y, wht, 9); y+=dy;
   Lbl(p+"t3", "Float  : " + (fl >= 0 ? "+" : "") + DoubleToString(fl, 2),    10, y, fl>=0?grn:red, 9); y+=dy;

   string plStr = g_DailyPnL >= 0
      ? "+"+DoubleToString(g_DailyPnL,2)+" (+"+DoubleToString(profPct,2)+"%)"
      : DoubleToString(g_DailyPnL,2)+" (-"+DoubleToString(lossPct,2)+"%)";
   Lbl(p+"t4", "J.PnL  : " + plStr, 10, y, g_DailyPnL >= 0 ? grn : red, 9); y+=dy;

   Lbl(p+"t5", "Trades / jour : " + IntegerToString(g_TradesDay), 10, y, wht, 9); y+=dy;
   Lbl(p+"t6", "Ouverts: " + IntegerToString(CountMyTrades()) + "/" + IntegerToString(MaxOpenTrades), 10, y, wht, 9); y+=dy;
   Lbl(p+"t7", "Spread : " + DoubleToString(sp, 0) + " pts", 10, y, sp > MaxSpreadPts ? red : grn, 9); y+=dy;
   Lbl(p+"t8", "ATR(M5): " + DoubleToString(c_ATR / Point, 0) + " pts", 10, y, wht, 9); y+=dy;
   Lbl(p+"t9", "RSI    : " + DoubleToString(c_RSI, 1), 10, y,
       c_RSI > 70 ? red : (c_RSI < 30 ? grn : wht), 9); y+=dy;
   Lbl(p+"ta", "Tendance H1: " + trend_str, 10, y, tc, 9); y+=dy;
   Lbl(p+"tb", "Signal : " + sig_str, 10, y, clrDodgerBlue, 9); y+=dy;
   Lbl(p+"tc", "Session: " + (IsSessionClosed() ? "FERMEE" : "OUVERTE"), 10, y,
       IsSessionClosed() ? red : grn, 9); y+=dy;

   string asianStr = (g_AsianHigh > 0)
      ? DoubleToString(g_AsianLow, Digits) + " - " + DoubleToString(g_AsianHigh, Digits)
      : "N/A";
   Lbl(p+"td", "Asian  : " + asianStr, 10, y, gry, 9);
}

//+------------------------------------------------------------------+
//| Création / mise à jour d'un label                                |
//+------------------------------------------------------------------+
void Lbl(string name, string txt, int x, int y, color clr, int sz, bool bold=false)
{
   if (ObjectFind(name) < 0)
   {
      ObjectCreate(name, OBJ_LABEL, 0, 0, 0);
      ObjectSet(name, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSet(name, OBJPROP_XDISTANCE, x);
      ObjectSet(name, OBJPROP_YDISTANCE, y);
   }
   ObjectSetText(name, txt, sz, bold ? "Arial Bold" : "Arial", clr);
}

//+------------------------------------------------------------------+
//| Deinit : nettoyage                                               |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, "GHP3_");
   Print("[GHP3] Désinitialisé. Raison: ", reason);
}

//+------------------------------------------------------------------+
