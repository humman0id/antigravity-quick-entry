#!/usr/bin/env node
/**
 * Zero-dependency MCP stdio server for Antigravity Quick Entry.
 * Exposes `get_latest_screenshot`, returning the most recent PNG captured by the macOS app.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';

const CACHE_DIR =
  process.env.QUICK_ENTRY_CACHE_DIR ||
  path.join(os.homedir(), 'Library', 'Caches', 'AntigravityQuickEntry');

const LATEST_PNG = path.join(CACHE_DIR, 'latest.png');
const LATEST_META = path.join(CACHE_DIR, 'latest.json');

function send(message) {
  process.stdout.write(JSON.stringify(message) + '\n');
}

function handleGetLatestScreenshot() {
  if (!fs.existsSync(LATEST_PNG)) {
    return {
      isError: true,
      content: [
        {
          type: 'text',
          text: `No screenshot found at ${LATEST_PNG}. Trigger Antigravity Quick Entry (⌥ ⌥) on macOS to capture one first.`
        }
      ]
    };
  }

  const pngBytes = fs.readFileSync(LATEST_PNG);
  let metaSummary = `Captured PNG (${pngBytes.length} bytes)`;
  if (fs.existsSync(LATEST_META)) {
    try {
      const meta = JSON.parse(fs.readFileSync(LATEST_META, 'utf8'));
      metaSummary = [
        `Label: ${meta.label ?? 'Screenshot'}`,
        `Kind: ${meta.kind ?? 'unknown'}`,
        `Dimensions: ${meta.widthPx ?? '?'}x${meta.heightPx ?? '?'} px`,
        meta.appName ? `App: ${meta.appName}` : null,
        meta.capturedAtISO8601 ? `Captured: ${meta.capturedAtISO8601}` : null
      ]
        .filter(Boolean)
        .join(' | ');
    } catch {
      // Ignore malformed metadata JSON
    }
  }

  return {
    content: [
      { type: 'text', text: metaSummary },
      {
        type: 'image',
        data: pngBytes.toString('base64'),
        mimeType: 'image/png'
      }
    ]
  };
}

function handleRequest(req) {
  const { id, method, params } = req;

  // Notifications have no id and require no response
  if (id === undefined || id === null) {
    return;
  }

  switch (method) {
    case 'initialize':
      send({
        jsonrpc: '2.0',
        id,
        result: {
          protocolVersion: '2024-11-05',
          serverInfo: { name: 'quick-capture-mcp', version: '0.1.0' },
          capabilities: { tools: {} }
        }
      });
      return;

    case 'tools/list':
      send({
        jsonrpc: '2.0',
        id,
        result: {
          tools: [
            {
              name: 'get_latest_screenshot',
              description:
                'Returns the most recent screenshot PNG and metadata captured by Antigravity Quick Entry on macOS.',
              inputSchema: {
                type: 'object',
                properties: {},
                additionalProperties: false
              }
            }
          ]
        }
      });
      return;

    case 'tools/call':
      if (params?.name === 'get_latest_screenshot') {
        send({
          jsonrpc: '2.0',
          id,
          result: handleGetLatestScreenshot()
        });
      } else {
        send({
          jsonrpc: '2.0',
          id,
          error: { code: -32601, message: `Unknown tool: ${params?.name}` }
        });
      }
      return;

    default:
      send({
        jsonrpc: '2.0',
        id,
        error: { code: -32601, message: `Method not found: ${method}` }
      });
  }
}

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  try {
    handleRequest(JSON.parse(trimmed));
  } catch (err) {
    send({
      jsonrpc: '2.0',
      id: null,
      error: { code: -32700, message: `Parse error: ${err.message}` }
    });
  }
});
