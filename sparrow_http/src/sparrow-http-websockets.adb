with Ada.Strings.Fixed;
with Sparrow.Base64;
with Sparrow.Crypto.Hashes;
with Sparrow.Encoding;
with Sparrow.Http.Delivery;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;

package body Sparrow.Http.Websockets is

   Handshake_Guid : constant String := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

   function Accept_Key (Key : String) return String is
     (Base64.Encode (Crypto.Hashes.Hash (Crypto.Sha1, Key & Handshake_Guid)));

   --  Whether the comma-separated list Value holds Token, ignoring case and spaces.
   function Has_Token (Value, Token : String) return Boolean is
      Start : Positive := Value'First;
   begin
      for Index in Value'First .. Value'Last + 1 loop
         if Index > Value'Last or else Value (Index) = ',' then
            if Encoding.Equal_Ignoring_Case
                 (Ada.Strings.Fixed.Trim (Value (Start .. Index - 1), Ada.Strings.Both), Token)
            then
               return True;
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return False;
   end Has_Token;

   function Origin_Allowed (Origin, Host, Allowed : String) return Boolean is
      Marker : constant Natural := Ada.Strings.Fixed.Index (Origin, "://");
   begin
      if Origin'Length = 0 or else Allowed = "*" then
         return True;
      elsif Allowed'Length = 0 then
         return Marker > 0 and then Encoding.Equal_Ignoring_Case (Origin (Marker + 3 .. Origin'Last), Host);
      end if;
      --  A space-separated list of whole origins.
      declare
         Start : Positive := Allowed'First;
      begin
         for Index in Allowed'First .. Allowed'Last + 1 loop
            if Index > Allowed'Last or else Allowed (Index) = ' ' then
               if Index > Start and then Encoding.Equal_Ignoring_Case (Allowed (Start .. Index - 1), Origin) then
                  return True;
               end if;
               Start := Index + 1;
            end if;
         end loop;
      end;
      return False;
   end Origin_Allowed;

   --  What the server calls, passed on to the application's endpoint.
   type Forwarder is new Delivery.Endpoint_Handlers with record
      Target : Endpoint_Access;
   end record;
   overriding procedure On_Message
     (This : Forwarder; Socket : Connection_Id; Message : String; Binary : Boolean; Context : Handler_Context);
   overriding procedure On_Close (This : Forwarder; Socket : Connection_Id);

   overriding procedure On_Message
     (This : Forwarder; Socket : Connection_Id; Message : String; Binary : Boolean; Context : Handler_Context)
   is begin
      This.Target.On_Message (Socket, Message, Binary, Context);
   end On_Message;

   overriding procedure On_Close (This : Forwarder; Socket : Connection_Id) is begin
      This.Target.On_Close (Socket);
   end On_Close;

   function Serve
     (Handlers        : not null Endpoint_Access;
      Run             : Placement := On_Worker;
      Max_Message     : Positive := 1_048_576;
      Allowed_Origins : String := "") return Upgrade
   is
      Number : constant Positive :=
        Delivery.Register ((Handlers => new Forwarder'(Target => Handlers), Run => Run, Max_Message => Max_Message));
   begin
      return (Handlers => Handlers, Number => Number, Allowed_Origins => new String'(Allowed_Origins));
   end Serve;

   overriding procedure Handle (This : Upgrade; Request : Http_Request; Response : in out Http_Response) is
      Key : constant String := Requests.Header (Request, "Sec-WebSocket-Key");
   begin
      if not Has_Token (Requests.Header (Request, "Upgrade"), "websocket")
        or else not Has_Token (Requests.Header (Request, "Connection"), "upgrade")
        or else Key'Length /= 24
      then
         Responses.Send (Response, Bad_Request, "A WebSocket handshake was expected.");
         return;
      elsif Requests.Header (Request, "Sec-WebSocket-Version") /= "13" then
         Responses.Set_Header (Response, "Sec-WebSocket-Version", "13");
         Responses.Fail (Response, Upgrade_Required);
         return;
      elsif not Origin_Allowed (Requests.Header (Request, "Origin"), Requests.Header (Request, "Host"),
                                This.Allowed_Origins.all)
      then
         Responses.Fail (Response, Forbidden);
         return;
      end if;

      Responses.Clear (Response);
      Response.Status   := Switching_Protocols;
      Response.Mode     := Responses.Upgrade;
      Response.Endpoint := This.Number;
      Responses.Set_Header (Response, "Upgrade", "websocket");
      Responses.Set_Header (Response, "Connection", "Upgrade");
      Responses.Set_Header (Response, "Sec-WebSocket-Accept", Accept_Key (Key));
      This.Handlers.On_Open (Requests.Connection (Request), Request);
   end Handle;

end Sparrow.Http.Websockets;
