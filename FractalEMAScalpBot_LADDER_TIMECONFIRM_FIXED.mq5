//+------------------------------------------------------------------+
//|                           FractalEMAScalpBot.mq5                  |
//|   Fractal + EMA(8) M1 scalp with tight SL, trailing, Telegram     |
//+------------------------------------------------------------------+
#property strict
#property version "1.31"

//--- enum for direction
enum TradeType { NONE=0, BUY=1, SELL=2 };

//--- inputs
input double   LotSize          = 0.01;
input int      StopLossPips     = 150; // SL افتراضي كبير لتجنب Invalid stops على GOLD
input bool     UseTrailing      = false; // سيتم تعطيل التريلينج القديم واستبداله بسلم أهداف/تأمين أرباح
input int      TrailingPips     = 3;     // متروك للتوافق (غير مستخدم مع سلم الأهداف)
input int      MaxTrades        = 1;
input string   TradeSymbol      = "GOLD";
input long     MagicNumber      = 123456;

input double   MinCrossDiffPips = 0.5;
input int      MaxReentries     = 1;

// --- Profit ladder (سلم أهداف + تأمين أرباح)
input int      TP1_Pips            = 10;
input int      TP2_Pips            = 20;
input int      TP3_Pips            = 35;
input int      PreSecureBufferPips = 5;   // قبل الهدف التالي بهذا المقدار ننقل SL لتأمين الهدف السابق
input int      AfterTP3_StepPips   = 15;  // بعد TP3 نضيف هدف جديد كل 15 pip (قابل للتغيير)
input int      AfterTP3_SLOffsetPips= 5;  // بعد TP3: نجعل SL قبل الهدف السابق بـ 5 pip
input int      MaxLadderLevels     = 50;  // حد أقصى لمستويات السلم

// --- Entry timing control (دخول لحظي + تأكيد زمني)
input int      ConfirmMillis       = 300; // تأكيد زمني للاختراق داخل نفس الشمعة (ms)

// --- Re-entry after early close (إعادة محاولة دخول بعد إغلاق انعكاس EMA)
input int      ReentryWindowMs     = 60000; // نافذة زمنية بالمللي ثانية لإعادة المحاولة (0 لتعطيل الإغلاق التلقائي للنافذة)

// --- Exit on opposite EMA cross (إغلاق يدوي بدون انتظار SL)
input bool     ExitOnOppCross   = true;
input bool     TradingEnabledDefault = true; // الحالة الافتراضية عند تشغيل الاكسبرت

input bool     UseTelegram      = true;
// --- Telegram (كما طلبت)
input string   BotToken         = "8515837339:AAEs-66xF51GqWBydY_eLSgUp5s14UN_v9g";
input string   ChatId           = "8155685182";

//--- indicator handles
int handleEMA     = INVALID_HANDLE;
int handleFractal = INVALID_HANDLE;

//--- runtime copies (modifiable via Telegram commands)
bool   gTradingEnabled   = true;
double gLotSize          = 0.0;
int    gMaxTrades        = 0;
string gTradeSymbol      = "";
double gMinCrossDiffPips = 0.0;
int    gMaxReentries     = 0;

//--- state
datetime lastSignalBarTime      = 0;
datetime lastFractalTimestamp   = 0;
TradeType lastFractalType       = NONE;
int      reentryCount           = 0;

//--- Telegram state
long lastUpdateId = 0;
string GV_UPDATE_ID = "FES_lastUpdateId";
string lastTelegramCmd = "";
datetime lastTelegramCmdTime = 0;

//--- Re-entry cache (بعد إغلاق الصفقة بسبب تقاطع معاكس)
TradeType reentryWanted = NONE;
uint      reentrySetMs      = 0;

//--- In-bar (tick) cross confirmation (no need to wait for a new candle)
int      gLastZone      = 0;     // -1 below EMA, 0 neutral, +1 above EMA
TradeType gPendingSide  = NONE;  // side being confirmed
uint     gPendingMs     = 0;     // GetTickCount() when confirmation started

//--- Ladder helpers (stored per ticket using GlobalVariables)
string GVLevelKey(const ulong ticket) { return StringFormat("FES_level_%I64u", ticket); }

int GetLevel(const ulong ticket)
{
   string k = GVLevelKey(ticket);
   if(GlobalVariableCheck(k))
      return (int)GlobalVariableGet(k);
   return 0;
}

void SetLevel(const ulong ticket, const int level)
{
   GlobalVariableSet(GVLevelKey(ticket), (double)level);
}

