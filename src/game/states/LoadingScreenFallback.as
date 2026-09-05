package game.states
{
   import flash.display.MovieClip;
   import flash.text.TextField;
   import flash.text.TextFormat;

   /**
    * Minimal source-defined loading screen used only when the original
    * Animate linkage class "background" is unavailable to a headless build.
    */
   public class LoadingScreenFallback extends MovieClip
   {
      public function LoadingScreenFallback()
      {
         super();

         graphics.beginFill(0x202830);
         graphics.drawRect(0,0,1024,768);
         graphics.endFill();

         var title:TextField = new TextField();
         title.name = "Text_Title";
         title.width = 600;
         title.height = 45;
         title.x = 212;
         title.y = 300;
         title.defaultTextFormat = new TextFormat("Arial",28,0xFFFFFF,true,null,null,null,null,"center");
         title.text = "Army Attack";
         addChild(title);

         var bar:MovieClip = new MovieClip();
         bar.name = "Fill_Bar";
         bar.x = 312;
         bar.y = 365;
         bar.graphics.beginFill(0x3A4650);
         bar.graphics.drawRoundRect(0,0,400,70,12,12);
         bar.graphics.endFill();

         var progress:TextField = new TextField();
         progress.name = "Progress";
         progress.width = 100;
         progress.height = 28;
         progress.x = 150;
         progress.y = 8;
         progress.defaultTextFormat = new TextFormat("Arial",18,0xFFFFFF,true,null,null,null,null,"center");
         progress.text = "0%";
         bar.addChild(progress);

         var description:TextField = new TextField();
         description.name = "Text_Description";
         description.width = 360;
         description.height = 28;
         description.x = 20;
         description.y = 38;
         description.defaultTextFormat = new TextFormat("Arial",14,0xDDE6EC,false,null,null,null,null,"center");
         description.text = "Loading...";
         bar.addChild(description);

         addChild(bar);
      }
   }
}
