import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { inflateSync } from 'node:zlib';

const catalog = new URL('../apps/macos/LecturaMacApp/Resources/Assets.xcassets/AppIcon.appiconset/', import.meta.url);

function decodeRGBA(png) {
  assert.deepEqual(png.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  const idat = [];
  let width;
  let height;

  for (let offset = 8; offset < png.length;) {
    const length = png.readUInt32BE(offset);
    const type = png.toString('ascii', offset + 4, offset + 8);
    const data = png.subarray(offset + 8, offset + 8 + length);
    if (type === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      assert.equal(data[8], 8, 'icon must use 8-bit channels');
      assert.equal(data[9], 6, 'icon must use RGBA pixels');
      assert.equal(data[12], 0, 'icon must not be interlaced');
    } else if (type === 'IDAT') {
      idat.push(data);
    }
    offset += length + 12;
  }

  const bytes = inflateSync(Buffer.concat(idat));
  const stride = width * 4;
  const rows = [];
  let sourceOffset = 0;
  let previous = Buffer.alloc(stride);

  for (let y = 0; y < height; y += 1) {
    const filter = bytes[sourceOffset];
    const source = bytes.subarray(sourceOffset + 1, sourceOffset + 1 + stride);
    const row = Buffer.alloc(stride);
    for (let index = 0; index < stride; index += 1) {
      const left = index >= 4 ? row[index - 4] : 0;
      const up = previous[index];
      const upperLeft = index >= 4 ? previous[index - 4] : 0;
      const predictor = filter === 0 ? 0
        : filter === 1 ? left
          : filter === 2 ? up
            : filter === 3 ? Math.floor((left + up) / 2)
              : filter === 4 ? paeth(left, up, upperLeft)
                : assert.fail(`unsupported PNG filter ${filter}`);
      row[index] = (source[index] + predictor) & 255;
    }
    rows.push(row);
    previous = row;
    sourceOffset += stride + 1;
  }

  return { width, height, alpha: (x, y) => rows[y][x * 4 + 3] };
}

function paeth(left, up, upperLeft) {
  const estimate = left + up - upperLeft;
  const leftDistance = Math.abs(estimate - left);
  const upDistance = Math.abs(estimate - up);
  const upperLeftDistance = Math.abs(estimate - upperLeft);
  return leftDistance <= upDistance && leftDistance <= upperLeftDistance
    ? left : upDistance <= upperLeftDistance ? up : upperLeft;
}

test('AppIcon declares every rounded macOS representation', async () => {
  const contents = JSON.parse(await readFile(new URL('Contents.json', catalog), 'utf8'));
  assert.equal(contents.images.length, 10);

  await Promise.all(contents.images.map(async ({ filename, idiom, scale, size }) => {
    assert.equal(idiom, 'mac');
    const icon = decodeRGBA(await readFile(new URL(filename, catalog)));
    const expectedSize = Number.parseInt(size, 10) * Number.parseInt(scale, 10);
    assert.deepEqual([icon.width, icon.height], [expectedSize, expectedSize]);
    assert.deepEqual([
      icon.alpha(0, 0),
      icon.alpha(icon.width - 1, 0),
      icon.alpha(0, icon.height - 1),
      icon.alpha(icon.width - 1, icon.height - 1),
    ], [0, 0, 0, 0], `${filename} must have transparent rounded corners`);
    assert.equal(icon.alpha(Math.floor(icon.width / 2), Math.floor(icon.height / 2)), 255,
      `${filename} must remain opaque at its center`);
  }));
});
