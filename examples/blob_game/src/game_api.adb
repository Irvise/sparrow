with Arena;
with Sparrow.Encoding;
with Sparrow.Http.Requests;
with Sparrow.Http.Streams;

package body Game_Api is

   overriding procedure On_Open (This : Players; Socket : Connection_Id; Request : Http_Request) is
      pragma Unreferenced (This);
      Name   : constant UTF8_String := Sparrow.Http.Requests.Query_Text (Request, "name");
      Joined : Boolean;
   begin
      Arena.Join ((if Name'Length in 1 .. 32 then Name else "Blob"), Socket, Joined);
      if not Joined then
         Sparrow.Http.Streams.Close (Socket);   --  full
      end if;
   end On_Open;

   overriding procedure On_Message
     (This : Players; Socket : Connection_Id; Message : String; Binary : Boolean; Context : Handler_Context)
   is
      pragma Unreferenced (This, Binary, Context);
      Space : Natural := 0;
      X, Y  : Long_Long_Integer;
      Valid : Boolean;
   begin
      if Message = "respawn" then
         Arena.Respawn (Socket);
         return;
      end if;
      for Index in Message'Range loop
         if Message (Index) = ' ' then
            Space := Index;
         end if;
      end loop;
      if Space = 0 then
         return;
      end if;
      Sparrow.Encoding.Parse_Decimal (Message (Message'First .. Space - 1), X, Valid);
      if Valid then
         Sparrow.Encoding.Parse_Decimal (Message (Space + 1 .. Message'Last), Y, Valid);
      end if;
      if Valid and then abs X < 1_000_000 and then abs Y < 1_000_000 then
         Arena.Steer (Socket, Long_Float (X), Long_Float (Y));
      end if;
   end On_Message;

   overriding procedure On_Close (This : Players; Socket : Connection_Id) is
      pragma Unreferenced (This);
   begin
      Arena.Leave (Socket);
   end On_Close;

end Game_Api;