double TargetPipsForLevel(const int level)
{
   if(level<=1) return (double)TP1_Pips;
   if(level==2) return (double)TP2_Pips;
   if(level==3) return (double)TP3_Pips;
   // بعد TP3: أهداف متتابعة
   return (double)TP3_Pips + (double)(level-3) * (double)AfterTP3_StepPips;
}

double SecureSLForPrevLevel(const TradeType side, const double entryPrice, const int prevLevel)
{
   double prevPips = TargetPipsForLevel(prevLevel);
   double prevPrice = (side==BUY)
      ? (entryPrice + PipToPrice(gTradeSymbol, prevPips))
      : (entryPrice - PipToPrice(gTradeSymbol, prevPips));

   if(prevLevel>=3)
   {
      double off = PipToPrice(gTradeSymbol, (double)AfterTP3_SLOffsetPips);
      return (side==BUY) ? (prevPrice - off) : (prevPrice + off);
   }
   // قبل/حتى TP2: SL = الهدف السابق تمامًا
   return prevPrice;
}

//+------------------------------------------------------------------+
//| Helpers: symbol info                                              |
//+------------------------------------------------------------------+
double SymPoint(const string sym)  { return SymbolInfoDouble(sym, SYMBOL_POINT); }
int    SymDigits(const string sym) { return (int)SymbolInfoInteger(sym, SYMBOL_DIGITS); }

double PipToPrice(const string sym, const double pips)
{
   int digits = SymDigits(sym);
   double point = SymPoint(sym);
   double factor = (digits==3 || digits==5) ? 10.0 : 1.0;
   return pips * factor * point;
}

int MinStopLevelPoints(const string sym)
{
   int stops  = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   int minlv = (stops > freeze ? stops : freeze);
   // ملاحظة: بعض الوسطاء قد يرجعون 0 هنا، لكن السيرفر ما زال يرفض "Invalid stops".
   // لذلك سنستخدم OrderCheck لاحقاً لضبط الـ SL عملياً إن لزم.
   return minlv;
}

ENUM_ORDER_TYPE_FILLING GetFillingMode(const string sym)
{
   int mode = (int)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if(mode==ORDER_FILLING_FOK || mode==ORDER_FILLING_IOC || mode==ORDER_FILLING_RETURN)
      return (ENUM_ORDER_TYPE_FILLING)mode;

   // fallback شائع
   return ORDER_FILLING_IOC;
}

//+------------------------------------------------------------------+
//| String utils                                                      |
//+------------------------------------------------------------------+
string TrimString(string s)
{
   int start=0, len=StringLen(s);
   while(start<len && StringGetCharacter(s,start)<=32) start++;
   int end=len-1;
   while(end>=start && StringGetCharacter(s,end)<=32) end--;
   if(start>end) return "";
   return StringSubstr(s,start,end-start+1);
}

string IntegerToHexString(int value, int width)
{
   uint v=(uint)value;
   string hex="";
   string digits="0123456789ABCDEF";
   while(v>0)
   {
      int d=(int)(v%16);
      v/=16;
      hex = StringSubstr(digits,d,1) + hex;
   }
   if(StringLen(hex)==0) hex="0";
   while(StringLen(hex)<width) hex="0"+hex;
   return hex;
}

// URL encode UTF-8
string UrlEncodeUtf8(string s)
{
   uchar bytes[];
   int n = StringToCharArray(s, bytes, 0, WHOLE_ARRAY, 65001); // UTF-8
   if(n<=0) return "";

   string out="";
   for(int i=0;i<n;i++)
   {
      uchar b = bytes[i];
      if(b==0) break;

      if((b>='0' && b<='9') || (b>='A' && b<='Z') || (b>='a' && b<='z') || b=='_' || b=='-' || b=='.' || b=='~')
      {
         out += CharToString((ushort)b);
      }
      else if(b==' ')
      {
         out += "+";
      }
      else
      {
         out += "%";
         out += IntegerToHexString((int)b,2);
      }
   }
   return out;
}

//+------------------------------------------------------------------+
//| HTTP GET via WebRequest                                           |
//+------------------------------------------------------------------+
bool HttpGet(const string url, string &response, const int timeout_ms=10000)
{
   char data[];
   ArrayResize(data,0);

   char result[];
   string result_headers;

   ResetLastError();
   int res = WebRequest("GET", url, "", timeout_ms, data, result, result_headers);
   if(res<=0)
   {
      int err = GetLastError();
      // 4014 غالبًا يعني WebRequest غير مسموح
      if(err==4014)
         Print("WebRequest blocked. Add https://api.telegram.org in MT5: Tools->Options->Expert Advisors.");
      return false;
   }

   response = CharArrayToString(result, 0, WHOLE_ARRAY, 65001);
   return true;
}

