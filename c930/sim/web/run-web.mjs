// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Gridworkz
// run-web.mjs -- npu_web_test.cc's transcript, driven through the browser module
// (web/npu_web.js) the way a page calls it: cwrap'd exports, nothing else.
// It must print the same bytes as the native test, which compare.sh checks.
// Usage: node run-web.mjs WEB_DIR
import { createRequire } from 'node:module';
import { join } from 'node:path';

const require = createRequire(import.meta.url);
const webDir = process.argv[2];
const NpuWeb = require(join(webDir, 'npu_web.js'));
const M_ = await NpuWeb({ locateFile: (f) => join(webDir, f) });
const fn = (name, ret, args) => M_.cwrap(name, ret, args);
const reset = fn('npu_web_reset', null, []);
const csrW = fn('npu_web_csr_write', 'number', ['number', 'number']);
const csrR = (a) => fn('npu_web_csr_read', 'number', ['number'])(a) >>> 0;
const memW = fn('npu_web_mem_write32', null, ['number', 'number']);
const memR = (a) => fn('npu_web_mem_read32', 'number', ['number'])(a) >>> 0;
const run = fn('npu_web_run', 'number', ['number']);

let lcg = 930;
const rnd = () => { lcg = (Math.imul(lcg, 1664525) + 1013904223) >>> 0; return lcg >>> 8; };
const f32bits = (x) => { const d = new DataView(new ArrayBuffer(4)); d.setFloat32(0, x, true); return d.getUint32(0, true); };
const f16 = (x) => {
  if (x === 0) return 0;
  const b = f32bits(x), s = (b >>> 16) & 0x8000, e = ((b >>> 23) & 0xff) - 127 + 15, m = (b & 0x7fffff) >>> 13;
  return s | (e << 10) | m;
};
const bf16 = (x) => f32bits(x) >>> 16;
const PRECS = [
  { code: 0, name: 'INT8', bits: 8, flt: false, lo: -128, hi: 127 }, { code: 1, name: 'INT16', bits: 16, flt: false, lo: -32768, hi: 32767 },
  { code: 4, name: 'INT4', bits: 4, flt: false, lo: -8, hi: 7 }, { code: 2, name: 'FP16', bits: 16, flt: true }, { code: 3, name: 'BF16', bits: 16, flt: true },
];
const SHAPES = [[1, 1, 1], [2, 3, 5], [4, 4, 4], [8, 1, 4], [1, 12, 8], [5, 7, 9], [3, 9, 11], [8, 8, 16], [8, 12, 16]];
const A_BASE = 0x8000, B_BASE = 0x8400, C_BASE = 0x8800;
const hex8 = (v) => (v >>> 0).toString(16).toUpperCase().padStart(8, '0');
const pad = (v, n) => String(v).padStart(n);
const lines = [];
const out = (s) => lines.push(s);

function pack(base, elems, bits) {
  const per = 32 / bits, words = Math.ceil(elems.length / per), mask = bits === 32 ? 0xffffffff : (1 << bits) - 1;
  for (let w = 0; w < words; w++) {
    let v = 0;
    for (let j = 0; j < per && w * per + j < elems.length; j++) v |= (elems[w * per + j] & mask) << (j * bits);
    memW(base + 4 * w, v >>> 0);
  }
}

