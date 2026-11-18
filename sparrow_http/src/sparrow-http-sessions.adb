with Sparrow.Base64;
with Sparrow.Http.Session_Envelope;
with Sparrow.Crypto.Key_Derivation;
with Sparrow.Crypto.Random;
with Sparrow.Encoding;
with Sparrow.IO.Process;
with Sparrow.Times;

package body Sparrow.Http.Sessions is

   use type Stores.Session_Table_Access;

   package Envelope renames Sparrow.Http.Session_Envelope;

   use type Value_Maps.Cursor;

   Max_Cookie : constant := 4000;   --  bytes of the cookie's value

   function Image_Of (Value : Natural) return String is (Encoding.Decimal_Image (Long_Long_Integer (Value)));

   function New_Token return String is
      Token : String (1 .. 24);
      Last  : Natural;
   begin
      Crypto.Random.Token (18, Token, Last);
      return Token (1 .. Last);
   end New_Token;

   function Get (This : Session; Name : String; Default : UTF8_String := "") return UTF8_String is
      Position : constant Value_Maps.Cursor := This.Values.Find (Name);
   begin
      return (if Position = Value_Maps.No_Element then Default else UTF8_String (Value_Maps.Element (Position)));
   end Get;

   function Has (This : Session; Name : String) return Boolean is (This.Values.Contains (Name));

   procedure Set (This : in out Session; Name : String; Value : UTF8_String) is begin
      if not This.Values.Contains (Name) or else This.Values.Element (Name) /= String (Value) then
         This.Values.Include (Name, String (Value));
         This.Changed := True;
      end if;
   end Set;

   procedure Remove (This : in out Session; Name : String) is begin
      if This.Values.Contains (Name) then
         This.Values.Delete (Name);
         This.Changed := True;
      end if;
   end Remove;

   procedure Renew (This : in out Session) is begin
      This.Token   := New_Token;
      This.Changed := True;
      if This.Has_Id then   --  a new id when saved; the old one is deleted then
         if not This.Drop_Old then
            This.Old_Id   := This.Id;
            This.Drop_Old := True;
         end if;
         This.Has_Id := False;
      end if;
   end Renew;

   procedure Clear (This : in out Session) is begin
      This.Values.Clear;
      Renew (This);
   end Clear;

   Generation_Name : constant String := "sparrow.generation";

   procedure Set_Generation (This : in out Session; Generation : Natural) is begin
      Set (This, Generation_Name, UTF8_String (Image_Of (Generation)));
   end Set_Generation;

   function Generation (This : Session) return Natural is
      Text  : constant String := String (Get (This, Generation_Name, "0"));
      Value : Long_Long_Integer;
      Done  : Boolean;
   begin
      Encoding.Parse_Decimal (Text, Value, Done);
      return (if Done and then Value in 0 .. Long_Long_Integer (Natural'Last) then Natural (Value) else 0);
   end Generation;

   procedure Check_Generation (This : in out Session; Current : Natural) is begin
      if Generation (This) /= Current then
         Clear (This);
      end if;
   end Check_Generation;

   function Csrf_Token (This : Session) return String is (This.Token);

   function Csrf_Field (This : Session) return String is
     ("<input type=""hidden"" name=""csrf_token"" value=""" & This.Token & """>");

   function Csrf_Valid (This : Session; Request : Requests.Request) return Boolean is
      Sent : constant String :=
        (if Requests.Has_Header (Request, "X-CSRF-Token") then Requests.Header (Request, "X-CSRF-Token")
         else Requests.Form_Value (Request, "csrf_token"));
   begin
      return Sent'Length = This.Token'Length and then Crypto.Constant_Time_Equal (Sent, This.Token);
   end Csrf_Valid;

   function Random_Secret return String is
      Secret : String (1 .. 32);
   begin
      Crypto.Random.Fill (Secret);
      return Secret;
   end Random_Secret;

   ---------------------------------------------------------------------------------------------------------------
   --  The sealed text: issued time, token, then each value as "length:name length:value".

   function Image (Value : Natural) return String is (Encoding.Decimal_Image (Long_Long_Integer (Value)));

   function Serialize (This : Session) return String is
      function Each (Position : Value_Maps.Cursor) return String is
        (if Position = Value_Maps.No_Element then ""
         else Image (Value_Maps.Key (Position)'Length) & ":" & Value_Maps.Key (Position)
              & Image (Value_Maps.Element (Position)'Length) & ":" & Value_Maps.Element (Position)
              & Each (Value_Maps.Next (Position)));
   begin
      return Encoding.Decimal_Image (This.Issued) & ASCII.LF & This.Token & Each (This.Values.First);
   end Serialize;

   procedure Deserialize (Text : String; Into : out Session; Valid : out Boolean) is
      Token    : Encoding.Span;
      Position : Positive;
   begin
      Into  := (others => <>);
      Valid := False;
      if Text'Length = 0 or else Text'Last > Envelope.Max_Index then
         return;
      end if;
      Envelope.Read_Head (Text, Into.Issued, Token, Position, Valid);
      if not Valid then
         return;
      end if;
      Into.Token := Encoding.Slice (Text, Token);
      while Position <= Text'Last loop
         declare
            Name, Value : Encoding.Span;
         begin
            Envelope.Read_Field (Text, Position, Name, Valid);
            if Valid then
               if Position > Text'Last then
                  Valid := False;   --  a name without its value
               else
                  Envelope.Read_Field (Text, Position, Value, Valid);
               end if;
            end if;
            if not Valid then
               Into := (others => <>);
               return;
            end if;
            Into.Values.Include (Encoding.Slice (Text, Name), Encoding.Slice (Text, Value));
         end;
      end loop;
      Into.Changed := False;
      Valid := True;
   end Deserialize;

   function Clock return Long_Long_Integer is
      Now : Times.Unix_Seconds;
   begin
      IO.Process.Read_Clock (Now);
      return Long_Long_Integer (Now);
   end Clock;

   function Key_Of (Secret, Cookie_Name : String) return Crypto.Ciphers.Key_Bytes is
     (Crypto.Key_Derivation.Hkdf (Crypto.Sha256, Secret, Salt => "", Info => "sparrow session " & Cookie_Name,
                                  Length => 32));

   function Cookie_Store
     (Secret          : String;
      Cookie_Name     : String := "session";
      Max_Age         : Positive := 14 * 24 * 60 * 60;
      Secure          : Boolean := True;
      Same_Site       : Responses.Same_Site_Policy := Responses.Lax;
      Previous_Secret : String := "") return Store
   is begin
      if Secret'Length < 32 or else Previous_Secret'Length in 1 .. 31 then
         raise Program_Error with "a session secret needs at least 32 bytes";
      end if;
      return (Key         => Key_Of (Secret, Cookie_Name),
              Old_Key     => (if Previous_Secret = "" then [others => ASCII.NUL]
                              else Key_Of (Previous_Secret, Cookie_Name)),
              Has_Old_Key => Previous_Secret /= "",
              Table       => null,
              Cookie_Name => new String'(Cookie_Name),
              Max_Age     => Max_Age,
              Secure      => Secure,
              Same_Site   => Same_Site);
   end Cookie_Store;

   function Table_Store
     (Table       : not null Session_Table_Access;
      Cookie_Name : String := "session";
      Max_Age     : Positive := 14 * 24 * 60 * 60;
      Secure      : Boolean := True;
      Same_Site   : Responses.Same_Site_Policy := Responses.Lax) return Store
   is
     ((Key         => [others => ASCII.NUL],
       Old_Key     => [others => ASCII.NUL],
       Has_Old_Key => False,
       Table       => Table,
       Cookie_Name => new String'(Cookie_Name),
       Max_Age     => Max_Age,
       Secure      => Secure,
       Same_Site   => Same_Site));

   procedure Revoke_User (This : Store; User : String) is begin
      if This.Table = null then
         raise Program_Error with "a cookie session cannot be revoked from the server: use Set_Generation";
      end if;
      This.Table.Delete_User (User);
   end Revoke_User;

   function New_Id return Session_Id is
      Bytes : String (1 .. 32);
   begin
      Crypto.Random.Fill (Bytes);
      return Base64.Encode (Bytes, Base64.Url_Safe);
   end New_Id;

   function Fresh return Session is
   begin
      return Result : Session do
         Result.Token   := New_Token;
         Result.Changed := True;
      end return;
   end Fresh;

   --  A table's session: the cookie is its id.
   function Load_From_Table (This : Store; Request : Requests.Request) return Session is
      Id : constant String := Requests.Cookie (Request, This.Cookie_Name.all);
   begin
      if Id'Length /= Session_Id'Length then
         return Fresh;
      end if;
      declare
         Data  : constant String := This.Table.Read (Id);
         Found : Session;
         Valid : Boolean;
      begin
         if Data = "" then
            return Fresh;
         end if;
         Deserialize (Data, Found, Valid);
         if not Valid or else Clock - Found.Issued > Long_Long_Integer (This.Max_Age) then
            return Fresh;
         end if;
         Found.Id     := Id;
         Found.Has_Id := True;
         return Found;
      end;
   end Load_From_Table;

   function Load (This : Store; Request : Requests.Request) return Session is
      Text   : constant String := Requests.Cookie (Request, This.Cookie_Name.all);
      Bytes  : String (1 .. Base64.Decoded_Length (Text'Length));
      Last   : Natural;
      Valid  : Boolean;
   begin
      if This.Table /= null then
         return Load_From_Table (This, Request);
      elsif Text'Length = 0 or else Text'Length > Max_Cookie then
         return Fresh;
      end if;
      Base64.Decode (Text, Bytes, Last, Valid, Base64.Url_Safe);
      if not Valid or else Last < 12 + Crypto.Ciphers.Tag_Length then
         return Fresh;
      end if;
      declare
         Plain        : String (1 .. Last - 12 - Crypto.Ciphers.Tag_Length);
         Used         : Natural;
         Found        : Session;
         Old_Key_Used : Boolean := False;
      begin
         Crypto.Ciphers.Open (Crypto.Ciphers.Aes_256_Gcm, This.Key, Bytes (1 .. 12), Bytes (13 .. Last), Plain,
                              Used, Valid, Associated => This.Cookie_Name.all);
         if not Valid and then This.Has_Old_Key then   --  sealed before the secret changed
            Crypto.Ciphers.Open (Crypto.Ciphers.Aes_256_Gcm, This.Old_Key, Bytes (1 .. 12), Bytes (13 .. Last),
                                 Plain, Used, Valid, Associated => This.Cookie_Name.all);
            Old_Key_Used := Valid;
         end if;
         if Valid then
            Deserialize (Plain (1 .. Used), Found, Valid);
            Found.Changed := Old_Key_Used;   --  sealed again under the new secret when saved
         end if;
         if not Valid or else Clock - Found.Issued > Long_Long_Integer (This.Max_Age)
           or else Found.Issued > Clock + 300
         then
            return Fresh;
         end if;
         return Found;
      end;
   end Load;

   procedure Save (This : Store; Item : in out Session; Response : in out Responses.Response) is
      Now : constant Long_Long_Integer := Clock;
   begin
      if not Item.Changed and then Now - Item.Issued < Long_Long_Integer (This.Max_Age / 2) then
         return;
      end if;
      Item.Issued := Now;
      if This.Table /= null then
         if Item.Drop_Old then
            This.Table.Delete (Item.Old_Id);
            Item.Drop_Old := False;
         end if;
         if not Item.Has_Id then
            Item.Id     := New_Id;
            Item.Has_Id := True;
         end if;
         This.Table.Write (Item.Id, String (Get (Item, "user")), Serialize (Item),
                           Expires => Now + Long_Long_Integer (This.Max_Age));
         Responses.Set_Cookie (Response, This.Cookie_Name.all, Item.Id, Max_Age => This.Max_Age,
                               Secure => This.Secure, Same_Site => This.Same_Site);
         Item.Changed := False;
         return;
      end if;
      declare
         Nonce : Crypto.Ciphers.Nonce_Bytes;
      begin
         Crypto.Random.Fill (Nonce);
         declare
            Value : constant String :=
              Base64.Encode (Nonce & Crypto.Ciphers.Seal (Crypto.Ciphers.Aes_256_Gcm, This.Key, Nonce,
                                                         Serialize (Item), Associated => This.Cookie_Name.all),
                             Base64.Url_Safe);
         begin
            if Value'Length > Max_Cookie then
               raise Too_Large with "the session's cookie would be" & Value'Length'Image & " bytes";
            end if;
            Responses.Set_Cookie (Response, This.Cookie_Name.all, Value, Max_Age => This.Max_Age,
                                  Secure => This.Secure, Same_Site => This.Same_Site);
         end;
      end;
      Item.Changed := False;
   end Save;

   ---------------------------------------------------------------------------------------------------------------
   --  Memory_Table

   protected body Guarded_Sessions is

      function Read (Id : String; Now : Long_Long_Integer) return String is
         Position : constant Saved_Maps.Cursor := Sessions.Find (Id);
      begin
         if not Saved_Maps.Has_Element (Position) or else Saved_Maps.Element (Position).Expires < Now then
            return "";
         end if;
         return Saved_Maps.Element (Position).Data;
      end Read;

      procedure Write (Id : String; Item : Saved; Now : Long_Long_Integer) is begin
         Sessions.Include (Id, Item);
         Writes := Writes + 1;
         if Writes >= 1024 then   --  now and then, forget the expired ones
            Writes := 0;
            declare
               Next : Saved_Maps.Cursor := Sessions.First;
               Here : Saved_Maps.Cursor;
            begin
               while Saved_Maps.Has_Element (Next) loop
                  Here := Next;
                  Next := Saved_Maps.Next (Next);
                  if Saved_Maps.Element (Here).Expires < Now then
                     Sessions.Delete (Here);
                  end if;
               end loop;
            end;
         end if;
      end Write;

      procedure Delete (Id : String) is begin
         Sessions.Exclude (Id);
      end Delete;

      procedure Delete_User (User : String) is
         Next : Saved_Maps.Cursor := Sessions.First;
         Here : Saved_Maps.Cursor;
      begin
         while Saved_Maps.Has_Element (Next) loop
            Here := Next;
            Next := Saved_Maps.Next (Next);
            if Saved_Maps.Element (Here).User = User then
               Sessions.Delete (Here);
            end if;
         end loop;
      end Delete_User;

      function Count return Natural is (Natural (Sessions.Length));

   end Guarded_Sessions;

   overriding function Read (This : Memory_Table; Id : String) return String is (This.Guard.Read (Id, Clock));

   overriding procedure Write
     (This : in out Memory_Table; Id : String; User : String; Data : String; Expires : Long_Long_Integer)
   is begin
      This.Guard.Write (Id, (User_Length => User'Length, Data_Length => Data'Length, User => User, Data => Data,
                             Expires => Expires), Clock);
   end Write;

   overriding procedure Delete (This : in out Memory_Table; Id : String) is begin
      This.Guard.Delete (Id);
   end Delete;

   overriding procedure Delete_User (This : in out Memory_Table; User : String) is begin
      if User /= "" then
         This.Guard.Delete_User (User);
      end if;
   end Delete_User;

   function Count (This : Memory_Table) return Natural is (This.Guard.Count);

end Sparrow.Http.Sessions;
