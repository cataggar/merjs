import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const wasm = await readFile(new URL("../examples/site/worker/merjs.wasm", import.meta.url));
const { instance } = await WebAssembly.instantiate(wasm);
const api = instance.exports;
const encoder = new TextEncoder();
const decoder = new TextDecoder();
api.init();

for (const [path, expectedStatus] of [
  ["/api/hello", 200],
  ["/isr-demo", 200],
  ["/admin", 303],
]) {
  const input = encoder.encode(`GET ${path}`);
  const pointer = api.alloc(input.length);
  assert.notEqual(pointer, 0);
  try {
    new Uint8Array(api.memory.buffer, pointer, input.length).set(input);
    const result = api.handle(pointer, input.length);
    assert.notEqual(result, 0);
    const length = api.response_len();
    assert.ok(length >= 4);
    const response = new DataView(api.memory.buffer, result, length);
    const status = response.getUint16(0, true);
    const typeLength = response.getUint16(2, true);
    assert.ok(4 + typeLength <= length);
    const type = decoder.decode(new Uint8Array(api.memory.buffer, result + 4, typeLength));
    const body = decoder.decode(new Uint8Array(api.memory.buffer, result + 4 + typeLength, length - 4 - typeLength));
    assert.equal(status, expectedStatus, path);
    if (path === "/api/hello") {
      assert.equal(type, "application/json");
      assert.equal(JSON.parse(body).zig_version, "0.17.0");
    }
    if (path === "/isr-demo") {
      assert.equal(type, "text/html; charset=utf-8");
      assert.ok(body.includes("Incremental Static Regeneration"));
    }
    console.log(`Worker ${path}: ${status}`);
  } finally {
    api.dealloc(pointer, input.length);
  }
}
