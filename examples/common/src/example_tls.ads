--  HTTPS for the examples. With CERT_FILE and KEY_FILE set (PEM files; ./make_cert.sh makes a pair for
--  localhost), Security is a server context that offers HTTP/2 and HTTP/1.1 by ALPN, so browsers speak HTTP/2.
--  Without them it is null and the examples serve plain HTTP, where HTTP/2 needs a client that starts with it
--  (curl --http2-prior-knowledge).
--
--     Sparrow.Http.Servers.Run (Sparrow.Http.Servers.From_Environment, Routes, Security => Example_Tls.Security);
with Sparrow.Tls;

package Example_Tls is

   --  Raises Program_Error, saying why, when the files cannot be used.
   function Security return access constant Sparrow.Tls.Context;

end Example_Tls;
