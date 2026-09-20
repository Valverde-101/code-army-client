param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ExpectedSha,
  [Parameter(Mandatory=$true)][string]$GitPath,
  [ValidateSet('Apply','Restore')][string]$Mode='Apply'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
if(-not(Test-Path -LiteralPath $GitPath -PathType Leaf)){throw "ANDROID_BOOT_RESOURCE_OVERLAY=FAIL git_missing=$GitPath"}
$actual=(& $GitPath -C $RepoRoot rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $actual -ne $ExpectedSha){throw "ANDROID_BOOT_RESOURCE_OVERLAY=FAIL exact_head expected=$ExpectedSha actual=$actual"}

$relative='src\com\dchoc\graphics\DCResourceManager.as'
$target=Join-Path $RepoRoot $relative
$backupRoot=Join-Path $RepoRoot ('.work\scratch\android-boot-resource-overlay\'+$ExpectedSha)
$backupPath=Join-Path $backupRoot 'DCResourceManager.as.original'
$manifestPath=Join-Path $backupRoot 'manifest.json'

function Get-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Normalize-Lf([string]$Text){$Text.Replace("`r`n","`n").Replace("`r","`n")}
function Write-Utf8Bom([string]$Path,[string]$Text){[System.IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($true)))}
function Replace-Exact([string]$Text,[string]$Old,[string]$New,[string]$Name){
  $i=$Text.IndexOf($Old,[System.StringComparison]::Ordinal)
  if($i -lt 0){throw "ANDROID_BOOT_RESOURCE_OVERLAY=FAIL patch=$Name reason=pattern_missing"}
  if($Text.IndexOf($Old,$i+$Old.Length,[System.StringComparison]::Ordinal) -ge 0){throw "ANDROID_BOOT_RESOURCE_OVERLAY=FAIL patch=$Name reason=pattern_ambiguous"}
  $Text.Substring(0,$i)+$New+$Text.Substring($i+$Old.Length)
}
function Replace-Before([string]$Text,[string]$Start,[string]$Next,[string]$New,[string]$Name){
  $s=$Text.IndexOf($Start,[System.StringComparison]::Ordinal)
  if($s -lt 0){throw "ANDROID_BOOT_RESOURCE_OVERLAY=FAIL patch=$Name reason=start_missing"}
  if($Text.IndexOf($Start,$s+$Start.Length,[System.StringComparison]::Ordinal) -ge 0){throw "ANDROID_BOOT_RESOURCE_OVERLAY=FAIL patch=$Name reason=start_ambiguous"}
  $e=$Text.IndexOf($Next,$s+$Start.Length,[System.StringComparison]::Ordinal)
  if($e -lt 0){throw "ANDROID_BOOT_RESOURCE_OVERLAY=FAIL patch=$Name reason=end_missing"}
  $Text.Substring(0,$s)+$New+$Text.Substring($e)
}

if($Mode -eq 'Restore'){
  if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){
    Write-Host "ANDROID_BOOT_RESOURCE_OVERLAY=PASS mode=restore status=no_overlay sha=$ExpectedSha"
    return
  }
  $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$manifest.source_sha -ne $ExpectedSha){throw "ANDROID_BOOT_RESOURCE_OVERLAY=FAIL restore_manifest_sha expected=$ExpectedSha actual=$($manifest.source_sha)"}
  if(-not(Test-Path -LiteralPath $backupPath -PathType Leaf)){throw "ANDROID_BOOT_RESOURCE_OVERLAY=FAIL restore_backup_missing=$backupPath"}
  Copy-Item -LiteralPath $backupPath -Destination $target -Force
  $restored=Get-Sha256 $target
  if($restored -ne [string]$manifest.baseline_sha256){throw "ANDROID_BOOT_RESOURCE_OVERLAY=FAIL restore_hash expected=$($manifest.baseline_sha256) actual=$restored"}
  Remove-Item -LiteralPath $backupRoot -Recurse -Force
  Write-Host "ANDROID_BOOT_RESOURCE_OVERLAY=PASS mode=restore baseline_restored=true composable=true sha=$ExpectedSha"
  return
}

