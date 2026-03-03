//+------------------------------------------------------------------+
//|                                              GoldHunterPro.mq4   |
//|                          Bot de trading automatique XAUUSD       |
//|                                                                  |
//|  STRATÉGIE :                                                     |
//|   - Tendance multi-timeframe (H4 + H1)                          |
//|   - Entrées sur M15 via croisement EMA + filtre RSI + ATR       |
//|   - Gestion du risque dynamique (ATR-based SL/TP)               |
//|   - Trailing stop, filtre spread, filtre session                 |
//|   - Protection drawdown journalier                               |
//+------------------------------------------------------------------+

#property copyright "GoldHunterPro"
#property version   "2.00"
#property strict

//--- Paramètres de la stratégie
input string   S1_Strategy       = "=== STRATÉGIE ===";
input int      FastEMA            = 8;         // EMA rapide (signal)
input int      SlowEMA            = 21;        // EMA lente (signal)
input int      TrendEMA_H1        = 50;        // EMA tendance H1
input int      TrendEMA_H4        = 200;       // EMA tendance H4
input int      RSI_Period         = 14;        // Période RSI
input double   RSI_Overbought     = 70.0;      // Seuil surachat RSI
input double   RSI_Oversold       = 30.0;      // Seuil survente RSI
input int      ATR_Period         = 14;        // Période ATR
input double   ATR_SL_Multiplier  = 1.8;       // Multiplicateur ATR pour Stop Loss
input double   ATR_TP_Multiplier  = 3.0;       // Multiplicateur ATR pour Take Profit

//--- Paramètres de gestion du risque
input string   S2_Risk            = "=== GESTION DU RISQUE ===";
input double   RiskPercent        = 1.0;       // Risque par trade (% du solde)
input double   MaxSpreadPoints    = 35.0;      // Spread maximum autorisé (points)
input int      MaxOpenTrades      = 2;         // Nombre max de trades simultanés
input double   MaxDailyLossPct    = 3.0;       // Perte journalière max (% du solde)
input double   TrailingStopATR    = 1.2;       // Multiplicateur ATR pour trailing stop
input int      TrailingStepPoints = 10;        // Pas minimum du trailing stop (points)
input double   MinLotSize         = 0.01;      // Lot minimum
input double   MaxLotSize         = 5.0;       // Lot maximum

//--- Paramètres de session
input string   S3_Session         = "=== FILTRE DE SESSION ===";
input bool     UseSessionFilter   = true;      // Activer filtre de session
input int      SessionStartHour   = 7;         // Heure d'ouverture (GMT)
input int      SessionEndHour     = 20;        // Heure de fermeture (GMT)
input bool     TradeMonday        = true;      // Trader le lundi
input bool     TradeFriday        = false;     // Trader le vendredi (éviter clôture hebdo)

//--- Paramètres du Magic Number et commentaires
input string   S4_General         = "=== GÉNÉRAL ===";
input int      MagicNumber        = 202400;    // Magic number unique du bot
input string   TradeComment       = "GHP_XAUUSD"; // Commentaire des trades
input bool     ShowDashboard      = true;      // Afficher le tableau de bord
input bool     EnableAlerts       = true;      // Activer les alertes

//--- Variables globales
double   g_DayStartBalance  = 0;
double   g_DailyLoss        = 0;
datetime g_LastBarTime      = 0;
int      g_TotalTrades      = 0;
double   g_TotalProfit      = 0;

