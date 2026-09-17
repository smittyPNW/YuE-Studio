import { mkdir, cp, readFile, writeFile, access } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(root, 'dist');
const name = 'YuE-Studio-0.5.0-Apple-Silicon.dmg';
const sha256 = 'ffb3baa32630b376deb70316ee53b8bcd34710780f2c849cb78ab450af18e95d';
const release = `https://github.com/smittyPNW/YuE-Studio/releases/download/v0.5.0/${name}`;
await mkdir(path.join(out, 'downloads'), { recursive: true });
for (const file of ['index.html', 'styles.css', 'app.js', 'robots.txt', 'sitemap.xml']) {
  await cp(path.join(root, file), path.join(out, file));
}
await cp(path.join(root, 'assets'), path.join(out, 'assets'), { recursive: true });

let bytes;
for (const candidate of [process.env.RELEASE_DMG_PATH, path.join(out, 'downloads', name)]) {
  if (!candidate) continue;
  try {
    await access(candidate);
    const value = await readFile(candidate);
    if (createHash('sha256').update(value).digest('hex') === sha256) { bytes = value; break; }
  } catch { /* Missing local artifacts are downloaded from the published release. */ }
}
if (!bytes) {
  const response = await fetch(release, { signal: AbortSignal.timeout(120_000) });
  if (!response.ok) throw new Error(`Release download failed: HTTP ${response.status}`);
  bytes = Buffer.from(await response.arrayBuffer());
}
if (createHash('sha256').update(bytes).digest('hex') !== sha256) {
  throw new Error('DMG checksum mismatch; refusing to publish a different binary.');
}
await writeFile(path.join(out, 'downloads', name), bytes);
await writeFile(path.join(out, 'downloads', `${name}.sha256`), `${sha256}  ${name}\n`);
console.log(`Site ready. Verified ${name} (${bytes.length} bytes).`);
