import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const root = process.cwd();
const mime = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8' };

createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (url.pathname === '/api/session' && req.method === 'POST') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      res.writeHead(201, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ id: crypto.randomUUID(), ...JSON.parse(body || '{}') }));
    });
    return;
  }
  const requested = url.pathname === '/' ? '/index.html' : url.pathname;
  const path = normalize(join(root, 'public', requested));
  if (!path.startsWith(join(root, 'public'))) { res.writeHead(403).end(); return; }
  try {
    const file = await readFile(path);
    res.writeHead(200, { 'content-type': mime[extname(path)] || 'application/octet-stream' });
    res.end(file);
  } catch { res.writeHead(404).end('Not found'); }
}).listen(4173, () => console.log('TARST is listening at http://localhost:4173'));