//+------------------------------------------------------------------+
//| Initialisation de l'EA                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   if (Symbol() != "XAUUSD" && Symbol() != "GOLD" && Symbol() != "XAUUSDm")
   {
      Alert("ATTENTION: Ce bot est optimisé pour XAUUSD. Symbole actuel: ", Symbol());
   }

   if (Period() != PERIOD_M15)
   {
      Alert("ATTENTION: Timeframe recommandé M15. Actuel: ", Period());
   }

   g_DayStartBalance = AccountBalance();
   g_LastBarTime     = 0;

   Print("GoldHunterPro initialisé. Solde: ", AccountBalance(), " ", AccountCurrency());
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Tick principal                                                    |
//+------------------------------------------------------------------+
void OnTick()
{
   // Ne traiter qu'à l'ouverture d'une nouvelle bougie M15
   datetime currentBarTime = iTime(Symbol(), PERIOD_M15, 0);
   if (currentBarTime == g_LastBarTime)
   {
      ManageTrailingStops();
      if (ShowDashboard) DrawDashboard();
      return;
   }
   g_LastBarTime = currentBarTime;

   // Mise à jour du suivi journalier
   UpdateDailyTracking();

   // Vérifications de sécurité
   if (!IsTradingAllowed()) return;
   if (IsSpreadTooHigh())   return;
   if (IsSessionClosed())   return;
   if (IsDailyLossReached()) return;
   if (CountOpenTrades() >= MaxOpenTrades) return;

   // Calcul des indicateurs
   double fastEMA_curr  = iMA(NULL, PERIOD_M15, FastEMA,  0, MODE_EMA, PRICE_CLOSE, 1);
   double fastEMA_prev  = iMA(NULL, PERIOD_M15, FastEMA,  0, MODE_EMA, PRICE_CLOSE, 2);
   double slowEMA_curr  = iMA(NULL, PERIOD_M15, SlowEMA,  0, MODE_EMA, PRICE_CLOSE, 1);
   double slowEMA_prev  = iMA(NULL, PERIOD_M15, SlowEMA,  0, MODE_EMA, PRICE_CLOSE, 2);

   double rsi           = iRSI(NULL, PERIOD_M15, RSI_Period, PRICE_CLOSE, 1);
   double atr           = iATR(NULL, PERIOD_M15, ATR_Period, 1);

   double trendH1       = iMA(NULL, PERIOD_H1, TrendEMA_H1, 0, MODE_EMA, PRICE_CLOSE, 1);
   double trendH4       = iMA(NULL, PERIOD_H4, TrendEMA_H4, 0, MODE_EMA, PRICE_CLOSE, 1);
   double priceH1       = iClose(Symbol(), PERIOD_H1, 1);
   double priceH4       = iClose(Symbol(), PERIOD_H4, 1);

   if (atr <= 0) return;

   // Détection de la tendance principale (H4 + H1)
   bool bullTrend = (priceH4 > trendH4) && (priceH1 > trendH1);
   bool bearTrend = (priceH4 < trendH4) && (priceH1 < trendH1);

   // Détection du croisement EMA sur M15
   bool bullCross = (fastEMA_prev <= slowEMA_prev) && (fastEMA_curr > slowEMA_curr);
   bool bearCross = (fastEMA_prev >= slowEMA_prev) && (fastEMA_curr < slowEMA_curr);

   // Calcul SL et TP dynamiques via ATR
   double sl_distance = atr * ATR_SL_Multiplier;
   double tp_distance = atr * ATR_TP_Multiplier;
   double lotSize     = CalculateLotSize(sl_distance);

   // Signal ACHAT : tendance haussière + croisement bull + RSI non suracheté
   if (bullTrend && bullCross && rsi < RSI_Overbought && rsi > 40.0)
   {
      double entryPrice = Ask;
      double sl         = entryPrice - sl_distance;
      double tp         = entryPrice + tp_distance;

      sl = NormalizeDouble(sl, Digits);
      tp = NormalizeDouble(tp, Digits);

      if (!HasOpenTrade(OP_BUY))
         OpenTrade(OP_BUY, lotSize, sl, tp, "BUY|RSI:" + DoubleToStr(rsi, 1));
   }

   // Signal VENTE : tendance baissière + croisement bear + RSI non survendu
   if (bearTrend && bearCross && rsi > RSI_Oversold && rsi < 60.0)
   {
      double entryPrice = Bid;
      double sl         = entryPrice + sl_distance;
      double tp         = entryPrice - tp_distance;

      sl = NormalizeDouble(sl, Digits);
      tp = NormalizeDouble(tp, Digits);

      if (!HasOpenTrade(OP_SELL))
         OpenTrade(OP_SELL, lotSize, sl, tp, "SELL|RSI:" + DoubleToStr(rsi, 1));
   }

   if (ShowDashboard) DrawDashboard();
}

