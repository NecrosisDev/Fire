"""Writes scripts/flammables.lua: every placed model name in the installed levels that is made of
wood, cloth or straw, with its material, most common first, and the name prefixes that find them.

The game has no material flag on placed scenery, so the class comes from the model name (rules below).
Names longer than 16 characters are left out: world.nearby takes model names of at most 16.
Hellmode installs keep the vanilla Resource.rpk in Resource.zip.001...; its levels are read too, so the list covers\nboth games. The install is only read; only names are written, never game data.

    python -X utf8 -B tools/make_flammables.py [--game <Exanima folder>] [--exanimate <ExaniMate service folder>]
"""
import argparse
import os
import sys
import tempfile
import zipfile
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# First matching rule wins. Not flammable: metal, stone, glass and pottery sets, and fixed architecture.
NOT = ('brass', 'rusty', 'ir_', 'iron', 'mrb', 'marble', 'stn', 'stone', 'glass', 'braz', 'brat5', 'tin',
       'bits', 'ring', 'hoop', 'hook', 'vice', 'lid', 'pole', 'sign', 'fence', 'bathtub', 'minecart',
       'anchor', 'plate', 'bucket brass', 'crater', 'cotto', 'target', 'blowtube', 'cup')
RULES = (
    ('straw', ('hay', 'straw', 'stickbundle', 'basket', 'wckb', 'wkr', 'sack', 'mattress', 'pillow',
               'bed', 'cot')),
    ('cloth', ('cloth', 'rug', 'carpet', 'curtain', 'awning', 'bann', 'banner', 'tapest')),
    ('logs', ('log', 'llog', 'firew')),
    ('wood', ('crate', 'barrel wdo', 'barrel mtob', 'barrel a', 'barrels', 'barrelstand', 'barrelplank',
              'table', 'chair', 'stool', 'bench', 'desk', 'shelf', 'bshelf', 'bookstand', 'bookstnd',
              'cart', 'ladder', 'plank', 'barricade', 'scaff', 'stagewood', 'traywood', 'bathwood',
              'trough', 'washtube', 'tub mtob', 'bucket wod', 'bucket mtob', 'box open', 'trainingdummy',
              'potbench', 'awningframe', 'wd_bench', 'doorplanks')),
)


def classify(name: str) -> str | None:
    low = name.lower()
    if any(word in low for word in NOT):
        # Wooden sets that share a word with the exclusions.
        if not any(word in low for word in ('cratel', 'cratesmall', 'chairbroken', 'bed', 'plankbed')):
            return None
    for material, words in RULES:
        if any(word in low for word in words):
            return material
    return None


def level_names(game: Path, exanimate: Path) -> Counter:
    sys.path.insert(0, str(exanimate))
    from exanimate import level, rpk
    counts = Counter()
    seen = set()
    overrides = game / 'hm_files' / 'Resource'
    if overrides.is_dir():
        for path in sorted(overrides.glob('*.rfc')):
            data = path.read_bytes()
            if level.is_level(data):
                seen.add(path.name.lower())
                for placed in level.parse(data).objects:
                    counts[placed.name] += 1
    def add_archive(archive: Path, skip=()):
        for member in rpk.members(archive):
            if member.name.lower().endswith('.rfc') and member.name.lower() not in skip:
                data = rpk.read(archive, member.name)
                if level.is_level(data):
                    for placed in level.parse(data).objects:
                        counts[placed.name] += 1
    add_archive(game / 'Resource.rpk', seen)
    parts = sorted(game.glob('Resource.zip.0*'))
    if parts:
        with tempfile.TemporaryDirectory(prefix='fire-vanilla-') as tmp:
            joined = Path(tmp) / 'vanilla.zip'
            with joined.open('wb') as out:
                for part in parts:
                    out.write(part.read_bytes())
            with zipfile.ZipFile(joined) as archive:
                (Path(tmp) / 'Resource.rpk').write_bytes(archive.read(archive.namelist()[0]))
            add_archive(Path(tmp) / 'Resource.rpk')
    return counts


def prefixes(counts, rows) -> list[str]:
    """The shortest prefixes (3+ characters) that every flammable name starts with and no other placed name
    in the installed levels does, most placements first: world.nearby (runtime 0.28.0-r51) takes 64 a call,
    and the most common 64 find nearly every flammable placement."""
    names = {n.lower() for n in counts if 0 < len(n.encode('latin-1')) <= 16}
    flammable = {name.lower() for name, _, _ in rows}
    placed = {name.lower(): n for name, _, n in rows}
    chosen = []
    for length in range(3, 17):
        for name in sorted(flammable):
            p = name[:length]
            if any(name.startswith(c) for c in chosen):
                continue
            if all(other in flammable for other in names if other.startswith(p)):
                chosen.append(p)
    return sorted(chosen, key=lambda p: (-sum(n for name, n in placed.items() if name.startswith(p)), p))


def lua_string(text: str) -> str:
    return '"' + text.replace('\\', '\\\\').replace('"', '\\"') + '"'


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--game', type=Path, default=os.environ.get('EXANIMA_DIR'), required=not os.environ.get('EXANIMA_DIR'),
                        help='the Exanima folder (or set EXANIMA_DIR)')
    parser.add_argument('--exanimate', type=Path,
                        default=os.environ.get('EXANIMATE_SERVICE'),
                        required=not os.environ.get('EXANIMATE_SERVICE'), help='the ExaniMate service folder (or set EXANIMATE_SERVICE)')
    args = parser.parse_args()
    counts = level_names(args.game, args.exanimate)
    rows = [(name, classify(name), n) for name, n in counts.most_common()]
    rows = [(name, material, n) for name, material, n in rows if material and 0 < len(name.encode('latin-1')) <= 16]
    found = prefixes(counts, rows)
    lines = ['-- Generated by tools/make_flammables.py from the installed (and vanilla) levels: placed model names made of',
             '-- wood, cloth or straw, most common first, with how many the levels place; and the prefixes that',
             '-- find exactly these names, most placements first. Do not edit by hand.',
             'return {', '  names = {']
    lines += [f'    {{{lua_string(name)}, "{material}"}},  -- {n}' for name, material, n in rows]
    lines += ['  },', '  prefixes = {']
    lines += [f'    {lua_string(p)},' for p in found]
    lines += ['  },', '}']
    out = ROOT / 'scripts' / 'flammables.lua'
    out.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    by = Counter(material for _, material, _ in rows)
    print(f'FLAMMABLES={len(rows)} {dict(by)} prefixes={len(found)} -> {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
