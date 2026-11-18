with Ada.Strings.Fixed;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.Metrics;

package body Sparrow.Http.Limits is

   use type Stores.Bucket_Store_Access;

   use type Ada.Real_Time.Time;

   Refused : constant Metrics.Counter :=
     Metrics.New_Counter ("sparrow_http_rate_limited_total", "Requests answered 429 by a rate limit");

   protected body Shard is

      procedure Take
        (Key         : String;
         Rate        : Long_Float;
         Burst       : Positive;
         Max_Keys    : Natural;
         Allowed     : out Boolean;
         Retry_After : out Natural)
      is
         use Bucket_Maps;
         Now      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
         Full     : constant Long_Float := Long_Float (Burst);
         Position : constant Cursor := Buckets.Find (Key);
         Current  : Bucket;

         --  The bucket's tokens now.
         function Refilled (Item : Bucket) return Long_Float is
           (Long_Float'Min (Full, Item.Tokens + Rate * Long_Float (Ada.Real_Time.To_Duration (Now - Item.Updated))));

         --  Forget the buckets that have filled up; when none has, the one left alone longest.
         procedure Make_Room is
            Next   : Cursor := Buckets.First;
            Oldest : Cursor := No_Element;
            Here   : Cursor;
         begin
            while Has_Element (Next) loop
               Here := Next;
               Next := Bucket_Maps.Next (Next);
               if Refilled (Element (Here)) >= Full then
                  Buckets.Delete (Here);
               elsif Oldest = No_Element or else Element (Here).Updated < Element (Oldest).Updated then
                  Oldest := Here;
               end if;
            end loop;
            if Natural (Buckets.Length) >= Max_Keys and then Oldest /= No_Element then
               Buckets.Delete (Oldest);
            end if;
         end Make_Room;
      begin
         if Position = No_Element then
            if Natural (Buckets.Length) >= Max_Keys then
               Make_Room;
            end if;
            Current := (Tokens => Full, Updated => Now);
         else
            Current := (Tokens => Refilled (Element (Position)), Updated => Now);
         end if;

         Allowed := Current.Tokens >= 1.0;
         if Allowed then
            Current.Tokens := Current.Tokens - 1.0;
            Retry_After    := 0;
         else
            Retry_After := Natural'Max (1, Natural (Long_Float'Ceiling ((1.0 - Current.Tokens) / Rate)));
         end if;

         if Position = No_Element then
            Buckets.Insert (Key, Current);
         else
            Buckets.Replace_Element (Position, Current);
         end if;
      end Take;

   end Shard;

   function Client_Key (Request : Http_Request) return String is (Requests.Client_Address (Request));

   overriding procedure Take
     (This        : in out Memory_Buckets;
      Key         : String;
      Rate        : Long_Float;
      Burst       : Positive;
      Allowed     : out Boolean;
      Retry_After : out Natural)
   is
      use type Ada.Containers.Hash_Type;
   begin
      This.Shards (Natural (Ada.Strings.Hash (Key) mod Shard_Count)).Take
        (Key, Rate, Burst, (This.Max_Keys + Shard_Count - 1) / Shard_Count, Allowed, Retry_After);
   end Take;

   function Per_Key
     (Rate     : Long_Float;
      Burst    : Positive;
      Key      : not null Key_Function;
      Max_Keys : Positive := 100_000;
      Store    : Bucket_Store_Access := null) return Limit
   is
     ((Rate  => Rate,
       Burst => Burst,
       Key   => Key,
       Store => (if Store = null then Bucket_Store_Access'(new Memory_Buckets (Max_Keys)) else Store)));

   function Per_Client
     (Rate     : Long_Float;
      Burst    : Positive;
      Max_Keys : Positive := 100_000;
      Store    : Bucket_Store_Access := null) return Limit
   is
     (Per_Key (Rate, Burst, Client_Key'Access, Max_Keys, Store));

   procedure Take (This : Limit; Key : String; Allowed : out Boolean; Retry_After : out Natural) is
   begin
      if This.Store = null then
         raise Program_Error with "a limit made without Per_Key or Per_Client";
      end if;
      This.Store.Take (Key, This.Rate, This.Burst, Allowed, Retry_After);
   end Take;

   procedure Check (This : Limit; Request : Http_Request; Response : in out Http_Response; Allowed : out Boolean)
   is
      Key         : constant String := This.Key (Request);
      Retry_After : Natural;
   begin
      if Key = "" then
         Allowed := True;
         return;
      end if;
      Take (This, Key, Allowed, Retry_After);
      if not Allowed then
         Metrics.Add (Refused);
         Responses.Set_Header (Response, "Retry-After", Ada.Strings.Fixed.Trim (Retry_After'Image, Ada.Strings.Left));
         Responses.Send (Response, Too_Many_Requests, "too many requests: try again later");
      end if;
   end Check;

   overriding procedure Handle (This : Limited_Route; Request : Http_Request; Response : in out Http_Response) is
      Allowed : Boolean;
   begin
      Check (This.Rule, Request, Response, Allowed);
      if not Allowed then
         null;
      elsif This.Procedure_Action /= null then
         This.Procedure_Action (Request, Response);
      else
         This.Object_Action.Handle (Request, Response);
      end if;
   end Handle;

   function Wrap (This : Limit; Action : not null Handler) return Limited_Route is
     ((Rule => This, Procedure_Action => Action, Object_Action => null));

   function Wrap (This : Limit; Action : Route_Handler'Class) return Limited_Route is
     ((Rule => This, Procedure_Action => null, Object_Action => new Route_Handler'Class'(Action)));

end Sparrow.Http.Limits;
