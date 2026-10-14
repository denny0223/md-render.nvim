// Offline regression using the installed Renovate implementation, not a second updater.
// Run: node tests/renovate_test.mjs /path/to/node_modules/renovate
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, realpath, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

assert(process.argv[2], 'Pass an installed Renovate package directory or executable path.');
let packageDir = await realpath(resolve(process.argv[2]));
if (!(await stat(packageDir)).isDirectory()) packageDir = dirname(packageDir);
for (;;) {
  const metadata = await readFile(join(packageDir, 'package.json'), 'utf8').catch(() => '{}');
  if (JSON.parse(metadata).name === 'renovate') break;
  const parent = dirname(packageDir);
  assert.notEqual(parent, packageDir, 'Could not locate the Renovate package.');
  packageDir = parent;
}
const load = path => import(pathToFileURL(join(packageDir, 'dist', path)).href);
await (await load('logger/index.js')).init();
const [{ GlobalConfig }, { extractPackageFile: extractRegex }, { extractPackageFile: extractPreCommit },
  { doAutoReplace }, { CustomDatasource }, { matchRegexOrGlobList }, { getConfig }, { lookupUpdates }] = await Promise.all([
  load('config/global.js'), load('modules/manager/custom/regex/index.js'),
  load('modules/manager/pre-commit/index.js'), load('workers/repository/update/branch/auto-replace.js'),
  load('modules/datasource/custom/index.js'), load('util/string-match.js'),
  load('config/defaults.js'), load('workers/repository/process/lookup/index.js'),
]);
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const config = JSON.parse(await readFile(join(root, 'renovate.json'), 'utf8'));
const localDir = await mkdtemp(join(tmpdir(), 'md-render-renovate-test-'));
GlobalConfig.set({ localDir, platform: 'local' });

