import http from 'node:http';
import { deflateSync, gzipSync } from 'node:zlib';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { setTimeout } from 'node:timers/promises';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Only synthetic simulator data reaches this process. Never proxy to a server.
const requests = [];
let registered = false;
let mapAvailable = false;
let mapLoads = 0;
// The AR storm view's data: one synthetic storm south of Munich, boxed as the data service
// boxes storms since 2026-10-05 -- by zoom-10 map tile, two tiles sharing a
// system, each with a one-voxel apron -- a tracked cell standing in it, its
// track, and a few strikes. All made up here.
const STORM = { lat: 47.9, lon: 11.6 };
const SCAN = '20261004T020500';
const CELL_CODE = '2026100402050000012345';
const ZOOM = 10;
const ACROSS = 104;
const APRON = 1;

function tileOf(lat, lon) {
  const n = 2 ** ZOOM;
  const x = Math.floor((lon + 180) / 360 * n);
  const r = lat * Math.PI / 180;
  const y = Math.floor((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2 * n);
  return { x, y };
}
function tileCentre(x, y) {
  const n = 2 ** ZOOM;
  const lon = (x + 0.5) / n * 360 - 180;
  const lat = Math.atan(Math.sinh(Math.PI * (1 - 2 * (y + 0.5) / n))) * 180 / Math.PI;
  return { lat, lon };
}
const PEAK = tileOf(STORM.lat, STORM.lon);
const code = (x, y) => `T${String(ZOOM).padStart(2, '0')}${String(x).padStart(5, '0')}${String(y).padStart(5, '0')}`;
const SYSTEM = code(PEAK.x, PEAK.y);
// The peak's tile and its eastern neighbour, which holds the storm's flank.
const TILES = [PEAK, { x: PEAK.x + 1, y: PEAK.y }].map(({ x, y }, index) => ({
  x, y, code: code(x, y), centre: tileCentre(x, y), peak: index === 0 ? 52 : 38,
  path: `meteoradar/volumes/${SCAN}/de-${code(x, y)}.mcvx`,
}));
const VOLUME_PATH = TILES[0].path;

/** One tile of the storm: a leaning column of echo, 52 dBZ at its core in the peak's tile. */
function syntheticVolume(tile) {
  const nx = ACROSS + 2 * APRON, ny = nx, nz = 32;
  const step = 2 * Math.PI * 6371008.8 * Math.cos(tile.centre.lat * Math.PI / 180) / 2 ** ZOOM / ACROSS;
  const half = step * nx / 2;
  const header = Buffer.from(JSON.stringify({
    code: tile.code, reference_time: '2026-10-04T02:05:00+00:00', lon: tile.centre.lon, lat: tile.centre.lat,
    nx, ny, nz, step_m: [step, step, 500], origin_m: [-half, -half, 0], tile: [ZOOM, tile.x, tile.y], apron: [APRON, APRON, 0],
    dbz_floor: -32, dbz_scale: 2, sites: ['deisn'], coverage: 1, network: 'de', tier: 2,
    scanned_at: new Date(Date.now() - 4 * 60000).toISOString(), oldest_scan_at: null,
  }));
  // The storm's own centre, in metres east and north of this tile's centre.
  const east = (STORM.lon - tile.centre.lon) * 111320 * Math.cos(STORM.lat * Math.PI / 180);
  const north = (STORM.lat - tile.centre.lat) * 110570;
  const voxels = Buffer.alloc(nx * ny * nz * 2);
  for (let z = 0; z < nz; z++) {
    const h = z * 0.5;
    const lean = z * 0.25; // the core leans east with height, in km
    for (let y = 0; y < ny; y++) {
      for (let x = 0; x < nx; x++) {
        const ex = ((x + 0.5) * step - half - east) / 1000 - lean, ny_ = ((y + 0.5) * step - half - north) / 1000;
        const r = Math.hypot(ex, ny_);
        const dbz = h < 11 ? 52 - 1.4 * r - (h > 7 ? (h - 7) * 4 : 0) : -20;
        const i = ((z * ny + y) * nx + x) * 2;
        voxels[i] = Math.max(0, Math.min(255, Math.round((dbz + 32) * 2)));
        voxels[i + 1] = h < 14 ? 255 : 0;
      }
    }
  }
  const prefix = Buffer.alloc(12);
  prefix.write('MCVX', 0, 'ascii');
  prefix.writeUInt32LE(1, 4);
  prefix.writeUInt32LE(header.length, 8);
  return gzipSync(Buffer.concat([prefix, header, voxels]));
}

function mercator(lat, lon) {
  const r = 6378137;
  return { lon: lon * Math.PI / 180 * r, lat: r * Math.log(Math.tan(Math.PI / 4 + lat * Math.PI / 360)) };
}

function stormData(path) {
  if (path === '/cells/volumes') {
    return { reference_time: '2026-10-04T02:05:00Z', volumes: TILES.map((tile) => ({
      code: tile.code, network: 'de', lon: tile.centre.lon, lat: tile.centre.lat, path: tile.path, tier: 2,
      tile: [ZOOM, tile.x, tile.y], system: SYSTEM, coarse: false,
      peak_dbz: tile.peak, area_km2: 90, coverage: 1, seed_dbz: 25, reference_time: '2026-10-04T02:05:00Z',
      scanned_at: new Date(Date.now() - 4 * 60000).toISOString(),
    })) };
  }
  if (path === '/cells/current') {
    return { reference_time: '2026-10-04T02:05:00Z', cells: [{
      code: CELL_CODE, identifier: 7, t: '2026-10-04T02:05:00Z', lon: STORM.lon, lat: STORM.lat,
      severity: 2, max_dbz: 52, echo_top_m: 11000, heading_deg: 60, speed_kmh: 40,
      hail_flag: 1, lightning_rate: 12, forecast: [
        { t: '2026-10-04T02:20:00Z', lon: STORM.lon + 0.12, lat: STORM.lat + 0.05, major_km: 3, minor_km: 2, angle_deg: 60 },
        { t: '2026-10-04T02:35:00Z', lon: STORM.lon + 0.24, lat: STORM.lat + 0.1, major_km: 5, minor_km: 3, angle_deg: 60 },
      ],
      volume: { path: VOLUME_PATH, coverage: 1, tier: 2 },
    }] };
  }
  if (path.startsWith('/cells/tracks')) {
    return { type: 'FeatureCollection', reference_time: '2026-10-04T02:05:00Z', features: [{
      type: 'Feature',
      geometry: { type: 'LineString', coordinates: [[STORM.lon - 0.3, STORM.lat - 0.12], [STORM.lon - 0.15, STORM.lat - 0.06], [STORM.lon, STORM.lat]] },
      properties: { code: CELL_CODE, active: true,
        placement: { place: 'Holzkirchen', kind: 'town', distance_km: 3, direction: 'W', bearing_deg: 270 } },
    }] };
  }
  if (path === '/lightning_cache') {
    return [0, 20, 50, 120].map((ago, i) => ({ ...mercator(STORM.lat + 0.02 * i, STORM.lon + 0.03), time: Date.now() - ago * 1000 }));
  }
  if (path === '/mesocyclones/all/') return [];
  return null;
}

// The rain Live Activity's inputs: the bar chart at the user's location --
// rain arriving in 15 minutes, peaking at 38 dBZ, over within the hour --
// and a radar image, both made up here.
function rainTimeseries() {
  const now = Math.floor(Date.now() / 300000) * 300;
  const frames = {};
  for (let step = -24; step <= 24; step++) {
    const lead = step * 5;
    const dbz = lead < 15 ? -32.5 : lead > 70 ? -32.5 : Math.round(2 * (38 - Math.abs(lead - 40) * 0.9)) / 2;
    frames[now + step * 300] = step > 22 ? null : {
      dbz, source: step <= 0 ? 'observation' : 'nowcast_phys', tile_id: 'fixture', processed_time: now, filename: 'fixture',
    };
  }
  return { server_time: now, frames };
}

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
function crc32(buffer) {
  let c = 0xffffffff;
  for (const byte of buffer) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
/** A 256 px square "radar image": a map-grey ground with a storm west of the centre. */
function radarPreview() {
  const side = 256;
  const rows = [];
  for (let y = 0; y < side; y++) {
    const row = Buffer.alloc(1 + side * 3);
    for (let x = 0; x < side; x++) {
      const r = Math.hypot(x - 90, (y - 120) * 1.4);
      const [red, green, blue] = r < 18 ? [255, 167, 0] : r < 40 ? [15, 195, 22] : r < 62 ? [96, 179, 212] : [214, 219, 222];
      row.set([red, green, blue], 1 + x * 3);
    }
    rows.push(row);
  }
  const chunk = (type, data) => {
    const length = Buffer.alloc(4);
    length.writeUInt32BE(data.length);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(Buffer.concat([Buffer.from(type, 'ascii'), data])));
    return Buffer.concat([length, Buffer.from(type, 'ascii'), data, crc]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(side, 0);
  header.writeUInt32BE(side, 4);
  header.set([8, 2, 0, 0, 0], 8);
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header), chunk('IDAT', deflateSync(Buffer.concat(rows))), chunk('IEND', Buffer.alloc(0))]);
}

