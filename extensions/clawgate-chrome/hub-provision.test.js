import test from 'node:test';
import assert from 'node:assert/strict';
import { parseProvisionFile, probeCapabilities, validateCapabilities, validateProvision } from './hub-provision.js';

const provision = {
  schema_version: 1,
  source: 'chrome',
  base_url: 'https://hub.example.test/',
  bearer_token: 'private-token',
  allowed_domains: ['page', 'history', 'messenger'],
};

const capabilities = {
  version: 1,
  source: 'chrome',
  domains: ['history', 'messenger', 'page'],
  storage_receipt_version: 1,
  max_event_bytes: 20 * 1024 * 1024,
  max_chunk_bytes: 4 * 1024 * 1024,
  finalize_replay_safe: true,
};

test('validates the private Chrome provision and canonical capabilities', () => {
  assert.equal(validateProvision(provision).ok, true);
  assert.equal(validateCapabilities(capabilities).ok, true);
});

test('rejects non-Chrome, unsafe URL, newline token, and wrong domains', () => {
  assert.equal(validateProvision({ ...provision, source: 'line' }).ok, false);
  assert.equal(validateProvision({ ...provision, base_url: 'https://user:pass@hub.example.test/' }).ok, false);
  assert.equal(validateProvision({ ...provision, base_url: 'https://hub.example.test/path' }).ok, false);
  assert.equal(validateProvision({ ...provision, bearer_token: 'x\nsecret' }).ok, false);
  assert.equal(validateProvision({ ...provision, allowed_domains: ['page'] }).ok, false);
});

test('probes capabilities read-only and never saves or writes', async () => {
  let request;
  const result = await probeCapabilities(provision, async (url, options) => {
    request = { url, options };
    return new Response(JSON.stringify(capabilities), { status: 200 });
  });
  assert.equal(result.ok, true);
  assert.equal(request.url, 'https://hub.example.test/v1/capabilities');
  assert.equal(request.options.method, 'GET');
  assert.equal(request.options.redirect, 'error');
  assert.equal(request.options.headers.Authorization, 'Bearer private-token');
});

test('rejects oversized provision files and capabilities responses', async () => {
  const tooLarge = { size: 64 * 1024 + 1, text: async () => '{}' };
  assert.equal((await parseProvisionFile(tooLarge)).error, 'provision_too_large');
  const result = await probeCapabilities(provision, async () => new Response('x'.repeat(64 * 1024 + 1), { status: 200 }));
  assert.equal(result.error, 'response_too_large');
});

test('rejects redirects and contract mismatches', async () => {
  const redirect = await probeCapabilities(provision, async () => new Response('', { status: 302 }));
  assert.equal(redirect.error, 'redirect_not_allowed');
  const mismatch = await probeCapabilities(provision, async () => new Response(JSON.stringify({ ...capabilities, source: 'line' }), { status: 200 }));
  assert.equal(mismatch.error, 'capabilities_contract_invalid');
});