//+------------------------------------------------------------------+
//| Ouvrir un trade avec validation complète                         |
//+------------------------------------------------------------------+
bool OpenTrade(int type, double lots, double sl, double tp, string reason)
{
   // Validation du lot
   lots = MathMax(MinLotSize, MathMin(MaxLotSize, lots));
   lots = NormalizeDouble(lots, 2);

   // Vérification que SL/TP respectent le broker
   int    minStop    = (int)MarketInfo(Symbol(), MODE_STOPLEVEL);
   double minStopPts = minStop * Point;
   double price      = (type == OP_BUY) ? Ask : Bid;

   if (type == OP_BUY)
   {
      if ((price - sl) < minStopPts) sl = price - minStopPts * 1.5;
      if ((tp - price) < minStopPts) tp = price + minStopPts * 1.5;
   }
   else
   {
      if ((sl - price) < minStopPts) sl = price + minStopPts * 1.5;
      if ((price - tp) < minStopPts) tp = price - minStopPts * 1.5;
   }

   string comment = TradeComment + "|" + reason;
   int ticket = OrderSend(Symbol(), type, lots, price, 3, sl, tp, comment, MagicNumber, 0,
                          (type == OP_BUY) ? clrLime : clrRed);

   if (ticket < 0)
   {
      int err = GetLastError();
      Print("Erreur ouverture trade #", err, " | Type:", type, " | Lots:", lots,
            " | SL:", sl, " | TP:", tp);
      if (EnableAlerts) Alert("GoldHunterPro: Erreur ouverture trade #", err);
      return false;
   }

   Print("Trade ouvert: #", ticket, " | ", (type == OP_BUY ? "BUY" : "SELL"),
         " | Lots:", lots, " | SL:", sl, " | TP:", tp, " | Raison:", reason);
   g_TotalTrades++;
   return true;
}

//+------------------------------------------------------------------+
//| Calcul dynamique de la taille de lot basé sur le risque ATR     |
//+------------------------------------------------------------------+
double CalculateLotSize(double sl_distance)
{
   double balance      = AccountBalance();
   double riskAmount   = balance * RiskPercent / 100.0;
   double tickValue    = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize     = MarketInfo(Symbol(), MODE_TICKSIZE);

   if (tickSize <= 0 || tickValue <= 0 || sl_distance <= 0) return MinLotSize;

   double slInTicks    = sl_distance / tickSize;
   double lots         = riskAmount / (slInTicks * tickValue);

   // Arrondi au pas du broker
   double lotStep      = MarketInfo(Symbol(), MODE_LOTSTEP);
   if (lotStep > 0) lots = MathFloor(lots / lotStep) * lotStep;

   lots = MathMax(MinLotSize, MathMin(MaxLotSize, lots));
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Gestion du trailing stop dynamique basé sur l'ATR               |
//+------------------------------------------------------------------+
void ManageTrailingStops()
{
   double atr        = iATR(NULL, PERIOD_M15, ATR_Period, 1);
   double trailDist  = atr * TrailingStopATR;
   double stepPts    = TrailingStepPoints * Point;

   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderMagicNumber() != MagicNumber)          continue;
      if (OrderSymbol() != Symbol())                  continue;

      double currentSL  = OrderStopLoss();
      double openPrice  = OrderOpenPrice();
      double newSL      = 0;
      bool   modify     = false;

      if (OrderType() == OP_BUY)
      {
         newSL = Bid - trailDist;
         newSL = NormalizeDouble(newSL, Digits);
         if (newSL > currentSL + stepPts && newSL < Bid)
         {
            modify = true;
         }
      }
      else if (OrderType() == OP_SELL)
      {
         newSL = Ask + trailDist;
         newSL = NormalizeDouble(newSL, Digits);
         if ((currentSL == 0 || newSL < currentSL - stepPts) && newSL > Ask)
         {
            modify = true;
         }
      }

      if (modify)
      {
         bool ok = OrderModify(OrderTicket(), openPrice, newSL, OrderTakeProfit(), 0, clrYellow);
         if (!ok)
            Print("Erreur trailing stop #", GetLastError(), " Ticket:", OrderTicket());
      }
   }
}