try {
  const files = ['.pre-commit-config.yaml', '.github/ci/neovim-archives.tsv',
    '.github/ci/ffmpeg-archives.tsv', '.github/ci/install-neovim.sh', '.github/ci/install-terminal.sh',
    '.github/workflows/lint.yml', '.github/workflows/test.yml', '.github/workflows/terminal.yml'];
  const originals = new Map(await Promise.all(files.map(async file => [file, await readFile(join(root, file), 'utf8')])));
  const extracted = [];
  for (const manager of config.customManagers) {
    assert.equal(manager.customType, 'regex');
    for (const [packageFile, content] of originals) {
      if (!matchRegexOrGlobList(packageFile, manager.managerFilePatterns)) continue;
      const deps = extractRegex(content, packageFile, manager)?.deps ?? [];
      deps.forEach((dep, depIndex) => extracted.push({ ...manager, ...dep, manager: 'regex', packageFile, depIndex }));
    }
  }
  const preFile = '.pre-commit-config.yaml';
  extractPreCommit(originals.get(preFile), preFile).deps.forEach((dep, depIndex) =>
    extracted.push({ ...dep, manager: 'pre-commit', packageFile: preFile, depIndex }));
  const depsFor = name => extracted.filter(dep => dep.depName === name);
  const expectedFiles = {
    'neovim/neovim': ['.github/ci/neovim-archives.tsv', '.github/ci/neovim-archives.tsv',
      '.github/ci/install-neovim.sh', '.github/workflows/test.yml', '.github/workflows/terminal.yml'],
    'kovidgoyal/kitty': ['.github/ci/install-terminal.sh', '.github/workflows/terminal.yml'],
    'JohnnyMorganz/StyLua': [preFile, '.github/workflows/lint.yml'],
    'folke/snacks.nvim': ['.github/workflows/test.yml', '.github/workflows/test.yml'],
    'BtbN/FFmpeg-Builds 9.0 linux64-gpl': ['.github/ci/ffmpeg-archives.tsv'],
  };
  for (const [name, expected] of Object.entries(expectedFiles)) {
    assert.deepEqual(depsFor(name).map(dep => dep.packageFile).sort(), expected.sort(), `${name}: all callers extracted`);
    const values = depsFor(name).map(dep => dep.currentValue.replace(/^v/, ''));
    assert.equal(new Set(values).size, 1, `${name}: current references agree`);
  }
  assert.equal(extracted.length, Object.values(expectedFiles).flat().length, 'No unreviewed custom dependencies');

  const nextVersion = value => value.replace(/(\d+)$/, number => String(Number(number) + 1));
  const digest = dep => createHash('sha256').update(`${dep.depName}:${dep.packageName}:${dep.currentDigest}:next`)
    .digest('hex').slice(0, dep.currentDigest.length);
  const updated = new Map(originals);
  const replacements = [];
  for (const dep of extracted) {
    const newValue = dep.depName === 'folke/snacks.nvim' ? dep.currentValue
      : dep.depName.startsWith('BtbN/') ? dep.currentValue.replace(/autobuild-(\d{4})-/, (_, year) => `autobuild-${Number(year) + 1}-`)
      : nextVersion(dep.currentValue);
    const upgrade = { ...dep, newValue, ...(dep.currentDigest && { newDigest: digest(dep) }) };
    const before = updated.get(dep.packageFile);
    const after = await doAutoReplace(upgrade, before, false, before === originals.get(dep.packageFile));
    assert.equal(typeof after, 'string', `${dep.depName}: replacement succeeds`);
    assert.notEqual(after, before, `${dep.depName}: expected occurrence changes`);
    updated.set(dep.packageFile, after);
    replacements.push(upgrade);
  }
  for (const [file, original] of originals) {
    let restored = updated.get(file);
    for (const dep of replacements.filter(item => item.packageFile === file)) {
      restored = restored.replaceAll(dep.newValue, dep.currentValue);
      if (dep.newDigest) restored = restored.replaceAll(dep.newDigest, dep.currentDigest);
    }
    // Renovate standardizes pre-commit's tag comment while retaining its pinned SHA.
    if (file === preFile && !original.includes('# frozen:')) restored = restored.replace('# frozen:', '#');
    assert.equal(restored, original, `${file}: floors, fallbacks, observations and unrelated text stay unchanged`);
  }

  const offlineSources = Object.fromEntries(Object.entries(config.customDatasources).map(([name, source]) =>
    [name, { ...source, defaultRegistryUrlTemplate: 'file://releases.json' }]));
  async function releases(dep, input) {
    await writeFile(join(localDir, 'releases.json'), JSON.stringify(input));
    const result = await new CustomDatasource().getReleases({ ...dep, customDatasources: offlineSources });
    assert(result, `${dep.datasource}: fixture transforms into a valid Renovate release result`);
    return result.releases;
  }
  const asset = (name, hash = 'a'.repeat(64)) => ({ name, digest: `sha256:${hash}` });
  const release = (tag_name, assets) => ({ tag_name, assets, draft: false, prerelease: false, published_at: '2020-01-01T00:00:00Z' });
  const nvim = depsFor('neovim/neovim').filter(dep => dep.currentDigest);
  const nvimTag = nextVersion(nvim[0].currentValue);
  const nvimAssets = [asset('nvim-linux-x86_64.tar.gz'), asset('nvim-macos-arm64.tar.gz', 'b'.repeat(64))];
  for (const dep of nvim) {
    const valid = await releases(dep, [release(nvimTag, nvimAssets)]);
    assert.deepEqual(valid.map(item => item.version), [nvimTag]);
    assert.equal(valid[0].newDigest, nvimAssets.find(item => item.name === `nvim-${dep.packageName}.tar.gz`).digest.slice(7));
    const sameName = `nvim-${dep.packageName}.tar.gz`;
    for (const invalid of [{ name: sameName }, { name: sameName, digest: null }, asset(sameName, 'invalid')]) {
      assert.deepEqual(await releases(dep, [release(nvimTag, [...nvimAssets, invalid])]), valid,
        'An invalid duplicate must not contaminate the valid Neovim archive');
    }
    for (const incomplete of [[nvimAssets[0]], [nvimAssets[0], nvimAssets[0]],
      [nvimAssets[0], { name: nvimAssets[1].name }], [nvimAssets[0], { name: nvimAssets[1].name, digest: null }],
      [nvimAssets[0], asset(nvimAssets[1].name, 'invalid')]]) {
      assert.deepEqual(await releases(dep, [release(nvimTag, incomplete)]), [], 'Both distinct Neovim platforms need valid digests');
    }
    assert.deepEqual(await releases(dep, [{ ...release(nvimTag, nvimAssets), prerelease: true }]), []);
  }
  const kitty = depsFor('kovidgoyal/kitty').find(dep => dep.currentDigest);
  const kittyVersion = nextVersion(kitty.currentValue);
  const kittyAsset = asset(`kitty-${kittyVersion}-x86_64.txz`);
  assert.deepEqual((await releases(kitty, [release(`v${kittyVersion}`, [kittyAsset])])).map(item => item.version), [kittyVersion]);
  for (const incomplete of [{ name: kittyAsset.name }, { name: kittyAsset.name, digest: null }, asset(kittyAsset.name, 'invalid')]) {
    assert.deepEqual(await releases(kitty, [release(`v${kittyVersion}`, [incomplete])]), [], 'Kitty requires a valid digest');
  }

  const ffmpeg = depsFor('BtbN/FFmpeg-Builds 9.0 linux64-gpl')[0];
  const now = new Date();
  const month = offset => new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + offset, 1)).toISOString().slice(0, 7);
  const build = (stamp, series = '9.0') => {
    const tag = `autobuild-${stamp}-13-00`;
    const archive = asset(`ffmpeg-n${series}.1-1-gabcdef-linux64-gpl-${series}.tar.xz`);
    archive.browser_download_url = `https://github.com/BtbN/FFmpeg-Builds/releases/download/${tag}/${archive.name}`;
    return release(tag, [archive]);
  };
  const previous = build(`${month(-1)}-25`);
  const older = build(`${month(-2)}-25`);
  const result = await releases(ffmpeg, [build(`${month(0)}-01`), previous, build(`${month(-1)}-05`), older]);
  assert.deepEqual(result.map(item => item.version).sort(), [previous, older].map(item => item.assets[0].browser_download_url).sort(),
    'Only the last build of each completed UTC month is offered');
  assert(result.every(item => item.newDigest === 'a'.repeat(64)));
  assert.deepEqual(await releases(ffmpeg, [build(`${month(-1)}-25`, '10.0')]), [], 'FFmpeg series stays at 9.0');
  const missingDigest = structuredClone(previous);
  delete missingDigest.assets[0].digest;
  assert.deepEqual(await releases(ffmpeg, [missingDigest]), [], 'FFmpeg requires a digest');
  missingDigest.assets[0].digest = null;
  assert.deepEqual(await releases(ffmpeg, [missingDigest]), [], 'FFmpeg rejects a null digest');
  for (const flag of ['draft', 'prerelease']) {
    assert.deepEqual(await releases(ffmpeg, [{ ...previous, [flag]: true }]), [], `FFmpeg excludes ${flag} releases`);
  }
  assert.deepEqual(await releases(ffmpeg, [build(`${month(0)}-01`)]), [], 'The current month is not complete');
  // BtbN retires old archives; the old release must not be needed to prepare its replacement.
  await releases(ffmpeg, [previous]);
  const retired = { ...getConfig(), ...config, ...ffmpeg, customDatasources: offlineSources,
    currentValue: ffmpeg.currentValue.replace(/autobuild-\d{4}-\d{2}-\d{2}-/, `autobuild-${month(-3)}-25-`) };
  const { val: lookup, err } = (await lookupUpdates(retired)).unwrap();
  if (err) throw err;
  assert.equal(lookup.updates.length, 1, 'A retired current archive still receives an update');
  assert.equal(lookup.updates[0].newValue, previous.assets[0].browser_download_url);
  assert.equal(lookup.updates[0].newDigest, previous.assets[0].digest.slice(7));
  assert.equal(lookup.warnings.length, 1);
  assert.match(lookup.warnings[0].message, /Could not determine new digest/, 'Only the retired-current digest warning is expected');
  const retiredContent = originals.get(ffmpeg.packageFile).replace(ffmpeg.currentValue, retired.currentValue);
  const retiredDep = extractRegex(retiredContent, ffmpeg.packageFile, ffmpeg).deps[0];
  const replaced = await doAutoReplace({ ...retired, ...retiredDep, ...lookup.updates[0] }, retiredContent, false);
  assert(replaced.includes(`${previous.assets[0].browser_download_url}\t${previous.assets[0].digest.slice(7)}`));
  console.log(`PASS: Renovate extracts and updates ${extracted.length} references; archive filters and fixed coverage boundaries hold.`);
} finally {
  await rm(localDir, { recursive: true, force: true });
}