//+------------------------------------------------------------------+
//| Telegram                                                          |
//+------------------------------------------------------------------+
void SendTelegram(const string text)
{
   if(!UseTelegram) return;
   if(StringLen(BotToken)==0 || StringLen(ChatId)==0) return;

   string encoded = UrlEncodeUtf8(text);
   string url = StringFormat("https://api.telegram.org/bot%s/sendMessage?chat_id=%s&text=%s",
                             BotToken, ChatId, encoded);

   string resp;
   if(!HttpGet(url, resp, 10000))
      Print("Telegram send failed. err=", GetLastError());
}

// Parse very basic commands: "lot 0.02", "max 2", "symbol GOLD", "diff 0.5", "re 1"
void ParseCommand(const string raw_cmd)
{
   string original = TrimString(raw_cmd);
   if(StringLen(original)==0) return;
   // بعض المستخدمين يكتبون /start أو /status .. نحذف / إن وُجدت
   if(StringGetCharacter(original,0)=='/') original = StringSubstr(original,1);
   string text = StringToLower(original);


   if(text=="start" || text=="panel")
   {
      SendTelegram("Commands:\nstart/panel = show panel\nstatus = report\nstop = disable trading\nrun = enable trading\nlot X\nmax N\nsymbol GOLD\ndiff X\nre N");
      return;
   }
   if(text=="status")
   {
      string s = StringFormat("Status: %s\nSymbol=%s\nLot=%.2f\nMaxTrades=%d\nReentries=%d\nDiff=%.2f pips\nSL=%d pips",
                              (gTradingEnabled?"RUNNING":"STOPPED"),
                              gTradeSymbol, gLotSize, gMaxTrades, gMaxReentries, gMinCrossDiffPips, StopLossPips);
      SendTelegram(s);
      return;
   }
   if(text=="stop")
   {
      gTradingEnabled = false;
      SendTelegram("Trading STOPPED.");
      return;
   }
   if(text=="run")
   {
      gTradingEnabled = true;
      SendTelegram("Trading RUNNING.");
      return;
   }
   if(StringFind(text,"lot ")==0)
   {
      double v = StringToDouble(StringSubstr(original,4));
      if(v>0) { gLotSize=v; SendTelegram("Lot updated: "+DoubleToString(gLotSize,2)); }
      return;
   }
   if(StringFind(text,"max ")==0)
   {
      int v = (int)StringToInteger(StringSubstr(original,4));
      if(v>=1) { gMaxTrades=v; SendTelegram("Max trades updated: "+IntegerToString(gMaxTrades)); }
      return;
   }
   if(StringFind(text,"symbol ")==0)
   {
      string v = TrimString(StringSubstr(original,7));
      if(StringLen(v)>=3)
      {
         gTradeSymbol = StringToUpper(v);

         if(handleEMA!=INVALID_HANDLE)     IndicatorRelease(handleEMA);
         if(handleFractal!=INVALID_HANDLE) IndicatorRelease(handleFractal);

         handleEMA     = iMA(gTradeSymbol, PERIOD_M1, 8, 0, MODE_EMA, PRICE_CLOSE);
         handleFractal = iFractals(gTradeSymbol, PERIOD_M1);

         if(handleEMA==INVALID_HANDLE || handleFractal==INVALID_HANDLE)
            SendTelegram("Failed to set symbol: "+gTradeSymbol);
         else
            SendTelegram("Symbol updated: "+gTradeSymbol);
      }
      return;
   }
   if(StringFind(text,"diff ")==0)
   {
      double v = StringToDouble(StringSubstr(original,5));
      if(v>=0) { gMinCrossDiffPips=v; SendTelegram("Diff updated: "+DoubleToString(gMinCrossDiffPips,2)); }
      return;
   }
   if(StringFind(text,"re ")==0)
   {
      int v = (int)StringToInteger(StringSubstr(original,3));
      if(v>=0) { gMaxReentries=v; SendTelegram("Re-entries updated: "+IntegerToString(gMaxReentries)); }
      return;
   }

   SendTelegram("Unknown command. Send: panel");
}

