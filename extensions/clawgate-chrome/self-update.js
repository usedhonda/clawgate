// Decide whether the manifest on disk is a newer version than the one the
// running extension was loaded with (dotted numeric versions).
export function isNewerVersion(disk, running) {
  const parse = (value) => String(value || '').split('.').map((part) => Number.parseInt(part, 10));
  const a = parse(disk), b = parse(running);
  if (a.some(Number.isNaN) || b.some(Number.isNaN) || !a.length || !b.length) return false;
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
    const x = a[i] ?? 0, y = b[i] ?? 0;
    if (x !== y) return x > y;
  }
  return false;
}
