import { createServer } from 'node:http';
import { readFileSync, writeFileSync } from 'node:fs';

const audio = readFileSync(process.argv[2]);
let requests = 0;
const server = createServer((request, response) => {
  if (request.url !== '/asset.wav') { response.writeHead(404); response.end(); return; }
  const body = ++requests === 1 ? Buffer.from('invalid audio') : audio;
  response.writeHead(200, { 'Content-Type': 'audio/wav', 'Content-Length': body.length });
  response.end(body);
});
server.listen(0, '127.0.0.1', () => writeFileSync(process.argv[3], String(server.address().port)));
process.on('SIGTERM', () => server.close(() => process.exit(0)));