void CheckTelegramCommands()
{
   if(!UseTelegram) return;
   if(StringLen(BotToken)==0 || StringLen(ChatId)==0) return;

   string url = StringFormat("https://api.telegram.org/bot%s/getUpdates?offset=%I64d",
                             BotToken, (long)(lastUpdateId+1));

   string response;
   if(!HttpGet(url, response, 10000))
      return;

   int posUpdate = StringFind(response, "\"update_id\":");
   while(posUpdate>=0)
   {
      int comma = StringFind(response, ",", posUpdate);
      if(comma<0) break;

      string idStr = StringSubstr(response, posUpdate+13, comma-(posUpdate+13));
      long updateId = (long)StringToInteger(idStr);
      if(updateId>lastUpdateId) { lastUpdateId=updateId; GlobalVariableSet(GV_UPDATE_ID,(double)lastUpdateId); }

      int textPos = StringFind(response, "\"text\":", posUpdate);
      if(textPos>0)
      {
         int q1 = StringFind(response, "\"", textPos+7);
         int q2 = StringFind(response, "\"", q1+1);
         if(q1>0 && q2>q1)
         {
            string cmd = StringSubstr(response, q1+1, q2-(q1+1));
            // منع تكرار تنفيذ نفس الأمر بسرعة (يحل مشكلة التكرار/السبام عند الضغط على الأزرار)
            datetime now = TimeCurrent();
            if(cmd!=lastTelegramCmd || (now-lastTelegramCmdTime) > 2)
            {
               lastTelegramCmd = cmd;
               lastTelegramCmdTime = now;
               ParseCommand(cmd);
            }
         }
      }

      posUpdate = StringFind(response, "\"update_id\":", comma);
   }
}

//+------------------------------------------------------------------+
//| Trading helpers                                                   |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;

      if(!PositionSelectByTicket(ticket)) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long mg    = (long)PositionGetInteger(POSITION_MAGIC);

      if(sym==gTradeSymbol && mg==MagicNumber)
         count++;
   }
   return count;
}

ulong FindNewestPositionTicket(const TradeType side)
{
   datetime bestTime=0;
   ulong bestTicket=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=gTradeSymbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      long type=(long)PositionGetInteger(POSITION_TYPE);
      if(side==BUY  && type!=POSITION_TYPE_BUY)  continue;
      if(side==SELL && type!=POSITION_TYPE_SELL) continue;
      datetime t=(datetime)PositionGetInteger(POSITION_TIME);
      if(t>bestTime){ bestTime=t; bestTicket=ticket; }
   }
   return bestTicket;
}

