package com.dchoc.graphics
{
   import flash.display.Bitmap;
   import flash.display.BitmapData;
   import flash.display.Loader;
   import flash.display.LoaderInfo;
   import flash.display.MovieClip;
   import flash.display.Sprite;
   import flash.events.Event;
   import flash.events.EventDispatcher;
   import flash.events.IOErrorEvent;
   import flash.events.ProgressEvent;
   import flash.net.URLLoaderDataFormat;
   import flash.net.URLRequest;
   import flash.system.ApplicationDomain;
   import flash.system.LoaderContext;
   import flash.system.Security;
   import flash.utils.ByteArray;
   import flash.utils.Dictionary;
   import flash.utils.getDefinitionByName;
   import flash.utils.getTimer;
   
   public class DCResourceManager extends EventDispatcher
   {
      
      private static var mInstance:DCResourceManager;
      
      private static var mAllowInstantiation:Boolean;
      
      public static const EVENT_COMPLETE_SINGLE_FILE:String = "_Complete";
      
      public static const USE_CONTEXT:Boolean = true;
       
      
      private var mList:Object;
      
      private var mType:Object;
      
      private var mLoaded:Object;
      
      private var mAffectsLoadingScreen:Object;
      
      private var mResolver:Dictionary;
      
      private var mUnloader:Object;
      
      private var mTotalSize:int;
      
      private var mFileCountToLoad:int;
      
      private var mTotalFileCountToLoad:int;
      
      private var mLoadedPolicyFiles:Array;

      private var mSwfLookupCount:int = 0;

      private var mSwfLookupMissCount:int = 0;

      private var mSwfAliasRiskCount:int = 0;

      private var mSwfAliasRiskLogged:Object = new Object();

      private var mSwfClassResolveLogged:Object = new Object();

      private var mSwfLoadRequestLogged:Object = new Object();

      private var mAssetLoadRequestLogged:Object = new Object();

      private var mAssetLoadCompleteLogged:Object = new Object();

      private var mSwfClassResourceDomainCount:int = 0;

      private var mSwfClassFallbackCount:int = 0;

      private var mSwfClassHitCount:int = 0;

      private var mLastSwfStatsAt:int = 0;
      
      public function DCResourceManager()
      {
         this.mList = new Object();
         this.mType = new Object();
         this.mLoaded = new Object();
         this.mAffectsLoadingScreen = new Object();
         this.mResolver = new Dictionary(true);
         this.mUnloader = new Object();
         this.mLoadedPolicyFiles = new Array();
         super();
         if(!mAllowInstantiation)
         {
            throw new Error("ERROR: DCResourceManager Error: Instantiation failed: Use DCResourceManager.getInstance() instead of new.");
         }
      }
      
      public static function getInstance() : DCResourceManager
      {
         if(mInstance == null)
         {
            mAllowInstantiation = true;
            mInstance = new DCResourceManager();
            mAllowInstantiation = false;
         }
         return mInstance;
      }
      
      public function unsetResources() : void
      {
         try
         {
            this.unloadAll();
         }
         catch(error:Error)
         {
         }
         this.mTotalSize = 0;
         this.mFileCountToLoad = 0;
         this.mTotalFileCountToLoad = 0;
         this.mList = null;
         this.mType = null;
         this.mLoaded = null;
         this.mAffectsLoadingScreen = null;
         this.mResolver = null;
         this.mUnloader = null;
         this.mList = new Object();
         this.mType = new Object();
         this.mLoaded = new Object();
         this.mAffectsLoadingScreen = new Object();
         this.mResolver = new Dictionary(true);
         this.mUnloader = new Object();
      }
      
      public function load(param1:String, param2:String = "", param3:String = null, param4:Boolean = true, param5:Boolean = false) : Boolean
      {
         var _loc6_:int = param1.lastIndexOf(".");
         var _loc7_:String = param1.slice(_loc6_ + 1);
         if(this.mLoaded[param2])
         {
            return false;
         }
         if(_loc7_ == "swf")
         {
            if(!this.mSwfLoadRequestLogged[param2])
            {
               this.mSwfLoadRequestLogged[param2] = true;
               Utils.DiagEvent("SWF_LOAD_REQUEST","resource=" + param2 + ";url=" + param1 + ";mode=embedded_symbols");
            }
            if(Config.DEBUG_MODE)
            {
            }
            this.loadTextFile("../config/dummy.json",param2);
            return false;
         }
         if(this.mType[param2] == null)
         {
            if(_loc7_ != "swf" && !this.mAssetLoadRequestLogged[param2])
            {
               this.mAssetLoadRequestLogged[param2] = true;
               Utils.DiagEvent("ASSET_LOAD_REQUEST","resource=" + param2 + ";url=" + param1 + ";type=" + (param3 ? param3 : _loc7_));
            }
            this.loadFromFile(param1,param2,param3,param4,param5);
            if(param4)
            {
               ++this.mTotalFileCountToLoad;
               ++this.mFileCountToLoad;
            }
         }
         return true;
      }
      
      private function loadTextFile(param1:String, param2:String, param3:String = null) : void
      {
         var _loc4_:URLRequest = new URLRequest(param1);
         var _loc5_:URLLoaderWithName;
         (_loc5_ = new URLLoaderWithName()).dataFormat = URLLoaderDataFormat.TEXT;
         _loc5_.load(_loc4_);
         this.mResolver[_loc5_.name] = new ResourceLoaderObject(param2,_loc4_,null);
         this.mList[param2] = _loc5_;
         this.mUnloader[param2] = _loc5_;
         _loc5_.addEventListener(Event.COMPLETE,this.completeTextLoad,false,0,true);
         _loc5_.addEventListener(ProgressEvent.PROGRESS,this.progressLoad,false,0,true);
         _loc5_.addEventListener(IOErrorEvent.IO_ERROR,this.errorTextLoad,false,0,true);
      }
      
      private function loadBinFile(param1:String, param2:String, param3:String = null) : void
      {
         var _loc4_:URLRequest = new URLRequest(param1);
         var _loc5_:URLLoaderWithName;
         (_loc5_ = new URLLoaderWithName()).dataFormat = URLLoaderDataFormat.BINARY;
         _loc5_.load(_loc4_);
         this.mResolver[_loc5_.name] = new ResourceLoaderObject(param2,_loc4_,null);
         this.mList[param2] = _loc5_;
         this.mUnloader[param2] = _loc5_;
         _loc5_.addEventListener(Event.COMPLETE,this.completeTextLoad,false,0,true);
         _loc5_.addEventListener(ProgressEvent.PROGRESS,this.progressLoad,false,0,true);
         _loc5_.addEventListener(IOErrorEvent.IO_ERROR,this.errorTextLoad,false,0,true);
      }
      
      private function loadFromFile(param1:String, param2:String, param3:String = null, param4:Boolean = true, param5:Boolean = false) : void
      {
         var _loc9_:int = 0;
         if(param3 == null || param3 == "")
         {
            if((_loc9_ = param1.lastIndexOf(".")) != -1)
            {
               param3 = param1.substring(_loc9_);
            }
         }
         this.mLoaded[param2] = false;
         this.mType[param2] = param3;
         this.mAffectsLoadingScreen[param2] = param4;
         switch(param3)
         {
            case ".csv":
            case ".txt":
            case ".json":
               this.loadTextFile(param1,param2,param3);
               return;
            default:
               if(param3 == ".bin")
               {
                  this.loadBinFile(param1,param2,param3);
                  return;
               }
               var _loc6_:URLRequest = new URLRequest(param1);
               var _loc7_:Loader = new Loader();
               this.mList[param2] = _loc7_;
               this.mUnloader[param2] = _loc7_;
               _loc7_.contentLoaderInfo.addEventListener(Event.COMPLETE,this.completeLoad,false,0,true);
               _loc7_.contentLoaderInfo.addEventListener(ProgressEvent.PROGRESS,this.progressLoad,false,0,true);
               _loc7_.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR,this.errorLoad,false,0,true);
               var _loc8_:LoaderContext = null;
               if(param3 == ".swf")
               {
                  if(param5)
                  {
                     _loc8_ = new LoaderContext(true,ApplicationDomain.currentDomain);
                  }
                  _loc7_.load(_loc6_,_loc8_);
               }
               else
               {
                  if(USE_CONTEXT)
                  {
                     _loc8_ = new LoaderContext(true,ApplicationDomain.currentDomain);
                  }
                  _loc7_.load(_loc6_,_loc8_);
               }
               this.mResolver[_loc7_.contentLoaderInfo] = new ResourceLoaderObject(param2,_loc6_,_loc8_);
               return;
         }
      }
      
      public function getLoadedSWFAppDomain(param1:String) : ApplicationDomain
      {
         var _loc2_:Object = this.mUnloader[param1];
         if(!(_loc2_ is Loader))
         {
            return null;
         }
         return (_loc2_ as Loader).contentLoaderInfo.applicationDomain;
      }
      
      private function emitSwfResourceStats(param1:Boolean = false) : void
      {
         var now:int = getTimer();
         if(!param1 && now - this.mLastSwfStatsAt < 5000)
         {
            return;
         }
         this.mLastSwfStatsAt = now;
         Utils.DiagEvent("SWF_RESOURCE_STATS","lookups=" + this.mSwfLookupCount + ";hits=" + this.mSwfClassHitCount + ";resource_domain=" + this.mSwfClassResourceDomainCount + ";global_fallback=" + this.mSwfClassFallbackCount + ";misses=" + this.mSwfLookupMissCount + ";alias_risk=" + this.mSwfAliasRiskCount + ";pending=" + this.mFileCountToLoad + ";total_requests=" + this.mTotalFileCountToLoad);
      }

      public function getSWFClass(param1:String, param2:String = null) : Class
      {
         var _loc4_:int = 0;
         var _loc3_:String = null;
         var aliasKey:String = null;
         var resolved:Class = null;
         var resourceDomain:ApplicationDomain = null;
         var domainMode:String = "global_fallback";
         var resolveKey:String = null;
         var resolvedName:String = null;
         var startedAt:int = getTimer();
         if(!param2)
         {
            if(!param1)
            {
               return null;
            }
            _loc4_ = param1.lastIndexOf("/");
            _loc3_ = param1.slice(_loc4_ + 1);
            param1 = param1.slice(0,_loc4_);
         }
         else
         {
            _loc3_ = param2;
         }
         this.mSwfLookupCount++;
         if(param1 != null && param1.indexOf("swf/units_opfor") == 0 && _loc3_ != null && _loc3_.indexOf("pvp_") != 0 && _loc3_.indexOf("_airdrop") < 0)
         {
            this.mSwfAliasRiskCount++;
            aliasKey = param1 + "|" + _loc3_;
            if(!this.mSwfAliasRiskLogged[aliasKey])
            {
               this.mSwfAliasRiskLogged[aliasKey] = true;
               Utils.DiagEvent("SWF_ALIAS_RISK","resource=" + param1 + ";symbol=" + _loc3_ + ";lookup=" + this.mSwfLookupCount);
            }
         }
         resourceDomain = this.getLoadedSWFAppDomain(param1);
         if(resourceDomain != null)
         {
            try
            {
               if(resourceDomain.hasDefinition(_loc3_))
               {
                  resolved = resourceDomain.getDefinition(_loc3_) as Class;
                  domainMode = "resource";
                  this.mSwfClassResourceDomainCount++;
               }
               else
               {
                  Utils.DiagEvent("SWF_RESOURCE_SYMBOL_MISS","resource=" + param1 + ";symbol=" + _loc3_);
               }
            }
            catch(domainError:Error)
            {
               Utils.DiagEvent("SWF_RESOURCE_DOMAIN_ERROR","resource=" + param1 + ";symbol=" + _loc3_ + ";error=" + domainError.errorID);
            }
         }
         if(resolved == null)
         {
            try
            {
               resolved = getDefinitionByName(_loc3_) as Class;
               this.mSwfClassFallbackCount++;
            }
            catch(error:Error)
            {
               this.mSwfLookupMissCount++;
               Utils.DiagEvent("SWF_CLASS_MISS","resource=" + param1 + ";symbol=" + _loc3_ + ";domain=" + domainMode + ";elapsed_ms=" + (getTimer() - startedAt) + ";lookups=" + this.mSwfLookupCount + ";misses=" + this.mSwfLookupMissCount + ";error=" + error.errorID);
               this.emitSwfResourceStats(true);
               throw error;
            }
         }
         if(resolved != null)
         {
            this.mSwfClassHitCount++;
            resolvedName = String(resolved);
            resolveKey = param1 + "|" + _loc3_ + "|" + domainMode;
            if(!this.mSwfClassResolveLogged[resolveKey])
            {
               this.mSwfClassResolveLogged[resolveKey] = true;
               Utils.DiagEvent("SWF_CLASS_RESOLVED","resource=" + param1 + ";symbol=" + _loc3_ + ";resolved_class=" + resolvedName + ";domain=" + domainMode + ";elapsed_ms=" + (getTimer() - startedAt));
               if(resolvedName.indexOf(_loc3_) < 0)
               {
                  Utils.DiagEvent("SWF_CLASS_IDENTITY_MISMATCH","resource=" + param1 + ";symbol=" + _loc3_ + ";resolved_class=" + resolvedName + ";domain=" + domainMode);
               }
            }
         }
         this.emitSwfResourceStats(false);
         return resolved;
      }
      
      public function get(param1:String) : *
      {
         var _loc2_:BitmapData = null;
         var _loc3_:Sprite = null;
         if(this.mList[param1] == null)
         {
            if(Config.DEBUG_MODE)
            {
            }
            return null;
         }
         if(!this.mLoaded[param1])
         {
            if(Config.DEBUG_MODE)
            {
            }
            return null;
         }
         switch(this.mType[param1])
         {
            case ".bin":
               return this.mList[param1] as ByteArray;
            case ".swf":
               return this.mList[param1] as MovieClip;
            case ".jpg":
            case "jpeg":
            case ".gif":
            case ".png":
            case "BitmapData":
               return Bitmap(this.mList[param1]).bitmapData;
            case "MovieClip":
               return this.mList[param1] as MovieClip;
            case "Sprite":
               _loc2_ = Bitmap(this.mList[param1]).bitmapData;
               _loc3_ = new Sprite();
               _loc3_.addChild(new Bitmap(_loc2_));
               return _loc3_;
            case "Bitmap":
               _loc2_ = Bitmap(this.mList[param1]).bitmapData;
               return new Bitmap(_loc2_);
            case ".xml":
               return new XML(this.mList[param1]);
            case ".txt":
            case ".csv":
            case ".json":
               return this.mList[param1] as String;
            default:
               return null;
         }
      }
      
      public function unload(param1:String) : void
      {
         if(param1 == "")
         {
            throw new Error("ERROR: DCResourceManager: must specify a resource to unload");
         }
         if(!this.mLoaded[param1])
         {
            throw new Error("ERROR: DCResourceManager resource " + param1 + " not mLoaded.");
         }
         switch(this.mType[param1])
         {
            case ".swf":
               break;
            case "Bitmap":
            case "BitmapData":
            case ".jpg":
            case "jpeg":
            case ".gif":
            case ".png":
               Bitmap(this.mList[param1]).bitmapData.dispose();
               break;
            case "MovieClip":
            case "Sprite":
         }
         if(this.mUnloader[param1] is Loader)
         {
            if(this.mUnloader[param1].numChildren > 0)
            {
               this.mUnloader[param1].unload();
            }
         }
         this.mLoaded[param1] = false;
         delete this.mUnloader[param1];
         delete this.mResolver[param1];
         delete this.mList[param1];
         delete this.mLoaded[param1];
         delete this.mType[param1];
      }
      
      public function unloadAll() : void
      {
         var _loc1_:String = null;
         for(_loc1_ in this.mList)
         {
            this.unload(_loc1_);
         }
      }
      
      private function progressLoad(param1:ProgressEvent) : void
      {
         var _loc2_:String = null;
         if(param1.target is Loader)
         {
            _loc2_ = String(this.mResolver[param1.target].mResourceName);
            if(Config.DEBUG_MODE)
            {
            }
         }
         this.updateProgess();
      }
      
      private function updateProgess() : void
      {
         var _loc1_:String = null;
         this.mTotalSize = 0;
         for(_loc1_ in this.mList)
         {
            if(this.mUnloader[_loc1_] is Loader)
            {
               this.mTotalSize += Loader(this.mUnloader[_loc1_]).contentLoaderInfo.bytesTotal;
            }
            else
            {
               this.mTotalSize += URLLoaderWithName(this.mUnloader[_loc1_]).bytesTotal;
            }
         }
      }
      
      private function completeLoad(param1:Event) : void
      {
         var _loc2_:String = String(this.mResolver[param1.target].mResourceName);
         if(Config.DEBUG_MODE)
         {
         }
         var _loc3_:Loader = param1.target.loader;
         param1.target.removeEventListener(Event.COMPLETE,this.completeLoad);
         param1.target.removeEventListener(ProgressEvent.PROGRESS,this.progressLoad);
         param1.target.removeEventListener(IOErrorEvent.IO_ERROR,this.errorLoad);
         if(!param1.target.childAllowsParent)
         {
            this.mResolver[param1.target].mLoaderInfo = param1.target;
            this.loadSecurityPolicyFile(this.mResolver[param1.target]);
            return;
         }
         this.finalizeLoading(param1.target as LoaderInfo);
      }
      
      private function finalizeLoading(param1:LoaderInfo) : void
      {
         var _loc2_:String = String(this.mResolver[param1].mResourceName);
         this.mList[_loc2_] = param1.content;
         this.mLoaded[_loc2_] = true;
         if(!this.mAssetLoadCompleteLogged[_loc2_])
         {
            this.mAssetLoadCompleteLogged[_loc2_] = true;
            Utils.DiagEvent("ASSET_LOAD_COMPLETE","resource=" + _loc2_ + ";type=" + this.mType[_loc2_] + ";bytes=" + param1.bytesLoaded + ";width=" + (param1.content ? param1.content.width : 0) + ";height=" + (param1.content ? param1.content.height : 0));
         }
         delete this.mResolver[param1];
         this.mUnloader[_loc2_] = param1.loader;
         dispatchEvent(new Event(_loc2_ + "_Complete"));
         if(this.mAffectsLoadingScreen[_loc2_])
         {
            --this.mFileCountToLoad;
            if(this.mFileCountToLoad == 0)
            {
               dispatchEvent(new Event("LoadOver"));
            }
         }
      }
      
      private function loadSecurityPolicyFile(param1:ResourceLoaderObject) : void
      {
         var _loc2_:String = param1.mLoaderInfo.url;
         var _loc3_:Array = _loc2_.split("/");
         _loc2_ = _loc3_[0] + "//" + _loc3_[2];
         if(this.mLoadedPolicyFiles.indexOf(_loc2_) < 0)
         {
            this.mLoadedPolicyFiles.push(_loc2_);
            Security.loadPolicyFile(_loc2_ + "/crossdomain.xml");
         }
         param1.startPolling(this.finalizeLoading);
      }
      
      private function completeTextLoad(param1:Event) : void
      {
         var _loc2_:URLLoaderWithName = URLLoaderWithName(param1.target);
         var _loc3_:String = String(this.mResolver[_loc2_.name].mResourceName);
         if(Config.DEBUG_MODE)
         {
         }
         _loc2_.removeEventListener(Event.COMPLETE,this.completeTextLoad);
         _loc2_.removeEventListener(ProgressEvent.PROGRESS,this.progressLoad);
         _loc2_.removeEventListener(IOErrorEvent.IO_ERROR,this.errorTextLoad);
         this.mList[_loc3_] = _loc2_.data;
         this.mLoaded[_loc3_] = true;
         if(_loc3_.indexOf("swf/") == 0)
         {
            Utils.DiagEvent("SWF_LOAD_COMPLETE","resource=" + _loc3_ + ";mode=embedded_symbols;bytes=" + _loc2_.bytesLoaded);
         }
         delete this.mResolver[_loc2_.name];
         this.mUnloader[_loc3_] = _loc2_;
         dispatchEvent(new Event(_loc3_ + EVENT_COMPLETE_SINGLE_FILE));
         if(this.mAffectsLoadingScreen[_loc3_])
         {
            --this.mFileCountToLoad;
            if(this.mFileCountToLoad == 0)
            {
               dispatchEvent(new Event("LoadOver"));
            }
         }
      }
      
      private function errorLoad(param1:IOErrorEvent) : void
      {
         if(Config.DEBUG_MODE)
         {
         }
         var _loc2_:ResourceLoaderObject = this.mResolver[param1.target];
         var _loc3_:Loader = param1.target.loader;
         if(_loc2_.mRetryCount > 1)
         {
            Utils.DiagEvent("ASSET_LOAD_ERROR","resource=" + _loc2_.mResourceName + ";url=" + _loc2_.mURL.url + ";retry=" + _loc2_.mRetryCount + ";terminal=true;text=" + param1.text);
            --this.mFileCountToLoad;
         }
         else
         {
            Utils.DiagEvent("ASSET_LOAD_ERROR","resource=" + _loc2_.mResourceName + ";url=" + _loc2_.mURL.url + ";retry=" + _loc2_.mRetryCount + ";terminal=false;text=" + param1.text);
            _loc3_.load(_loc2_.mURL,_loc2_.mLoaderContext);
            ++_loc2_.mRetryCount;
         }
      }
      
      private function errorTextLoad(param1:IOErrorEvent) : void
      {
         if(Config.DEBUG_MODE)
         {
         }
         var _loc2_:URLLoaderWithName = URLLoaderWithName(param1.target);
         var _loc3_:ResourceLoaderObject = this.mResolver[_loc2_.name];
         if(_loc3_.mRetryCount > 1)
         {
            --this.mFileCountToLoad;
         }
         else
         {
            _loc2_.load(_loc3_.mURL);
            ++_loc3_.mRetryCount;
         }
      }
      
      public function isAddedToLoadingList(param1:String) : Boolean
      {
         return this.mList[param1] != null;
      }
      
      public function getFileCountToLoad() : int
      {
         return this.mFileCountToLoad;
      }
      
      public function isLoaded(param1:String) : Boolean
      {
         if(this.mLoaded[param1] != null)
         {
            return this.mLoaded[param1];
         }
         return false;
      }
      
      public function getLoadingPercent() : int
      {
         if(Config.DEBUG_MODE)
         {
         }
         return (this.mTotalFileCountToLoad - this.mFileCountToLoad) * 100 / this.mTotalFileCountToLoad;
      }
   }
}
