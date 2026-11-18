with Sparrow.Logs;

package body Shared_State is

   procedure Cache_Example is
      Cache : Sparrow.Valkey.Connection;
      Hits  : Long_Long_Integer;
   begin
      Sparrow.Valkey.Connect (Cache, Sparrow.Valkey.Server_At (Url));
      Sparrow.Valkey.Set (Cache, "page:/", "<h1>Hello</h1>", Lifetime => 60);
      if Sparrow.Valkey.Get (Cache, "page:/", Default => "") /= "" then
         Hits := Sparrow.Valkey.Increment (Cache, "hits");
         Sparrow.Logs.Info ("cache hit", Sparrow.Logs.Field ("hits", Hits));
      end if;
   end Cache_Example;

end Shared_State;