let bad = 0, n = 0;
out('npu_web_test: c930_npu_top, Verilated; SoC parameters (8x8, DIN_W 16, M<=8 K<=16 N<=12)');
for (const p of PRECS) for (const [M, N, K] of SHAPES) {
  reset();
  for (let a = 0x8000; a < 0x9000; a += 4) memW(a, 0);
  const A = new Array(M * K), B = new Array(K * N);
  for (const mat of [A, B]) for (let i = 0; i < mat.length; i++)
    mat[i] = p.flt ? ((rnd() % 17) - 8) / 4 : p.lo + (rnd() % (p.hi - p.lo + 1));
  const enc = (x) => (p.flt ? (p.code === 2 ? f16(x) : bf16(x)) : x >>> 0);
  pack(A_BASE, A.map(enc), p.bits); pack(B_BASE, B.map(enc), p.bits);
  csrW(0x08, M); csrW(0x0C, N); csrW(0x10, K); csrW(0x14, A_BASE); csrW(0x18, B_BASE); csrW(0x1C, C_BASE); csrW(0x20, p.code);
  csrW(0x00, 1);
  const cyc = run(200000);
  const st = csrR(0x04), cy = csrR(0x24), op = csrR(0x2C), stall = csrR(0x30), dma = csrR(0x28);
  let miss = 0, h = 2166136261;
  for (let i = 0; i < M; i++) for (let j = 0; j < N; j++) {
    const got = memR(C_BASE + 4 * (i * N + j));
    h = Math.imul((h ^ got) >>> 0, 16777619) >>> 0;
    let want;
    if (p.flt) { let s = 0; for (let k = 0; k < K; k++) s += A[i * K + k] * B[k * N + j]; want = f32bits(Math.fround(s)); }
    else { let s = 0n; for (let k = 0; k < K; k++) s += BigInt(A[i * K + k]) * BigInt(B[k * N + j]); want = Number(BigInt.asUintN(32, s)); }
    if (got !== want) { if (miss < 3) out(`    C[${i}][${j}] = 0x${hex8(got)}, expected 0x${hex8(want)}`); miss++; }
  }
  const ok = cyc > 0 && (st & 2) && !(st & 4) && miss === 0;
  out(`${p.name.padEnd(5)} M=${M} N=${pad(N, 2)} K=${pad(K, 2)}  run=${pad(cyc, 6)} cycles  STATUS=${st} CYCLE_LO=${cy} OP_COUNT=${op} STALL_CT=${stall} DMA_LAST=${dma}  C=${hex8(h)}  ${ok ? 'PASS' : 'FAIL'}`);
  bad += ok ? 0 : 1; n++;
}
reset();
csrW(0x08, 4); csrW(0x0C, 4); csrW(0x10, 20); csrW(0x20, 0); csrW(0x00, 1);
let cyc = run(200), st = csrR(0x04), ok = (st & 4) !== 0;
out(`INT8  M=4 N= 4 K=20  run=${pad(cyc, 6)} cycles  STATUS=${st} (dims past MAX_K: ERROR expected)  ${ok ? 'PASS' : 'FAIL'}`);
bad += ok ? 0 : 1; n++;
csrW(0x10, 4); csrW(0x14, A_BASE); csrW(0x18, B_BASE); csrW(0x1C, C_BASE);
csrW(0x00, 1);
cyc = run(20000); st = csrR(0x04); ok = cyc > 0 && st === 2;
out(`INT8  M=4 N= 4 K= 4  run=${pad(cyc, 6)} cycles  STATUS=${st} (the command after the refused one: runs)  ${ok ? 'PASS' : 'FAIL'}`);
bad += ok ? 0 : 1; n++;
reset();
csrW(0x08, 8); csrW(0x0C, 12); csrW(0x10, 16); csrW(0x20, 0);
csrW(0x14, A_BASE); csrW(0x18, B_BASE); csrW(0x1C, C_BASE);
for (let i = 0; i < 5; i++) csrW(0x00, 1);
const q4 = csrR(0x38);
csrW(0x00, 1);
const q5 = csrR(0x38);
const hex2 = (v) => (v >>> 0).toString(16).toUpperCase().padStart(2, '0');
ok = q4 === 0x14 && q5 === 0x14;
out(`QUEUE_STAT one running, four queued: 0x${hex2(q4)}, after a fifth START: 0x${hex2(q5)} (0x14 expected)  ${ok ? 'PASS' : 'FAIL'}`);
bad += ok ? 0 : 1; n++;
out(`npu_web_test: ${n - bad} of ${n} passed`);
process.stdout.write(lines.join('\n') + '\n');
process.exit(bad ? 1 : 0);
