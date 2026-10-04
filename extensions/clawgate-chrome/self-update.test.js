import assert from 'node:assert/strict';
import { test } from 'node:test';
import { isNewerVersion } from './self-update.js';

test('only a strictly newer, well-formed disk version triggers an update', () => {
  assert.equal(isNewerVersion('0.12.8', '0.12.7'), true);
  assert.equal(isNewerVersion('0.13.0', '0.12.9'), true);
  assert.equal(isNewerVersion('0.12.7', '0.12.7'), false);
  assert.equal(isNewerVersion('0.12.6', '0.12.7'), false);
  assert.equal(isNewerVersion('', '0.12.7'), false);
  assert.equal(isNewerVersion('x.y', '0.12.7'), false);
});
