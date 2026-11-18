--  AWS Signature Version 4, the signing of S3 requests (and of any other AWS API). Sparrow.S3 uses it; it is
--  public for other AWS services and for checking against AWS's published examples.
--
--  Paths and query strings are given encoded (Uri_Encode); headers as "name:value" lines separated by LF, in any
--  order and case.
with Sparrow.Times;

package Sparrow.S3.Signatures is

   --  RFC 3986 percent-encoding as AWS wants it: every byte but A-Z a-z 0-9 - . _ ~ (and '/' when Keep_Slash).
   function Uri_Encode (Text : String; Keep_Slash : Boolean := False) return String;

   --  20130524T000000Z
   function Amz_Date (Time : Times.Unix_Seconds) return String
      with Post => Amz_Date'Result'Length = 16;

   --  The hex SHA-256 of Content, for the x-amz-content-sha256 header.
   function Payload_Hash (Content : String) return String;

   --  "host;range;x-amz-date": the names of Headers, lower case, sorted.
   function Signed_Headers (Headers : String) return String;

   function Canonical_Request
     (Method       : String;
      Path         : String;    --  encoded, from '/'
      Query        : String;    --  encoded name=value pairs joined by '&', in any order; "" for none
      Headers      : String;
      Payload_Hash : String) return String;

   --  The hex signature of Canonical (a canonical request) at Stamp (Amz_Date) for Region and Service.
   function Signature
     (Secret_Key : String;
      Region     : String;
      Service    : String;
      Stamp      : String;
      Canonical  : String) return String
      with Pre => Stamp'Length = 16;

   --  "20130524/us-east-1/s3/aws4_request"
   function Scope (Stamp : String; Region : String; Service : String) return String
      with Pre => Stamp'Length = 16;

end Sparrow.S3.Signatures;
