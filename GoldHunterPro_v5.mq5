//+------------------------------------------------------------------+
//|                                        GoldHunterPro_v5.mq5     |
//|          Bot de trading XAUUSD — MetaTrader 5  v5.0              |
//|                                                                  |
//|  PORTAGE COMPLET MQL4 → MQL5 :                                  |
//|  Toutes les APIs MT4 remplacées par leurs équivalents MT5        |
//|                                                                  |
//|  ARCHITECTURE SIGNAUX (3+ trades/jour) :                         |
//|   Signal A — EMA 8/21 cross sur M5 avec filtre H1               |
//|   Signal B — RSI pullback en zone tendance H1                    |
//|   Signal C — London Breakout du range session asiatique          |
//|                                                                  |
//|  GESTION DE TRADE :                                              |
//|   · Breakeven automatique à 1.2× ATR M5                         |
//|   · Clôture partielle 40% à 1.2× ATR M5                         |
//|   · Trailing stop après breakeven (ATR dynamique)               |
//|   · Perte jour max 5% | Objectif jour 6%                        |
//|                                                                  |
//|  RISQUE AUGMENTÉ vs v3 :                                         |
//|   · 2.0% / trade  (était 0.8%)  → gains plus importants         |
//|   · TP à 3.5× ATR (était 2.5×) → objectifs plus ambitieux      |
//|   · 5 positions max (était 4)   → plus d'exposition             |
//|   · MaxDailyLoss 5% (était 3%)  → budget journalier élargi      |
//|                                                                  |
//|  CHANGEMENTS MQL5 CLÉS :                                         |
//|   · CTrade pour toutes les opérations de trade                  |
//|   · Handles d'indicateurs (iATR, iRSI, iMA) créés en OnInit     |
//|   · PositionsTotal() + PositionGetTicket() (pas OrdersTotal)     |
//|   · SymbolInfoDouble/Integer remplace MarketInfo()               |
//|   · AccountInfoDouble/String remplace AccountBalance/Currency()  |
//|   · MqlDateTime pour la gestion des heures (pas TimeHour)        |
//|   · ObjectSetString/Integer remplace ObjectSet/ObjectSetText     |
//+------------------------------------------------------------------+

#property copyright  "GoldHunterPro v5"
#property version    "5.00"
#property description "XAUUSD Expert Advisor | MT5 | 3+ trades/jour"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| PARAMÈTRES                                                        |
//+------------------------------------------------------------------+

input group "====== STRATÉGIE M5 ======"
input int      EMA_Fast          = 8;       // EMA rapide M5
input int      EMA_Slow          = 21;      // EMA lente M5
input int      EMA_Trend_H1      = 50;      // EMA tendance H1
input int      EMA_Filter_H1     = 200;     // EMA structure H1 (long terme)
input int      RSI_Period        = 14;      // Période RSI M5
input double   RSI_BuyLow        = 35.0;   // Zone achat RSI bas
input double   RSI_BuyHigh       = 55.0;   // Zone achat RSI haut
input double   RSI_SellLow       = 45.0;   // Zone vente RSI bas
input double   RSI_SellHigh      = 65.0;   // Zone vente RSI haut
input int      ATR_Period        = 14;      // Période ATR M5

input group "====== RISQUE (AGRESSIF) ======"
input double   ATR_SL_Mult       = 1.5;    // [v5: 1.5 | v3: 1.2] SL = N × ATR
input double   ATR_TP_Mult       = 3.5;    // [v5: 3.5 | v3: 2.5] TP = N × ATR
input double   ATR_BE_Mult       = 1.2;    // [v5: 1.2 | v3: 1.0] Breakeven à N × ATR
input double   ATR_TP1_Mult      = 1.2;    // [v5: 1.2 | v3: 1.0] Clôture partielle
input double   RiskPercent       = 2.0;    // [v5: 2.0%| v3: 0.8%] Risque par trade
input double   PartialClosePct   = 40.0;   // [v5: 40% | v3: 50%] Volume clôture partielle
input double   MaxSpreadPts      = 35.0;   // Spread max autorisé (points)
input int      MaxOpenPositions  = 5;      // [v5: 5   | v3: 4  ] Positions simultanées max
input double   MaxDailyLossPct   = 5.0;    // [v5: 5%  | v3: 3% ] Perte journalière max
input double   DailyProfitPct    = 6.0;    // [v5: 6%  | v3: 3% ] Profit journalier cible
input double   MinLot            = 0.01;   // Lot minimum
input double   MaxLot            = 10.0;   // [v5: 10  | v3: 5  ] Lot maximum
input int      CooldownMin       = 15;     // [v5: 15m | v3: 20m] Cooldown entre signaux

