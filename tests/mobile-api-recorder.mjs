import http from 'node:http';
import { gzipSync } from 'node:zlib';

// Only synthetic simulator data reaches this process. Never proxy to a server.
const requests = [];
let registered = false;
let mapAvailable = false;
let mapLoads = 0;
// The AR storm view's data: one synthetic storm south of Munich, a tracked
// cell standing in it, its track, and a few strikes. All made up here.
const STORM = { lat: 47.9, lon: 11.6 };
const SCAN = '20261004T020500';
const VOLUME_PATH = `meteoradar/volumes/${SCAN}/de-G4790011600.mcvx`;
const CELL_CODE = '2026100402050000012345';

/** A 40 x 40 x 16 km box holding a leaning column of echo, 50 dBZ at its core. */
function syntheticVolume() {
  const nx = 80, ny = 80, nz = 32;
  const header = Buffer.from(JSON.stringify({
    code: 'G4790011600', reference_time: '2026-10-04T02:05:00+00:00', lon: STORM.lon, lat: STORM.lat,
    nx, ny, nz, step_m: [500, 500, 500], origin_m: [-20000, -20000, 0], dbz_floor: -32, dbz_scale: 2,
    sites: ['deisn'], coverage: 1, network: 'de', tier: 2,
    scanned_at: new Date(Date.now() - 4 * 60000).toISOString(), oldest_scan_at: null,
  }));
  const voxels = Buffer.alloc(nx * ny * nz * 2);
  for (let z = 0; z < nz; z++) {
    const lean = z * 0.25; // the core leans east with height
    for (let y = 0; y < ny; y++) {
      for (let x = 0; x < nx; x++) {
        const dx = (x + 0.5 - nx / 2 - lean) * 0.5, dy = (y + 0.5 - ny / 2) * 0.5, h = z * 0.5;
        const r = Math.hypot(dx, dy);
        const dbz = h < 11 ? 52 - 2.2 * r - (h > 7 ? (h - 7) * 4 : 0) : -20;
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
    return { reference_time: '2026-10-04T02:05:00Z', volumes: [{
      code: 'G4790011600', network: 'de', lon: STORM.lon, lat: STORM.lat, path: VOLUME_PATH, tier: 2,
      peak_dbz: 52, area_km2: 180, coverage: 1, seed_dbz: 25, reference_time: '2026-10-04T02:05:00Z',
      scanned_at: new Date(Date.now() - 4 * 60000).toISOString(),
    }] };
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

http.createServer(async (request, response) => {
  response.setHeader('Content-Type', 'application/json');
  const path = request.url.split('?')[0];
  if (request.method === 'GET' && path === `/${VOLUME_PATH}`) {
    response.setHeader('Content-Type', 'application/octet-stream');
    response.setHeader('Content-Encoding', 'gzip');
    response.end(syntheticVolume());
    return;
  }
  const storms = request.method === 'GET' ? stormData(path) : null;
  if (storms) {
    response.end(JSON.stringify(storms));
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
    response.end(`<!doctype html><title>Map recovery fixture</title>
      <p>Map connection restored</p><p id="settings"></p><p id="map">map=satellite</p><p id="link"></p>
      <script>
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
  if (request.method !== 'POST' || !['/post_location', '/unregister', '/clear_notification'].includes(request.url)) {
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
