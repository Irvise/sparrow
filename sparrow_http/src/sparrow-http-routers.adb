with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with Sparrow.Encoding; use Sparrow.Encoding;
with Sparrow.Http.Route_Patterns;

package body Sparrow.Http.Routers is

   type Owned_Route is access Route_Handler'Class;   --  what Add allocates, and Free releases
   procedure Release is new Ada.Unchecked_Deallocation (Route_Handler'Class, Owned_Route);

   overriding procedure Handle (This : Procedure_Route; Request : Http_Request; Response : in out Http_Response)
   is begin
      This.Action (Request, Response);
   end Handle;

   function Keep (Action : Route_Handler'Class) return Route_Handler_Access is
      Copy : constant Owned_Route := new Route_Handler'Class'(Action);
   begin
      return Route_Handler_Access (Copy);
   end Keep;

   ---------
   -- Add --
   ---------

   procedure Check_Pattern (Pattern : String) is
      use Route_Patterns;
      Found : constant Problem := (if Pattern'Last > Max_Index then No_Leading_Slash else Check (Pattern));
   begin
      case Found is
         when None =>
            null;
         when No_Leading_Slash =>
            raise Invalid_Pattern with "a route pattern starts with '/': " & Pattern;
         when Bad_Capture_Name =>
            raise Invalid_Pattern with "a capture needs a name of 1 .. 32 characters: " & Pattern;
         when Star_Not_Last =>
            raise Invalid_Pattern with "a '*' capture must be the last segment: " & Pattern;
         when Too_Many_Captures =>
            raise Invalid_Pattern with "too many captures: " & Pattern;
         when Repeated_Name =>
            raise Invalid_Pattern with "a capture name is repeated: " & Pattern;
      end case;
   end Check_Pattern;

   procedure Add
     (This    : in out Router;
      Verb    : Method;
      Pattern : String;
      Action    : Route_Handler'Class;
      Run       : Placement := On_Worker;
      Body_Mode : Body_Handling := Buffered)
   is begin
      Check_Pattern (Pattern);
      if Body_Mode = Streamed and then Run = On_Reactor then
         raise Program_Error with Pattern & ": a streamed body is read on a worker, which may wait for it";
      end if;
      if This.Route_Total = This.Capacity then
         raise Too_Many_Routes with "the router holds" & This.Capacity'Image & " routes";
      end if;
      This.Route_Total := This.Route_Total + 1;
      This.Routes (This.Route_Total) :=
        (Verb => Verb, Pattern => new String'(Pattern), Action => Keep (Action), Run => Run, Mode => Body_Mode);
      This.Any_Streamed := This.Any_Streamed or else Body_Mode = Streamed;
   end Add;

   procedure Add
     (This    : in out Router;
      Verb    : Method;
      Pattern : String;
      Action    : not null Handler;
      Run       : Placement := On_Worker;
      Body_Mode : Body_Handling := Buffered)
   is begin
      Add (This, Verb, Pattern, Procedure_Route'(Action => Action), Run, Body_Mode);
   end Add;

   procedure Set_Fallback (This : in out Router; Action : Route_Handler'Class; Run : Placement := On_Reactor) is
   begin
      This.Fallback     := Keep (Action);
      This.Fallback_Run := Run;
   end Set_Fallback;

   procedure Set_Fallback (This : in out Router; Action : not null Handler; Run : Placement := On_Reactor) is begin
      Set_Fallback (This, Procedure_Route'(Action => Action), Run);
   end Set_Fallback;

   --  Record in Request what Pattern's captures matched in Path (which matches it). Path is a copy of the
   --  request's path; Path_Offset turns a position in it into one in the request's bytes.
   procedure Capture (Pattern : String; Path : String; Path_Offset : Integer; Request : in out Requests.Request) is
      Captures : Route_Patterns.Capture_List;
      Count    : Natural;
   begin
      Route_Patterns.Find_Captures (Pattern, Path, Captures, Count);
      for Item of Captures (1 .. Count) loop
         Requests.Add_Parameter
           (Request, Slice (Pattern, Item.Name),
            (First => Item.Value.First + Path_Offset, Last => Item.Value.Last + Path_Offset));
      end loop;
   end Capture;

   ----------
   -- Find --
   ----------

   procedure Find (This : Router; Request : in out Requests.Request; Result : out Route_Match) is
      Path : constant String := Requests.Path (Request);
      Verb : constant Method := Requests.Verb (Request);
   begin
      if Path'First < 1 or else Path'Last > Route_Patterns.Max_Index then
         Result := (Action => This.Fallback, Run => This.Fallback_Run, Path_Matched => False, Index => 0,
                    Body_Mode => Buffered);
         return;
      end if;
      Result := (Action => This.Fallback, Run => This.Fallback_Run, Path_Matched => False, Index => 0,
                 Body_Mode => Buffered);
      for Index in 1 .. This.Route_Total loop
         declare
            Item : Route renames This.Routes (Index);
         begin
            if Route_Patterns.Matches (Item.Pattern.all, Path) then
               --  HEAD is answered by the GET route; the server drops the body.
               if Item.Verb = Verb or else (Verb = Head and then Item.Verb = Get) then
                  Result := (Action => Item.Action, Run => Item.Run, Path_Matched => True, Index => Index,
                             Body_Mode => Item.Mode);
                  --  Path may be a copy with its own bounds; in the request's bytes it starts at Path_First.
                  Capture (Item.Pattern.all, Path, Requests.Path_First (Request) - Path'First, Request);
                  return;
               end if;
               Result.Path_Matched := True;
            end if;
         end;
      end loop;
   end Find;

   function Has_Streamed_Body (This : Router) return Boolean is (This.Any_Streamed);

   function Route_Count (This : Router) return Natural is (This.Route_Total);
   function Pattern (This : Router; Index : Positive) return String is (This.Routes (Index).Pattern.all);
   function Verb (This : Router; Index : Positive) return Method is (This.Routes (Index).Verb);

   procedure Free (This : in out Router) is
      --  Every handler object of the router was allocated by Keep, as an Owned_Route.
      function To_Owned is new Ada.Unchecked_Conversion (Route_Handler_Access, Owned_Route);
      Owned : Owned_Route;
   begin
      for Item of This.Routes (1 .. This.Route_Total) loop
         Buffers.Free (Item.Pattern);
         Owned := To_Owned (Item.Action);
         Release (Owned);
         Item.Action := null;
      end loop;
      Owned := To_Owned (This.Fallback);
      Release (Owned);
      This.Fallback    := null;
      This.Route_Total := 0;
   end Free;

end Sparrow.Http.Routers;