input group "====== SESSION ======"
input bool     UseSessionFilter  = true;
input int      SessionStartGMT   = 6;      // Heure d'ouverture (GMT)
input int      SessionEndGMT     = 21;     // Heure de clôture (GMT)
input bool     TradeMonday       = true;
input bool     TradeFriday       = true;
input int      FridayCutGMT      = 14;     // Coupure vendredi (GMT)
input bool     LondonBreakout    = true;   // Signal London breakout
input int      AsianStartGMT     = 1;      // Début session asiatique (GMT)
input int      AsianEndGMT       = 8;      // Fin session asiatique = London open (GMT)

input group "====== GÉNÉRAL ======"
input ulong    MagicNumber       = 202500;
input string   EA_Comment        = "GHP5";   // Commentaire (max 6 chars pour MT5)
input bool     ShowDashboard     = true;
input bool     EnableAlerts      = true;

//+------------------------------------------------------------------+
//| Constantes internes                                              |
//+------------------------------------------------------------------+
#define SIG_EMA      1
#define SIG_RSI      2
#define SIG_BREAKOUT 3

//+------------------------------------------------------------------+
//| Variables globales                                               |
//+------------------------------------------------------------------+
CTrade        g_Trade;
CPositionInfo g_Pos;
CSymbolInfo   g_Sym;

// Handles d'indicateurs (créés une seule fois en OnInit)
int h_ATR;
int h_RSI;
int h_EMA_Fast;
int h_EMA_Slow;
int h_TrendH1;
int h_FilterH1;

// Cache indicateurs (valeurs recalculées par nouvelle bougie M5)
double c_ATR       = 0;
double c_RSI       = 0;
double c_EmaFast   = 0;
double c_EmaSlow   = 0;
double c_EmaFastP  = 0;  // valeur de la bougie précédente
double c_EmaSlowP  = 0;
double c_TrendH1   = 0;
double c_FilterH1  = 0;

// Suivi journalier
double   g_DayStartBal   = 0;
double   g_DailyPnL      = 0;
int      g_TradesDay     = 0;
int      g_TotalTrades   = 0;

// Cooldowns par signal (timestamp dernier signal ouvert)
datetime g_CdEMABuy    = 0;
datetime g_CdEMASell   = 0;
datetime g_CdRSIBuy    = 0;
datetime g_CdRSISell   = 0;
datetime g_CdBrkBuy    = 0;
datetime g_CdBrkSell   = 0;

// Range session asiatique (recalculé chaque jour)
double   g_AsianHigh    = 0;
double   g_AsianLow     = 0;
datetime g_AsianDay     = 0;

// Contrôle barre M5
datetime g_LastBar = 0;

