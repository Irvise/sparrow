package body Sparrow.Http.Route_Patterns with SPARK_Mode is

   --  The segment of Text starting at First: its last position, before the next '/' or the end.
   function Segment_End (Text : String; First : Positive) return Natural
      with Pre  => First >= Text'First and then Text'Last <= Max_Index and then First <= Text'Last + 1,
           Post => Segment_End'Result in First - 1 .. Text'Last
                   and then (Segment_End'Result = Text'Last or else Text (Segment_End'Result + 1) = '/')
   is
      Last : Natural := First - 1;
   begin
      while Last < Text'Last and then Text (Last + 1) /= '/' loop
         pragma Loop_Invariant (Last in First - 1 .. Text'Last - 1);
         pragma Loop_Variant (Increases => Last);
         Last := Last + 1;
      end loop;
      return Last;
   end Segment_End;

   function Check (Pattern : String) return Problem is
      Names : array (1 .. Max_Captures) of Span := [others => Empty];
      Count : Natural := 0;
      First : Positive;
      Last  : Natural;
   begin
      if Pattern'Length = 0 or else Pattern (Pattern'First) /= '/' then
         return No_Leading_Slash;
      end if;
      First := Pattern'First + 1;
      while First <= Pattern'Last loop
         pragma Loop_Invariant (First > Pattern'First and then Count <= Max_Captures
                                and then (for all Index in 1 .. Count => Within (Names (Index), Pattern)));
         pragma Loop_Variant (Increases => First);
         Last := Segment_End (Pattern, First);
         if Last >= First and then Pattern (First) in ':' | '*' then
            if Last = First or else Last - First > 32 then
               return Bad_Capture_Name;
            elsif Pattern (First) = '*' and then Last /= Pattern'Last then
               return Star_Not_Last;
            elsif Count = Max_Captures then
               return Too_Many_Captures;
            end if;
            for Index in 1 .. Count loop
               if Slice (Pattern, Names (Index)) = Pattern (First + 1 .. Last) then
                  return Repeated_Name;
               end if;
            end loop;
            Count         := Count + 1;
            Names (Count) := (First => First + 1, Last => Last);
         end if;
         First := Last + 2;
      end loop;
      return None;
   end Check;

   function Matches (Pattern, Path : String) return Boolean is
      Pattern_First : Positive := Pattern'First;
      Path_First    : Positive := Path'First;
      Pattern_Last  : Natural;
      Path_Last     : Natural;
   begin
      loop
         pragma Loop_Invariant (Pattern_First >= Pattern'First and then Path_First >= Path'First);
         pragma Loop_Variant (Increases => Pattern_First);
         --  Both are at a '/' here.
         if Pattern_First > Pattern'Last or else Path_First > Path'Last then
            return Pattern_First > Pattern'Last and then Path_First > Path'Last;
         elsif Path (Path_First) /= '/' or else Pattern (Pattern_First) /= '/' then
            return False;
         end if;

         Pattern_Last := Segment_End (Pattern, Pattern_First + 1);
         Path_Last    := Segment_End (Path, Path_First + 1);
         if Pattern_Last >= Pattern_First + 1 and then Pattern (Pattern_First + 1) = '*' then
            return True;   --  the rest, even nothing
         elsif Pattern_Last >= Pattern_First + 1 and then Pattern (Pattern_First + 1) = ':' then
            if Path_Last < Path_First + 1 then
               return False;   --  ":name" matches one segment, never an empty one
            end if;
         elsif Pattern (Pattern_First + 1 .. Pattern_Last) /= Path (Path_First + 1 .. Path_Last) then
            return False;
         end if;
         Pattern_First := Pattern_Last + 1;
         Path_First    := Path_Last + 1;
      end loop;
   end Matches;

   procedure Find_Captures (Pattern, Path : String; Captures : out Capture_List; Count : out Natural) is
      Pattern_First : Positive := Pattern'First;
      Path_First    : Positive := Path'First;
      Pattern_Last  : Natural;
      Path_Last     : Natural;
   begin
      Captures := [others => (Name => Empty, Value => Empty)];
      Count    := 0;
      while Pattern_First <= Pattern'Last and then Path_First <= Path'Last loop
         pragma Loop_Invariant (Pattern_First >= Pattern'First and then Path_First >= Path'First
                                and then Count <= Max_Captures
                                and then (for all Index in 1 .. Count =>
                                            Within (Captures (Index).Name, Pattern)
                                            and then Within (Captures (Index).Value, Path)));
         pragma Loop_Variant (Increases => Pattern_First);
         Pattern_Last := Segment_End (Pattern, Pattern_First + 1);
         Path_Last    := Segment_End (Path, Path_First + 1);
         if Pattern_Last >= Pattern_First + 1 and then Pattern (Pattern_First + 1) in ':' | '*' then
            if Pattern (Pattern_First + 1) = '*' then
               Path_Last := Path'Last;
            end if;
            if Count < Max_Captures then
               Count            := Count + 1;
               Captures (Count) := (Name  => (First => Pattern_First + 2, Last => Pattern_Last),
                                    Value => (First => Path_First + 1, Last => Path_Last));
            end if;
         end if;
         Pattern_First := Pattern_Last + 1;
         Path_First    := Path_Last + 1;
      end loop;
   end Find_Captures;

end Sparrow.Http.Route_Patterns;
