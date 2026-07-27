import http from "node:http";

function lastArgument(named) {
  const index = process.argv.lastIndexOf(named);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

const requestedPort = Number(lastArgument("--port")) || 0;
const requestedHost = lastArgument("--host") || "127.0.0.1";

const server = http.createServer((_request, response) => {
  response.writeHead(200, { "content-type": "text/html" });
  response.end("<!doctype html><title>ViewDeck test</title><h1>Native WebKit</h1>");
});

server.on("error", (error) => {
  if (error.code === "EADDRINUSE") {
    console.error(`Port ${requestedPort} is already in use`);
    process.exit(1);
  }
  throw error;
});

server.listen(requestedPort, requestedHost, () => {
  console.log(`\u001b[32mLocal:\u001b[0m http://localhost:\u001b[1m${server.address().port}\u001b[0m/`);
});

process.on("SIGTERM", () => server.close(() => process.exit(0)));