if(-not(Test-Path -LiteralPath $target -PathType Leaf)){throw "ANDROID_BOOT_RESOURCE_OVERLAY=FAIL source_missing=$relative"}
if(Test-Path -LiteralPath $backupRoot){Remove-Item -LiteralPath $backupRoot -Recurse -Force}
New-Item -ItemType Directory -Force -Path $backupRoot|Out-Null
Copy-Item -LiteralPath $target -Destination $backupPath -Force
$baselineSha=Get-Sha256 $target
[ordered]@{
  schema='armyattack-android-boot-resource-overlay/v1'
  source_sha=$ExpectedSha
  path=$relative
  baseline_sha256=$baselineSha
  purpose='Normalize AIR application-relative asset paths and make the loading gate race/error safe on Android.'
}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $manifestPath -Encoding UTF8

try{
  $text=Normalize-Lf ([IO.File]::ReadAllText($target))

  $loadSignature='      public function load(param1:String, param2:String = "", param3:String = null, param4:Boolean = true, param5:Boolean = false) : Boolean'
  $loadWithNormalizer=@'
      private function normalizeAndroidResourceUrl(param1:String) : String
      {
         var normalized:String = param1;
         while(normalized && normalized.indexOf("../") == 0)
         {
            normalized = normalized.substr(3);
         }
         if(normalized != param1)
         {
            Utils.DiagEvent("ASSET_PATH_NORMALIZED","from=" + param1 + ";to=" + normalized);
         }
         return normalized;
      }

      public function load(param1:String, param2:String = "", param3:String = null, param4:Boolean = true, param5:Boolean = false) : Boolean
'@
  $text=Replace-Exact $text $loadSignature $loadWithNormalizer 'android_relative_path_helper'
  $normalizePublicLoad="         param1 = this.normalizeAndroidResourceUrl(param1);`n         var extensionIndex:int = param1.lastIndexOf(`".`");"
  $text=Replace-Exact $text '         var extensionIndex:int = param1.lastIndexOf(".");' $normalizePublicLoad 'normalize_public_load'

  $textLoad=@'
      private function loadTextFile(param1:String, param2:String, param3:String = null) : void
      {
         param1 = this.normalizeAndroidResourceUrl(param1);
         var request:URLRequest = new URLRequest(param1);
         var loader:URLLoaderWithName = new URLLoaderWithName();
         loader.dataFormat = URLLoaderDataFormat.TEXT;
         this.mResolver[loader.name] = new ResourceLoaderObject(param2,request,null);
         this.mList[param2] = loader;
         this.mUnloader[param2] = loader;
         loader.addEventListener(Event.COMPLETE,this.completeTextLoad,false,0,true);
         loader.addEventListener(ProgressEvent.PROGRESS,this.progressLoad,false,0,true);
         loader.addEventListener(IOErrorEvent.IO_ERROR,this.errorTextLoad,false,0,true);
         loader.load(request);
      }

'@
  $text=Replace-Before $text '      private function loadTextFile(' '      private function loadBinFile(' $textLoad 'text_loader_listeners_before_load'

  $binLoad=@'
      private function loadBinFile(param1:String, param2:String, param3:String = null) : void
      {
         param1 = this.normalizeAndroidResourceUrl(param1);
         var request:URLRequest = new URLRequest(param1);
         var loader:URLLoaderWithName = new URLLoaderWithName();
         loader.dataFormat = URLLoaderDataFormat.BINARY;
         this.mResolver[loader.name] = new ResourceLoaderObject(param2,request,null);
         this.mList[param2] = loader;
         this.mUnloader[param2] = loader;
         loader.addEventListener(Event.COMPLETE,this.completeTextLoad,false,0,true);
         loader.addEventListener(ProgressEvent.PROGRESS,this.progressLoad,false,0,true);
         loader.addEventListener(IOErrorEvent.IO_ERROR,this.errorTextLoad,false,0,true);
         loader.load(request);
      }

'@
  $text=Replace-Before $text '      private function loadBinFile(' '      private function loadFromFile(' $binLoad 'binary_loader_listeners_before_load'

  $loadFromFile=@'
      private function loadFromFile(param1:String, param2:String, param3:String = null, param4:Boolean = true, param5:Boolean = false) : void
      {
         param1 = this.normalizeAndroidResourceUrl(param1);
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
               if(param3 == ".swf" && param5)
               {
                  context = new LoaderContext(true,ApplicationDomain.currentDomain);
               }
               else if(param3 != ".swf" && USE_CONTEXT)
               {
                  context = new LoaderContext(true,ApplicationDomain.currentDomain);
               }
               this.mResolver[loader.contentLoaderInfo] = new ResourceLoaderObject(param2,request,context);
               loader.load(request,context);
               return;
         }
      }

'@
  $text=Replace-Before $text '      private function loadFromFile(' '      public function getLoadedSWFAppDomain(' $loadFromFile 'display_loader_resolver_before_load'

  $completeText=@'
      private function completeTextLoad(param1:Event) : void
      {
         var loader:URLLoaderWithName = URLLoaderWithName(param1.target);
         var resourceObject:ResourceLoaderObject = this.mResolver[loader.name];
         var resource:String = String(resourceObject.mResourceName);
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
         else if(!this.mAssetLoadCompleteLogged[resource])
         {
            this.mAssetLoadCompleteLogged[resource] = true;
            Utils.DiagEvent("ASSET_LOAD_COMPLETE","resource=" + resource + ";url=" + resourceObject.mURL.url + ";type=" + this.mType[resource] + ";bytes=" + loader.bytesLoaded + ";pending_before=" + this.mFileCountToLoad);
         }
         delete this.mResolver[loader.name];
         this.mUnloader[resource] = loader;
         dispatchEvent(new Event(resource + EVENT_COMPLETE_SINGLE_FILE));
         if(this.mAffectsLoadingScreen[resource])
         {
            if(this.mFileCountToLoad > 0)
            {
               --this.mFileCountToLoad;
            }
            Utils.DiagEvent("ASSET_LOAD_GATE","resource=" + resource + ";result=complete;pending=" + this.mFileCountToLoad);
            if(this.mFileCountToLoad == 0)
            {
               dispatchEvent(new Event("LoadOver"));
            }
         }
      }

'@
  $text=Replace-Before $text '      private function completeTextLoad(' '      private function errorLoad(' $completeText 'observable_text_completion'

  $errorLoad=@'
      private function errorLoad(param1:IOErrorEvent) : void
      {
         if(Config.DEBUG_MODE)
         {
         }
         var resourceObject:ResourceLoaderObject = this.mResolver[param1.target];
         if(!resourceObject)
         {
            Utils.DiagEvent("ASSET_LOAD_ERROR","resource=unknown;terminal=true;text=" + param1.text);
            return;
         }
         var resource:String = resourceObject.mResourceName;
         var loader:Loader = param1.target.loader;
         if(resourceObject.mRetryCount > 1)
         {
            param1.target.removeEventListener(Event.COMPLETE,this.completeLoad);
            param1.target.removeEventListener(ProgressEvent.PROGRESS,this.progressLoad);
            param1.target.removeEventListener(IOErrorEvent.IO_ERROR,this.errorLoad);
            this.mLoaded[resource] = false;
            delete this.mResolver[param1.target];
            if(this.mAffectsLoadingScreen[resource] && this.mFileCountToLoad > 0)
            {
               --this.mFileCountToLoad;
            }
            Utils.DiagEvent("ASSET_LOAD_ERROR","resource=" + resource + ";url=" + resourceObject.mURL.url + ";retry=" + resourceObject.mRetryCount + ";terminal=true;pending=" + this.mFileCountToLoad + ";text=" + param1.text);
            if(this.mAffectsLoadingScreen[resource] && this.mFileCountToLoad == 0)
            {
               Utils.DiagEvent("ASSET_LOAD_GATE","resource=" + resource + ";result=terminal_error;pending=0");
               dispatchEvent(new Event("LoadOver"));
            }
         }
         else
         {
            Utils.DiagEvent("ASSET_LOAD_ERROR","resource=" + resource + ";url=" + resourceObject.mURL.url + ";retry=" + resourceObject.mRetryCount + ";terminal=false;text=" + param1.text);
            ++resourceObject.mRetryCount;
            loader.load(resourceObject.mURL,resourceObject.mLoaderContext);
         }
      }

'@
  $text=Replace-Before $text '      private function errorLoad(' '      private function errorTextLoad(' $errorLoad 'display_terminal_error_drains_gate'

  $errorText=@'
      private function errorTextLoad(param1:IOErrorEvent) : void
      {
         if(Config.DEBUG_MODE)
         {
         }
         var loader:URLLoaderWithName = URLLoaderWithName(param1.target);
         var resourceObject:ResourceLoaderObject = this.mResolver[loader.name];
         if(!resourceObject)
         {
            Utils.DiagEvent("ASSET_LOAD_ERROR","resource=unknown;terminal=true;text=" + param1.text);
            return;
         }
         var resource:String = resourceObject.mResourceName;
         if(resourceObject.mRetryCount > 1)
         {
            loader.removeEventListener(Event.COMPLETE,this.completeTextLoad);
            loader.removeEventListener(ProgressEvent.PROGRESS,this.progressLoad);
            loader.removeEventListener(IOErrorEvent.IO_ERROR,this.errorTextLoad);
            this.mLoaded[resource] = false;
            delete this.mResolver[loader.name];
            if(this.mAffectsLoadingScreen[resource] && this.mFileCountToLoad > 0)
            {
               --this.mFileCountToLoad;
            }
            Utils.DiagEvent("ASSET_LOAD_ERROR","resource=" + resource + ";url=" + resourceObject.mURL.url + ";retry=" + resourceObject.mRetryCount + ";terminal=true;pending=" + this.mFileCountToLoad + ";text=" + param1.text);
            if(this.mAffectsLoadingScreen[resource] && this.mFileCountToLoad == 0)
            {
               Utils.DiagEvent("ASSET_LOAD_GATE","resource=" + resource + ";result=terminal_error;pending=0");
               dispatchEvent(new Event("LoadOver"));
            }
         }
         else
         {
            Utils.DiagEvent("ASSET_LOAD_ERROR","resource=" + resource + ";url=" + resourceObject.mURL.url + ";retry=" + resourceObject.mRetryCount + ";terminal=false;text=" + param1.text);
            ++resourceObject.mRetryCount;
            loader.load(resourceObject.mURL);
         }
      }

'@
  $text=Replace-Before $text '      private function errorTextLoad(' '      public function isAddedToLoadingList(' $errorText 'text_terminal_error_drains_gate'

  Write-Utf8Bom $target $text

  $verify=Normalize-Lf ([IO.File]::ReadAllText($target))
  foreach($token in @(
    'normalizeAndroidResourceUrl',
    'ASSET_PATH_NORMALIZED',
    'ASSET_LOAD_COMPLETE',
    'ASSET_LOAD_GATE',
    'result=terminal_error;pending=0'
  )){
    if(-not $verify.Contains($token)){throw "ANDROID_BOOT_RESOURCE_OVERLAY=FAIL verify token=$token"}
  }
  $textStart=$verify.IndexOf('private function loadTextFile')
  $textComplete=$verify.IndexOf('loader.addEventListener(Event.COMPLETE,this.completeTextLoad',$textStart)
  $textLoadCall=$verify.IndexOf('loader.load(request);',$textStart)
  if($textStart -lt 0 -or $textComplete -lt 0 -or $textLoadCall -lt 0 -or $textComplete -gt $textLoadCall){
    throw 'ANDROID_BOOT_RESOURCE_OVERLAY=FAIL verify=text_listener_order'
  }
  $displayStart=$verify.IndexOf('private function loadFromFile')
  $displayResolver=$verify.IndexOf('this.mResolver[loader.contentLoaderInfo] = new ResourceLoaderObject',$displayStart)
  $displayLoad=$verify.IndexOf('loader.load(request,context);',$displayStart)
  if($displayStart -lt 0 -or $displayResolver -lt 0 -or $displayLoad -lt 0 -or $displayResolver -gt $displayLoad){
    throw 'ANDROID_BOOT_RESOURCE_OVERLAY=FAIL verify=display_resolver_order'
  }
  Write-Host 'REGRESSION_CHECK=PASS name=android_asset_paths_normalized application_relative=true'
  Write-Host 'REGRESSION_CHECK=PASS name=url_loader_listeners_registered_before_load'
  Write-Host 'REGRESSION_CHECK=PASS name=display_loader_resolver_registered_before_load'
  Write-Host 'REGRESSION_CHECK=PASS name=terminal_resource_failure_drains_loading_gate'
  Write-Host 'REGRESSION_CHECK=PASS name=text_asset_completion_is_observable'
  Write-Host "ANDROID_BOOT_RESOURCE_OVERLAY=PASS mode=apply sha=$ExpectedSha baseline_sha256=$baselineSha"
}catch{
  $failure=$_
  try{& $PSCommandPath -RepoRoot $RepoRoot -ExpectedSha $ExpectedSha -GitPath $GitPath -Mode Restore}catch{Write-Host "ANDROID_BOOT_RESOURCE_OVERLAY_RESTORE_AFTER_FAILURE=FAIL message=$($_.Exception.Message)"}
  throw $failure
}