bool EnsureSLDistance(const TradeType side, const double entryPrice, double &slPrice)
{
   int minPts = MinStopLevelPoints(gTradeSymbol);
   double point = SymPoint(gTradeSymbol);
   double minDist = minPts * point;

   if(minPts<=0)
   {
      // بعض الوسطاء يعيدون 0 لكن يفرضون مسافة فعلية؛ استخدم السبريد + هامش آمن
      int spr = (int)SymbolInfoInteger(gTradeSymbol, SYMBOL_SPREAD);
      minPts = (spr>0 ? spr+50 : 100);
      minDist = minPts * point;
   }

   if(side==BUY)
   {
      double maxSL = entryPrice - minDist;
      if(slPrice > maxSL) slPrice = maxSL;
   }
   else if(side==SELL)
   {
      double minSL = entryPrice + minDist;
      if(slPrice < minSL) slPrice = minSL;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Validate/adjust SL using OrderCheck (handles "Invalid stops")    |
//+------------------------------------------------------------------+
bool AdjustStopsWithOrderCheck(MqlTradeRequest &req, const TradeType side)
{
   // if no SL, nothing to adjust
   if(req.sl<=0.0) return true;

   const string sym=req.symbol;
   const int digits=SymDigits(sym);
   const double point=SymPoint(sym);

   // base step: use broker stop/freeze if available, otherwise a safe metal-friendly default
   int basePts = MinStopLevelPoints(sym);
   if(basePts<=0) basePts = 50; // 50 points default when broker reports 0 but still enforces

   // incremental step in points
   const int stepPts = 10;

   MqlTradeCheckResult check;
   for(int i=0;i<40;i++)
   {
      ZeroMemory(check);
      bool ok = OrderCheck(req, check);

      // if OrderCheck itself fails, still use check.retcode/comment if provided
      if(ok && (check.retcode==0 || check.retcode==10009 || check.retcode==10008))
         return true;

      // TRADE_RETCODE_INVALID_STOPS = 10016 (common)
      if(check.retcode!=10016)
         return true; // not a stops issue

      int distPts = basePts + i*stepPts;
      if(side==BUY)
      {
         double maxSL = req.price - distPts*point;
         if(req.sl > maxSL) req.sl = maxSL;
      }
      else if(side==SELL)
      {
         double minSL = req.price + distPts*point;
         if(req.sl < minSL) req.sl = minSL;
      }
      req.sl = NormalizeDouble(req.sl, digits);
   }
   return true;
}

//+------------------------------------------------------------------+
//| Signal logic                                                      |
//+------------------------------------------------------------------+
TradeType CheckSignal()
{
   if(handleFractal==INVALID_HANDLE || handleEMA==INVALID_HANDLE)
      return NONE;

   double bufUpper[1], bufLower[1];

   // fractals appear at shift 2
   if(CopyBuffer(handleFractal,0,2,1,bufUpper)>0 && CopyBuffer(handleFractal,1,2,1,bufLower)>0)
   {
      datetime fractalTime = iTime(gTradeSymbol, PERIOD_M1, 2);

      if(bufLower[0]!=0.0 && (fractalTime!=lastFractalTimestamp || lastFractalType!=BUY))
      {
         lastFractalTimestamp = fractalTime;
         lastFractalType = BUY;
         reentryCount = 0;
      }
      else if(bufUpper[0]!=0.0 && (fractalTime!=lastFractalTimestamp || lastFractalType!=SELL))
      {
         lastFractalTimestamp = fractalTime;
         lastFractalType = SELL;
         reentryCount = 0;
      }
   }

   if(lastFractalTimestamp==0 || lastFractalType==NONE) return NONE;
   // gMaxReentries = عدد الإعادات (محاولات إضافية) بعد الدخول الأساسي
   // مثال: 0 = بدون إعادة، 1 = إعادة واحدة (إجمالي محاولتين)
   if(reentryCount>gMaxReentries) return NONE;

   // --- Tick-based cross (enter within the same candle) with time confirmation
   double ema0Arr[1];
   if(CopyBuffer(handleEMA,0,0,1,ema0Arr)<1) return NONE;
   double ema0 = ema0Arr[0];

   double ask = SymbolInfoDouble(gTradeSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(gTradeSymbol, SYMBOL_BID);
   double threshold = PipToPrice(gTradeSymbol, gMinCrossDiffPips);

   // Define zones relative to EMA with threshold
   bool above = (bid > ema0 + threshold);
   bool below = (ask < ema0 - threshold);
   int zone = above ? 1 : (below ? -1 : 0);

   // Detect cross event (state change) and start confirmation timer
   if(zone==1 && gLastZone<=0)
   {
      gPendingSide = BUY;
      gPendingMs = (uint)GetTickCount();
   }
   else if(zone==-1 && gLastZone>=0)
   {
      gPendingSide = SELL;
      gPendingMs = (uint)GetTickCount();
   }
   gLastZone = zone;

   // Re-entry window management (armed after EMA reversal close)
   if(reentryWanted!=NONE && ReentryWindowMs>0)
   {
      uint elapsed = (uint)GetTickCount() - reentrySetMs;
      if(elapsed > (uint)ReentryWindowMs)
         reentryWanted = NONE;
   }

   // Confirm and decide
   if(gPendingSide!=NONE)
   {
      bool stillValid = ((gPendingSide==BUY && zone==1) || (gPendingSide==SELL && zone==-1));
      if(!stillValid)
      {
         gPendingSide = NONE;
      }
      else
      {
         uint elapsed = (uint)GetTickCount() - gPendingMs;
         if(elapsed >= (uint)ConfirmMillis)
         {
            // Priority: if reentry is armed, allow it without waiting for a new fractal
            if(reentryWanted==gPendingSide)
               return gPendingSide;

            // Otherwise, require fractal alignment
            if(lastFractalType==gPendingSide)
               return gPendingSide;

            // Not allowed -> reset pending and wait for a new cross event
            gPendingSide = NONE;
         }
      }
   }

   return NONE;
}

//+------------------------------------------------------------------+
//| Order placement                                                   |
//+------------------------------------------------------------------+
void PlaceOrder(const TradeType side)
{
   if(side!=BUY && side!=SELL) return;

    int digits = SymDigits(gTradeSymbol);
    double point = SymPoint(gTradeSymbol);
    // مسافات بالـ pip لتحويلها لسعر (حتى لا تختلط pips مع points)
    double slDistPrice  = PipToPrice(gTradeSymbol, (double)StopLossPips);

   double price = 0.0;
   double slPrice = 0.0;
   double fractalVal = 0.0;

   // الهدف الأول (TP1) حسب سلم الأهداف
   double tp1Dist = PipToPrice(gTradeSymbol, (double)TP1_Pips);

   if(side==BUY)
   {
      double bufLower[1];
      if(CopyBuffer(handleFractal,1,2,1,bufLower)>0 && bufLower[0]!=0.0)
         fractalVal = bufLower[0];
      else
         fractalVal = SymbolInfoDouble(gTradeSymbol, SYMBOL_BID);

       price = SymbolInfoDouble(gTradeSymbol, SYMBOL_ASK);
       slPrice = fractalVal - slDistPrice;

      EnsureSLDistance(BUY, price, slPrice);
   }
   else
   {
      double bufUpper[1];
      if(CopyBuffer(handleFractal,0,2,1,bufUpper)>0 && bufUpper[0]!=0.0)
         fractalVal = bufUpper[0];
      else
         fractalVal = SymbolInfoDouble(gTradeSymbol, SYMBOL_ASK);

       price = SymbolInfoDouble(gTradeSymbol, SYMBOL_BID);
       slPrice = fractalVal + slDistPrice;

      EnsureSLDistance(SELL, price, slPrice);
   }

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action      = TRADE_ACTION_DEAL;
   request.symbol      = gTradeSymbol;
   request.volume      = gLotSize;
   request.magic       = MagicNumber;
   request.deviation   = 10;
   request.type_time   = ORDER_TIME_GTC;
   // سنجرب أكثر من وضع Filling لأن بعض وسطاء (مثل FxPro على GOLD) يرفضون وضعًا بعينه (retcode=10030)
   request.type_filling= GetFillingMode(gTradeSymbol);

   if(side==BUY)
   {
      request.type  = ORDER_TYPE_BUY;
      request.price = price;
      request.sl    = NormalizeDouble(slPrice, digits);
      request.tp    = NormalizeDouble(price + tp1Dist, digits);
   }
   else
   {
      request.type  = ORDER_TYPE_SELL;
      request.price = price;
      request.sl    = NormalizeDouble(slPrice, digits);
      request.tp    = NormalizeDouble(price - tp1Dist, digits);
   }

   // نستخدم حد أدنى للمسافة + OrderCheck لضبط SL/TP عمليًا وتجنب Invalid stops
   EnsureSLDistance(side, price, request.sl);
   AdjustStopsWithOrderCheck(request, side);

   //--- Try multiple filling modes (RETURN -> IOC -> FOK) to avoid 10030/4756
   ENUM_ORDER_TYPE_FILLING modes[3] = {ORDER_FILLING_RETURN, ORDER_FILLING_IOC, ORDER_FILLING_FOK};
   bool ok=false;
   int  err=0;

   for(int i=0;i<3;i++)
   {
      request.type_filling = modes[i];
      ResetLastError();
      ZeroMemory(result);

      ok = OrderSend(request, result);
      err = GetLastError();

      // 10009 = DONE, 10008 = PLACED (بعض الحسابات تعتبرها نجاح)
      if(ok && (result.retcode==10009 || result.retcode==10008))
         break;

      // إذا كان الرفض ليس بسبب filling فلا داعي للتجربة
      if(result.retcode!=10030)
         break;
   }

   if(!ok || (result.retcode!=10009 && result.retcode!=10008))
   {
      Print("OrderSend FAILED. side=", (side==BUY?"BUY":"SELL"),
            " retcode=", result.retcode, " err=", err,
            " fill=", (int)request.type_filling);

      SendTelegram(StringFormat("OrderSend FAILED (%s) retcode=%d err=%d fill=%d",
                                (side==BUY?"BUY":"SELL"),
                                (int)result.retcode, err, (int)request.type_filling));
      return;
   }

   SendTelegram(StringFormat("Opened %s at %s SL=%s fill=%d",
                             (side==BUY?"BUY":"SELL"),
                             DoubleToString(price, digits),
                             DoubleToString(slPrice, digits),
                             (int)request.type_filling));

   // تهيئة سلم الأرباح لهذه الصفقة
   ulong newTicket = FindNewestPositionTicket(side);
   if(newTicket>0)
      SetLevel(newTicket, 1);

   // تم تنفيذ إعادة الدخول/الدخول، أزل التسليح
   reentryWanted = NONE;

   reentryCount++;
}

//+------------------------------------------------------------------+
//| Close position                                                    |
//+------------------------------------------------------------------+
void ClosePosition(const ulong ticket)
{
   if(ticket==0) return;
   if(!PositionSelectByTicket(ticket)) return;

   string sym = PositionGetString(POSITION_SYMBOL);
   long mg    = (long)PositionGetInteger(POSITION_MAGIC);
   if(sym!=gTradeSymbol || mg!=MagicNumber) return;

   long   type   = (long)PositionGetInteger(POSITION_TYPE);
   double volume = PositionGetDouble(POSITION_VOLUME);

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = gTradeSymbol;
   request.position     = ticket;
   request.volume       = volume;
   request.deviation    = 10;
   request.magic        = MagicNumber;
   request.type_time    = ORDER_TIME_GTC;
   request.type_filling = GetFillingMode(gTradeSymbol); // مهم أيضًا

   if(type==POSITION_TYPE_BUY)
   {
      request.type  = ORDER_TYPE_SELL;
      request.price = SymbolInfoDouble(gTradeSymbol, SYMBOL_BID);
   }
   else if(type==POSITION_TYPE_SELL)
   {
      request.type  = ORDER_TYPE_BUY;
      request.price = SymbolInfoDouble(gTradeSymbol, SYMBOL_ASK);
   }
   else return;

   //--- Try multiple filling modes to avoid server rejection
   ENUM_ORDER_TYPE_FILLING modes[3] = {ORDER_FILLING_RETURN, ORDER_FILLING_IOC, ORDER_FILLING_FOK};
   bool ok=false;
   int  err=0;

   for(int i=0;i<3;i++)
   {
      request.type_filling = modes[i];
      ResetLastError();
      ZeroMemory(result);
      ok = OrderSend(request, result);
      err = GetLastError();
      if(ok && (result.retcode==10009 || result.retcode==10008))
         break;
      if(result.retcode!=10030)
         break;
   }

   if(!ok || (result.retcode!=10009 && result.retcode!=10008))
      Print("Close FAILED retcode=", result.retcode, " err=", err, " fill=", (int)request.type_filling);
}

//+------------------------------------------------------------------+
//| Trailing + EMA exit                                               |
//+------------------------------------------------------------------+
void ManagePositions()
{
   if(handleEMA==INVALID_HANDLE) return;

   double ema0[1];
   bool haveEMA = (CopyBuffer(handleEMA,0,0,1,ema0)>0);
   if(!haveEMA) return;

   int digits = SymDigits(gTradeSymbol);
   double bid = SymbolInfoDouble(gTradeSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(gTradeSymbol, SYMBOL_ASK);
   double threshold = PipToPrice(gTradeSymbol, gMinCrossDiffPips);

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)!=gTradeSymbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

      long   ptype = (long)PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);

      TradeType side = (ptype==POSITION_TYPE_BUY ? BUY : SELL);

      // (A) إغلاق يدوي عند انعكاس السعر عبر EMA (بدون انتظار SL)
      if(ExitOnOppCross)
      {
         if(side==BUY && bid < (ema0[0] - threshold))
         {
            ClosePosition(ticket);
            reentryWanted = BUY;
            reentrySetMs = (uint)GetTickCount();
            SendTelegram("Closed BUY (Opp EMA cross) -> reentry armed");
            continue;
         }
         if(side==SELL && ask > (ema0[0] + threshold))
         {
            ClosePosition(ticket);
            reentryWanted = SELL;
            reentrySetMs = (uint)GetTickCount();
            SendTelegram("Closed SELL (Opp EMA cross) -> reentry armed");
            continue;
         }
      }

      // (B) سلم الأهداف
      int level = GetLevel(ticket);
      if(level<=0) level=1;
      if(level>MaxLadderLevels) level=MaxLadderLevels;

      double tgtPips = TargetPipsForLevel(level);
      double tgtPrice = (side==BUY)
         ? (open + PipToPrice(gTradeSymbol, tgtPips))
         : (open - PipToPrice(gTradeSymbol, tgtPips));

      // تأكد أن TP الموجود على الصفقة يساوي هدف المستوى الحالي
      if(tp==0.0 || MathAbs(tp - tgtPrice) > (SymPoint(gTradeSymbol)*2))
      {
         MqlTradeRequest req;
         MqlTradeResult  res;
         ZeroMemory(req);
         ZeroMemory(res);
         req.action   = TRADE_ACTION_SLTP;
         req.symbol   = gTradeSymbol;
         req.position = ticket;
         req.magic    = MagicNumber;
         req.sl       = sl;
         req.tp       = NormalizeDouble(tgtPrice, digits);
         OrderSend(req,res);
      }

      // (B1) قبل الوصول للهدف التالي: انقل SL لتأمين الهدف السابق
      if(level>=2)
      {
         double pre = PipToPrice(gTradeSymbol, (double)PreSecureBufferPips);
         bool nearTarget = (side==BUY) ? (bid >= (tgtPrice - pre)) : (ask <= (tgtPrice + pre));
         if(nearTarget)
         {
            double secureSL = SecureSLForPrevLevel(side, open, level-1);
            // تحديث SL فقط إذا كان أفضل (يرفع/يخفض في الاتجاه الصحيح)
            bool improve = (side==BUY) ? (sl==0.0 || secureSL>sl) : (sl==0.0 || secureSL<sl);
            if(improve)
            {
               MqlTradeRequest req;
               MqlTradeResult  res;
               ZeroMemory(req);
               ZeroMemory(res);
               req.action   = TRADE_ACTION_SLTP;
               req.symbol   = gTradeSymbol;
               req.position = ticket;
               req.magic    = MagicNumber;
               req.sl       = NormalizeDouble(secureSL, digits);
               req.tp       = NormalizeDouble(tgtPrice, digits);
               OrderSend(req,res);
            }
         }
      }

      // (B2) عند تحقق الهدف: تقدم للمستوى التالي (TP جديد)
      bool hit = (side==BUY) ? (bid >= tgtPrice) : (ask <= tgtPrice);
      if(hit)
      {
         int next = level + 1;
         if(next<=MaxLadderLevels)
         {
            SetLevel(ticket, next);
            double nextPips = TargetPipsForLevel(next);
            double nextTP   = (side==BUY)
               ? (open + PipToPrice(gTradeSymbol, nextPips))
               : (open - PipToPrice(gTradeSymbol, nextPips));

            // بعد TP3: ارفع SL إلى قبل الهدف السابق بـ offset
            double newSL = sl;
            if(next>=4)
               newSL = SecureSLForPrevLevel(side, open, next-1);

            MqlTradeRequest req;
            MqlTradeResult  res;
            ZeroMemory(req);
            ZeroMemory(res);
            req.action   = TRADE_ACTION_SLTP;
            req.symbol   = gTradeSymbol;
            req.position = ticket;
            req.magic    = MagicNumber;
            req.sl       = NormalizeDouble(newSL, digits);
            req.tp       = NormalizeDouble(nextTP, digits);
            OrderSend(req,res);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| OnInit / OnTick                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(_Period!=PERIOD_M1)
      Print("Attach EA to M1 for intended behaviour.");

   gLotSize          = LotSize;
   gMaxTrades        = MaxTrades;
   gTradeSymbol      = TradeSymbol;
   gMinCrossDiffPips = MinCrossDiffPips;
   gMaxReentries     = MaxReentries;
   gTradingEnabled = TradingEnabledDefault;

   handleEMA     = iMA(gTradeSymbol, PERIOD_M1, 8, 0, MODE_EMA, PRICE_CLOSE);
   handleFractal = iFractals(gTradeSymbol, PERIOD_M1);

   if(handleEMA==INVALID_HANDLE || handleFractal==INVALID_HANDLE)
   {
      Print("Failed to create indicator handles. err=", GetLastError());
      return INIT_FAILED;
   }

   // إظهار المؤشرات على الشارت (ليس فقط في الخلفية)
   // نافذة 0 = الشارت الرئيسي
   ChartIndicatorAdd(0, 0, handleEMA);
   ChartIndicatorAdd(0, 0, handleFractal);
   ChartRedraw(0);

   Print("EA ready. Symbol=", gTradeSymbol, " filling=", (int)GetFillingMode(gTradeSymbol));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(handleEMA!=INVALID_HANDLE)     IndicatorRelease(handleEMA);
   if(handleFractal!=INVALID_HANDLE) IndicatorRelease(handleFractal);
}

void OnTick()
{
   ManagePositions();
   CheckTelegramCommands();

   if(CountPositions()>=gMaxTrades) return;

   
   TradeType sig = CheckSignal();
   if(sig==BUY || sig==SELL)
      PlaceOrder(sig);
}
//+------------------------------------------------------------------+
