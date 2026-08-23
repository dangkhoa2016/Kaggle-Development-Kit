#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 - <<'PY'
from pathlib import Path
import re
import subprocess
import sys

pattern = re.compile(
        r'[\u0102\u00c2\u0110\u00ca\u00d4\u01a0\u01af\u0103\u00e2\u0111\u00ea\u00f4\u01a1\u01b0]'        r'|[\u00c0\u00c1\u1ea2\u00c3\u1ea0\u00c8\u00c9\u1eba\u1ebc\u1eb8\u00cc\u00cd\u1ec8\u0128\u1eca\u00d2\u00d3\u1ece\u00d5\u1ecc\u00d9\u00da\u1ee6\u0168\u1ee4\u1ef2\u00dd\u1ef6\u1ef8\u1ef4\u00e0\u00e1\u1ea3\u00e3\u1ea1\u00e8\u00e9\u1ebb\u1ebd\u1eb9\u00ec\u00ed\u1ec9\u0129\u1ecb\u00f2\u00f3\u1ecf\u00f5\u1ecd\u00f9\u00fa\u1ee7\u0169\u1ee5\u1ef3\u00fd\u1ef7\u1ef9\u1ef5]'        r'|[\u1ea4\u1ea6\u1ea8\u1eaa\u1eac\u1eae\u1eb0\u1eb2\u1eb4\u1eb6\u1ebe\u1ec0\u1ec2\u1ec4\u1ec6\u1ed0\u1ed2\u1ed4\u1ed6\u1ed8\u1eda\u1edc\u1ede\u1ee0\u1ee2\u1ee8\u1eea\u1eec\u1eee\u1ef0\u1ea5\u1ea7\u1ea9\u1eab\u1ead\u1eaf\u1eb1\u1eb3\u1eb5\u1eb7\u1ebf\u1ec1\u1ec3\u1ec5\u1ec7\u1ed1\u1ed3\u1ed5\u1ed7\u1ed9\u1edb\u1edd\u1edf\u1ee1\u1ee3\u1ee9\u1eeb\u1eed\u1eef\u1ef1]')
files = [x for x in subprocess.check_output(['git', 'ls-files', '-z']).decode().split('\0') if x]
names = set(files)
violations = []
orphans = []

for name in files:
    if name.endswith('.vi.md'):
        english = name[:-6] + '.md'
        if english not in names:
            orphans.append(f'{name}: missing English counterpart {english}')
        continue
    if name.endswith('.md') and name[:-3] + '.vi.md' in names:
        continue
    path = Path(name)
    if not path.is_file():
        continue
    try:
        text = path.read_text(encoding='utf-8')
    except UnicodeDecodeError:
        continue
    for lineno, line in enumerate(text.splitlines(), 1):
        if pattern.search(line):
            violations.append(f'{name}:{lineno}: {line}')

if orphans or violations:
    if orphans:
        print('Vietnamese documentation without an English counterpart:', file=sys.stderr)
        print('\n'.join(orphans), file=sys.stderr)
    if violations:
        print('Vietnamese text found outside paired bilingual documentation:', file=sys.stderr)
        print('\n'.join(violations), file=sys.stderr)
    sys.exit(1)

print('PASS: Vietnamese text is confined to paired bilingual documentation.')
PY

NOTEBOOK="$ROOT/notebooks/kaggle-dev-bootstrap.ipynb"
if grep -Eq 'YOUR_GITHUB_USERNAME|YOUR_REPOSITORY' "$NOTEBOOK"; then
  echo 'Kaggle bootstrap notebook still contains a repository clone placeholder.' >&2
  exit 1
fi
if ! grep -Fq 'https://github.com/dangkhoa2016/Kaggle-Development-Kit.git' "$NOTEBOOK"; then
  echo 'Kaggle bootstrap notebook does not default to the official public repository.' >&2
  exit 1
fi
echo 'PASS: Kaggle bootstrap notebook defaults to the official clone URL and contains no repository placeholder.'