//+------------------------------------------------------------------+
//| Vérifie si un trade du même type est déjà ouvert                 |
//+------------------------------------------------------------------+
bool HasOpenTrade(int tradeType)
{
   for (int i = 0; i < OrdersTotal(); i++)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderMagicNumber() != MagicNumber)           continue;
      if (OrderSymbol()      != Symbol())              continue;
      if (OrderType()        == tradeType)             return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Compte le nombre de trades ouverts par ce bot                    |
//+------------------------------------------------------------------+
int CountOpenTrades()
{
   int count = 0;
   for (int i = 0; i < OrdersTotal(); i++)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderMagicNumber() != MagicNumber)           continue;
      if (OrderSymbol()      != Symbol())              continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Mise à jour du suivi journalier                                  |
//+------------------------------------------------------------------+
void UpdateDailyTracking()
{
   static datetime lastDay = 0;
   datetime today = StringToTime(TimeToStr(TimeCurrent(), TIME_DATE));

   if (today != lastDay)
   {
      lastDay           = today;
      g_DayStartBalance = AccountBalance();
      g_DailyLoss       = 0;
      Print("Nouveau jour: solde de départ = ", g_DayStartBalance);
   }

   // Calcul perte journalière incluant trades ouverts
   double floatingPL = 0;
   for (int i = 0; i < OrdersTotal(); i++)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderMagicNumber() != MagicNumber)           continue;
      floatingPL += OrderProfit() + OrderSwap() + OrderCommission();
   }
   g_DailyLoss = MathMin(0, AccountBalance() - g_DayStartBalance + floatingPL);
}

//+------------------------------------------------------------------+
//| Vérifications de protection                                      |
//+------------------------------------------------------------------+
bool IsTradingAllowed()
{
   if (!IsTradeAllowed())
   {
      static datetime lastWarn = 0;
      if (TimeCurrent() - lastWarn > 300)
      {
         Print("Trading non autorisé (AutoTrading désactivé?)");
         lastWarn = TimeCurrent();
      }
      return false;
   }
   return true;
}

bool IsSpreadTooHigh()
{
   double spread = MarketInfo(Symbol(), MODE_SPREAD);
   if (spread > MaxSpreadPoints)
   {
      static datetime lastWarn = 0;
      if (TimeCurrent() - lastWarn > 60)
      {
         Print("Spread trop élevé: ", spread, " > ", MaxSpreadPoints);
         lastWarn = TimeCurrent();
      }
      return true;
   }
   return false;
}

bool IsSessionClosed()
{
   if (!UseSessionFilter) return false;

   int hourGMT  = TimeHour(TimeGMT());
   int dayOfWeek = TimeDayOfWeek(TimeCurrent());

   // Bloquer le week-end
   if (dayOfWeek == 0 || dayOfWeek == 6) return true;

   // Filtre lundi/vendredi
   if (dayOfWeek == 1 && !TradeMonday)  return true;
   if (dayOfWeek == 5 && !TradeFriday)  return true;

   // Vérifier l'heure de session
   if (hourGMT < SessionStartHour || hourGMT >= SessionEndHour) return true;

   return false;
}

