with Sparrow.Buffers;
with Sparrow.Http.Delivery; use Sparrow.Http.Delivery;

package body Sparrow.Http.Bodies is

   procedure Read (Request : Requests.Request; Into : out String; Last : out Natural) is
      Id          : constant Connection_Id := Requests.Connection (Request);
      Pipe        : Pipe_Access;
      State       : Pipe_State;
      Status      : Status_Code;
      Wanted_More : Boolean;
   begin
      if not Requests.Body_Streamed (Request) then
         raise Program_Error with "the route's body is not streamed: add it with Body_Mode => Streamed";
      end if;
      if Id.Stream /= 0 then
         declare
            Place : constant Natural := Lane_Of (Id);
         begin
            if Place /= 0 then
               Pipe := Lanes (Id.Reactor) (Id.Slot).Pipes (Place);
            end if;
         end;
      elsif Pipes /= null and then Id.Reactor in Pipes'Range and then Pipes (Id.Reactor) /= null
        and then Id.Slot in Pipes (Id.Reactor)'Range
      then
         Pipe := Pipes (Id.Reactor) (Id.Slot);
      end if;
      if Pipe = null then
         raise Body_Error with "no server is reading this request's body";
      end if;

      Pipe.Take (Id.Generation, Id.Stream, Into, Last, State, Status, Wanted_More);
      if Wanted_More then
         declare
            Item : Job_Access := new Job;
         begin
            Item.Kind       := Body_Wanted;
            Item.Reactor    := Id.Reactor;
            Item.Slot       := Id.Slot;
            Item.Generation := Id.Generation;
            Item.Stream     := Id.Stream;
            Post (Item);
         end;
      end if;
      if State = Broken then
         raise Body_Error with
           (case Status is
               when Bad_Request       => "the client sent a malformed chunked body",
               when Payload_Too_Large => "the body is longer than Limits.Max_Streamed_Length",
               when others            => "the client left before sending the whole body");
      end if;
   end Read;

   function Read_All (Request : Requests.Request; Max_Length : Positive) return String is
      use Sparrow.Buffers;
      Whole : Buffer;
      Part  : String (1 .. 16_384);
      Last  : Natural;
   begin
      loop
         Read (Request, Part, Last);
         exit when Last < Part'First;
         if Whole.Length + Last > Max_Length then
            Free (Whole);
            raise Body_Error with "the body is longer than" & Max_Length'Image & " bytes";
         end if;
         Append (Whole, Part (1 .. Last));
      end loop;
      return Result : constant String := Content (Whole) do
         Free (Whole);
      end return;
   exception
      when Body_Error =>
         Free (Whole);
         raise;
   end Read_All;

   function Declared_Length (Request : Requests.Request) return Long_Long_Integer is
      Text : constant String := Requests.Header (Request, "Content-Length");
   begin
      if Requests.Header (Request, "Transfer-Encoding") /= "" or else Text = "" then
         return (if Requests.Header (Request, "Transfer-Encoding") /= "" then -1 else 0);
      end if;
      return Long_Long_Integer'Value (Text);   --  digits only: the parser checked them
   end Declared_Length;

end Sparrow.Http.Bodies;
