--  Rate limits: a token bucket per client (or per API key, user, ...). A client may send Burst requests at once,
--  then Rate a second; past that, a limited route answers 429 Too Many Requests with Retry-After.
--
--     Logins : constant Limits.Limit := Limits.Per_Client (Rate => 0.2, Burst => 5);   --  one every 5 s
--     ...
--     Routers.Add (Routes, Post, "/login", Limits.Wrap (Logins, Log_In'Access));
--
--  Build a limit at start-up and share it: every route it wraps draws from the same buckets. By default the
--  buckets live in memory, in this process: behind a load balancer each server counts on its own. A bucket left
--  alone long enough to fill up again is forgotten, so memory follows the clients seen lately. To count across
--  servers, give the limit a shared Store, such as sparrow_valkey's:
--
--     Logins : constant Limits.Limit :=
--       Limits.Per_Client (0.2, 5, Store => Valkey.Limits.Buckets (Environment ("VALKEY_URL"), Name => "logins"));
with Sparrow.Http.Routers; use Sparrow.Http.Routers;
with Sparrow.Stores;

private with Ada.Containers.Indefinite_Hashed_Maps;
private with Ada.Real_Time;
private with Ada.Strings.Hash;

package Sparrow.Http.Limits is

   type Limit is private;

   --  Where a limit's buckets live: see Sparrow.Stores, where the interface is declared so that a store
   --  (sparrow_valkey's, say) need not depend on this crate.
   subtype Bucket_Store is Stores.Bucket_Store;
   subtype Bucket_Store_Access is Stores.Bucket_Store_Access;

   --  Buckets in this process's memory, at most Max_Keys of them: past it, buckets that have filled up are
   --  forgotten, then the least recently used.
   type Memory_Buckets (Max_Keys : Positive) is limited new Bucket_Store with private;
   overriding procedure Take
     (This        : in out Memory_Buckets;
      Key         : String;
      Rate        : Long_Float;
      Burst       : Positive;
      Allowed     : out Boolean;
      Retry_After : out Natural);

   --  What a bucket is for: the request's text key ("" means no limit for this request).
   type Key_Function is access function (Request : Http_Request) return String;

   --  Rate: tokens a second (0.5: one every two seconds); Burst: the bucket's size. Store: where the buckets
   --  live; null for new Memory_Buckets of Max_Keys. A store shared by two limits mixes their buckets: give each
   --  limit its own.
   function Per_Key
     (Rate     : Long_Float;
      Burst    : Positive;
      Key      : not null Key_Function;
      Max_Keys : Positive := 100_000;
      Store    : Bucket_Store_Access := null) return Limit
     with Pre => Rate > 0.0;

   --  By the client's address (Requests.Client_Address, which honours Servers.Behind_Proxy).
   function Per_Client
     (Rate     : Long_Float;
      Burst    : Positive;
      Max_Keys : Positive := 100_000;
      Store    : Bucket_Store_Access := null) return Limit
     with Pre => Rate > 0.0;

   --  Take a token from Key's bucket. When it is empty, Allowed is False and Retry_After is the seconds until
   --  one is back.
   procedure Take (This : Limit; Key : String; Allowed : out Boolean; Retry_After : out Natural);

   --  Take a token for Request; when there is none, answer 429 with Retry-After.
   procedure Check (This : Limit; Request : Http_Request; Response : in out Http_Response; Allowed : out Boolean);

   --  Check, then Action when allowed.
   type Limited_Route is new Route_Handler with private;
   overriding procedure Handle (This : Limited_Route; Request : Http_Request; Response : in out Http_Response);
   function Wrap (This : Limit; Action : not null Handler) return Limited_Route;
   function Wrap (This : Limit; Action : Route_Handler'Class) return Limited_Route;

private

   type Bucket is record
      Tokens  : Long_Float;
      Updated : Ada.Real_Time.Time;
   end record;

   package Bucket_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Bucket, Hash => Ada.Strings.Hash, Equivalent_Keys => "=");

   --  One of a limit's shards: keys hash to one, so clients rarely wait for one another.
   protected type Shard is
      procedure Take
        (Key         : String;
         Rate        : Long_Float;
         Burst       : Positive;
         Max_Keys    : Natural;
         Allowed     : out Boolean;
         Retry_After : out Natural);
   private
      Buckets : Bucket_Maps.Map;
   end Shard;

   Shard_Count : constant := 16;
   type Shard_Array is array (0 .. Shard_Count - 1) of Shard;

   type Memory_Buckets (Max_Keys : Positive) is limited new Bucket_Store with record
      Shards : Shard_Array;
   end record;

   type Limit is record
      Rate  : Long_Float := 1.0;
      Burst : Positive := 1;
      Key   : Key_Function;
      Store : Bucket_Store_Access;
   end record;

   type Route_Handler_Holder is access constant Route_Handler'Class;

   type Limited_Route is new Route_Handler with record
      Rule             : Limit;
      Procedure_Action : Handler;               --  one of the two
      Object_Action    : Route_Handler_Holder;
   end record;

end Sparrow.Http.Limits;
