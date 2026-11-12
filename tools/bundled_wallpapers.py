"""Build/verify the catalog for this project's original, offline starter wallpapers.

Development only: the installed application reads the catalog in native Swift.
Run --write after intentionally changing content or generating new previews.
"""
from pathlib import Path
import argparse
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1] / 'native/Resources/StarterWallpapers'
IDS = ['night-lights', 'tide', 'morning-mist']


def catalog():
    entries = []
    for identifier in IDS:
        folder = ROOT / identifier
        assert folder.is_dir() and not folder.is_symlink(), identifier
        paths = sorted(folder.rglob('*'))
        assert all(not p.is_symlink() for p in paths), 'Symlink in bundled content'
        files = {p.relative_to(folder).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in paths if p.is_file()}
        assert 3 <= len(files) <= 256 and 'preview.png' in files and 'record.json' not in files
        assert sum(p.stat().st_size for p in paths if p.is_file()) <= 64 * 1024 * 1024
        for name in files:
            assert len(name.encode()) <= 512 and len(Path(name).parts) <= 8
            assert all(not c.startswith('.') and not any(v in c for v in ['\\', ':', '\0']) for c in Path(name).parts)
            assert (folder / name).stat().st_size <= 32 * 1024 * 1024
        project = json.loads((folder / 'project.json').read_text())
        assert project['type'] in ['scene', 'web', 'video'] and project['file'] in files
        assert project['preview'] == 'preview.png' and 0 < len(project['title'].encode()) <= 256
        identity = identifier + '\n' + project['title'] + '\n' + project['type'] + '\n'
        identity += ''.join(name + '\0' + digest + '\n' for name, digest in sorted(files.items()))
        entries.append(dict(id=identifier, revision=hashlib.sha256(identity.encode()).hexdigest(),
                            title=project['title'], type=project['type'], files=files))
    return dict(version=1, wallpapers=entries)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--write', action='store_true')
    group.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    value = catalog()
    destination = ROOT / 'catalog.json'
    if args.write:
        destination.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    else:
        assert json.loads(destination.read_text()) == value, 'Bundled catalog does not match resources'
    print('Verified 3 original bundled wallpapers: Scene, Web, Video')
