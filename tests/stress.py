"""Load-test demo_server: many concurrent keep-alive connections, each pipelining requests. Usage:
   python3 stress.py [connections] [requests-per-connection] [tls]"""
import asyncio, ssl, sys, time

HOST, PORT = "127.0.0.1", 18476
CONNECTIONS = int(sys.argv[1]) if len(sys.argv) > 1 else 200
REQUESTS = int(sys.argv[2]) if len(sys.argv) > 2 else 100
TLS = len(sys.argv) > 3 and sys.argv[3] == "tls"

async def read_response(reader):
    head = await reader.readuntil(b"\r\n\r\n")
    length = 0
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":")[1])
    body = await reader.readexactly(length)
    return head.split(b" ")[1], body

async def client(number, context):
    reader, writer = await asyncio.open_connection(HOST, PORT, ssl=context,
                                                   server_hostname="localhost" if context else None)
    bad = 0
    for index in range(0, REQUESTS, 4):   # 4 pipelined requests at a time
        batch = []
        for offset in range(4):
            name = f"c{number}r{index + offset}"
            path = b"/hello" if offset % 2 else f"/who/{name}".encode()
            batch.append((path, name))
            writer.write(b"GET " + path + b" HTTP/1.1\r\nHost: x\r\n\r\n")
        await writer.drain()
        for path, name in batch:
            status, body = await read_response(reader)
            want = b"hello" if path == b"/hello" else f"worker {name}".encode()
            bad += status != b"200" or body != want
    writer.close()
    return bad

async def main():
    context = None
    if TLS:
        context = ssl.create_default_context(cafile="data/cert.pem")
    start = time.time()
    results = await asyncio.gather(*(client(n, context) for n in range(CONNECTIONS)), return_exceptions=True)
    elapsed = time.time() - start
    errors = [r for r in results if isinstance(r, Exception)]
    bad = sum(r for r in results if not isinstance(r, Exception))
    total = CONNECTIONS * REQUESTS
    print(f"{'https' if TLS else 'http'}: {total} requests on {CONNECTIONS} connections in {elapsed:.2f} s "
          f"({total / elapsed:.0f}/s); wrong answers {bad}; failed connections {len(errors)}")
    for error in errors[:3]:
        print("  ", repr(error))
    sys.exit(1 if bad or errors else 0)

asyncio.run(main())
