#!/usr/bin/env node
/**
 * 把 glTF/GLB「拍平」成 Godot 能直接导入的最简 glTF：
 *   - 用 three 的 GLTFLoader 解码（它支持 meshopt 压缩与量化属性，Godot 两者都不支持）
 *   - 合并所有网格为一个 primitive：POSITION / NORMAL / COLOR_0 + 索引
 *   - 颜色来自各部件材质的主色（烘进顶点色），因此不再需要材质与贴图
 *
 * 用途：原项目自建的 floatplane.glb 是 meshopt + 量化压缩的，Godot 读不了，
 * 这个小工具把它转成等价的可读资产（外观不变，结构简化）。
 *
 * 用法：node tools/glb-flatten.mjs <输入.glb> <输出.glb>
 * 依赖：three（复用 shenzhen-open-roads 的 node_modules）
 */
import fs from 'node:fs';
import path from 'node:path';

const THREE_PATH = path.resolve(import.meta.dirname, '../../shenzhen-open-roads/node_modules/three');
const toUrl = (p) => 'file://' + p.replace(/\\/g, '/');

const THREE = await import(toUrl(path.join(THREE_PATH, 'build/three.module.js')));
const { GLTFLoader } = await import(toUrl(path.join(THREE_PATH, 'examples/jsm/loaders/GLTFLoader.js')));
const { MeshoptDecoder } = await import(toUrl(path.join(THREE_PATH, 'examples/jsm/libs/meshopt_decoder.module.js')));

const [, , src, dst] = process.argv;
if (!src || !dst) {
  console.error('用法：node tools/glb-flatten.mjs <输入.glb> <输出.glb>');
  process.exit(1);
}

const GLB_MAGIC = 0x46546c67;
const CHUNK_JSON = 0x4e4f534a;
const CHUNK_BIN = 0x004e4942;

/* ── 1. 解码 ── */

const buf = fs.readFileSync(src);
const loader = new GLTFLoader();
loader.setMeshoptDecoder(MeshoptDecoder);
const gltf = await loader.parseAsync(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength), '');

/* ── 2. 合并几何（把材质主色烘进顶点色）── */

const positions = [];
const normals = [];
const colors = [];
const indices = [];
let baseVertex = 0;

gltf.scene.updateMatrixWorld(true);
gltf.scene.traverse((obj) => {
  if (!obj.isMesh) return;
  const geo = obj.geometry;
  const matList = Array.isArray(obj.material) ? obj.material : [obj.material];
  const pos = geo.getAttribute('position');
  const nrm = geo.getAttribute('normal');
  const color = matList[0]?.color ?? new THREE.Color(0.8, 0.8, 0.8);
  const normalMatrix = new THREE.Matrix3().getNormalMatrix(obj.matrixWorld);

  for (let i = 0; i < pos.count; i++) {
    const p = new THREE.Vector3().fromBufferAttribute(pos, i).applyMatrix4(obj.matrixWorld);
    positions.push(p.x, p.y, p.z);
    if (nrm) {
      const n = new THREE.Vector3().fromBufferAttribute(nrm, i).applyMatrix3(normalMatrix).normalize();
      normals.push(n.x, n.y, n.z);
    } else {
      normals.push(0, 1, 0);
    }
    colors.push(color.r, color.g, color.b, 1.0);
  }

  const idx = geo.getIndex();
  if (idx) {
    for (let i = 0; i < idx.count; i++) indices.push(baseVertex + idx.getX(i));
  } else {
    for (let i = 0; i < pos.count; i++) indices.push(baseVertex + i);
  }
  baseVertex += pos.count;
});

const vertexCount = positions.length / 3;
if (vertexCount === 0) throw new Error('没有找到任何网格');

/* ── 3. 组装缓冲区 ── */

const chunks = [];
let cursor = 0;

function pushTyped(typedArray) {
  const bytes = Buffer.from(typedArray.buffer, typedArray.byteOffset, typedArray.byteLength);
  const offset = cursor;
  chunks.push(bytes);
  cursor += bytes.length;
  while (cursor % 4 !== 0) {
    chunks.push(Buffer.alloc(1));
    cursor += 1;
  }
  return offset;
}