http.createServer(async (request, response) => {
  response.setHeader('Content-Type', 'application/json');
  const path = request.url.split('?')[0];
  const tile = request.method === 'GET' ? TILES.find((candidate) => path === `/${candidate.path}`) : undefined;
  if (tile) {
    response.setHeader('Content-Type', 'application/octet-stream');
    response.setHeader('Content-Encoding', 'gzip');
    response.end(syntheticVolume(tile));
    return;
  }
  if (request.method === 'GET' && path === '/v3/radar/timeseries') {
    response.end(JSON.stringify(rainTimeseries()));
    return;
  }
  if (request.method === 'GET' && path === '/v3/preview/og.png') {
    response.setHeader('Content-Type', 'image/png');
    response.end(radarPreview());
    return;
  }
  const storms = request.method === 'GET' ? stormData(path) : null;
  if (storms) {
    response.end(JSON.stringify(storms));
    return;
  }
  // XCTest screen captures wait for a gesture to finish. Read the simulator
  // framebuffer independently so a UI test can inspect a held-down drag.
  if (request.url === '/slider-drag-screenshot' || request.url === '/slider-screenshot') {
    const scratch = await mkdtemp(join(tmpdir(), 'meteocool-slider-'));
    try {
      if (request.url === '/slider-drag-screenshot') await setTimeout(3000);
      const path = join(scratch, 'screen.png');
      await promisify(execFile)('xcrun', ['simctl', 'io', process.env.MC_TEST_SIMULATOR ?? 'booted', 'screenshot', '--type=png', path], {
        env: { ...process.env, DEVELOPER_DIR: process.env.DEVELOPER_DIR ?? '/Applications/Xcode.app/Contents/Developer' },
      });
      response.setHeader('Content-Type', 'image/png');
      response.end(await readFile(path));
    } catch {
      response.writeHead(500).end('{"success":false}');
    } finally {
      await rm(scratch, { recursive: true, force: true });
    }
    return;
  }
  if (request.url === '/map/fail' || request.url === '/map/recover') {
    mapAvailable = request.url === '/map/recover';
    response.end('{"success":true}');
    return;
  }
  if (request.url.split('?')[0] === '/ios.html') {
    if (!mapAvailable) { response.destroy(); return; }
    mapLoads += 1;
    response.setHeader('Content-Type', 'text/html');
    response.end(`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Map recovery fixture</title>
      <p>Map connection restored</p><p id="settings"></p><p id="map">map=satellite</p><p id="link"></p>
      <p id="caps"></p>
      <!-- Clear of the native buttons over the page's top corners. -->
      <div style="margin-top:200px">
        <button id="share" style="width:200px;height:60px">Share view</button>
        <button id="elsewhere" style="width:200px;height:60px">Share elsewhere</button>
      </div>
      <script>
        // What core's lib/share.ts asks of the app: shown when the app says it can share,
        // sent as share:{...} with the button's place, and a link back to this host only.
        document.getElementById("caps").textContent = "share=" + (window.nativeCapabilities?.share === true);
        const link = { url: location.origin + "/?layer=radar&latLonZ=47.80000,11.70000,8.00&shared=20261006T1234Z", title: "Fixture view · meteocool" };
        window.shareLink = () => link;
        const send = (share, button) => {
          const rect = button.getBoundingClientRect();
          webkit.messageHandlers.scriptHandler.postMessage("share:" + JSON.stringify({ ...share, x: rect.x, y: rect.y, width: rect.width, height: rect.height }));
        };
        document.getElementById("share").addEventListener("click", (event) => send(link, event.currentTarget));
        document.getElementById("elsewhere").addEventListener("click", (event) =>
          send({ url: "https://example.invalid/?layer=radar", title: "Elsewhere" }, event.currentTarget));
        window.addEventListener("popstate", () => {
          document.getElementById("link").textContent = "link=" + window.location.search;
        });
        window.settings = { injectSettings(settings) {
          document.getElementById("settings").textContent =
            "mapBaseLayer=" + settings.mapBaseLayer + ";radarColorMapping=" + settings.radarColorMapping;
        }};
        // The part of core's layer manager the logo uses to return to the radar.
        window.lm = {
          currentCap: "satellite",
          getCapability: (cap) => ({ name: cap }),
          setTarget(cap) { this.currentCap = cap; document.getElementById("map").textContent = "map=" + cap; },
        };
        webkit.messageHandlers.scriptHandler.postMessage("requestSettings");
      </script>`);
    return;
  }
  if (request.method === 'GET' && request.url === '/requests') {
    response.end(JSON.stringify({ requests, registered, mapLoads }));
    return;
  }
  if (request.method === 'DELETE' && request.url === '/requests') {
    requests.length = 0;
    registered = false;
    response.end('{"success":true}');
    return;
  }
  if (request.method !== 'POST' || !['/post_location', '/unregister', '/clear_notification', '/v3/mobile/live_activity'].includes(request.url)) {
    response.writeHead(404).end('{"success":false}');
    return;
  }
  try {
    let data = '';
    for await (const chunk of request) data += chunk;
    const body = JSON.parse(data);
    if (body.token !== 'a'.repeat(64)) throw new Error('Only synthetic tokens are accepted');
    requests.push({ path: request.url, body });
    if (request.url === '/post_location') registered = true;
    if (request.url === '/unregister') registered = false;
    response.end('{"success":true}');
  } catch {
    response.writeHead(400).end('{"success":false}');
  }
}).listen(18765, '127.0.0.1', () => console.log('Simulator recorder listening on 127.0.0.1:18765'));
