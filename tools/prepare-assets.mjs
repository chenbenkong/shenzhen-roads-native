#!/usr/bin/env node
/**
 * 资产准备：把原项目自建的 glb 拆成 Godot 侧可直接消费的分组资产
 *
 * 为什么需要：
 *  - 这些 glb 是「多部件 + 多材质」结构（例如行人 12 个部件、5 种材质），
 *    直接导入后是一个多节点场景，没法喂给 MultiMesh（批量绘制要求单一网格）。
 *  - 引擎端要按「躯干 / 腿 / 手臂」分组做行走动画，所以必须在这里按部件名拆开。
 *  - 材质色统一烘进顶点色，游戏内无需材质与贴图，且 instance color 可整体调色。
 *
 * 产物（单一 primitive、float 属性、带 COLOR_0、顶点已按需平移）：
 *   ped_body.glb   行人躯干 + 头（原点在脚底）
 *   ped_arm.glb    单条手臂（原点在肩关节）
 *   ped_leg.glb    单条腿  （原点在髋关节）
 *   car_plain.glb  交通车（车漆顶点色置白，便于 instance color 换色）
 *   palm_plain.glb 棕榈树（原点在根部）
 *   bicycle_plain.glb 自行车
 *
 * 用法：node tools/prepare-assets.mjs
 */
import fs from 'node:fs';
import path from 'node:path';

const THREE_PATH = path.resolve(import.meta.dirname, '../../shenzhen-open-roads/node_modules/three');
const toUrl = (p) => 'file://' + p.replace(/\\/g, '/');
const THREE = await import(toUrl(path.join(THREE_PATH, 'build/three.module.js')));
const { GLTFLoader } = await import(toUrl(path.join(THREE_PATH, 'examples/jsm/loaders/GLTFLoader.js')));
const { MeshoptDecoder } = await import(toUrl(path.join(THREE_PATH, 'examples/jsm/libs/meshopt_decoder.module.js')));

const GLB_MAGIC = 0x46546c67;
const CHUNK_JSON = 0x4e4f534a;
const CHUNK_BIN = 0x004e4942;

/* ── 读取与写出 ── */

async function load(file) {
  const buf = fs.readFileSync(file);
  const loader = new GLTFLoader();
  loader.setMeshoptDecoder(MeshoptDecoder);
  const gltf = await loader.parseAsync(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength), '');
  gltf.scene.updateMatrixWorld(true);
  return gltf;
}

function pad4(b, fill) {
  const rem = b.length % 4;
  return rem === 0 ? b : Buffer.concat([b, Buffer.alloc(4 - rem, fill)]);
}

function writeGlb(dst, group, name) {
  const chunks = [];
  let cursor = 0;
  const push = (typed) => {
    const bytes = Buffer.from(typed.buffer, typed.byteOffset, typed.byteLength);
    const offset = cursor;
    chunks.push(bytes);
    cursor += bytes.length;
    while (cursor % 4 !== 0) {
      chunks.push(Buffer.alloc(1));
      cursor += 1;
    }
    return offset;
  };
  const posOff = push(new Float32Array(group.positions));
  const nrmOff = push(new Float32Array(group.normals));
  const colOff = push(new Float32Array(group.colors));
  const idxOff = push(new Uint32Array(group.indices));
  const bin = Buffer.concat(chunks);

  const vc = group.positions.length / 3;
  let mn = [Infinity, Infinity, Infinity];
  let mx = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < group.positions.length; i += 3) {
    for (let k = 0; k < 3; k++) {
      mn[k] = Math.min(mn[k], group.positions[i + k]);
      mx[k] = Math.max(mx[k], group.positions[i + k]);
    }
  }

  const json = {
    asset: { version: '2.0', generator: 'prepare-assets (shenzhen-native)' },
    scene: 0,
    scenes: [{ nodes: [0] }],
    nodes: [{ mesh: 0, name }],
    meshes: [{ name, primitives: [{ attributes: { POSITION: 0, NORMAL: 1, COLOR_0: 2 }, indices: 3, material: 0, mode: 4 }] }],
    materials: [{ name: 'vertexColor', pbrMetallicRoughness: { baseColorFactor: [1, 1, 1, 1], metallicFactor: 0.05, roughnessFactor: 0.7 }, doubleSided: true }],
    accessors: [
      { bufferView: 0, componentType: 5126, count: vc, type: 'VEC3', min: mn, max: mx },
      { bufferView: 1, componentType: 5126, count: vc, type: 'VEC3' },
      { bufferView: 2, componentType: 5126, count: vc, type: 'VEC4' },
      { bufferView: 3, componentType: 5125, count: group.indices.length, type: 'SCALAR' },
    ],
    bufferViews: [
      { buffer: 0, byteOffset: posOff, byteLength: vc * 12, target: 34962 },
      { buffer: 0, byteOffset: nrmOff, byteLength: vc * 12, target: 34962 },
      { buffer: 0, byteOffset: colOff, byteLength: vc * 16, target: 34962 },
      { buffer: 0, byteOffset: idxOff, byteLength: group.indices.length * 4, target: 34963 },
    ],
    buffers: [{ byteLength: bin.length }],
  };

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
  return { vc, tris: group.indices.length / 3, kb: total / 1024, min: mn, max: mx };
}

