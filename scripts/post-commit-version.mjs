import { execFileSync } from 'node:child_process';

const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();
const existing = git('tag', '--points-at', 'HEAD', '--list', 'v[0-9]*');
if (existing.split(/\r?\n/).some((tag) => /^v\d+\.\d+\.\d+$/.test(tag))) {
  console.log('El commit ya tiene una etiqueta semántica; no se crea otra.');
  process.exit(0);
}
const versions = git('tag', '--list', 'v[0-9]*').split(/\r?\n/)
  .map((tag) => /^v(\d+)\.(\d+)\.(\d+)$/.exec(tag))
  .filter(Boolean).map((m) => m.slice(1).map(Number))
  .sort((a, b) => b[0] - a[0] || b[1] - a[1] || b[2] - a[2]);
const [major, minor, patch] = versions[0] ?? [0, 1, 0];
const tag = `v${major}.${minor}.${patch + 1}`;
git('tag', '-a', tag, '-m', `Release ${tag}`);
console.log(`Versión creada: ${tag}. Usa git push --follow-tags para publicarla.`);
