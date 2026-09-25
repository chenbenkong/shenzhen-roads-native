#!/usr/bin/env node
/**
 * 查看 glb 的节点结构：部件名 / 材质色 / 包围盒（用于决定怎么拆分与分组）
 *
 * 用法：node tools/glb-inspect.mjs <文件.glb> [...]
 * 依赖：three（复用 shenzhen-open-roads 的 node_modules）
 */
import path from 'node:path';

const THREE_PATH = path.resolve(import.meta.dirname, '../../shenzhen-open-roads/node_modules/three');
const toUrl = (p) => 'file://' + p.replace(/\\/g, '/');
const THREE = await import(toUrl(path.join(THREE_PATH, 'build/three.module.js')));
const { GLTFLoader } = await import(toUrl(path.join(THREE_PATH, 'examples/jsm/loaders/GLTFLoader.js')));
const { MeshoptDecoder } = await import(toUrl(path.join(THREE_PATH, 'examples/jsm/libs/meshopt_decoder.module.js')));

import fs from 'node:fs';

for (const file of process.argv.slice(2)) {
  const buf = fs.readFileSync(file);
  const loader = new GLTFLoader();
  loader.setMeshoptDecoder(MeshoptDecoder);
  let gltf;
  try {
    gltf = await loader.parseAsync(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength), '');
  } catch (err) {
    console.log(`\n=== ${path.basename(file)} 加载失败：${err.message}`);
    continue;
  }
  gltf.scene.updateMatrixWorld(true);
  console.log(`\n=== ${path.basename(file)}  (${(buf.length / 1024).toFixed(0)}KB)`);
  const rows = [];
  gltf.scene.traverse((o) => {
    if (!o.isMesh) return;
    const g = o.geometry;
    const pos = g.getAttribute('position');
    g.computeBoundingBox();
    const bb = g.boundingBox.clone().applyMatrix4(o.matrixWorld);
    const mat = Array.isArray(o.material) ? o.material[0] : o.material;
    const col = mat?.color;
    const tris = (g.getIndex()?.count ?? pos.count) / 3;
    rows.push({
      name: o.name || '(无名)',
      mat: mat?.name ?? '(无材质)',
      color: col ? `#${col.getHexString()}` : '-',
      tris: Math.round(tris),
      center: `(${bb.getCenter(new THREE.Vector3()).x.toFixed(2)}, ${bb.getCenter(new THREE.Vector3()).y.toFixed(2)}, ${bb.getCenter(new THREE.Vector3()).z.toFixed(2)})`,
      size: `(${bb.getSize(new THREE.Vector3()).x.toFixed(2)}, ${bb.getSize(new THREE.Vector3()).y.toFixed(2)}, ${bb.getSize(new THREE.Vector3()).z.toFixed(2)})`,
    });
  });
  console.log(`部件 ${rows.length} 个：`);
  for (const r of rows) {
    console.log(`  ${r.name.padEnd(28)} 材质=${r.mat.padEnd(14)} 色=${r.color.padEnd(9)} 三角=${String(r.tris).padStart(5)} 中心=${r.center.padEnd(22)} 尺寸=${r.size}`);
  }
  const total = rows.reduce((a, r) => a + r.tris, 0);
  console.log(`  合计三角 ${total}`);
}