//+------------------------------------------------------------------+
//| INITIALISATION                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Vérification du symbole
   if (StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0)
      Print("[GHP5] ATTENTION: Bot optimisé pour XAUUSD. Symbole: ", _Symbol);

   if (_Period != PERIOD_M5)
      Print("[GHP5] ATTENTION: Timeframe requis M5. Actuel: ", EnumToString(_Period));

   // Vérification du mode de compte (hedging requis pour positions multiples)
   ENUM_ACCOUNT_MARGIN_MODE mode = (ENUM_ACCOUNT_MARGIN_MODE)
                                    AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if (mode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("[GHP5] ATTENTION: Compte en mode NETTING. Positions simultanées limitées.");

   // Configuration CTrade
   g_Trade.SetExpertMagicNumber(MagicNumber);
   g_Trade.SetDeviationInPoints(10);
   g_Trade.SetTypeFilling(ORDER_FILLING_IOC);
   g_Trade.LogLevel(LOG_LEVEL_ERRORS);

   // Création des handles d'indicateurs
   h_ATR     = iATR(_Symbol, PERIOD_M5, ATR_Period);
   h_RSI     = iRSI(_Symbol, PERIOD_M5, RSI_Period, PRICE_CLOSE);
   h_EMA_Fast = iMA(_Symbol, PERIOD_M5, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   h_EMA_Slow = iMA(_Symbol, PERIOD_M5, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   h_TrendH1  = iMA(_Symbol, PERIOD_H1, EMA_Trend_H1,  0, MODE_EMA, PRICE_CLOSE);
   h_FilterH1 = iMA(_Symbol, PERIOD_H1, EMA_Filter_H1, 0, MODE_EMA, PRICE_CLOSE);

   if (h_ATR == INVALID_HANDLE || h_RSI == INVALID_HANDLE ||
       h_EMA_Fast == INVALID_HANDLE || h_EMA_Slow == INVALID_HANDLE ||
       h_TrendH1  == INVALID_HANDLE || h_FilterH1  == INVALID_HANDLE)
   {
      Print("[GHP5] ERREUR: Impossible de créer les handles d'indicateurs.");
      return INIT_FAILED;
   }

   g_DayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_LastBar     = 0;

   Print("[GHP5] v5.0 initialisé | Solde: ",
         DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2), " ",
         AccountInfoString(ACCOUNT_CURRENCY),
         " | Magic: ", MagicNumber);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| DÉINITIALISATION                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Libération des handles
   IndicatorRelease(h_ATR);
   IndicatorRelease(h_RSI);
   IndicatorRelease(h_EMA_Fast);
   IndicatorRelease(h_EMA_Slow);
   IndicatorRelease(h_TrendH1);
   IndicatorRelease(h_FilterH1);

   // Suppression des objets graphiques
   ObjectsDeleteAll(0, "GHP5_");
   Print("[GHP5] Désinitialisé. Raison: ", reason);
}

//+------------------------------------------------------------------+
//| TICK PRINCIPAL                                                    |
//+------------------------------------------------------------------+
void OnTick()
{
   // Gestion tick-par-tick : trailing stop + breakeven + clôture partielle
   ManageOpenPositions();
   if (ShowDashboard) DrawDashboard();

   // Logique d'entrée uniquement à la nouvelle bougie M5
   datetime barTime = iTime(_Symbol, PERIOD_M5, 0);
   if (barTime == g_LastBar) return;
   g_LastBar = barTime;

   UpdateDailyTracking();
   UpdateAsianRange();

   // Échec lecture indicateurs = skip
   if (!LoadIndicators()) return;

   // ── Filtres globaux ──────────────────────────────────────────────
   if (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if (!MQLInfoInteger(MQL_TRADE_ALLOWED))           return;
   if (IsSpreadTooHigh())                            return;
   if (IsSessionClosed())                            return;
   if (IsDailyLossHit())                             return;
   if (IsDailyProfitHit())                           return;
   if (CountMyPositions() >= MaxOpenPositions)        return;

   // ── Tendance H1 ──────────────────────────────────────────────────
   double lastCloseH1 = iClose(_Symbol, PERIOD_H1, 1);
   bool trendUp   = (c_TrendH1 > c_FilterH1) && (lastCloseH1 > c_TrendH1);
   bool trendDown = (c_TrendH1 < c_FilterH1) && (lastCloseH1 < c_TrendH1);

   // ─────────────────────────────────────────────────────────────────
   // SIGNAL A : Croisement EMA 8/21 sur M5
   // ─────────────────────────────────────────────────────────────────
   bool crossBull = (c_EmaFastP <= c_EmaSlowP) && (c_EmaFast > c_EmaSlow);
   bool crossBear = (c_EmaFastP >= c_EmaSlowP) && (c_EmaFast < c_EmaSlow);

   if (crossBull && trendUp && !InCooldown(SIG_EMA, ORDER_TYPE_BUY))
   {
      if (OpenPosition(ORDER_TYPE_BUY, SIG_EMA, "EMACX"))
         g_CdEMABuy = TimeCurrent();
   }

   if (crossBear && trendDown && !InCooldown(SIG_EMA, ORDER_TYPE_SELL))
   {
      if (OpenPosition(ORDER_TYPE_SELL, SIG_EMA, "EMACX"))
         g_CdEMASell = TimeCurrent();
   }

   // ─────────────────────────────────────────────────────────────────
   // SIGNAL B : RSI Pullback dans la direction de la tendance H1
   // ─────────────────────────────────────────────────────────────────
   bool rsiBuy  = trendUp   && (c_RSI >= RSI_BuyLow)  && (c_RSI <= RSI_BuyHigh)
                  && (c_EmaFast > c_EmaSlow);
   bool rsiSell = trendDown && (c_RSI >= RSI_SellLow) && (c_RSI <= RSI_SellHigh)
                  && (c_EmaFast < c_EmaSlow);

   if (rsiBuy  && !InCooldown(SIG_RSI, ORDER_TYPE_BUY))
   {
      if (OpenPosition(ORDER_TYPE_BUY, SIG_RSI, "RSIPB"))
         g_CdRSIBuy = TimeCurrent();
   }

   if (rsiSell && !InCooldown(SIG_RSI, ORDER_TYPE_SELL))
   {
      if (OpenPosition(ORDER_TYPE_SELL, SIG_RSI, "RSIPB"))
         g_CdRSISell = TimeCurrent();
   }

   // ─────────────────────────────────────────────────────────────────
   // SIGNAL C : London Breakout (cassure range session asiatique)
   // ─────────────────────────────────────────────────────────────────
   if (LondonBreakout && IsLondonWindow() && g_AsianHigh > 0 && g_AsianLow > 0)
   {
      double buf    = c_ATR * 0.3; // marge anti-faux breakout
      double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if (ask > g_AsianHigh + buf && trendUp  && !InCooldown(SIG_BREAKOUT, ORDER_TYPE_BUY))
      {
         if (OpenPosition(ORDER_TYPE_BUY, SIG_BREAKOUT, "LNBRK"))
            g_CdBrkBuy = TimeCurrent();
      }

      if (bid < g_AsianLow - buf  && trendDown && !InCooldown(SIG_BREAKOUT, ORDER_TYPE_SELL))
      {
         if (OpenPosition(ORDER_TYPE_SELL, SIG_BREAKOUT, "LNBRK"))
            g_CdBrkSell = TimeCurrent();
      }
   }
}

//+------------------------------------------------------------------+
//| Lecture des indicateurs depuis les handles (buffer cache)         |
//+------------------------------------------------------------------+
bool LoadIndicators()
{
   c_ATR      = Buf(h_ATR,      1);
   c_RSI      = Buf(h_RSI,      1);
   c_EmaFast  = Buf(h_EMA_Fast, 1);
   c_EmaSlow  = Buf(h_EMA_Slow, 1);
   c_EmaFastP = Buf(h_EMA_Fast, 2);
   c_EmaSlowP = Buf(h_EMA_Slow, 2);
   c_TrendH1  = Buf(h_TrendH1,  1);
   c_FilterH1 = Buf(h_FilterH1, 1);

   // Vérification de validité (EMPTY_VALUE = échec lecture)
   return (c_ATR > 0 && c_RSI > 0 &&
           c_EmaFast  != EMPTY_VALUE && c_EmaSlow  != EMPTY_VALUE &&
           c_TrendH1  != EMPTY_VALUE && c_FilterH1 != EMPTY_VALUE);
}

//+------------------------------------------------------------------+
//| Lecture d'une valeur de buffer (helper générique)                |
//+------------------------------------------------------------------+
double Buf(int handle, int shift, int bufIdx = 0)
{
   double arr[];
   ArraySetAsSeries(arr, true);
   if (CopyBuffer(handle, bufIdx, shift, 1, arr) != 1) return EMPTY_VALUE;
   return arr[0];
}

//+------------------------------------------------------------------+
//| Calcul et cache du range de la session asiatique                  |
//+------------------------------------------------------------------+
void UpdateAsianRange()
{
   // Calculé une seule fois par jour, après l'ouverture de Londres
   MqlDateTime gmtNow;
   TimeToStruct(TimeGMT(), gmtNow);
   if (gmtNow.hour < AsianEndGMT) return; // Attendre la clôture de la session asiatique

   datetime todayGMT = TimeGMT() - gmtNow.hour * 3600
                                  - gmtNow.min  * 60
                                  - gmtNow.sec;
   if (g_AsianDay == todayGMT) return; // Déjà calculé aujourd'hui

   g_AsianHigh = 0;
   g_AsianLow  = DBL_MAX;

   // Décalage serveur → GMT pour convertir les heures des bougies
   long srvToGMT = (long)(TimeGMT() - TimeCurrent()); // en secondes

   // On scanne les bougies M5 des dernières 20h pour couvrir la session asiatique
   int maxBars = 20 * 12 + 10; // 20 heures × 12 bougies/heure
   double highs[], lows[];
   datetime times[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows,  true);
   ArraySetAsSeries(times, true);

   int copied = CopyTime(_Symbol, PERIOD_M5, 0, maxBars, times);
   if (copied <= 0) { g_AsianLow = 0; return; }
   CopyHigh(_Symbol, PERIOD_M5, 0, copied, highs);
   CopyLow (_Symbol, PERIOD_M5, 0, copied, lows);

   for (int i = 0; i < copied; i++)
   {
      MqlDateTime bdt;
      TimeToStruct(times[i] + srvToGMT, bdt); // conversion en GMT

      // Ne garder que les bougies d'aujourd'hui dans la fenêtre asiatique
      if (bdt.day_of_year != gmtNow.day_of_year) continue;
      if (bdt.hour < AsianStartGMT || bdt.hour >= AsianEndGMT) continue;

      if (highs[i] > g_AsianHigh) g_AsianHigh = highs[i];
      if (lows[i]  < g_AsianLow)  g_AsianLow  = lows[i];
   }

   if (g_AsianLow == DBL_MAX) g_AsianLow = 0;
   g_AsianDay = todayGMT;

   if (g_AsianHigh > 0)
      Print("[GHP5] Range asiatique | H:", DoubleToString(g_AsianHigh, _Digits),
            " L:", DoubleToString(g_AsianLow, _Digits),
            " Amp:", DoubleToString((g_AsianHigh - g_AsianLow) / _Point, 0), " pts");
}

//+------------------------------------------------------------------+
//| Vérifie si on est dans la fenêtre London open (08h-10h GMT)      |
//+------------------------------------------------------------------+
bool IsLondonWindow()
{
   MqlDateTime gmtDt;
   TimeToStruct(TimeGMT(), gmtDt);
   return (gmtDt.hour >= AsianEndGMT && gmtDt.hour < AsianEndGMT + 2);
}

//+------------------------------------------------------------------+
//| Gestion des positions ouvertes (BE + clôture partielle + trail)  |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   if (c_ATR <= 0) return;

   double atr      = c_ATR;
   double beDist   = atr * ATR_BE_Mult;
   double tp1Dist  = atr * ATR_TP1_Mult;
   double trailDst = atr * 1.0;

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (ticket == 0) continue;
      if (PositionGetInteger(POSITION_MAGIC)  != (long)MagicNumber) continue;
      if (PositionGetString(POSITION_SYMBOL)  != _Symbol)           continue;

      ENUM_POSITION_TYPE type      = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL  = PositionGetDouble(POSITION_SL);
      double currentTP  = PositionGetDouble(POSITION_TP);
      double lots       = PositionGetDouble(POSITION_VOLUME);
      double curPrice   = PositionGetDouble(POSITION_PRICE_CURRENT);

      double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

      if (type == POSITION_TYPE_BUY)
      {
         double profit = curPrice - openPrice;

         // 1. Clôture partielle à TP1 (si volume suffisant et pas encore fait)
         if (profit >= tp1Dist && lots > volMin * 1.5)
         {
            double closeVol = NormalizeVol(lots * PartialClosePct / 100.0, volMin, MaxLot, volStep);
            if (closeVol >= volMin && closeVol < lots)
            {
               if (g_Trade.PositionClosePartial(ticket, closeVol))
                  Print("[GHP5] Clôture partielle BUY #", ticket, " Vol:", closeVol);
            }
         }

         // 2. Breakeven : SL → ouverture+1 point quand profit ≥ beDist
         if (profit >= beDist && currentSL < openPrice)
         {
            double newSL = NormalizeDouble(openPrice + _Point, _Digits);
            if (newSL > currentSL)
               g_Trade.PositionModify(ticket, newSL, currentTP);
         }

         // 3. Trailing stop (uniquement quand SL est déjà au breakeven)
         if (currentSL >= openPrice - _Point)
         {
            double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double newSL = NormalizeDouble(curPrice - trailDst, _Digits);
            if (newSL > currentSL + 5 * _Point && newSL < ask)
               g_Trade.PositionModify(ticket, newSL, currentTP);
         }
      }
      else if (type == POSITION_TYPE_SELL)
      {
         double profit = openPrice - curPrice;

         // 1. Clôture partielle
         if (profit >= tp1Dist && lots > volMin * 1.5)
         {
            double closeVol = NormalizeVol(lots * PartialClosePct / 100.0, volMin, MaxLot, volStep);
            if (closeVol >= volMin && closeVol < lots)
            {
               if (g_Trade.PositionClosePartial(ticket, closeVol))
                  Print("[GHP5] Clôture partielle SELL #", ticket, " Vol:", closeVol);
            }
         }

         // 2. Breakeven
         if (profit >= beDist && (currentSL == 0 || currentSL > openPrice))
         {
            double newSL = NormalizeDouble(openPrice - _Point, _Digits);
            if (currentSL == 0 || newSL < currentSL)
               g_Trade.PositionModify(ticket, newSL, currentTP);
         }

         // 3. Trailing stop
         if (currentSL > 0 && currentSL <= openPrice + _Point)
         {
            double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double newSL = NormalizeDouble(curPrice + trailDst, _Digits);
            if (newSL < currentSL - 5 * _Point && newSL > bid)
               g_Trade.PositionModify(ticket, newSL, currentTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Ouverture de position avec validation complète                   |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE type, int sigType, string reason)
{
   if (c_ATR <= 0) return false;

   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price  = (type == ORDER_TYPE_BUY) ? ask : bid;

   double slDist = c_ATR * ATR_SL_Mult;
   double tpDist = c_ATR * ATR_TP_Mult;

   double sl, tp;
   if (type == ORDER_TYPE_BUY)
   {
      sl = NormalizeDouble(price - slDist, _Digits);
      tp = NormalizeDouble(price + tpDist, _Digits);
   }
   else
   {
      sl = NormalizeDouble(price + slDist, _Digits);
      tp = NormalizeDouble(price - tpDist, _Digits);
   }

   // Respect du stoplevel minimum du broker
   long   stopsLvl  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist   = stopsLvl * _Point * 1.5;
   if (type == ORDER_TYPE_BUY)
   {
      if (price - sl < minDist) sl = NormalizeDouble(price - minDist, _Digits);
      if (tp - price < minDist) tp = NormalizeDouble(price + minDist, _Digits);
   }
   else
   {
      if (sl - price < minDist) sl = NormalizeDouble(price + minDist, _Digits);
      if (price - tp < minDist) tp = NormalizeDouble(price - minDist, _Digits);
   }

   double lots = CalculateLots(slDist);

   // Commentaire (limité à 31 chars en MT5)
   string cmt = StringSubstr(EA_Comment + "|S" + IntegerToString(sigType) + "|" + reason, 0, 31);

   bool ok;
   if (type == ORDER_TYPE_BUY)
      ok = g_Trade.Buy(lots, _Symbol, ask, sl, tp, cmt);
   else
      ok = g_Trade.Sell(lots, _Symbol, bid, sl, tp, cmt);

   if (!ok || g_Trade.ResultRetcode() != TRADE_RETCODE_DONE)
   {
      uint rc = g_Trade.ResultRetcode();
      Print("[GHP5] Erreur trade: ", rc, " - ", g_Trade.ResultRetcodeDescription(),
            " | Lots:", lots, " | SL:", sl, " | TP:", tp);
      if (EnableAlerts && rc != 10016) // 10016 = invalid stops (transitoire)
         Alert("[GHP5] Erreur ouverture: ", g_Trade.ResultRetcodeDescription());
      return false;
   }

   g_TotalTrades++;
   g_TradesDay++;
   Print("[GHP5] Trade ouvert | ",
         (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
         " | Ticket:", g_Trade.ResultOrder(),
         " | Lots:", lots, " | SL:", sl, " | TP:", tp,
         " | Signal:", reason);
   return true;
}

//+------------------------------------------------------------------+
//| Calcul de la taille de lot selon le risque % du solde            |
//+------------------------------------------------------------------+
double CalculateLots(double sl_dist)
{
   if (sl_dist <= 0) return MinLot;

   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk     = balance * RiskPercent / 100.0;
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if (tickVal <= 0 || tickSz <= 0) return MinLot;

   double slTicks = sl_dist / tickSz;
   double lots    = risk / (slTicks * tickVal);

   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   return NormalizeVol(lots, MathMax(MinLot, volMin), MathMin(MaxLot, volMax), volStep);
}

//+------------------------------------------------------------------+
//| Normalisation du volume selon les contraintes du broker          |
//+------------------------------------------------------------------+
double NormalizeVol(double vol, double vMin, double vMax, double vStep)
{
   if (vStep > 0) vol = MathFloor(vol / vStep) * vStep;
   return NormalizeDouble(MathMax(vMin, MathMin(vMax, vol)), 2);
}

//+------------------------------------------------------------------+
//| Vérifie le cooldown pour éviter les entrées répétées             |
//+------------------------------------------------------------------+
bool InCooldown(int sig, ENUM_ORDER_TYPE dir)
{
   datetime last   = 0;
   int      cdSecs = CooldownMin * 60;

   if (sig == SIG_EMA      && dir == ORDER_TYPE_BUY)  last = g_CdEMABuy;
   if (sig == SIG_EMA      && dir == ORDER_TYPE_SELL) last = g_CdEMASell;
   if (sig == SIG_RSI      && dir == ORDER_TYPE_BUY)  last = g_CdRSIBuy;
   if (sig == SIG_RSI      && dir == ORDER_TYPE_SELL) last = g_CdRSISell;
   if (sig == SIG_BREAKOUT && dir == ORDER_TYPE_BUY)  last = g_CdBrkBuy;
   if (sig == SIG_BREAKOUT && dir == ORDER_TYPE_SELL) last = g_CdBrkSell;

   return (TimeCurrent() - last < cdSecs);
}

//+------------------------------------------------------------------+
//| Compte les positions ouvertes de ce bot                          |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int n = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (ticket == 0) continue;
      if ((ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
          PositionGetString(POSITION_SYMBOL) == _Symbol)
         n++;
   }
   return n;
}

//+------------------------------------------------------------------+
//| Mise à jour du suivi journalier                                  |
//+------------------------------------------------------------------+
void UpdateDailyTracking()
{
   static datetime lastDay = 0;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = TimeCurrent() - dt.hour * 3600 - dt.min * 60 - dt.sec;

   if (today != lastDay)
   {
      lastDay       = today;
      g_DayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
      g_DailyPnL    = 0;
      g_TradesDay   = 0;
      g_AsianHigh   = 0;
      g_AsianLow    = 0;
      g_AsianDay    = 0;
      Print("[GHP5] Nouveau jour | Solde: ", DoubleToString(g_DayStartBal, 2),
            " ", AccountInfoString(ACCOUNT_CURRENCY));
   }

   // P&L = (solde actuel - solde début) + flottant des positions ouvertes
   double floatPL = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (ticket == 0) continue;
      if ((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      floatPL += PositionGetDouble(POSITION_PROFIT)
               + PositionGetDouble(POSITION_SWAP)
               + PositionGetDouble(POSITION_COMMISSION);
   }
   g_DailyPnL = (AccountInfoDouble(ACCOUNT_BALANCE) - g_DayStartBal) + floatPL;
}

//+------------------------------------------------------------------+
//| Filtres de protection                                            |
//+------------------------------------------------------------------+
bool IsSpreadTooHigh()
{
   double sp = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if (sp > MaxSpreadPts)
   {
      static datetime lw = 0;
      if (TimeCurrent() - lw > 60)
      { Print("[GHP5] Spread élevé: ", sp, " > ", MaxSpreadPts); lw = TimeCurrent(); }
      return true;
   }
   return false;
}

bool IsSessionClosed()
{
   if (!UseSessionFilter) return false;

   MqlDateTime gmtDt;
   TimeToStruct(TimeGMT(), gmtDt);

   int h   = gmtDt.hour;
   int dow = gmtDt.day_of_week;

   if (dow == 0 || dow == 6)                  return true; // Week-end
   if (dow == 1 && !TradeMonday)              return true;
   if (dow == 5 && !TradeFriday)              return true;
   if (dow == 5 && h >= FridayCutGMT)         return true; // Coupure vendredi
   if (h < SessionStartGMT || h >= SessionEndGMT) return true;
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
         string msg = "[GHP5] Stop perte journalière: " + DoubleToString(pct, 2) + "%";
         Print(msg);
         if (EnableAlerts) Alert(msg);
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
         string msg = "[GHP5] Objectif journalier atteint: +" + DoubleToString(pct, 2) + "%";
         Print(msg);
         if (EnableAlerts) Alert(msg);
         lw = TimeCurrent();
      }
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Transaction callback — Enregistrement des trades fermés          |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &req,
                        const MqlTradeResult      &res)
{
   if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if (trans.deal_type != DEAL_TYPE_BUY && trans.deal_type != DEAL_TYPE_SELL) return;
   if (HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != (long)MagicNumber) return;
   if (HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
   if (profit == 0) return; // entrée (pas sortie)

   g_TotalProfit += profit;
   Print("[GHP5] Trade fermé | Profit: ", DoubleToString(profit, 2),
         " | Total: ", DoubleToString(g_TotalProfit, 2));
}

//+------------------------------------------------------------------+
//| Tableau de bord (MT5 — ObjectSetString/Integer)                  |
//+------------------------------------------------------------------+
void DrawDashboard()
{
   static datetime lastDraw = 0;
   if (TimeCurrent() - lastDraw < 3) return; // Throttle max 1x / 3s
   lastDraw = TimeCurrent();

   string p   = "GHP5_";
   color  gld = clrGold;
   color  grn = clrLimeGreen;
   color  red = clrTomato;
   color  wht = clrWhite;
   color  gry = (color)StringToInteger("0xA0A0A0"); // gris

   double bal  = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   double fl   = eq - bal;
   string cur  = AccountInfoString(ACCOUNT_CURRENCY);
   double sp   = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   double lossPct  = (g_DayStartBal > 0 && g_DailyPnL < 0)
                     ? -g_DailyPnL / g_DayStartBal * 100.0 : 0;
   double profPct  = (g_DayStartBal > 0 && g_DailyPnL > 0)
                     ?  g_DailyPnL / g_DayStartBal * 100.0 : 0;

   // Tendance
   double closeH1  = iClose(_Symbol, PERIOD_H1, 1);
   string trendStr = "NEUTRE";
   color  tc       = clrYellow;
   if (c_TrendH1 > c_FilterH1 && closeH1 > c_TrendH1) { trendStr = "HAUSSIERE"; tc = grn; }
   if (c_TrendH1 < c_FilterH1 && closeH1 < c_TrendH1) { trendStr = "BAISSIERE"; tc = red; }

   string sigStr = IsLondonWindow() && LondonBreakout ? "LONDON BREAKOUT"
                  : (c_EmaFast > c_EmaSlow ? "EMA BULL" : "EMA BEAR");

   string plStr = g_DailyPnL >= 0
      ? "+" + DoubleToString(g_DailyPnL, 2) + " (+" + DoubleToString(profPct, 2) + "%)"
      :        DoubleToString(g_DailyPnL, 2) + " (-" + DoubleToString(lossPct, 2) + "%)";

   string asianStr = (g_AsianHigh > 0)
      ? DoubleToString(g_AsianLow, _Digits) + " – " + DoubleToString(g_AsianHigh, _Digits)
      : "N/A";

   int y = 15; int dy = 19;

   Lbl5(p+"00", "  GoldHunterPro  v5.0  ",     10, y, gld, 11, true); y += dy + 4;
   Lbl5(p+"01", "Solde  : " + DoubleToString(bal,2) + " " + cur, 10, y, wht, 9); y += dy;
   Lbl5(p+"02", "Equity : " + DoubleToString(eq, 2) + " " + cur, 10, y, wht, 9); y += dy;
   Lbl5(p+"03", "Float  : " + (fl >= 0 ? "+" : "") + DoubleToString(fl, 2),
        10, y, fl >= 0 ? grn : red, 9); y += dy;
   Lbl5(p+"04", "J.PnL  : " + plStr, 10, y, g_DailyPnL >= 0 ? grn : red, 9); y += dy;
   Lbl5(p+"05", "Trades/j: " + IntegerToString(g_TradesDay) +
        " | Total: " + IntegerToString(g_TotalTrades),        10, y, wht, 9); y += dy;
   Lbl5(p+"06", "Positions: " + IntegerToString(CountMyPositions()) +
        "/" + IntegerToString(MaxOpenPositions),               10, y, wht, 9); y += dy;
   Lbl5(p+"07", "Spread : " + DoubleToString(sp, 0) + " pts", 10, y,
        sp > MaxSpreadPts ? red : grn, 9); y += dy;
   Lbl5(p+"08", "ATR M5 : " + DoubleToString(c_ATR / _Point, 0) + " pts", 10, y, wht, 9); y += dy;
   Lbl5(p+"09", "RSI    : " + DoubleToString(c_RSI, 1), 10, y,
        c_RSI > 70 ? red : (c_RSI < 30 ? grn : wht), 9); y += dy;
   Lbl5(p+"10", "Tendance: " + trendStr,   10, y, tc,  9); y += dy;
   Lbl5(p+"11", "Signal : " + sigStr,      10, y, clrDodgerBlue, 9); y += dy;
   Lbl5(p+"12", "Session: " + (IsSessionClosed() ? "FERMEE" : "OUVERTE"), 10, y,
        IsSessionClosed() ? red : grn, 9); y += dy;
   Lbl5(p+"13", "Asian  : " + asianStr,    10, y, gry, 9); y += dy;
   Lbl5(p+"14", "SL:" + DoubleToString(ATR_SL_Mult,1) +
        "xATR | TP:" + DoubleToString(ATR_TP_Mult,1) +
        "xATR | Risk:" + DoubleToString(RiskPercent,1) + "%",
        10, y, (color)StringToInteger("0x606060"), 8);
}

//+------------------------------------------------------------------+
//| Création / mise à jour d'un label MT5                            |
//+------------------------------------------------------------------+
void Lbl5(string name, string txt, int x, int y, color clr, int sz, bool bold = false)
{
   long cid = ChartID();
   if (ObjectFind(cid, name) < 0)
   {
      ObjectCreate(cid, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(cid, name, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(cid, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(cid, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(cid, name, OBJPROP_SELECTABLE, false);
   }
   ObjectSetString (cid, name, OBJPROP_TEXT,     txt);
   ObjectSetString (cid, name, OBJPROP_FONT,     bold ? "Arial Bold" : "Arial");
   ObjectSetInteger(cid, name, OBJPROP_FONTSIZE, sz);
   ObjectSetInteger(cid, name, OBJPROP_COLOR,    clr);
}

//+------------------------------------------------------------------+
