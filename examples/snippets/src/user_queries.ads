with Sparrow.Postgres; use Sparrow.Postgres;

package User_Queries is
   procedure Open (Db : in out Connection; Url : String);
   procedure Print_User (Db : in out Connection; Email : String);
end User_Queries;
