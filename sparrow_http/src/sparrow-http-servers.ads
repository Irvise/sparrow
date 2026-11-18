--  The server: reactors that own the sockets, workers that run the handlers which may block.
--
--     reactor  an event loop with its own Poller. It accepts, reads, parses, routes, runs On_Reactor
--              handlers itself, and writes responses. A connection has at most one request in flight;
--              pipelined requests wait in its input buffer. Where the system spreads connections over
--              several listeners on one port (Linux) each reactor has its own listener; elsewhere they
--              share one.
--     worker   takes On_Worker requests from one shared queue, runs the handler, and hands the response back
--              to the request's reactor (a queue per reactor and a Waker). A handler that blocks delays only
--              its own worker.
--
--  A response whose client hung up meanwhile is dropped. One server per process.
--
--  With a Sparrow.Tls server context the same server speaks HTTPS: the reactors run each connection's
--  handshake and encryption between socket events, and handlers see no difference.
--
--  The server keeps metrics (Sparrow.Metrics, served by Sparrow.Http.Health): sparrow_http_requests_total and
--  sparrow_http_request_duration_seconds by route, sparrow_http_connections by mode, sparrow_http_queue_depth,
--  and counts of rejected requests, refused connections, dropped slow clients and WebSocket messages. Each
--  request is a span of its trace (Sparrow.Http.Spans).
with Sparrow.Http.Parser;
with Sparrow.Http.Routers;
with Sparrow.IO.Sockets;
with Sparrow.Times;
with Sparrow.Tls;

package Sparrow.Http.Servers is

   type Configuration is record
      Address           : IO.Sockets.IP_Address   := IO.Sockets.Loopback;   --  HOST: "0.0.0.0", "::" (both), ...
      Port              : IO.Sockets.Port_Number  := 8080;
      Reactors          : Natural                 := 0;        --  0: one per processor
      Workers           : Worker_Id               := 8;
      Limits            : Parser.Limits           := Parser.Default_Limits;
      --  Per reactor. An unused slot costs 16 bytes; a connection's record (under 1 KiB, plus its buffers) is
      --  allocated when its slot is first used and kept for the next connection, so memory follows the most
      --  connections open at once. The start-up log line reports both.
      Max_Connections   : Positive                := 16_384;
      Idle_Timeout      : Times.Milliseconds      := 60_000;   --  a connection with no request in flight
      Handshake_Timeout : Times.Milliseconds      := 10_000;   --  a TLS handshake, start to finish
      Queue_Limit       : Positive                := 10_000;   --  requests waiting for a worker; past it, 503
      Catch_Signals     : Boolean                 := True;     --  the system's termination requests stop it
      --  One Sparrow.Logs line per request (method, path, status, bytes, duration, client, request id): info,
      --  or error for 5xx. Query strings are left out: they often carry tokens.
      Access_Log        : Boolean                 := True;
      --  Keep the X-Request-Id and traceparent a request arrives with (see Sparrow.Http.Log). Turn off when
      --  clients reach the server directly and their ids should not be trusted.
      Trust_Trace       : Boolean                 := True;
      --  Behind a reverse proxy: the client's address is the last one in X-Forwarded-For (the one the proxy
      --  added), not the proxy's. Only when every request comes through that proxy.
      Behind_Proxy      : Boolean                 := False;
      --  HTTP/2 over plain TCP for clients that start with its preface ("prior knowledge", as from a proxy or
      --  curl --http2-prior-knowledge). Over TLS, a client gets HTTP/2 when it asks by ALPN and the context offers
      --  it (Tls.Open_Server's Offer_Http_2), whatever this says.
      Http_2            : Boolean                 := True;
      --  gzip for whole responses of text, JSON and the like, when the client takes it (Sparrow.Http.Compression
      --  says which). Off when a proxy in front compresses.
      Compression       : Boolean                 := True;
   end record;

   --  Called on each worker task as it starts and as it stops: the place to open and close what a worker
   --  owns, such as its database connection. An exception from On_Start stops the server from starting.
   type Worker_Hook is access procedure (Worker : Worker_Id);

   type Worker_Hooks is record
      On_Start : Worker_Hook;
      On_Stop  : Worker_Hook;
   end record;

   No_Hooks : constant Worker_Hooks := (null, null);

   Start_Error : exception;   --  the address cannot be bound, or a worker's On_Start failed

   --  Serve Routes until Stop (or a termination request): start the tasks, listen, and return once requests
   --  in flight have been answered and every task has ended. Routes must not change meanwhile.
   --
   --  Security null serves plain HTTP. Otherwise it is an open server context (Sparrow.Tls.Open_Server), and
   --  every connection is TLS; it must stay open until Run returns.
   procedure Run
     (Settings : Configuration;
      Routes   : Routers.Router;
      Hooks    : Worker_Hooks := No_Hooks;
      Security : access constant Tls.Context := null);

   --  Ask a running server to stop; callable from any task, including a handler.
   procedure Stop;

   --  Whether Stop has been called (or a termination request came) and the server is finishing what it has:
   --  Sparrow.Http.Health answers /readyz with 503 meanwhile, so that a load balancer stops sending requests.
   function Is_Stopping return Boolean;

   --  A Configuration from the environment: HOST, PORT, REACTORS, WORKERS, and ACCESS_LOG, TRUST_TRACE,
   --  BEHIND_PROXY, HTTP_2 and COMPRESSION (on/off) override Defaults when set and well-formed.
   function From_Environment (Defaults : Configuration := (others => <>)) return Configuration;

end Sparrow.Http.Servers;
