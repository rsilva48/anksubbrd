// Prints `app=true|false` and `bridge=true|false` for the changes between two
// revisions. Every commit bumps the version in the Xcode project and the
// bridge's package files, so a file that differs only in its version does not
// count as an app or bridge change.
//   node scripts/changed-components.mjs <base> <head>
import { execFileSync } from 'node:child_process';
import { sameIgnoringVersion, syncedFiles } from './version.mjs';

const [base, head = 'HEAD'] = process.argv.slice(2);
if (!base) {
  console.error('Uso: node scripts/changed-components.mjs <base> [head]');
  process.exit(2);
}
const git = (...args) => execFileSync('git', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
const show = (revision, file) => { try { return git('show', `${revision}:${file}`); } catch { return null; } };

const changed = { app: false, bridge: false };
for (const file of git('diff', '--name-only', base, head).split(/\r?\n/).filter(Boolean)) {
  const component = file.startsWith('ios/') ? 'app' : file.startsWith('proxy/') ? 'bridge' : null;
  if (!component || changed[component]) continue;
  if (syncedFiles.includes(file) && sameIgnoringVersion(file, show(base, file), show(head, file))) continue;
  changed[component] = true;
}
console.log(`app=${changed.app}\nbridge=${changed.bridge}`);