/* ── 分组收集 ── */

/**
 * @param gltf 已加载的 gltf
 * @param match (name, materialName) => boolean
 * @param origin [x,y,z] 顶点平移量（把关节移到原点）
 * @param whiteMaterials 顶点色置白的材质名集合（便于实例换色）
 */
function collect(gltf, match, origin = [0, 0, 0], whiteMaterials = new Set()) {
  const positions = [];
  const normals = [];
  const colors = [];
  const indices = [];
  let base = 0;
  const used = [];
  gltf.scene.traverse((o) => {
    if (!o.isMesh) return;
    const mat = Array.isArray(o.material) ? o.material[0] : o.material;
    const matName = mat?.name ?? '';
    if (!match(o.name || '', matName)) return;
    used.push(o.name);
    const geo = o.geometry;
    const pos = geo.getAttribute('position');
    const nrm = geo.getAttribute('normal');
    const col = whiteMaterials.has(matName) ? new THREE.Color(1, 1, 1) : (mat?.color ?? new THREE.Color(0.8, 0.8, 0.8));
    const normalMatrix = new THREE.Matrix3().getNormalMatrix(o.matrixWorld);
    for (let i = 0; i < pos.count; i++) {
      const p = new THREE.Vector3().fromBufferAttribute(pos, i).applyMatrix4(o.matrixWorld);
      positions.push(p.x - origin[0], p.y - origin[1], p.z - origin[2]);
      if (nrm) {
        const n = new THREE.Vector3().fromBufferAttribute(nrm, i).applyMatrix3(normalMatrix).normalize();
        normals.push(n.x, n.y, n.z);
      } else {
        normals.push(0, 1, 0);
      }
      colors.push(col.r, col.g, col.b, 1.0);
    }
    const idx = geo.getIndex();
    if (idx) {
      for (let i = 0; i < idx.count; i++) indices.push(base + idx.getX(i));
    } else {
      for (let i = 0; i < pos.count; i++) indices.push(base + i);
    }
    base += pos.count;
  });
  return { positions, normals, colors, indices, used };
}

/* ── 执行 ── */

const root = path.resolve(import.meta.dirname, '..');
const models = path.join(root, 'models');
const outDir = models;

// 肩关节 / 髋关节高度：由部件包围盒推得（臂顶 1.37、腿顶 0.885）
const SHOULDER_Y = 1.37;
const HIP_Y = 0.885;

const ped = await load(path.join(models, 'pedestrian.glb'));
const jobs = [
  {
    out: 'ped_body.glb',
    group: collect(ped, (n) => n.startsWith('person_body_')),
  },
  {
    // 用 person_arm_1_*（右臂），原点移到肩关节；左臂由 transform 镜像位置
    out: 'ped_arm.glb',
    group: collect(ped, (n) => n.startsWith('person_arm_1_'), [0, SHOULDER_Y, 0]),
  },
  {
    out: 'ped_leg.glb',
    group: collect(ped, (n) => n.startsWith('person_leg_1_'), [0, HIP_Y, 0]),
  },
];

const car = await load(path.join(models, 'traffic-car.glb'));
jobs.push({
  out: 'car_plain.glb',
  group: collect(car, () => true, [0, 0, 0], new Set(['carpaint'])),
});

const palm = await load(path.join(models, 'palm.glb'));
jobs.push({ out: 'palm_plain.glb', group: collect(palm, () => true) });

const bike = await load(path.join(models, 'bicycle.glb'));
jobs.push({ out: 'bicycle_plain.glb', group: collect(bike, () => true) });

for (const job of jobs) {
  const dst = path.join(outDir, job.out);
  const info = writeGlb(dst, job.group, job.out.replace('.glb', ''));
  console.log(
    `${job.out.padEnd(18)} 顶点 ${String(info.vc).padStart(5)} 三角 ${String(info.tris).padStart(5)}  ` +
      `${info.kb.toFixed(0)}KB  部件[${job.group.used.length}]  ` +
      `范围 x[${info.min[0].toFixed(2)},${info.max[0].toFixed(2)}] y[${info.min[1].toFixed(2)},${info.max[1].toFixed(2)}] z[${info.min[2].toFixed(2)},${info.max[2].toFixed(2)}]`,
  );
}
console.log('\n完成。下一步：godot --headless --path . --import');