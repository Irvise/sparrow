with Ada.Numerics.Float_Random; use Ada.Numerics.Float_Random;
with Ada.Numerics.Long_Elementary_Functions; use Ada.Numerics.Long_Elementary_Functions;
with Ada.Real_Time; use Ada.Real_Time;
with Ada.Strings.Fixed;
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Http.Streams;
with Sparrow.Json.Builders; use Sparrow.Json.Builders;

package body Arena is

   World_Size    : constant := 3_000.0;
   Pellet_Count  : constant := 600;
   Start_Mass    : constant := 10.0;
   Pellet_Mass   : constant := 1.0;
   Eat_Ratio     : constant := 1.25;              --  how much heavier the eater must be
   Tick          : constant Time_Span := Milliseconds (33);
   Tick_Seconds  : constant Long_Float := 0.033;
   Bot_Respawn   : constant Time_Span := Seconds (3);
   Bot_Thinking  : constant Time_Span := Milliseconds (300);

   subtype Bot_Id is Blob_Id range Max_Players + 1 .. Blob_Id'Last;

   Bot_Names : constant array (Bot_Id) of String (1 .. 8) :=
     ["Gloop   ", "Mochi   ", "Blorb   ", "Pudding ", "Wobble  ", "Nugget  ",
      "Bean    ", "Dumpling", "Jelly   ", "Tofu    ", "Squish  ", "Bubbles "];

   type Blob is record
      Active      : Boolean := False;            --  a slot in use (bots: always)
      Alive       : Boolean := False;
      Name        : String (1 .. 32) := [others => ' '];
      Name_Length : Natural := 0;
      Hue         : Natural := 0;
      X, Y        : Long_Float := 0.0;
      Mass        : Long_Float := Start_Mass;
      Aim_X       : Long_Float := 0.0;           --  where it is heading
      Aim_Y       : Long_Float := 0.0;
      Socket      : Connection_Id := No_Connection;   --  players: theirs
      Seen        : Time := Time_First;          --  bots: when to think again
      Eaten_By    : Natural := 0;
   end record;

   type Pellet is record
      X, Y : Long_Float := 0.0;
      Hue  : Natural := 0;
   end record;

   type Blob_Array is array (Blob_Id) of Blob;
   type Pellet_Array is array (1 .. Pellet_Count) of Pellet;

   --  Only the World's procedures use it, one at a time.
   Dice : Generator;

   function Random (Low, High : Long_Float) return Long_Float is (Low + (High - Low) * Long_Float (Random (Dice)));
   function Random_Hue return Natural is (Natural (Random (0.0, 359.0)));

   function Radius (Mass : Long_Float) return Long_Float is (6.0 * Sqrt (Mass));
   function Speed (Mass : Long_Float) return Long_Float is (280.0 * Mass ** (-0.2));   --  world units a second
   function Distance (A_X, A_Y, B_X, B_Y : Long_Float) return Long_Float is
     (Sqrt ((A_X - B_X) ** 2 + (A_Y - B_Y) ** 2));
   function Clamp (Value : Long_Float) return Long_Float is (Long_Float'Max (0.0, Long_Float'Min (World_Size, Value)));

   --  Half the side of the square a blob of Mass is sent: the client shows 800 * the same factor top to bottom,
   --  so this covers screens up to 3.5 times wider than tall.
   function View_Half (Mass : Long_Float) return Long_Float is (1400.0 * (Radius (Mass) / Radius (Start_Mass)) ** 0.35);

   function Rounded (Value : Long_Float) return Long_Long_Integer is (Long_Long_Integer (Value));

   protected World is
      procedure Add (Name : UTF8_String; Socket : Connection_Id; Added : out Boolean);
      procedure Steer (Socket : Connection_Id; X, Y : Long_Float);
      procedure Respawn (Socket : Connection_Id);
      procedure Remove (Socket : Connection_Id);
      function View (Id : Player_Id; Into : aliased in out Buffer; Socket : out Connection_Id) return Boolean;
      procedure Step (Seconds : Long_Float);
   private
      Blobs   : Blob_Array;
      Pellets : Pellet_Array;
      Ready   : Boolean := False;   --  pellets and bots placed
   end World;

   protected body World is

      procedure Place (Item : out Pellet) is begin
         Item := (X => Random (0.0, World_Size), Y => Random (0.0, World_Size), Hue => Random_Hue);
      end Place;

      --  A fresh blob somewhere no heavier blob is close, the best of a few tries.
      procedure Spawn (Id : Blob_Id) is
         Best_X, Best_Y : Long_Float := World_Size / 2.0;
         Best_Room      : Long_Float := -1.0;
      begin
         for Attempt in 1 .. 8 loop
            declare
               X    : constant Long_Float := Random (100.0, World_Size - 100.0);
               Y    : constant Long_Float := Random (100.0, World_Size - 100.0);
               Room : Long_Float := World_Size;
            begin
               for Other of Blobs loop
                  if Other.Active and then Other.Alive and then Other.Mass > Start_Mass then
                     Room := Long_Float'Min (Room, Distance (X, Y, Other.X, Other.Y) - Radius (Other.Mass));
                  end if;
               end loop;
               if Room > Best_Room then
                  Best_X := X;
                  Best_Y := Y;
                  Best_Room := Room;
               end if;
            end;
         end loop;
         Blobs (Id).Alive    := True;
         --  Bots come back at mixed sizes, so a lone player meets both prey and danger from the start.
         Blobs (Id).Mass     := (if Id in Bot_Id then Start_Mass * Random (0.8, 6.0) else Start_Mass);
         Blobs (Id).X        := Best_X;
         Blobs (Id).Y        := Best_Y;
         Blobs (Id).Aim_X    := Best_X;
         Blobs (Id).Aim_Y    := Best_Y;
         Blobs (Id).Eaten_By := 0;
      end Spawn;

      procedure Prepare is begin
         Reset (Dice);
         for Item of Pellets loop
            Place (Item);
         end loop;
         for Id in Bot_Id loop
            Blobs (Id).Active      := True;
            Blobs (Id).Name (1 .. 8) := Bot_Names (Id);
            Blobs (Id).Name_Length := Ada.Strings.Fixed.Index_Non_Blank (Bot_Names (Id), Ada.Strings.Backward);
            Blobs (Id).Hue         := Random_Hue;
            Spawn (Id);
         end loop;
         Ready := True;
      end Prepare;

      procedure Add (Name : UTF8_String; Socket : Connection_Id; Added : out Boolean) is begin
         Added := False;
         if not Ready then
            Prepare;
         end if;
         for Slot in Player_Id loop
            if not Blobs (Slot).Active then
               Blobs (Slot).Active                 := True;
               Blobs (Slot).Name (1 .. Name'Length) := String (Name);
               Blobs (Slot).Name_Length            := Name'Length;
               Blobs (Slot).Hue                    := Random_Hue;
               Blobs (Slot).Socket                 := Socket;
               Spawn (Slot);
               Added := True;
               return;
            end if;
         end loop;
      end Add;

      --  The player whose socket is Socket; 0 for none.
      function Player_Of (Socket : Connection_Id) return Natural is begin
         for Id in Player_Id loop
            if Blobs (Id).Active and then Blobs (Id).Socket = Socket then
               return Natural (Id);
            end if;
         end loop;
         return 0;
      end Player_Of;

      procedure Steer (Socket : Connection_Id; X, Y : Long_Float) is
         Id : constant Natural := Player_Of (Socket);
      begin
         if Id /= 0 then
            Blobs (Blob_Id (Id)).Aim_X := Clamp (X);
            Blobs (Blob_Id (Id)).Aim_Y := Clamp (Y);
         end if;
      end Steer;

      procedure Respawn (Socket : Connection_Id) is
         Id : constant Natural := Player_Of (Socket);
      begin
         if Id /= 0 and then not Blobs (Blob_Id (Id)).Alive then
            Spawn (Blob_Id (Id));
         end if;
      end Respawn;

      procedure Remove (Socket : Connection_Id) is
         Id : constant Natural := Player_Of (Socket);
      begin
         if Id /= 0 then
            Blobs (Blob_Id (Id)).Active := False;
            Blobs (Blob_Id (Id)).Alive  := False;
            Blobs (Blob_Id (Id)).Socket := No_Connection;
         end if;
      end Remove;

      --  A bot's next aim: away from the nearest threat, else toward the nearest prey, else the nearest pellet.
      procedure Think (Id : Bot_Id) is
         Self        : Blob renames Blobs (Id);
         Threat      : Natural := 0;
         Prey        : Natural := 0;
         Threat_Near : Long_Float := 300.0 + Radius (Self.Mass);
         Prey_Near   : Long_Float := 450.0;
         Pellet_Near : Long_Float := Long_Float'Last;
      begin
         for Other in Blob_Id loop
            if Other /= Id and then Blobs (Other).Active and then Blobs (Other).Alive then
               declare
                  Apart : constant Long_Float := Distance (Self.X, Self.Y, Blobs (Other).X, Blobs (Other).Y);
               begin
                  if Blobs (Other).Mass > Eat_Ratio * Self.Mass and then Apart < Threat_Near then
                     Threat      := Natural (Other);
                     Threat_Near := Apart;
                  elsif Self.Mass > Eat_Ratio * Blobs (Other).Mass and then Apart < Prey_Near then
                     Prey      := Natural (Other);
                     Prey_Near := Apart;
                  end if;
               end;
            end if;
         end loop;

         if Threat /= 0 then
            declare
               Away_X : constant Long_Float := Self.X - Blobs (Blob_Id (Threat)).X;
               Away_Y : constant Long_Float := Self.Y - Blobs (Blob_Id (Threat)).Y;
               Length : constant Long_Float := Long_Float'Max (1.0, Sqrt (Away_X ** 2 + Away_Y ** 2));
            begin
               Self.Aim_X := Clamp (Self.X + 400.0 * Away_X / Length + Random (-80.0, 80.0));
               Self.Aim_Y := Clamp (Self.Y + 400.0 * Away_Y / Length + Random (-80.0, 80.0));
            end;
         elsif Prey /= 0 then
            Self.Aim_X := Blobs (Blob_Id (Prey)).X;
            Self.Aim_Y := Blobs (Blob_Id (Prey)).Y;
         else
            for Item of Pellets loop
               declare
                  Apart : constant Long_Float := Distance (Self.X, Self.Y, Item.X, Item.Y);
               begin
                  if Apart < Pellet_Near then
                     Pellet_Near := Apart;
                     Self.Aim_X  := Item.X;
                     Self.Aim_Y  := Item.Y;
                  end if;
               end;
            end loop;
         end if;
      end Think;

      procedure Move (Self : in out Blob; Seconds : Long_Float) is
         To_X  : constant Long_Float := Self.Aim_X - Self.X;
         To_Y  : constant Long_Float := Self.Aim_Y - Self.Y;
         Apart : constant Long_Float := Sqrt (To_X ** 2 + To_Y ** 2);
         Step  : Long_Float;
      begin
         if Apart > 0.5 then
            --  Full speed from 80 units out, slowing on the way in, so a still pointer means a still blob.
            Step   := Long_Float'Min (Apart, Speed (Self.Mass) * Seconds * Long_Float'Min (1.0, Apart / 80.0));
            Self.X := Clamp (Self.X + Step * To_X / Apart);
            Self.Y := Clamp (Self.Y + Step * To_Y / Apart);
         end if;
      end Move;

      procedure Step (Seconds : Long_Float) is
         Now : constant Time := Clock;
      begin
         if not Ready then
            Prepare;
         end if;

         for Id in Blob_Id loop
            declare
               Self : Blob renames Blobs (Id);
            begin
               if Id in Bot_Id and then not Self.Alive and then Now >= Self.Seen then
                  Spawn (Id);
               elsif Id in Bot_Id and then Self.Alive and then Now >= Self.Seen then
                  Think (Id);
                  Self.Seen := Now + Bot_Thinking;
               end if;

               if Self.Active and then Self.Alive then
                  Move (Self, Seconds);
                  if Self.Mass > 40.0 then
                     Self.Mass := Self.Mass * (1.0 - 0.004 * Seconds);   --  the bigger, the more it loses
                  end if;
                  declare
                     Reach : constant Long_Float := Radius (Self.Mass);
                  begin
                     for Item of Pellets loop
                        if (Item.X - Self.X) ** 2 + (Item.Y - Self.Y) ** 2 < Reach ** 2 then
                           Self.Mass := Self.Mass + Pellet_Mass;
                           Place (Item);
                        end if;
                     end loop;
                  end;
               end if;
            end;
         end loop;

         for Eater in Blob_Id loop
            for Eaten in Blob_Id loop
               declare
                  A : Blob renames Blobs (Eater);
                  B : Blob renames Blobs (Eaten);
               begin
                  if Eater /= Eaten and then A.Active and then A.Alive and then B.Active and then B.Alive
                    and then A.Mass > Eat_Ratio * B.Mass
                    and then Distance (A.X, A.Y, B.X, B.Y) < Radius (A.Mass) - 0.4 * Radius (B.Mass)
                  then
                     A.Mass     := A.Mass + B.Mass;
                     B.Alive    := False;
                     B.Eaten_By := Natural (Eater);
                     if Eaten in Bot_Id then
                        B.Seen := Now + Bot_Respawn;
                     end if;
                  end if;
               end;
            end loop;
         end loop;
      end Step;

      function View (Id : Player_Id; Into : aliased in out Buffer; Socket : out Connection_Id) return Boolean is
         Self   : Blob renames Blobs (Id);
         Half   : constant Long_Float := View_Half (Self.Mass);
         Json   : Builder (Into'Access);
         Shown  : array (Blob_Id) of Boolean := [others => False];

         function Name_Of (Item : Blob) return UTF8_String is (UTF8_String (Item.Name (1 .. Item.Name_Length)));

         function In_View (X, Y, Margin : Long_Float) return Boolean is
           (abs (X - Self.X) < Half + Margin and then abs (Y - Self.Y) < Half + Margin);
      begin
         Socket := Self.Socket;
         if not Self.Active then
            return False;
         end if;

         Json.Begin_Object;
         Json.Key ("you");
         Json.Begin_Object;
         Json.Member ("id", Long_Long_Integer (Id));
         Json.Member ("x", Rounded (Self.X));
         Json.Member ("y", Rounded (Self.Y));
         Json.Member ("r", Rounded (Radius (Self.Mass)));
         Json.Member ("mass", Rounded (Self.Mass));
         Json.Member ("alive", Self.Alive);
         Json.Member ("eaten_by",
                      (if Self.Eaten_By = 0 then "" else Name_Of (Blobs (Blob_Id (Self.Eaten_By)))));
         Json.End_Object;
         Json.Member ("size", Long_Long_Integer (World_Size));

         Json.Key ("blobs");
         Json.Begin_Array;
         for Other in Blob_Id loop
            declare
               Item : Blob renames Blobs (Other);
            begin
               if Item.Active and then Item.Alive and then In_View (Item.X, Item.Y, Radius (Item.Mass)) then
                  Json.Begin_Array;
                  Json.Value (Long_Long_Integer (Other));
                  Json.Value (Rounded (Item.X));
                  Json.Value (Rounded (Item.Y));
                  Json.Value (Rounded (Radius (Item.Mass)));
                  Json.Value (Long_Long_Integer (Item.Hue));
                  Json.Value (Name_Of (Item));
                  Json.End_Array;
               end if;
            end;
         end loop;
         Json.End_Array;

         Json.Key ("pellets");
         Json.Begin_Array;
         for Item of Pellets loop
            if In_View (Item.X, Item.Y, 10.0) then
               Json.Begin_Array;
               Json.Value (Rounded (Item.X));
               Json.Value (Rounded (Item.Y));
               Json.Value (Long_Long_Integer (Item.Hue));
               Json.End_Array;
            end if;
         end loop;
         Json.End_Array;

         --  The five heaviest, by repeated selection.
         Json.Key ("top");
         Json.Begin_Array;
         for Place in 1 .. 5 loop
            declare
               Heaviest : Natural := 0;
            begin
               for Other in Blob_Id loop
                  if Blobs (Other).Active and then Blobs (Other).Alive and then not Shown (Other)
                    and then (Heaviest = 0 or else Blobs (Other).Mass > Blobs (Blob_Id (Heaviest)).Mass)
                  then
                     Heaviest := Natural (Other);
                  end if;
               end loop;
               exit when Heaviest = 0;
               Shown (Blob_Id (Heaviest)) := True;
               Json.Begin_Array;
               Json.Value (Name_Of (Blobs (Blob_Id (Heaviest))));
               Json.Value (Rounded (Blobs (Blob_Id (Heaviest)).Mass));
               Json.Value (Heaviest = Natural (Id));
               Json.End_Array;
            end;
         end loop;
         Json.End_Array;
         Json.End_Object;
         return True;
      end View;

   end World;

   ---------------------------------------------------------------------------------------------------------------

   procedure Join (Name : UTF8_String; Socket : Connection_Id; Joined : out Boolean) is begin
      World.Add (Name, Socket, Joined);
   end Join;

   procedure Steer (Socket : Connection_Id; X, Y : Long_Float) is begin
      World.Steer (Socket, X, Y);
   end Steer;

   procedure Respawn (Socket : Connection_Id) is begin
      World.Respawn (Socket);
   end Respawn;

   procedure Leave (Socket : Connection_Id) is begin
      World.Remove (Socket);
   end Leave;

   --  Each player's view to its socket, sent outside the World's lock.
   procedure Broadcast (Scratch : aliased in out Buffer) is
      Socket : Connection_Id;
   begin
      for Id in Player_Id loop
         Clear (Scratch);
         if World.View (Id, Scratch, Socket) then
            Sparrow.Http.Streams.Send (Socket, UTF8_String (Content (Scratch)));
         end if;
      end loop;
   end Broadcast;

   task Ticker is
      entry Start;
      entry Stop;
   end Ticker;

   task body Ticker is
      Next    : Time;
      Scratch : aliased Buffer;
   begin
      select
         accept Start;
      or
         terminate;
      end select;
      Next := Clock;
      loop
         select
            accept Stop;
            exit;
         or
            delay until Next;
            World.Step (Tick_Seconds);
            Broadcast (Scratch);
            Next := Next + Tick;
         end select;
      end loop;
   end Ticker;

   procedure Start is begin
      Ticker.Start;
   end Start;

   procedure Stop is begin
      Ticker.Stop;
   end Stop;

end Arena;