const posOff = pushTyped(new Float32Array(positions));
const nrmOff = pushTyped(new Float32Array(normals));
const colOff = pushTyped(new Float32Array(colors));
const idxOff = pushTyped(new Uint32Array(indices));
const bin = Buffer.concat(chunks);

let minX = Infinity;
let minY = Infinity;
let minZ = Infinity;
let maxX = -Infinity;
let maxY = -Infinity;
let maxZ = -Infinity;
for (let i = 0; i < positions.length; i += 3) {
  minX = Math.min(minX, positions[i]);
  maxX = Math.max(maxX, positions[i]);
  minY = Math.min(minY, positions[i + 1]);
  maxY = Math.max(maxY, positions[i + 1]);
  minZ = Math.min(minZ, positions[i + 2]);
  maxZ = Math.max(maxZ, positions[i + 2]);
}

const json = {
  asset: { version: '2.0', generator: 'glb-flatten (shenzhen-native)' },
  scene: 0,
  scenes: [{ nodes: [0] }],
  nodes: [{ mesh: 0, name: path.basename(src, '.glb') }],
  meshes: [
    {
      name: 'flattened',
      primitives: [{ attributes: { POSITION: 0, NORMAL: 1, COLOR_0: 2 }, indices: 3, material: 0, mode: 4 }],
    },
  ],
  materials: [
    {
      name: 'vertexColor',
      pbrMetallicRoughness: { baseColorFactor: [1, 1, 1, 1], metallicFactor: 0.05, roughnessFactor: 0.65 },
      doubleSided: true,
    },
  ],
  accessors: [
    { bufferView: 0, componentType: 5126, count: vertexCount, type: 'VEC3', min: [minX, minY, minZ], max: [maxX, maxY, maxZ] },
    { bufferView: 1, componentType: 5126, count: vertexCount, type: 'VEC3' },
    { bufferView: 2, componentType: 5126, count: vertexCount, type: 'VEC4' },
    { bufferView: 3, componentType: 5125, count: indices.length, type: 'SCALAR' },
  ],
  bufferViews: [
    { buffer: 0, byteOffset: posOff, byteLength: vertexCount * 12, target: 34962 },
    { buffer: 0, byteOffset: nrmOff, byteLength: vertexCount * 12, target: 34962 },
    { buffer: 0, byteOffset: colOff, byteLength: vertexCount * 16, target: 34962 },
    { buffer: 0, byteOffset: idxOff, byteLength: indices.length * 4, target: 34963 },
  ],
  buffers: [{ byteLength: bin.length }],
};

function pad4(b, fill) {
  const rem = b.length % 4;
  return rem === 0 ? b : Buffer.concat([b, Buffer.alloc(4 - rem, fill)]);
}

const jsonBuf = pad4(Buffer.from(JSON.stringify(json), 'utf8'), 0x20);
const binBuf = pad4(bin, 0x00);
const total = 12 + 8 + jsonBuf.length + 8 + binBuf.length;
const out = Buffer.alloc(total);
out.writeUInt32LE(GLB_MAGIC, 0);
out.writeUInt32LE(2, 4);
out.writeUInt32LE(total, 8);
out.writeUInt32LE(jsonBuf.length, 12);
out.writeUInt32LE(CHUNK_JSON, 16);
jsonBuf.copy(out, 20);
const at = 20 + jsonBuf.length;
out.writeUInt32LE(binBuf.length, at);
out.writeUInt32LE(CHUNK_BIN, at + 4);
binBuf.copy(out, at + 8);
fs.writeFileSync(dst, out);

console.log(
  `拍平完成：${path.basename(src)} → ${path.basename(dst)}\n` +
    `  顶点 ${vertexCount}，三角 ${indices.length / 3}，输出 ${(total / 1024).toFixed(0)}KB\n` +
    `  包围盒 x[${minX.toFixed(2)}, ${maxX.toFixed(2)}] y[${minY.toFixed(2)}, ${maxY.toFixed(2)}] z[${minZ.toFixed(2)}, ${maxZ.toFixed(2)}]`,
);