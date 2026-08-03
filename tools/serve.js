"use strict";
const http = require("http");
const fs = require("fs");
const path = require("path");
const root = process.argv[2] || ".";
const port = Number(process.argv[3] || 8931);
http.createServer((req, res) => {
  const rel = req.url === "/" ? "index.html" : decodeURIComponent(req.url.slice(1));
  const file = path.join(root, rel);
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); res.end("not found"); return; }
    res.writeHead(200, { "content-type": "text/html" });
    res.end(data);
  });
}).listen(port, "127.0.0.1", () => console.log(`serving ${root} on ${port}`));
