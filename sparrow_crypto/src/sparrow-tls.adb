--  Sparrow.Tls over OpenSSL 3 (or LibreSSL): libssl and libcrypto, through the handful of calls below.
with Interfaces; use Interfaces;
with Interfaces.C; use Interfaces.C;
package body Sparrow.Tls with SPARK_Mode => Off is


   SSL_FILETYPE_PEM               : constant := 1;
   SSL_VERIFY_NONE                : constant := 0;
   SSL_VERIFY_PEER                : constant := 1;
   SSL_CTRL_MODE                  : constant := 33;
   SSL_CTRL_SET_TLSEXT_HOSTNAME   : constant := 55;
   SSL_CTRL_SET_MIN_PROTO_VERSION : constant := 123;
   SSL_MODE_PARTIAL_WRITE         : constant := 1;   --  a Send may take a prefix
   SSL_MODE_MOVING_WRITE_BUFFER   : constant := 2;   --  a repeated Send need not pass the same address
   SSL_OP_IGNORE_UNEXPECTED_EOF   : constant := 2 ** 7;
   TLS1_2_VERSION                 : constant := 16#0303#;
   TLS1_3_VERSION                 : constant := 16#0304#;
   SSL_ERROR_WANT_READ            : constant := 2;
   SSL_ERROR_WANT_WRITE           : constant := 3;
   SSL_ERROR_ZERO_RETURN          : constant := 6;

   function TLS_Server_Method return System.Address
      with Import, Convention => C, External_Name => "TLS_server_method";
   function TLS_Client_Method return System.Address
      with Import, Convention => C, External_Name => "TLS_client_method";
   function SSL_CTX_New (Method : System.Address) return System.Address
      with Import, Convention => C, External_Name => "SSL_CTX_new";
   procedure SSL_CTX_Free (Context : System.Address)
      with Import, Convention => C, External_Name => "SSL_CTX_free";
   function SSL_CTX_Ctrl (Context : System.Address; Command : int; Number : long; Pointer : System.Address)
                          return long
      with Import, Convention => C, External_Name => "SSL_CTX_ctrl";
   function SSL_CTX_Set_Options (Context : System.Address; Options : Unsigned_64) return Unsigned_64
      with Import, Convention => C, External_Name => "SSL_CTX_set_options";
   function SSL_CTX_Use_Certificate_Chain_File (Context : System.Address; File : char_array) return int
      with Import, Convention => C, External_Name => "SSL_CTX_use_certificate_chain_file";
   function SSL_CTX_Use_Private_Key_File (Context : System.Address; File : char_array; Kind : int) return int
      with Import, Convention => C, External_Name => "SSL_CTX_use_PrivateKey_file";
   function SSL_CTX_Check_Private_Key (Context : System.Address) return int
      with Import, Convention => C, External_Name => "SSL_CTX_check_private_key";
   procedure SSL_CTX_Set_Verify (Context : System.Address; Mode : int; Callback : System.Address)
      with Import, Convention => C, External_Name => "SSL_CTX_set_verify";
   function SSL_CTX_Set_Default_Verify_Paths (Context : System.Address) return int
      with Import, Convention => C, External_Name => "SSL_CTX_set_default_verify_paths";
   function SSL_CTX_Load_Verify_Locations (Context : System.Address; File : char_array; Path : System.Address)
                                           return int
      with Import, Convention => C, External_Name => "SSL_CTX_load_verify_locations";

   function SSL_New (Context : System.Address) return System.Address
      with Import, Convention => C, External_Name => "SSL_new";
   procedure SSL_Free (Session : System.Address)
      with Import, Convention => C, External_Name => "SSL_free";
   function SSL_Set_Fd (Session : System.Address; Socket : int) return int
      with Import, Convention => C, External_Name => "SSL_set_fd";
   procedure SSL_Set_Accept_State (Session : System.Address)
      with Import, Convention => C, External_Name => "SSL_set_accept_state";
   procedure SSL_Set_Connect_State (Session : System.Address)
      with Import, Convention => C, External_Name => "SSL_set_connect_state";
   function SSL_Ctrl (Session : System.Address; Command : int; Number : long; Pointer : System.Address) return long
      with Import, Convention => C, External_Name => "SSL_ctrl";
   function SSL_Set1_Host (Session : System.Address; Name : char_array) return int
      with Import, Convention => C, External_Name => "SSL_set1_host";
   function SSL_Do_Handshake (Session : System.Address) return int
      with Import, Convention => C, External_Name => "SSL_do_handshake";
   function SSL_Read (Session : System.Address; Into : System.Address; Count : int) return int
      with Import, Convention => C, External_Name => "SSL_read";
   function SSL_Write (Session : System.Address; From : System.Address; Count : int) return int
      with Import, Convention => C, External_Name => "SSL_write";
   function SSL_Shutdown (Session : System.Address) return int
      with Import, Convention => C, External_Name => "SSL_shutdown";
   function SSL_Get_Error (Session : System.Address; Returned : int) return int
      with Import, Convention => C, External_Name => "SSL_get_error";
   function SSL_Pending (Session : System.Address) return int
      with Import, Convention => C, External_Name => "SSL_pending";
   function SSL_Version (Session : System.Address) return int
      with Import, Convention => C, External_Name => "SSL_version";

   function ERR_Get_Error return unsigned_long
      with Import, Convention => C, External_Name => "ERR_get_error";
   procedure ERR_Error_String_N (Code : unsigned_long; Into : System.Address; Length : size_t)
      with Import, Convention => C, External_Name => "ERR_error_string_n";
   procedure ERR_Clear_Error
      with Import, Convention => C, External_Name => "ERR_clear_error";

   function Version_Number (Version : Protocol_Version) return long is
     (case Version is when Tls_1_2 => TLS1_2_VERSION, when Tls_1_3 => TLS1_3_VERSION);

   --  A file name fit to hand to C.
   function Usable (File : String) return Boolean is
     (File'Length in 1 .. 4096 and then (for all Symbol of File => Symbol /= ASCII.NUL));

   --  Why the library's last call on this thread failed, behind What; its error queue is emptied.
   procedure Describe (What : String; Into : out Failure_Text; Length : out Natural) is
      Code   : constant unsigned_long := ERR_Get_Error;
      Detail : aliased char_array (0 .. 159) := [others => nul];
   begin
      Into := [others => ' '];
      if Code /= 0 then
         ERR_Error_String_N (Code, Detail'Address, Detail'Length);
      end if;
      ERR_Clear_Error;

      declare
         Text : constant String := What & (if Code = 0 then "" else ": " & To_Ada (Detail));
      begin
         Length             := Natural'Min (Text'Length, Into'Length);
         Into (1 .. Length) := Text (Text'First .. Text'First + Length - 1);
      end;
   end Describe;

   --  What both kinds of context start from; Null_Address with the failure recorded.
   function New_Context (This : in out Context; Method : System.Address; Minimum : Protocol_Version)
                         return System.Address
   is
      Handle  : constant System.Address := SSL_CTX_New (Method);
      Ignored : long;
      Options : Unsigned_64;
   begin
      This.Failure_Length := 0;
      if Handle = System.Null_Address then
         Describe ("cannot create a TLS context", This.Failure, This.Failure_Length);
         return System.Null_Address;
      end if;

      if SSL_CTX_Ctrl (Handle, SSL_CTRL_SET_MIN_PROTO_VERSION, Version_Number (Minimum), System.Null_Address) /= 1
      then
         Describe ("cannot set the minimum TLS version", This.Failure, This.Failure_Length);
         SSL_CTX_Free (Handle);
         return System.Null_Address;
      end if;

      Ignored := SSL_CTX_Ctrl
        (Handle, SSL_CTRL_MODE, SSL_MODE_PARTIAL_WRITE + SSL_MODE_MOVING_WRITE_BUFFER, System.Null_Address);
      --  A peer that closes the socket without close_notify ends the session like one that sends it. HTTP and
      --  the Postgres protocol both frame their messages, so a cut stream cannot pass for a whole one.
      Options := SSL_CTX_Set_Options (Handle, SSL_OP_IGNORE_UNEXPECTED_EOF);
      pragma Unreferenced (Ignored, Options);
      return Handle;
   end New_Context;

   -----------------
   -- Open_Server --
   -----------------

   --  ALPN (RFC 7301): the server's protocols in order of preference, in the extension's form.
   Server_Protocols : aliased constant char_array :=
     [char'Val (2), 'h', '2', char'Val (8), 'h', 't', 't', 'p', '/', '1', '.', '1'];

   SSL_TLSEXT_ERR_OK       : constant := 0;
   SSL_TLSEXT_ERR_NOACK    : constant := 3;
   OPENSSL_NPN_NEGOTIATED  : constant := 1;

   function SSL_Select_Next_Proto
     (Chosen        : access System.Address;
      Chosen_Length : access unsigned_char;
      Server        : System.Address;
      Server_Length : unsigned;
      Client        : System.Address;
      Client_Length : unsigned) return int
      with Import, Convention => C, External_Name => "SSL_select_next_proto";

   type Alpn_Callback is access function
     (Session       : System.Address;
      Chosen        : access System.Address;
      Chosen_Length : access unsigned_char;
      Offered       : System.Address;
      Offered_Length : unsigned;
      Argument      : System.Address) return int
      with Convention => C;

   procedure SSL_CTX_Set_Alpn_Select_Cb (Context : System.Address; Callback : Alpn_Callback; Argument : System.Address)
      with Import, Convention => C, External_Name => "SSL_CTX_set_alpn_select_cb";

   procedure SSL_Get0_Alpn_Selected (Session : System.Address; Data : out System.Address; Length : out unsigned)
      with Import, Convention => C, External_Name => "SSL_get0_alpn_selected";

   --  The first of the server's protocols the client offers; without one, the handshake goes on without ALPN.
   function Select_Protocol
     (Session       : System.Address;
      Chosen        : access System.Address;
      Chosen_Length : access unsigned_char;
      Offered       : System.Address;
      Offered_Length : unsigned;
      Argument      : System.Address) return int
      with Convention => C;

   function Select_Protocol
     (Session       : System.Address;
      Chosen        : access System.Address;
      Chosen_Length : access unsigned_char;
      Offered       : System.Address;
      Offered_Length : unsigned;
      Argument      : System.Address) return int
   is
      pragma Unreferenced (Session, Argument);
   begin
      if SSL_Select_Next_Proto (Chosen, Chosen_Length, Server_Protocols'Address, Server_Protocols'Length, Offered,
                                Offered_Length) = OPENSSL_NPN_NEGOTIATED
      then
         return SSL_TLSEXT_ERR_OK;
      end if;
      return SSL_TLSEXT_ERR_NOACK;
   end Select_Protocol;

   procedure Open_Server
     (This             : in out Context;
      Certificate_File : String;
      Key_File         : String;
      Minimum_Version  : Protocol_Version := Tls_1_2;
      Offer_Http_2     : Boolean := True)
   is
      Handle : System.Address;
   begin
      if not Usable (Certificate_File) or else not Usable (Key_File) then
         Describe ("the certificate and key file names are not usable", This.Failure, This.Failure_Length);
         return;
      end if;

      Handle := New_Context (This, TLS_Server_Method, Minimum_Version);
      if Handle = System.Null_Address then
         return;
      end if;

      if SSL_CTX_Use_Certificate_Chain_File (Handle, To_C (Certificate_File)) /= 1 then
         Describe ("cannot load the certificate " & Certificate_File, This.Failure, This.Failure_Length);
      elsif SSL_CTX_Use_Private_Key_File (Handle, To_C (Key_File), SSL_FILETYPE_PEM) /= 1 then
         Describe ("cannot load the private key " & Key_File, This.Failure, This.Failure_Length);
      elsif SSL_CTX_Check_Private_Key (Handle) /= 1 then
         Describe ("the private key does not match the certificate", This.Failure, This.Failure_Length);
      else
         if Offer_Http_2 then
            SSL_CTX_Set_Alpn_Select_Cb (Handle, Select_Protocol'Access, System.Null_Address);
         end if;
         This.Handle := Handle;
         return;
      end if;

      SSL_CTX_Free (Handle);
   end Open_Server;

   -----------------
   -- Open_Client --
   -----------------

   procedure Open_Client
     (This            : in out Context;
      Verify          : Verification := Full;
      Trust_File      : String := "";
      Minimum_Version : Protocol_Version := Tls_1_2)
   is
      Handle : System.Address;
      Loaded : Boolean;
   begin
      if Trust_File'Length > 0 and then not Usable (Trust_File) then
         Describe ("the trust file name is not usable", This.Failure, This.Failure_Length);
         return;
      end if;

      Handle := New_Context (This, TLS_Client_Method, Minimum_Version);
      if Handle = System.Null_Address then
         return;
      end if;

      if Verify = Nothing then
         SSL_CTX_Set_Verify (Handle, SSL_VERIFY_NONE, System.Null_Address);
      else
         SSL_CTX_Set_Verify (Handle, SSL_VERIFY_PEER, System.Null_Address);
         Loaded := (if Trust_File'Length = 0
                    then SSL_CTX_Set_Default_Verify_Paths (Handle) = 1
                    else SSL_CTX_Load_Verify_Locations (Handle, To_C (Trust_File), System.Null_Address) = 1);
         if not Loaded then
            Describe ("cannot load the trusted roots", This.Failure, This.Failure_Length);
            SSL_CTX_Free (Handle);
            return;
         end if;
      end if;

      This.Verify := Verify;
      This.Handle := Handle;
   end Open_Client;

   -----------
   -- Close --
   -----------

   procedure Close (This : in out Context) is begin
      if This.Handle /= System.Null_Address then
         SSL_CTX_Free (This.Handle);
         This.Handle := System.Null_Address;
      end if;
   end Close;

   ------------------
   -- Last_Failure --
   ------------------

   function Last_Failure (This : Context) return String is (This.Failure (1 .. This.Failure_Length));
   function Last_Failure (This : Session) return String is (This.Failure (1 .. This.Failure_Length));

   --  A new session on Socket, or null with the failure recorded.
   procedure Start (This : in out Session; Using : Context; Socket : Socket_Handle) is
      Handle : constant System.Address := SSL_New (Using.Handle);
   begin
      This.Failure_Length := 0;
      if Handle = System.Null_Address then
         Describe ("cannot create a TLS session", This.Failure, This.Failure_Length);
      elsif Socket not in 0 .. Socket_Handle (int'Last) or else SSL_Set_Fd (Handle, int (Socket)) /= 1 then
         Describe ("cannot attach the TLS session to its socket", This.Failure, This.Failure_Length);
         SSL_Free (Handle);
      else
         This.Handle := Handle;
      end if;
   end Start;

   ------------------
   -- Start_Server --
   ------------------

   procedure Start_Server (This : in out Session; Using : Context; Socket : Socket_Handle) is begin
      Start (This, Using, Socket);
      if This.Handle /= System.Null_Address then
         SSL_Set_Accept_State (This.Handle);
      end if;
   end Start_Server;

   ------------------
   -- Start_Client --
   ------------------

   procedure Start_Client (This : in out Session; Using : Context; Socket : Socket_Handle; Host_Name : String) is
      Named : constant Boolean := Host_Name'Length > 0 and then (for all Symbol of Host_Name => Symbol /= ASCII.NUL);
   begin
      Start (This, Using, Socket);
      if This.Handle = System.Null_Address then
         return;
      end if;

      declare
         Handle : constant System.Address := This.Handle;
         Name   : aliased char_array := To_C (if Named then Host_Name else "");
      begin
         if Using.Verify = Full
           and then (not Named or else SSL_Set1_Host (Handle, Name) /= 1)
         then
            --  Without a name to hold the certificate to, Full cannot be honoured: refuse, never downgrade.
            Describe ("no usable host name to verify the certificate against", This.Failure, This.Failure_Length);
            SSL_Free (Handle);
            This.Handle := System.Null_Address;
            return;
         end if;

         if Named and then SSL_Ctrl (Handle, SSL_CTRL_SET_TLSEXT_HOSTNAME, 0, Name'Address) /= 1 then
            ERR_Clear_Error;   --  no SNI: the server answers with its default certificate
         end if;
         SSL_Set_Connect_State (Handle);
      end;
   end Start_Client;

   --  What a call that returned Returned (<= 0) means.
   procedure Classify (This : in out Session; Returned : int; What : String; Result : out Outcome) is
      Code : constant int := SSL_Get_Error (This.Handle, Returned);
   begin
      case Code is
         when SSL_ERROR_WANT_READ   => Result := Want_Read;
         when SSL_ERROR_WANT_WRITE  => Result := Want_Write;
         when SSL_ERROR_ZERO_RETURN => Result := Closed;
         when others                =>
            Describe (What, This.Failure, This.Failure_Length);
            Result := Failed;
      end case;
      if Result /= Failed then
         ERR_Clear_Error;
      end if;
   end Classify;

   procedure Inactive (This : in out Session; Result : out Outcome) is
      Text : constant String := "the TLS session was never started";
   begin
      This.Failure (1 .. Text'Length) := Text;
      This.Failure_Length             := Text'Length;
      Result                          := Failed;
   end Inactive;

   ---------------
   -- Handshake --
   ---------------

   procedure Handshake (This : in out Session; Result : out Outcome) is
      Returned : int;
   begin
      if This.Handle = System.Null_Address then
         Inactive (This, Result);
         return;
      end if;

      ERR_Clear_Error;
      Returned := SSL_Do_Handshake (This.Handle);
      if Returned = 1 then
         Result := Done;
      else
         Classify (This, Returned, "TLS handshake failed", Result);
      end if;
   end Handshake;

   -------------
   -- Receive --
   -------------

   procedure Receive (This : in out Session; Into : in out String; Count : out Natural; Result : out Outcome) is
      Returned : int;
   begin
      Count := 0;
      if This.Handle = System.Null_Address then
         Inactive (This, Result);
         return;
      end if;

      ERR_Clear_Error;
      Returned := SSL_Read (This.Handle, Into (Into'First)'Address, int (Into'Length));
      if Returned > 0 and then Natural (Returned) <= Into'Length then
         Count  := Natural (Returned);
         Result := Done;
      else
         Classify (This, Returned, "TLS read failed", Result);
      end if;
   end Receive;

   -----------------
   -- Has_Pending --
   -----------------

   function Has_Pending (This : Session) return Boolean is
     (This.Handle /= System.Null_Address and then SSL_Pending (This.Handle) > 0);

   ----------
   -- Send --
   ----------

   procedure Send (This : in out Session; From : String; Count : out Natural; Result : out Outcome) is
      Returned : int;
   begin
      Count := 0;
      if This.Handle = System.Null_Address then
         Inactive (This, Result);
         return;
      end if;

      ERR_Clear_Error;
      Returned := SSL_Write (This.Handle, From (From'First)'Address, int (From'Length));
      if Returned > 0 and then Natural (Returned) <= From'Length then
         Count  := Natural (Returned);
         Result := Done;
      else
         Classify (This, Returned, "TLS write failed", Result);
      end if;
   end Send;

   ---------------
   -- Shut_Down --
   ---------------

   procedure Shut_Down (This : in out Session; Result : out Outcome) is
      Returned : int;
   begin
      if This.Handle = System.Null_Address then
         Inactive (This, Result);
         return;
      end if;

      ERR_Clear_Error;
      Returned := SSL_Shutdown (This.Handle);
      if Returned >= 0 then
         Result := Done;   --  our close_notify is out (0), or theirs has also arrived (1)
      else
         Classify (This, Returned, "TLS shutdown failed", Result);
      end if;
   end Shut_Down;

   ----------
   -- Free --
   ----------

   procedure Free (This : in out Session) is begin
      if This.Handle /= System.Null_Address then
         SSL_Free (This.Handle);
         This.Handle := System.Null_Address;
      end if;
   end Free;

   ------------------------
   -- Negotiated_Version --
   ------------------------

   function Negotiated_Version (This : Session) return Protocol_Version is
     (if SSL_Version (This.Handle) >= TLS1_3_VERSION then Tls_1_3 else Tls_1_2);

   function Negotiated_Protocol (This : Session) return String is
      Data   : System.Address;
      Length : unsigned;
   begin
      SSL_Get0_Alpn_Selected (This.Handle, Data, Length);
      if Data = System.Null_Address or else Length = 0 or else Length > 255 then
         return "";
      end if;
      declare
         Name : String (1 .. Natural (Length)) with Import, Address => Data;
      begin
         return Name;
      end;
   end Negotiated_Protocol;

end Sparrow.Tls;
