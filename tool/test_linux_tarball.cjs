const { test } = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const {
  chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync,
} = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');

const script = join(__dirname, 'package_linux_tarball.sh');

function fakeBundle(root) {
  const bundle = join(root, 'bundle');
  mkdirSync(join(bundle, 'lib'), { recursive: true });
  mkdirSync(join(bundle, 'data/flutter_assets'), { recursive: true });
  writeFileSync(join(bundle, 'flutify'), '#!/bin/sh\nexit 0\n');
  chmodSync(join(bundle, 'flutify'), 0o755);
  writeFileSync(join(bundle, 'lib/libapp.so'), 'aot snapshot stand-in');
  writeFileSync(join(bundle, 'data/icudtl.dat'), 'icu stand-in');
  writeFileSync(join(bundle, 'data/flutter_assets/kernel_blob.bin'), 'debug leftover');
  return bundle;
}

test('package_linux_tarball.sh builds a relocatable archive with licenses', () => {
  const root = mkdtempSync(join(tmpdir(), 'flutify-tarball-test-'));
  try {
    const bundle = fakeBundle(root);
    const output = join(root, 'dist');
    execFileSync('bash', [script, '--label', 'v9.9-test', '--bundle', bundle, '--output', output], { stdio: 'pipe' });

    const tarball = join(output, 'Flutify-v9.9-test-linux-x64.tar.gz');
    const members = execFileSync('tar', ['-tzf', tarball], { encoding: 'utf8' })
      .trim().split('\n');
    const prefix = 'Flutify-v9.9-test-linux-x64';
    assert.ok(members.includes(`${prefix}/flutify`));
    assert.ok(members.includes(`${prefix}/lib/libapp.so`));
    assert.ok(members.includes(`${prefix}/data/icudtl.dat`));
    assert.ok(members.includes(`${prefix}/LICENSE`));
    assert.ok(members.includes(`${prefix}/THIRD_PARTY_NOTICES.md`));
    assert.ok(members.some((member) => member.startsWith(`${prefix}/`)),
      'expected an archive with a single top-level directory');
    assert.ok(!members.some((member) => member.endsWith('kernel_blob.bin')),
      'debug kernel must not be shipped');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('package_linux_tarball.sh refuses a bundle without the release executable', () => {
  const root = mkdtempSync(join(tmpdir(), 'flutify-tarball-test-'));
  try {
    const bundle = join(root, 'bundle');
    mkdirSync(join(bundle, 'lib'), { recursive: true });
    mkdirSync(join(bundle, 'data'), { recursive: true });
    assert.throws(
      () => execFileSync('bash', [script, '--label', 'v9.9-test', '--bundle', bundle, '--output', root], { stdio: 'pipe' }),
      (error) => error.status !== 0
        && /missing release build executable/.test(String(error.stderr)),
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