bool IsDailyLossReached()
{
   if (g_DayStartBalance <= 0) return false;
   double lossPct = MathAbs(g_DailyLoss) / g_DayStartBalance * 100.0;
   if (lossPct >= MaxDailyLossPct)
   {
      static datetime lastWarn = 0;
      if (TimeCurrent() - lastWarn > 300)
      {
         Print("Perte journalière max atteinte: ", DoubleToStr(lossPct, 2), "%");
         if (EnableAlerts) Alert("GoldHunterPro: Perte journalière max atteinte (",
                                  DoubleToStr(lossPct, 2), "%)");
         lastWarn = TimeCurrent();
      }
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Tableau de bord visuel sur le graphique                          |
//+------------------------------------------------------------------+
void DrawDashboard()
{
   string prefix = "GHP_";
   color  bg     = C'20,20,40';
   color  title  = clrGold;
   color  green  = clrLimeGreen;
   color  red    = clrTomato;
   color  white  = clrWhite;

   int openTrades   = CountOpenTrades();
   double spread    = MarketInfo(Symbol(), MODE_SPREAD);
   double atr       = iATR(NULL, PERIOD_M15, ATR_Period, 1);
   double rsi       = iRSI(NULL, PERIOD_M15, RSI_Period, PRICE_CLOSE, 1);
   double equity    = AccountEquity();
   double balance   = AccountBalance();
   double lossPct   = (g_DayStartBalance > 0) ? MathAbs(g_DailyLoss) / g_DayStartBalance * 100.0 : 0;

   // Tendance
   double tH1  = iMA(NULL, PERIOD_H1, TrendEMA_H1, 0, MODE_EMA, PRICE_CLOSE, 1);
   double tH4  = iMA(NULL, PERIOD_H4, TrendEMA_H4, 0, MODE_EMA, PRICE_CLOSE, 1);
   double pH1  = iClose(Symbol(), PERIOD_H1, 1);
   double pH4  = iClose(Symbol(), PERIOD_H4, 1);
   string trend = "NEUTRE";
   color tColor = clrYellow;
   if (pH4 > tH4 && pH1 > tH1) { trend = "HAUSSIERE"; tColor = green; }
   if (pH4 < tH4 && pH1 < tH1) { trend = "BAISSIERE"; tColor = red;   }

   // Création des labels
   CreateLabel(prefix+"title",   "  GoldHunterPro v2.0  ", 10, 20,  title, 12, true);
   CreateLabel(prefix+"symbol",  "Symbole : " + Symbol(),   10, 45,  white,  9);
   CreateLabel(prefix+"balance", "Solde   : " + DoubleToStr(balance,2) + " " + AccountCurrency(), 10, 65, white, 9);
   CreateLabel(prefix+"equity",  "Equity  : " + DoubleToStr(equity,2)  + " " + AccountCurrency(), 10, 85, white, 9);

   double floatPL = equity - balance;
   CreateLabel(prefix+"float",   "Float   : " + DoubleToStr(floatPL,2), 10, 105,
               floatPL >= 0 ? green : red, 9);

   CreateLabel(prefix+"loss",    "P.Jour  : " + DoubleToStr(lossPct,2) + "% / " +
               DoubleToStr(MaxDailyLossPct,1) + "%", 10, 125,
               lossPct > MaxDailyLossPct * 0.7 ? red : white, 9);

   CreateLabel(prefix+"trades",  "Trades  : " + IntegerToString(openTrades) + "/" +
               IntegerToString(MaxOpenTrades), 10, 145, white, 9);

   CreateLabel(prefix+"spread",  "Spread  : " + DoubleToStr(spread,0) + " pts", 10, 165,
               spread > MaxSpreadPoints ? red : green, 9);

   CreateLabel(prefix+"atr",     "ATR     : " + DoubleToStr(atr/_Point,0) + " pts", 10, 185, white, 9);
   CreateLabel(prefix+"rsi",     "RSI(14) : " + DoubleToStr(rsi,1), 10, 205,
               rsi > RSI_Overbought ? red : (rsi < RSI_Oversold ? green : white), 9);

   CreateLabel(prefix+"trend",   "Tendance: " + trend, 10, 225, tColor, 9);
   CreateLabel(prefix+"session", "Session : " + (IsSessionClosed() ? "FERMEE" : "OUVERTE"),
               10, 245, IsSessionClosed() ? red : green, 9);
}

//+------------------------------------------------------------------+
//| Création / mise à jour d'un label sur le graphique              |
//+------------------------------------------------------------------+
void CreateLabel(string name, string text, int x, int y, color clr, int fontSize, bool bold = false)
{
   if (ObjectFind(name) < 0)
   {
      ObjectCreate(name, OBJ_LABEL, 0, 0, 0);
      ObjectSet(name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSet(name, OBJPROP_XDISTANCE, x);
      ObjectSet(name, OBJPROP_YDISTANCE, y);
   }
   ObjectSetText(name, text, fontSize, bold ? "Arial Bold" : "Arial", clr);
}

//+------------------------------------------------------------------+
//| Nettoyage des objets graphiques                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, "GHP_");
   Print("GoldHunterPro désinitialisé. Raison: ", reason);
}

//+------------------------------------------------------------------+
//| Fin de fichier                                                   |
//+------------------------------------------------------------------+
