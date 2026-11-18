--  Shared state a server keeps outside its own memory, as interfaces: sessions and rate-limit buckets. They live
--  here, below every other crate, so that a store (sparrow_valkey's, or one over your database) and the code that
--  uses it (Sparrow.Http.Sessions and Sparrow.Http.Limits) need not depend on each other.
--
--  Each is called from several tasks at once: an implementation must be safe for that.
package Sparrow.Stores is

   ------------------------------------------------------------------------------------------------------------------
   --  Where sessions live, for Http.Sessions.Table_Store. Implement it over your database: one table of id, user,
   --  data and expiry, indexed by id and by user.
   type Session_Table is limited interface;

   --  The data written under Id, or "" when there is none or it has expired.
   function Read (This : Session_Table; Id : String) return String is abstract;

   --  Keep Data under Id until Expires (Unix seconds), replacing what was there. User: the session's "user"
   --  value ("" before login), so that Delete_User can find it.
   procedure Write
     (This    : in out Session_Table;
      Id      : String;
      User    : String;
      Data    : String;
      Expires : Long_Long_Integer) is abstract;

   procedure Delete (This : in out Session_Table; Id : String) is abstract;
   procedure Delete_User (This : in out Session_Table; User : String) is abstract;   --  every session of User

   type Session_Table_Access is access all Session_Table'Class;

   ------------------------------------------------------------------------------------------------------------------
   --  Where a rate limit's buckets live, for Http.Limits. Take takes a token from Key's bucket, which holds Burst
   --  tokens at most and gains Rate a second; when it is empty, Allowed is False and Retry_After is the seconds
   --  until one is back.
   type Bucket_Store is limited interface;

   procedure Take
     (This        : in out Bucket_Store;
      Key         : String;
      Rate        : Long_Float;
      Burst       : Positive;
      Allowed     : out Boolean;
      Retry_After : out Natural) is abstract;

   type Bucket_Store_Access is access all Bucket_Store'Class;

end Sparrow.Stores;
