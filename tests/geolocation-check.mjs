import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const swift = readFileSync(new URL('../meteocool/lib/GeolocationBridge.swift', import.meta.url), 'utf8');
const source = swift.split('private static let source = #"""')[1].split('"""#')[0];
const requests = [];
const context = vm.createContext({
  window: { webkit: { messageHandlers: { geolocationHandler: { postMessage: value => requests.push(value) } } } },
  navigator: {}, console, setTimeout, clearTimeout,
});
vm.runInContext(source, context);
const geo = context.navigator.geolocation;
const bridge = context.window.__mcGeo;
const fix = { latitude: 48, longitude: 11, accuracy: 20, altitude: null, altitudeAccuracy: null, heading: null, speed: null, timestamp: Date.now() };
let positions = 0;
const watch = geo.watchPosition(() => positions++);
bridge.push(fix);
assert.equal(positions, 1, 'one fix must deliver exactly one watch callback');
bridge.push(fix);
assert.equal(positions, 2);
geo.clearWatch(watch);
bridge.push(fix);
assert.equal(positions, 2);
const canceled = geo.watchPosition(() => positions++);
geo.clearWatch(canceled);
bridge.push(fix);
assert.equal(positions, 2, 'clearWatch must cancel its initial pending request too');
let errors = 0;
geo.getCurrentPosition(() => assert.fail('denied request succeeded'), () => errors++);
bridge.fail({ code: 1, message: 'denied' });
assert.equal(errors, 1);
const before = requests.length;
geo.getCurrentPosition(() => positions++);
assert.equal(requests.length, before + 1, 'a new request must recheck authorization after Settings changes');
bridge.push(fix);
assert.equal(positions, 3);
geo.getCurrentPosition(() => assert.fail('timed-out request succeeded'), e => { assert.equal(e.code, 3); errors++; }, { timeout: 0 });
await new Promise(resolve => setTimeout(resolve, 10));
bridge.push(fix);
assert.equal(errors, 2);
console.log('Geolocation delivery, cancellation, denial recovery, and timeout checks passed');
