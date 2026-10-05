import http from 'node:http';

// Only synthetic simulator data reaches this process. Never proxy to a server.
const requests = [];
let registered = false;
let mapAvailable = false;
let mapLoads = 0;
http.createServer(async (request, response) => {
  response.setHeader('Content-Type', 'application/json');
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
      <p>Map connection restored</p><p id="settings"></p><p id="map">map=satellite</p>
      <script>
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
