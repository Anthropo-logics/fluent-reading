import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';

const catalog = new URL('../apps/macos/LecturaMacApp/Resources/Assets.xcassets/AppIcon.appiconset/', import.meta.url);

test('AppIcon declares every macOS representation and each file exists', async () => {
  const contents = JSON.parse(await readFile(new URL('Contents.json', catalog), 'utf8'));
  assert.equal(contents.images.length, 10);

  await Promise.all(contents.images.map(async ({ filename, idiom }) => {
    assert.equal(idiom, 'mac');
    assert.ok((await readFile(new URL(filename, catalog))).length > 0);
  }));
});
