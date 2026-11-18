with Ada.Calendar.Formatting;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Sparrow.Encoding;
with Sparrow.S3.Signatures; use Sparrow.S3.Signatures;
with Sparrow.Times;

package body Sparrow.S3 is

   Service : constant String := "s3";

   Unix_Epoch : constant Ada.Calendar.Time := Ada.Calendar.Formatting.Time_Of (1970, 1, 1, Time_Zone => 0);

   function Now return Times.Unix_Seconds is
      use type Ada.Calendar.Time;
   begin
      return Times.Unix_Seconds (Ada.Calendar.Clock - Unix_Epoch);
   end Now;

   function Ends_With (Text, Suffix : String) return Boolean is
     (Text'Length >= Suffix'Length and then Text (Text'Last - Suffix'Length + 1 .. Text'Last) = Suffix);

   function Bucket_At
     (Endpoint      : String;
      Region        : String;
      Name          : String;
      Access_Key    : String;
      Secret_Key    : String;
      Session_Token : String := "";
      Using         : Client.Settings := Client.Default_Settings) return Bucket
   is
      Scheme_End : constant Natural := Ada.Strings.Fixed.Index (Endpoint, "://");
      Rest       : constant String :=
        (if Scheme_End = 0 then "" else Endpoint (Scheme_End + 3 .. Endpoint'Last));
      Slash      : constant Natural := Ada.Strings.Fixed.Index (Rest, "/");
      Host       : constant String := (if Slash = 0 then Rest else Rest (Rest'First .. Slash - 1));
      Scheme     : constant String := (if Scheme_End = 0 then "" else Endpoint (Endpoint'First .. Scheme_End + 2));
      Virtual    : constant Boolean := Ends_With (Host, ".amazonaws.com");
      Port_Colon : constant Natural := Ada.Strings.Fixed.Index (Host, ":", Ada.Strings.Backward);
      Plain_Host : constant String :=   --  without a port that is the scheme's anyway
        (if Port_Colon > 0
           and then ((Scheme = "https://" and then Host (Port_Colon .. Host'Last) = ":443")
                     or else (Scheme = "http://" and then Host (Port_Colon .. Host'Last) = ":80"))
         then Host (Host'First .. Port_Colon - 1) else Host);
   begin
      if Scheme not in "https://" | "http://" or else Host = "" then
         raise Constraint_Error with "an S3 endpoint is an http:// or https:// URL";
      elsif Access_Key = "" or else Secret_Key = "" then
         raise Constraint_Error with "S3 needs an access key and a secret key";
      end if;
      return
        (Scheme        => To_Unbounded_String (Scheme),
         Host          => To_Unbounded_String (if Virtual then Name & "." & Plain_Host else Plain_Host),
         Base_Path     => To_Unbounded_String (if Virtual then "" else "/" & Name),
         Region        => To_Unbounded_String (Region),
         Access_Key    => To_Unbounded_String (Access_Key),
         Secret_Key    => To_Unbounded_String (Secret_Key),
         Session_Token => To_Unbounded_String (Session_Token),
         Using         => Using);
   end Bucket_At;

   function Bucket_From_Environment (Name : String) return Bucket is
      function Variable (Name : String; Default : String := "") return String is
        (Ada.Environment_Variables.Value (Name, Default));
      Region   : constant String := Variable ("AWS_REGION", Default => "us-east-1");
      Endpoint : constant String :=
        Variable ("AWS_ENDPOINT_URL_S3",
                  Default => Variable ("AWS_ENDPOINT_URL", Default => "https://s3." & Region & ".amazonaws.com"));
   begin
      return Bucket_At (Endpoint, Region, Name, Variable ("AWS_ACCESS_KEY_ID"), Variable ("AWS_SECRET_ACCESS_KEY"),
                        Session_Token => Variable ("AWS_SESSION_TOKEN"));
   end Bucket_From_Environment;

   --  The encoded path of Key.
   function Path_Of (Where : Bucket; Key : String) return String is
     (To_String (Where.Base_Path) & "/" & Uri_Encode (Key, Keep_Slash => True));

   --  "Code: Message" of an S3 error document, or the status when it has none.
   function Error_Of (Answer : Client.Response) return String is
      Body_Text : constant String := Client.Content (Answer);

      function Element (Name : String) return String is
         First : constant Natural := Ada.Strings.Fixed.Index (Body_Text, "<" & Name & ">");
         Last  : constant Natural := Ada.Strings.Fixed.Index (Body_Text, "</" & Name & ">");
      begin
         if First = 0 or else Last < First then
            return "";
         end if;
         return Body_Text (First + Name'Length + 2 .. Last - 1);
      end Element;

      Code : constant String := Element ("Code");
   begin
      if Code = "" then
         return "HTTP" & Natural'Image (Client.Status (Answer));
      end if;
      return Code & ": " & Element ("Message");
   end Error_Of;

   --  Send a signed request; Answer holds the store's answer, whatever its status.
   procedure Send
     (Where      : Bucket;
      Method     : String;
      Key        : String;
      Answer     : out Client.Response;
      Content    : String := "";
      Media_Type : String := "")
   is
      Stamp   : constant String := Amz_Date (Now);
      Hash    : constant String := Payload_Hash (Content);
      Path    : constant String := Path_Of (Where, Key);
      Token   : constant String := To_String (Where.Session_Token);
      Headers : constant String :=
        "host:" & To_String (Where.Host) & ASCII.LF
        & (if Media_Type = "" then "" else "content-type:" & Media_Type & ASCII.LF)
        & "x-amz-content-sha256:" & Hash & ASCII.LF
        & "x-amz-date:" & Stamp
        & (if Token = "" then "" else ASCII.LF & "x-amz-security-token:" & Token);
      Signed  : constant String :=
        Signature (To_String (Where.Secret_Key), To_String (Where.Region), Service, Stamp,
                   Canonical_Request (Method, Path, "", Headers, Hash));
      Sent    : constant String :=   --  what the client adds of its own: all but host and content-type
        "x-amz-content-sha256: " & Hash & ASCII.LF & "x-amz-date: " & Stamp & ASCII.LF
        & (if Token = "" then "" else "x-amz-security-token: " & Token & ASCII.LF)
        & "Authorization: AWS4-HMAC-SHA256 Credential=" & To_String (Where.Access_Key) & "/"
        & Scope (Stamp, To_String (Where.Region), Service)
        & ", SignedHeaders=" & Signed_Headers (Headers) & ", Signature=" & Signed;
   begin
      Client.Send (Method, To_String (Where.Scheme) & To_String (Where.Host) & Path, Answer,
                   Content    => Content,
                   Media_Type => (if Media_Type = "" then "application/octet-stream" else Media_Type),
                   Headers    => Sent,
                   Using      => Where.Using);
   end Send;

   procedure Put
     (Where      : Bucket;
      Key        : String;
      Content    : String;
      Media_Type : String := "application/octet-stream")
   is
      Answer : Client.Response;
   begin
      Send (Where, "PUT", Key, Answer, Content, Media_Type);
      if Client.Status (Answer) not in 200 .. 299 then
         raise S3_Error with Error_Of (Answer);
      end if;
   end Put;

   function Get (Where : Bucket; Key : String) return String is
      Answer : Client.Response;
   begin
      Send (Where, "GET", Key, Answer);
      if Client.Status (Answer) /= 200 then
         raise S3_Error with Error_Of (Answer);
      end if;
      return Client.Content (Answer);
   end Get;

   function Exists (Where : Bucket; Key : String) return Boolean is
      Answer : Client.Response;
   begin
      Send (Where, "HEAD", Key, Answer);
      case Client.Status (Answer) is
         when 200 => return True;
         when 404 => return False;
         when others => raise S3_Error with Error_Of (Answer);
      end case;
   end Exists;

   function Size (Where : Bucket; Key : String) return Long_Long_Integer is
      Answer : Client.Response;
      Value  : Long_Long_Integer;
      Valid  : Boolean;
   begin
      Send (Where, "HEAD", Key, Answer);
      case Client.Status (Answer) is
         when 200 =>
            Encoding.Parse_Decimal (Client.Header (Answer, "Content-Length"), Value, Valid);
            if not Valid or else Value < 0 then
               raise S3_Error with "HEAD " & Key & ": no Content-Length";
            end if;
            return Value;
         when 404 => return -1;
         when others => raise S3_Error with Error_Of (Answer);
      end case;
   end Size;

   procedure Delete (Where : Bucket; Key : String) is
      Answer : Client.Response;
   begin
      Send (Where, "DELETE", Key, Answer);
      if Client.Status (Answer) not in 200 .. 299 then
         raise S3_Error with Error_Of (Answer);
      end if;
   end Delete;

   --  A URL for Method on Key, signed in its query (the host, and Content-Type when Media_Type is given).
   function Presigned (Where : Bucket; Method : String; Key : String; Media_Type : String; Lifetime : Positive)
      return String
   is
      Stamp   : constant String := Amz_Date (Now);
      Path    : constant String := Path_Of (Where, Key);
      Token   : constant String := To_String (Where.Session_Token);
      Headers : constant String :=
        "host:" & To_String (Where.Host) & (if Media_Type = "" then "" else ASCII.LF & "content-type:" & Media_Type);
      Query   : constant String :=
        "X-Amz-Algorithm=AWS4-HMAC-SHA256"
        & "&X-Amz-Credential="
        & Uri_Encode (To_String (Where.Access_Key) & "/" & Scope (Stamp, To_String (Where.Region), Service))
        & "&X-Amz-Date=" & Stamp
        & "&X-Amz-Expires=" & Ada.Strings.Fixed.Trim (Lifetime'Image, Ada.Strings.Left)
        & (if Token = "" then "" else "&X-Amz-Security-Token=" & Uri_Encode (Token))
        & "&X-Amz-SignedHeaders=" & Uri_Encode (Signed_Headers (Headers));
      Signed  : constant String :=
        Signature (To_String (Where.Secret_Key), To_String (Where.Region), Service, Stamp,
                   Canonical_Request (Method, Path, Query, Headers, "UNSIGNED-PAYLOAD"));
   begin
      return To_String (Where.Scheme) & To_String (Where.Host) & Path & "?" & Query & "&X-Amz-Signature=" & Signed;
   end Presigned;

   function Presigned_Get (Where : Bucket; Key : String; Lifetime : Positive := 900) return String is
     (Presigned (Where, "GET", Key, "", Lifetime));

   function Presigned_Put
     (Where : Bucket; Key : String; Media_Type : String := ""; Lifetime : Positive := 900) return String
   is
     (Presigned (Where, "PUT", Key, Media_Type, Lifetime));

end Sparrow.S3;
