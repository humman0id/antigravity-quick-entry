import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SERVER_PATH = path.join(__dirname, 'index.mjs');

function startServer(cacheDir) {
  const child = spawn(process.execPath, [SERVER_PATH], {
    env: { ...process.env, QUICK_ENTRY_CACHE_DIR: cacheDir },
    stdio: ['pipe', 'pipe', 'pipe']
  });
  const rl = readline.createInterface({ input: child.stdout });
  const queue = [];
  const waiters = [];

  rl.on('line', (line) => {
    const parsed = JSON.parse(line);
    if (waiters.length > 0) {
      waiters.shift()(parsed);
    } else {
      queue.push(parsed);
    }
  });

  function sendAndRead(payload) {
    return new Promise((resolve) => {
      if (queue.length > 0) {
        resolve(queue.shift());
      } else {
        waiters.push(resolve);
      }
      child.stdin.write(JSON.stringify(payload) + '\n');
    });
  }

  return { child, sendAndRead };
}

test('MCP server handles initialize, tools/list, missing file, and valid screenshot capture', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'aqe-mcp-test-'));
  const { child, sendAndRead } = startServer(tmpDir);

  try {
    const initRes = await sendAndRead({
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {}
    });
    assert.equal(initRes.result.serverInfo.name, 'quick-capture-mcp');

    const listRes = await sendAndRead({
      jsonrpc: '2.0',
      id: 2,
      method: 'tools/list',
      params: {}
    });
    assert.equal(listRes.result.tools.length, 1);
    assert.equal(listRes.result.tools[0].name, 'get_latest_screenshot');

    // Missing screenshot returns graceful error content
    const missingRes = await sendAndRead({
      jsonrpc: '2.0',
      id: 3,
      method: 'tools/call',
      params: { name: 'get_latest_screenshot', arguments: {} }
    });
    assert.equal(missingRes.result.isError, true);

    // Write fake PNG + metadata and re-test
    const fakePng = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    fs.writeFileSync(path.join(tmpDir, 'latest.png'), fakePng);
    fs.writeFileSync(
      path.join(tmpDir, 'latest.json'),
      JSON.stringify({
        label: 'Chrome — Dashboard',
        kind: 'window',
        widthPx: 1280,
        heightPx: 800,
        appName: 'Google Chrome'
      })
    );

    const okRes = await sendAndRead({
      jsonrpc: '2.0',
      id: 4,
      method: 'tools/call',
      params: { name: 'get_latest_screenshot', arguments: {} }
    });
    assert.equal(okRes.result.isError, undefined);
    assert.equal(okRes.result.content.length, 2);
    assert.match(okRes.result.content[0].text, /Chrome — Dashboard/);
    assert.equal(okRes.result.content[1].type, 'image');
    assert.equal(okRes.result.content[1].mimeType, 'image/png');
    assert.equal(okRes.result.content[1].data, fakePng.toString('base64'));
  } finally {
    child.kill();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
