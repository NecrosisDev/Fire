"""Builds the ready-to-ship mod into dist/mods/com.necrosis.fire from source: the manifest and the
scripts it names. Run tools/make_flammables.py first when the installed levels change.

    python -X utf8 -B tools/make_dist.py
"""
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOD_ID = 'com.necrosis.fire'


def main() -> int:
    manifest = (ROOT / 'manifest.toml').read_text(encoding='utf-8')
    scripts = sorted(set(re.findall(r'^\w+ = "(scripts/[\w.]+)"', manifest, re.M)))
    out = ROOT / 'dist' / 'mods' / MOD_ID
    (out / 'scripts').mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / 'manifest.toml', out / 'manifest.toml')
    for script in scripts:
        shutil.copyfile(ROOT / script, out / script)
    version = re.search(r'^version = "([^"]+)"', manifest, re.M).group(1)
    print(f'FIRE_BUILT={out} version={version} scripts={len(scripts)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
