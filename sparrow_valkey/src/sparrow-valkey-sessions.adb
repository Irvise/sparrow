with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body Sparrow.Valkey.Sessions is

   --  Every session id of a user's set, deleted with the set: one round trip, and atomic.
   Delete_User_Script : constant String :=
     "local ids = redis.call('SMEMBERS', KEYS[1]) "
     & "for _, id in ipairs(ids) do redis.call('DEL', ARGV[1] .. id) end "
     & "redis.call('DEL', KEYS[1]) return #ids";

   function Table
     (Url         : String;
      Prefix      : String := "sparrow:";
      Connections : Positive := 8;
      Trust_File  : String := "") return Stores.Session_Table_Access
   is
     (new Valkey_Table'(Links  => Pools.New_Pool (Server_At (Url, Trust_File => Trust_File), Connections),
                        Prefix => To_Unbounded_String (Prefix)));

   function Session_Key (This : Valkey_Table'Class; Id : String) return String is
     (To_String (This.Prefix) & "session:" & Id);

   function User_Key (This : Valkey_Table'Class; User : String) return String is
     (To_String (This.Prefix) & "user:" & User);

   overriding function Read (This : Valkey_Table; Id : String) return String is
      Result : Unbounded_String;

      procedure Action (Link : in out Connection) is
      begin
         Result := To_Unbounded_String (Get (Link, Session_Key (This, Id)));
      end Action;
   begin
      Pools.With_Connection (This.Links, Action'Access);
      return To_String (Result);
   end Read;

   overriding procedure Write
     (This : in out Valkey_Table; Id : String; User : String; Data : String; Expires : Long_Long_Integer)
   is
      Ends : constant Long_Long_Integer := Long_Long_Integer'Max (Expires, 1);

      procedure Action (Link : in out Connection) is
      begin
         Start (Link, "SET"); Add (Link, Session_Key (This, Id)); Add (Link, Data);
         Add (Link, "EXAT"); Add (Link, Ends);
         if User /= "" then
            --  The user's set lives as long as their last session: give it an end when it has none (NX),
            --  and move that end later (GT).
            Start (Link, "SADD"); Add (Link, User_Key (This, User)); Add (Link, Id);
            Start (Link, "EXPIREAT"); Add (Link, User_Key (This, User)); Add (Link, Ends); Add (Link, "NX");
            Start (Link, "EXPIREAT"); Add (Link, User_Key (This, User)); Add (Link, Ends); Add (Link, "GT");
         end if;
         Pools.Read_Replies (Link);
      end Action;
   begin
      Pools.With_Connection (This.Links, Action'Access);
   end Write;

   overriding procedure Delete (This : in out Valkey_Table; Id : String) is
      procedure Action (Link : in out Connection) is
      begin
         Delete (Link, Session_Key (This, Id));
      end Action;
   begin
      Pools.With_Connection (This.Links, Action'Access);
   end Delete;

   overriding procedure Delete_User (This : in out Valkey_Table; User : String) is
      procedure Action (Link : in out Connection) is
      begin
         Start (Link, "EVAL"); Add (Link, Delete_User_Script); Add (Link, 1);
         Add (Link, User_Key (This, User)); Add (Link, Session_Key (This, ""));
         Pools.Read_Replies (Link);
      end Action;
   begin
      Pools.With_Connection (This.Links, Action'Access);
   end Delete_User;

end Sparrow.Valkey.Sessions;
