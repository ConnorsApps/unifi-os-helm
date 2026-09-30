// Stands in for uos-discovery-client, a stub binary in the extracted image.
// unifi-core polls its port (11002) every few seconds and logs
// "Failed to fetch network interfaces" / "ECONNREFUSED 127.0.0.1:11002" without it.
//   GET /scan       → [] (no UDP broadcast domain in a pod)
//   GET <anything>  → os.networkInterfaces(), the shape unifi-core validates
//   HEAD /, /healthz → 200
const http = require("http");
const os = require("os");

const PORT = Number(process.env.DISCOVERY_SHIM_PORT || 11002);
const HOST = process.env.DISCOVERY_SHIM_HOST || "0.0.0.0";

function writeJson(res, statusCode, body) {
  res.statusCode = statusCode;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(body));
}

const server = http.createServer((req, res) => {
  const method = req.method || "GET";
  const url = req.url || "/";

  if (method === "HEAD" && (url === "/" || url === "/healthz")) {
    res.statusCode = 200;
    return res.end();
  }
  if (url.startsWith("/scan")) return writeJson(res, 200, []);
  if (method === "GET") return writeJson(res, 200, os.networkInterfaces());
  return writeJson(res, 404, {});
});

server.listen(PORT, HOST, () => {
  console.log(`discovery-shim listening on ${HOST}:${PORT}`);
});
