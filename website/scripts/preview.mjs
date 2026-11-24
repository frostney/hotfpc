// Serves the static export in out/ under the basePath, as GitHub Pages will
// (https://frostney.github.io/hotfpc/). The export's pages ask for /hotfpc/..., so a server
// that hands out out/ from the root would 404. No dependencies.
//
//   npm run build && npm run start     # http://localhost:3000/hotfpc/
//
// PORT and HOST change where it listens; BASE_PATH must match next.config.mjs.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.join(here, '..', 'out');
const basePath = process.env.BASE_PATH ?? '/hotfpc';
const port = Number(process.env.PORT ?? 3000);
const host = process.env.HOST ?? 'localhost';

const contentTypes = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.gif': 'image/gif',
  '.mp4': 'video/mp4',
  '.cast': 'application/x-asciicast',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
};

if (!fs.existsSync(outDir)) {
  console.error(`no out/ at ${outDir}: run "npm run build" first`);
  process.exit(1);
}

// The file for a path inside the export: a route is a directory with index.html in it.
function resolveFile(urlPath) {
  let clean;
  try {
    clean = decodeURIComponent(urlPath);
  } catch {
    return null;
  }
  const abs = path.normalize(path.join(outDir, clean));
  if (abs !== outDir && !abs.startsWith(outDir + path.sep)) return null;
  const candidates = path.extname(abs)
    ? [abs]
    : [path.join(abs, 'index.html'), abs + '.html', abs];
  return candidates.find((file) => fs.existsSync(file) && fs.statSync(file).isFile()) ?? null;
}

const server = http.createServer((req, res) => {
  const reqPath = (req.url ?? '/').split('?')[0];
  if (reqPath === '/' || reqPath === '') {
    res.writeHead(302, { Location: `${basePath}/` });
    res.end();
    return;
  }
  if (reqPath !== basePath && !reqPath.startsWith(basePath + '/')) {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end(`Not found. The site is at ${basePath}/`);
    return;
  }
  const file = resolveFile(reqPath.slice(basePath.length) || '/');
  if (!file) {
    const notFound = path.join(outDir, '404.html');
    res.writeHead(404, { 'Content-Type': 'text/html; charset=utf-8' });
    if (fs.existsSync(notFound)) fs.createReadStream(notFound).pipe(res);
    else res.end('Not found');
    return;
  }
  res.writeHead(200, {
    'Content-Type': contentTypes[path.extname(file)] ?? 'application/octet-stream',
  });
  fs.createReadStream(file).pipe(res);
});

server.listen(port, host, () => {
  console.log(`serving out/ at http://${host}:${port}${basePath}/`);
});
