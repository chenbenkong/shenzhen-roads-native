#!/usr/bin/env node
/**
 * 把 glTF/GLB 里的 EXT_meshopt_compression 解压成普通 bufferView。
 *
 * 为什么需要：Godot 的 glTF 导入器不认 meshopt 压缩扩展，而原项目自建的
 * floatplane.glb 恰好用了它（EXT_meshopt_compression + KHR_mesh_quantization）。
 * 解压后属性数据原样保留（仍可能是量化的，Godot 支持 KHR_mesh_quantization）。
 *
 * 用法：node tools/decompress-meshopt.mjs <输入.glb> <输出.glb>
 */
import fs from 'node:fs';
import { MeshoptDecoder } from 'meshoptimizer';

const [, , src, dst] = process.argv;
if (!src || !dst) {
  console.error('用法：node tools/decompress-meshopt.mjs <输入.glb> <输出.glb>');
  process.exit(1);
}

const GLB_MAGIC = 0x46546c67;
const CHUNK_JSON = 0x4e4f534a;
const CHUNK_BIN = 0x004e4942;

function readGlb(buf) {
  if (buf.readUInt32LE(0) !== GLB_MAGIC) throw new Error('不是 GLB 文件');
  let off = 12;
  let json = null;
  let bin = null;
  while (off < buf.length) {
    const len = buf.readUInt32LE(off);
    const type = buf.readUInt32LE(off + 4);
    const data = buf.subarray(off + 8, off + 8 + len);
    if (type === CHUNK_JSON) json = JSON.parse(data.toString('utf8'));
    else if (type === CHUNK_BIN) bin = Buffer.from(data);
    off += 8 + len;
  }
  return { json, bin };
}

function writeGlb(json, bin) {
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
  let at = 20 + jsonBuf.length;
  out.writeUInt32LE(binBuf.length, at);
  out.writeUInt32LE(CHUNK_BIN, at + 4);
  binBuf.copy(out, at + 8);
  return out;
}

function pad4(buf, fill) {
  const rem = buf.length % 4;
  if (rem === 0) return buf;
  return Buffer.concat([buf, Buffer.alloc(4 - rem, fill)]);
}

const { json, bin } = readGlb(fs.readFileSync(src));
if (!bin) throw new Error('GLB 缺少 BIN 块');

await MeshoptDecoder.ready;

const views = json.bufferViews ?? [];
const chunks = [];
let cursor = 0;
let decoded = 0;

for (let i = 0; i < views.length; i++) {
  const view = views[i];
  const ext = view.extensions?.EXT_meshopt_compression;
  if (!ext) {
    // 未压缩：整体搬到新 BIN 的对应位置
    const bytes = bin.subarray(view.byteOffset ?? 0, (view.byteOffset ?? 0) + view.byteLength);
    chunks.push(bytes);
    view.buffer = 0;
    view.byteOffset = cursor;
    cursor += bytes.length;
    while (cursor % 4 !== 0) {
      chunks.push(Buffer.alloc(1));
      cursor += 1;
    }
    continue;
  }

  // 压缩：按 count/byteStride 解出原始大小
  const count = ext.count;
  const stride = ext.byteStride;
  const target = new Uint8Array(count * stride);
  const source = bin.subarray(ext.byteOffset ?? 0, (ext.byteOffset ?? 0) + ext.byteLength);
  await MeshoptDecoder.decodeGltfBuffer(target, count, stride, source, ext.mode, ext.filter);
  const bytes = Buffer.from(target.buffer, target.byteOffset, target.byteLength);
  chunks.push(bytes);
  view.buffer = 0;
  view.byteOffset = cursor;
  view.byteLength = bytes.length;
  delete view.byteStride; // 解压后按紧凑布局
  delete view.extensions;
  cursor += bytes.length;
  while (cursor % 4 !== 0) {
    chunks.push(Buffer.alloc(1));
    cursor += 1;
  }
  decoded += 1;
}

const newBin = Buffer.concat(chunks);
json.buffers = [{ byteLength: newBin.length }];
json.extensionsUsed = (json.extensionsUsed ?? []).filter((e) => e !== 'EXT_meshopt_compression');
if (json.extensionsRequired) {
  json.extensionsRequired = json.extensionsRequired.filter((e) => e !== 'EXT_meshopt_compression');
  if (json.extensionsRequired.length === 0) delete json.extensionsRequired;
}

fs.writeFileSync(dst, writeGlb(json, newBin));
console.log(
  `解压完成：${src} → ${dst}\n` +
    `  bufferView ${views.length} 个，其中解压 ${decoded} 个；BIN ${(bin.length / 1024).toFixed(0)}KB → ${(newBin.length / 1024).toFixed(0)}KB`,
);