"""Builds the Fire release: dist/mods/com.necrosis.fire/ and dist/Fire-<version>.zip with a .sha256 beside it.

    python -X utf8 -B release.py [--zip-only] [--tag v<version>]

The ZIP holds mods/com.necrosis.fire/ as EMTK loads it from the Exanima folder. Its entries carry a fixed
timestamp, so the same files always give the same SHA256. Before building, the previous mod folder is moved to
dist/previous/, so the ZIP holds only what this build wrote. --zip-only packages the mod folder as it stands.
--tag (used by CI) stops unless the tag is v<manifest version>.
"""
import argparse
import hashlib
import re
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
NAME = 'Fire'
MOD_ID = 'com.necrosis.fire'
DIST = ROOT / 'dist'


def assemble(extra: list[str]) -> None:
    subprocess.run([sys.executable, '-X', 'utf8', '-B', str(ROOT / 'tools/make_dist.py'), *extra], check=True)


def version(mod: Path) -> str:
    match = re.search(r'^version = "([^"]+)"', (mod / 'manifest.toml').read_text(encoding='utf-8'), re.M)
    if not match:
        raise SystemExit(f'{mod / "manifest.toml"} has no version line')
    return match.group(1)


def set_aside(mod: Path) -> None:
    if mod.exists():
        target = DIST / 'previous' / f'{mod.name}-{datetime.now(timezone.utc):%Y%m%d-%H%M%S}'
        target.parent.mkdir(parents=True, exist_ok=True)
        mod.rename(target)
        print(f'previous build moved to {target}')


def package(mod: Path, name: str) -> Path:
    files = sorted(p for p in mod.rglob('*') if p.is_file())
    archive = mod.parents[1] / f'{name}-{version(mod)}.zip'
    with zipfile.ZipFile(archive, 'w') as z:
        for path in files:
            info = zipfile.ZipInfo(f'mods/{mod.name}/{path.relative_to(mod).as_posix()}', date_time=(1980, 1, 1, 0, 0, 0))
            info.external_attr = 0o644 << 16
            z.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_name(archive.name + '.sha256').write_text(f'{digest}  {archive.name}\n', encoding='ascii')
    print(f'RELEASE={archive} files={len(files)} sha256={digest}')
    return archive


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--zip-only', action='store_true', help='package the mod folder already in dist/')
    parser.add_argument('--tag', help='release tag; must be v<manifest version>')
    args, extra = parser.parse_known_args()
    mod = DIST / 'mods' / MOD_ID
    if args.zip_only and extra:
        parser.error('builder options need a build, not --zip-only')
    if not args.zip_only:
        set_aside(mod)
        assemble(extra)
    if not (mod / 'manifest.toml').is_file():
        raise SystemExit(f'no built mod in {mod}')
    if args.tag and args.tag != f'v{version(mod)}':
        raise SystemExit(f'tag {args.tag} does not match manifest version {version(mod)}')
    package(mod, NAME)
    return 0


if __name__ == '__main__':
    sys.exit(main())
