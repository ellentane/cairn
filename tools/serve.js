"use strict";
const http = require("http");
const fs = require("fs");
const path = require("path");
const root = process.argv[2] || ".";
const port = Number(process.argv[3] || 8931);
http.createServer((req, res) => {
  let rel;
  try { rel = req.url === "/" ? "index.html" : decodeURIComponent(req.url.slice(1)); }
  catch (e) { res.writeHead(400); res.end("bad request"); return; }
  const rootResolved = path.resolve(root);
  const file = path.resolve(rootResolved, rel);
  if (!file.startsWith(rootResolved + path.sep) && file !== rootResolved) {
    res.writeHead(403); res.end("forbidden"); return;
  }
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); res.end("not found"); return; }
    res.writeHead(200, { "content-type": "text/html" });
    res.end(data);
  });
}).listen(port, "127.0.0.1", () => console.log(`serving ${root} on ${port}`));
