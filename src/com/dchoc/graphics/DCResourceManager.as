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
      private var mSwfClassCacheHitCount:int = 0;
      private var mLastSwfStatsAt:int = 0;

      // Child-SWF symbols are embedded in the root mobile SWF. Preserve the original
      // logical resource identity in the cache key so reflection is deterministic and
      // repeated animation materialization does not repeatedly traverse AVM2 metadata.
      private var mSwfClassCache:Object = new Object();
      private var mSwfGlobalSymbolOwner:Object = new Object();
      private var mSwfGlobalSymbolCollisionLogged:Object = new Object();

      public function DCResourceManager()
      {
         this.mList = new Object();
         this.mType = new Object();
         this.mLoaded = new Object();
         this.mAffectsLoadingScreen = new Object();
         this.mResolver = new Dictionary(true);
         this.mUnloader = new Object();
         this.mLoadedPolicyFiles = new Array();
         this.mSwfClassCache = new Object();
         this.mSwfGlobalSymbolOwner = new Object();
         this.mSwfGlobalSymbolCollisionLogged = new Object();
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
         this.mSwfClassCache = new Object();
         this.mSwfGlobalSymbolOwner = new Object();
         this.mSwfGlobalSymbolCollisionLogged = new Object();
      }

      public function load(param1:String, param2:String = "", param3:String = null, param4:Boolean = true, param5:Boolean = false) : Boolean
      {
         var extensionIndex:int = param1.lastIndexOf(".");
         var extension:String = param1.slice(extensionIndex + 1);
         if(this.mLoaded[param2])
         {
            return false;
         }
         if(extension == "swf")
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
            if(extension != "swf" && !this.mAssetLoadRequestLogged[param2])
            {
               this.mAssetLoadRequestLogged[param2] = true;
               Utils.DiagEvent("ASSET_LOAD_REQUEST","resource=" + param2 + ";url=" + param1 + ";type=" + (param3 ? param3 : extension));
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
         var request:URLRequest = new URLRequest(param1);
         var loader:URLLoaderWithName = new URLLoaderWithName();
         loader.dataFormat = URLLoaderDataFormat.TEXT;
         loader.load(request);
         this.mResolver[loader.name] = new ResourceLoaderObject(param2,request,null);
         this.mList[param2] = loader;
         this.mUnloader[param2] = loader;
         loader.addEventListener(Event.COMPLETE,this.completeTextLoad,false,0,true);
         loader.addEventListener(ProgressEvent.PROGRESS,this.progressLoad,false,0,true);
         loader.addEventListener(IOErrorEvent.IO_ERROR,this.errorTextLoad,false,0,true);
      }

      private function loadBinFile(param1:String, param2:String, param3:String = null) : void
      {
         var request:URLRequest = new URLRequest(param1);
         var loader:URLLoaderWithName = new URLLoaderWithName();
         loader.dataFormat = URLLoaderDataFormat.BINARY;
         loader.load(request);
         this.mResolver[loader.name] = new ResourceLoaderObject(param2,request,null);
         this.mList[param2] = loader;
         this.mUnloader[param2] = loader;
         loader.addEventListener(Event.COMPLETE,this.completeTextLoad,false,0,true);
         loader.addEventListener(ProgressEvent.PROGRESS,this.progressLoad,false,0,true);
         loader.addEventListener(IOErrorEvent.IO_ERROR,this.errorTextLoad,false,0,true);
      }

      private function loadFromFile(param1:String, param2:String, param3:String = null, param4:Boolean = true, param5:Boolean = false) : void
      {
         var extensionIndex:int = 0;
         if(param3 == null || param3 == "")
         {
            extensionIndex = param1.lastIndexOf(".");
            if(extensionIndex != -1)
            {
               param3 = param1.substring(extensionIndex);
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
               var request:URLRequest = new URLRequest(param1);
               var loader:Loader = new Loader();
               this.mList[param2] = loader;
               this.mUnloader[param2] = loader;
               loader.contentLoaderInfo.addEventListener(Event.COMPLETE,this.completeLoad,false,0,true);
               loader.contentLoaderInfo.addEventListener(ProgressEvent.PROGRESS,this.progressLoad,false,0,true);
               loader.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR,this.errorLoad,false,0,true);
               var context:LoaderContext = null;
               if(param3 == ".swf")
               {
                  if(param5)
                  {
                     context = new LoaderContext(true,ApplicationDomain.currentDomain);
                  }
                  loader.load(request,context);
               }
               else
               {
                  if(USE_CONTEXT)
                  {
                     context = new LoaderContext(true,ApplicationDomain.currentDomain);
                  }
                  loader.load(request,context);
               }
               this.mResolver[loader.contentLoaderInfo] = new ResourceLoaderObject(param2,request,context);
               return;
         }
      }

      public function getLoadedSWFAppDomain(param1:String) : ApplicationDomain
      {
         var unloader:Object = this.mUnloader[param1];
         if(!(unloader is Loader))
         {
            return null;
         }
         return (unloader as Loader).contentLoaderInfo.applicationDomain;
      }

      private function emitSwfResourceStats(param1:Boolean = false) : void
      {
         var now:int = getTimer();
         if(!param1 && now - this.mLastSwfStatsAt < 5000)
         {
            return;
         }
         this.mLastSwfStatsAt = now;
         Utils.DiagEvent("SWF_RESOURCE_STATS","lookups=" + this.mSwfLookupCount + ";hits=" + this.mSwfClassHitCount + ";cache_hits=" + this.mSwfClassCacheHitCount + ";resource_domain=" + this.mSwfClassResourceDomainCount + ";global_fallback=" + this.mSwfClassFallbackCount + ";misses=" + this.mSwfLookupMissCount + ";alias_risk=" + this.mSwfAliasRiskCount + ";pending=" + this.mFileCountToLoad + ";total_requests=" + this.mTotalFileCountToLoad);
      }

      private function recordGlobalSymbolOwner(param1:String, param2:String) : void
      {
         var owner:String = this.mSwfGlobalSymbolOwner[param2] as String;
         if(owner == null || owner.length == 0)
         {
            this.mSwfGlobalSymbolOwner[param2] = param1 == null ? "" : param1;
            return;
         }
         if(owner == param1)
         {
            return;
         }
         var collisionKey:String = owner + "|" + param1 + "|" + param2;
         if(!this.mSwfGlobalSymbolCollisionLogged[collisionKey])
         {
            this.mSwfGlobalSymbolCollisionLogged[collisionKey] = true;
            Utils.DiagEvent("SWF_EMBEDDED_SYMBOL_COLLISION","symbol=" + param2 + ";first_resource=" + owner + ";next_resource=" + param1 + ";resolution=global_same_class");
         }
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
         var cacheKey:String = (param1 == null ? "" : param1) + "|" + _loc3_;
         var cached:Class = this.mSwfClassCache[cacheKey] as Class;
         if(cached != null)
         {
            this.mSwfClassCacheHitCount++;
            this.mSwfClassHitCount++;
            this.emitSwfResourceStats(false);
            return cached;
         }

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
                  if(param1 != null && param1.indexOf("swf/units_opfor") == 0)
                  {
                     this.mSwfLookupMissCount++;
                     Utils.DiagEvent("SWF_OPFOR_STRICT_MISS","resource=" + param1 + ";symbol=" + _loc3_ + ";reason=resource_symbol_missing;global_fallback=blocked");
                     this.emitSwfResourceStats(true);
                     return null;
                  }
               }
            }
            catch(domainError:Error)
            {
               Utils.DiagEvent("SWF_RESOURCE_DOMAIN_ERROR","resource=" + param1 + ";symbol=" + _loc3_ + ";error=" + domainError.errorID);
               if(param1 != null && param1.indexOf("swf/units_opfor") == 0)
               {
                  this.mSwfLookupMissCount++;
                  Utils.DiagEvent("SWF_OPFOR_STRICT_MISS","resource=" + param1 + ";symbol=" + _loc3_ + ";reason=resource_domain_error;error=" + domainError.errorID + ";global_fallback=blocked");
                  this.emitSwfResourceStats(true);
                  return null;
               }
            }
         }

         if(resolved == null)
         {
            try
            {
               resolved = getDefinitionByName(_loc3_) as Class;
               this.mSwfClassFallbackCount++;
               this.recordGlobalSymbolOwner(param1,_loc3_);
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
            this.mSwfClassCache[cacheKey] = resolved;
            resolvedName = String(resolved);
            resolveKey = param1 + "|" + _loc3_ + "|" + domainMode;
            if(!this.mSwfClassResolveLogged[resolveKey])
            {
               this.mSwfClassResolveLogged[resolveKey] = true;
               Utils.DiagEvent("SWF_CLASS_RESOLVED","resource=" + param1 + ";symbol=" + _loc3_ + ";resolved_class=" + resolvedName + ";domain=" + domainMode + ";cache_key=" + cacheKey + ";elapsed_ms=" + (getTimer() - startedAt));
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
         var bitmapData:BitmapData = null;
         var sprite:Sprite = null;
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
               bitmapData = Bitmap(this.mList[param1]).bitmapData;
               sprite = new Sprite();
               sprite.addChild(new Bitmap(bitmapData));
               return sprite;
            case "Bitmap":
               bitmapData = Bitmap(this.mList[param1]).bitmapData;
               return new Bitmap(bitmapData);
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
         var key:String = null;
         for(key in this.mList)
         {
            this.unload(key);
         }
      }

      private function progressLoad(param1:ProgressEvent) : void
      {
         var resource:String = null;
         if(param1.target is Loader)
         {
            resource = String(this.mResolver[param1.target].mResourceName);
            if(Config.DEBUG_MODE)
            {
            }
         }
         this.updateProgess();
      }

      private function updateProgess() : void
      {
         var key:String = null;
         this.mTotalSize = 0;
         for(key in this.mList)
         {
            if(this.mUnloader[key] is Loader)
            {
               this.mTotalSize += Loader(this.mUnloader[key]).contentLoaderInfo.bytesTotal;
            }
            else
            {
               this.mTotalSize += URLLoaderWithName(this.mUnloader[key]).bytesTotal;
            }
         }
      }

      private function completeLoad(param1:Event) : void
      {
         var resource:String = String(this.mResolver[param1.target].mResourceName);
         if(Config.DEBUG_MODE)
         {
         }
         var loader:Loader = param1.target.loader;
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
         var resource:String = String(this.mResolver[param1].mResourceName);
         this.mList[resource] = param1.content;
         this.mLoaded[resource] = true;
         if(!this.mAssetLoadCompleteLogged[resource])
         {
            this.mAssetLoadCompleteLogged[resource] = true;
            Utils.DiagEvent("ASSET_LOAD_COMPLETE","resource=" + resource + ";type=" + this.mType[resource] + ";bytes=" + param1.bytesLoaded + ";width=" + (param1.content ? param1.content.width : 0) + ";height=" + (param1.content ? param1.content.height : 0));
         }
         delete this.mResolver[param1];
         this.mUnloader[resource] = param1.loader;
         dispatchEvent(new Event(resource + "_Complete"));
         if(this.mAffectsLoadingScreen[resource])
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
         var url:String = param1.mLoaderInfo.url;
         var parts:Array = url.split("/");
         url = parts[0] + "//" + parts[2];
         if(this.mLoadedPolicyFiles.indexOf(url) < 0)
         {
            this.mLoadedPolicyFiles.push(url);
            Security.loadPolicyFile(url + "/crossdomain.xml");
         }
         param1.startPolling(this.finalizeLoading);
      }

      private function completeTextLoad(param1:Event) : void
      {
         var loader:URLLoaderWithName = URLLoaderWithName(param1.target);
         var resource:String = String(this.mResolver[loader.name].mResourceName);
         if(Config.DEBUG_MODE)
         {
         }
         loader.removeEventListener(Event.COMPLETE,this.completeTextLoad);
         loader.removeEventListener(ProgressEvent.PROGRESS,this.progressLoad);
         loader.removeEventListener(IOErrorEvent.IO_ERROR,this.errorTextLoad);
         this.mList[resource] = loader.data;
         this.mLoaded[resource] = true;
         if(resource.indexOf("swf/") == 0)
         {
            Utils.DiagEvent("SWF_LOAD_COMPLETE","resource=" + resource + ";mode=embedded_symbols;bytes=" + loader.bytesLoaded);
         }
         delete this.mResolver[loader.name];
         this.mUnloader[resource] = loader;
         dispatchEvent(new Event(resource + EVENT_COMPLETE_SINGLE_FILE));
         if(this.mAffectsLoadingScreen[resource])
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
         var resourceObject:ResourceLoaderObject = this.mResolver[param1.target];
         var loader:Loader = param1.target.loader;
         if(resourceObject.mRetryCount > 1)
         {
            Utils.DiagEvent("ASSET_LOAD_ERROR","resource=" + resourceObject.mResourceName + ";url=" + resourceObject.mURL.url + ";retry=" + resourceObject.mRetryCount + ";terminal=true;text=" + param1.text);
            --this.mFileCountToLoad;
         }
         else
         {
            Utils.DiagEvent("ASSET_LOAD_ERROR","resource=" + resourceObject.mResourceName + ";url=" + resourceObject.mURL.url + ";retry=" + resourceObject.mRetryCount + ";terminal=false;text=" + param1.text);
            loader.load(resourceObject.mURL,resourceObject.mLoaderContext);
            ++resourceObject.mRetryCount;
         }
      }

      private function errorTextLoad(param1:IOErrorEvent) : void
      {
         if(Config.DEBUG_MODE)
         {
         }
         var loader:URLLoaderWithName = URLLoaderWithName(param1.target);
         var resourceObject:ResourceLoaderObject = this.mResolver[loader.name];
         if(resourceObject.mRetryCount > 1)
         {
            --this.mFileCountToLoad;
         }
         else
         {
            loader.load(resourceObject.mURL);
            ++resourceObject.mRetryCount;
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
