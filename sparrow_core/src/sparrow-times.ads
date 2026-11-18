--  Time as the stack carries it (plain integers, no time zones) and the two text formats the web needs.

package Sparrow.Times with SPARK_Mode is

   --  Wall-clock time, UTC, since 1970-01-01.
   type Unix_Seconds is new Long_Long_Integer;
   type Unix_Microseconds is new Long_Long_Integer;

   --  A monotonic clock reading, or a duration.
   type Milliseconds is new Long_Long_Integer;

   function To_Seconds (Time : Unix_Microseconds) return Unix_Seconds;
   function To_Microseconds (Time : Unix_Seconds) return Unix_Microseconds
      with Pre => Time in -(10 ** 12) .. 10 ** 12;

   --  RFC 3339 with milliseconds, truncated: 2025-04-01T12:00:00.000Z. Years outside 0 .. 9999 keep their last
   --  four digits.
   subtype Rfc3339_Text is String (1 .. 24);
   function Rfc3339 (Time : Unix_Microseconds) return Rfc3339_Text;

   --  The reverse, for the forms Rfc3339 writes and the same with a numeric offset or without a fraction.
   procedure Parse_Rfc3339 (Source : String; Time : out Unix_Microseconds; Valid : out Boolean)
      with Post => (if not Valid then Time = 0);

   --  The HTTP date (RFC 9110 IMF-fixdate): Sun, 06 Nov 1994 08:49:37 GMT.
   subtype Http_Date_Text is String (1 .. 29);
   function Http_Date (Time : Unix_Seconds) return Http_Date_Text;

end Sparrow.Times;
