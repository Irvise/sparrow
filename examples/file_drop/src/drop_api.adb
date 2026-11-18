with Sparrow; use Sparrow;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Directories;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Sparrow.Http.Event_Streams;
with Sparrow.Http.Multipart;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.Http.Streams;
with Sparrow.Json; use Sparrow.Json;
with Sparrow.Json.Builders; use Sparrow.Json.Builders;
with Sparrow.Logs;
with Sparrow.S3;

package body Drop_Api is

   package Requests renames Sparrow.Http.Requests;
   package Responses renames Sparrow.Http.Responses;

   Folder_Path : Unbounded_String;
   Store       : Sparrow.S3.Bucket;
   In_Bucket   : Boolean := False;

   function Key_Of (Name : String) return String is ("drop/" & Name);

   ---------------------------------------------------------------------------------------------------------------
   --  the list of files, shared by every task

   package Size_Maps is new Ada.Containers.Indefinite_Ordered_Maps (String, Long_Long_Integer);

   protected Catalog is
      procedure Add (Name : String; Size : Long_Long_Integer);
      procedure Remove (Name : String);
      function Has (Name : String) return Boolean;
      function Files return Size_Maps.Map;
   private
      Sizes : Size_Maps.Map;
   end Catalog;

   protected body Catalog is
      procedure Add (Name : String; Size : Long_Long_Integer) is begin
         Sizes.Include (Name, Size);
      end Add;
      procedure Remove (Name : String) is begin
         Sizes.Exclude (Name);
      end Remove;
      function Has (Name : String) return Boolean is (Sizes.Contains (Name));
      function Files return Size_Maps.Map is (Sizes);
   end Catalog;

   --  Pages with an event stream open, told when the list changes.
   Watchers : Sparrow.Http.Streams.Group (Capacity => 256);

   procedure Changed is begin
      Sparrow.Http.Event_Streams.Send (Watchers, "", Name => "changed");
   end Changed;

   ---------------------------------------------------------------------------------------------------------------
   --  names

   --  A name safe in a path, a URL and an S3 key, from what the client called the file: letters, digits, '.',
   --  '-' and '_' kept, anything else '_', no leading '.', at most 100 bytes.
   function Safe_Name (Given : String) return String is
      Result : String (1 .. Natural'Min (Given'Length, 100));
   begin
      for Index in Result'Range loop
         declare
            Item : constant Character := Given (Given'First + Index - 1);
         begin
            Result (Index) := (if Item in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '-' | '_' then Item else '_');
         end;
      end loop;
      if Result'Length = 0 then
         return "file";
      elsif Result (1) = '.' then
         Result (1) := '_';
      end if;
      return Result;
   end Safe_Name;

   --  Name, or "2-name", "3-name" ... when it is taken.
   function Free_Name (Name : String) return String is
   begin
      if not Catalog.Has (Name) then
         return Name;
      end if;
      for Count in 2 .. 10_000 loop
         declare
            Image     : constant String := Count'Image;
            Candidate : constant String := Image (Image'First + 1 .. Image'Last) & "-" & Name;
         begin
            if not Catalog.Has (Candidate) then
               return Candidate;
            end if;
         end;
      end loop;
      raise Constraint_Error with "too many files named " & Name;
   end Free_Name;

   ---------------------------------------------------------------------------------------------------------------
   --  set-up

   procedure Use_Folder (Folder : String) is
      use Ada.Directories;
      Search : Search_Type;
      Item   : Directory_Entry_Type;
   begin
      Folder_Path := To_Unbounded_String (Folder);
      Create_Path (Compose (Folder, ".incoming"));
      Start_Search (Search, Folder, "", [Ordinary_File => True, others => False]);
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Item);
         if Simple_Name (Item) = Safe_Name (Simple_Name (Item)) then
            Catalog.Add (Simple_Name (Item), Long_Long_Integer (Size (Item)));
         end if;
      end loop;
      End_Search (Search);
   end Use_Folder;

   procedure Use_Bucket (Bucket : String) is begin
      Store     := Sparrow.S3.Bucket_From_Environment (Bucket);
      In_Bucket := True;
   end Use_Bucket;

   function Uses_Bucket return Boolean is (In_Bucket);

   ---------------------------------------------------------------------------------------------------------------
   --  answers

   procedure Send_Error (Response : in out Http_Response; Status : Status_Code; Message : UTF8_String) is
      Json : Builder (Response.Content'Access);
   begin
      Responses.Begin_Content (Response, Status, Application_Json);
      Json.Begin_Object;
      Json.Member ("error", Message);
      Json.End_Object;
   end Send_Error;

   procedure Send_List (Response : in out Http_Response; Status : Status_Code := OK) is
      Json : Builder (Response.Content'Access);
   begin
      Responses.Begin_Content (Response, Status, Application_Json);
      Json.Begin_Object;
      Json.Member ("mode", (if In_Bucket then "s3" else "local"));
      Json.Key ("files");
      Json.Begin_Array;
      for Position in Catalog.Files.Iterate loop
         Json.Begin_Object;
         Json.Member ("name", UTF8_String (Size_Maps.Key (Position)));
         Json.Member ("size", Size_Maps.Element (Position));
         Json.End_Object;
      end loop;
      Json.End_Array;
      Json.End_Object;
   end Send_List;

   --  Whether a write may go ahead: the header a cross-site form cannot send, and the right mode.
   function Allowed (Request : Http_Request; Response : in out Http_Response; Bucket : Boolean) return Boolean is
   begin
      if Requests.Header (Request, "X-Requested-With") = "" then
         Send_Error (Response, Forbidden, "send X-Requested-With");
         return False;
      elsif Bucket /= In_Bucket then
         Send_Error (Response, Conflict, (if In_Bucket then "uploads go to the bucket: POST /api/uploads"
                                          else "uploads go to the server: POST /api/files"));
         return False;
      end if;
      return True;
   end Allowed;

   ---------------------------------------------------------------------------------------------------------------
   --  routes

   procedure List (Request : Http_Request; Response : in out Http_Response) is
      pragma Unreferenced (Request);
   begin
      Send_List (Response);
   end List;

   procedure Upload (Request : Http_Request; Response : in out Http_Response) is
      Folder : constant String := To_String (Folder_Path);
      Form   : Sparrow.Http.Multipart.Form;
      Valid  : Boolean;
   begin
      if not Allowed (Request, Response, Bucket => False) then
         return;
      end if;
      --  File parts go to .incoming as they arrive, under names Sparrow chooses; then each moves to its own.
      Sparrow.Http.Multipart.Save_Stream
        (Request, Ada.Directories.Compose (Folder, ".incoming"), Form, Valid, Max_Parts => 50);
      if not Valid then
         Send_Error (Response, Bad_Request, "send multipart/form-data with file parts");
         return;
      end if;
      for Index in 1 .. Sparrow.Http.Multipart.Part_Count (Form) loop
         if Sparrow.Http.Multipart.Saved_Path (Form, Index) /= "" then
            declare
               Name : constant String := Free_Name (Safe_Name (Sparrow.Http.Multipart.File_Name (Form, Index)));
            begin
               Ada.Directories.Rename
                 (Sparrow.Http.Multipart.Saved_Path (Form, Index), Ada.Directories.Compose (Folder, Name));
               Catalog.Add (Name, Sparrow.Http.Multipart.Saved_Size (Form, Index));
               Sparrow.Logs.Info ("file stored", Sparrow.Logs.Field ("name", Name),
                                  Sparrow.Logs.Field ("size", Sparrow.Http.Multipart.Saved_Size (Form, Index)));
            end;
         end if;
      end loop;
      Changed;
      Send_List (Response, Created);
   end Upload;

   procedure Presign (Request : Http_Request; Response : in out Http_Response) is
   begin
      if not Allowed (Request, Response, Bucket => True) then
         return;
      end if;
      declare
         Fields : constant Document := Requests.Json_Body (Request);
         Kind   : constant String := String (Text (Fields, "type", Default => "application/octet-stream"));
         Name   : constant String := Free_Name (Safe_Name (String (Text (Fields, "name", Default => ""))));
         Json   : Builder (Response.Content'Access);
      begin
         if not Is_Valid (Fields) or else Kind'Length > 200 then
            Send_Error (Response, Bad_Request, "send {""name"": ..., ""type"": ...}");
            return;
         end if;
         Responses.Begin_Content (Response, OK, Application_Json);
         Json.Begin_Object;
         Json.Member ("name", UTF8_String (Name));
         Json.Member ("url", UTF8_String (Sparrow.S3.Presigned_Put (Store, Key_Of (Name), Media_Type => Kind)));
         Json.End_Object;
      end;
   end Presign;

   procedure Uploaded (Request : Http_Request; Response : in out Http_Response) is
      Name : constant String := Requests.Parameter (Request, "name");
      Size : Long_Long_Integer;
   begin
      if not Allowed (Request, Response, Bucket => True) then
         return;
      elsif Name'Length = 0 or else Name /= Safe_Name (Name) then
         Send_Error (Response, Not_Found, "no such file");
         return;
      end if;
      Size := Sparrow.S3.Size (Store, Key_Of (Name));
      if Size < 0 then
         Send_Error (Response, Not_Found, "the bucket has no such file");
         return;
      end if;
      Catalog.Add (Name, Size);
      Sparrow.Logs.Info ("file stored in the bucket", Sparrow.Logs.Field ("name", Name));
      Changed;
      Send_List (Response, Created);
   end Uploaded;

   procedure Remove (Request : Http_Request; Response : in out Http_Response) is
      Name : constant String := Requests.Parameter (Request, "name");
   begin
      if not Allowed (Request, Response, Bucket => In_Bucket) then
         return;
      elsif not Catalog.Has (Name) then
         Send_Error (Response, Not_Found, "no such file");
         return;
      end if;
      if In_Bucket then
         Sparrow.S3.Delete (Store, Key_Of (Name));
      else
         Ada.Directories.Delete_File (Ada.Directories.Compose (To_String (Folder_Path), Name));
      end if;
      Catalog.Remove (Name);
      Changed;
      Responses.Fail (Response, No_Content);
   end Remove;

   procedure Events (Request : Http_Request; Response : in out Http_Response) is
   begin
      Sparrow.Http.Event_Streams.Begin_Events (Response, Retry => 3_000);
      Sparrow.Http.Streams.Add (Watchers, Requests.Connection (Request));
   end Events;

   procedure Download (Request : Http_Request; Response : in out Http_Response) is
      Name : constant String := Requests.Parameter (Request, "file");
   begin
      if not Catalog.Has (Name) then
         Responses.Fail (Response, Not_Found);
      else
         Responses.Redirect (Response, Sparrow.S3.Presigned_Get (Store, Key_Of (Name), Lifetime => 300));
      end if;
   end Download;

end Drop_Api;
