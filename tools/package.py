#!/usr/bin/env python3
"""Build an allowlisted, reproducible plugin ZIP, excluding local test state."""
import argparse
import hashlib
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def package(version, output=None):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?', version):
        raise ValueError('Expected a semantic version')
    output = Path(output or ROOT / 'dist')
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f'gdriveshelf.koplugin-{version}.zip'
    members = [(p, p.relative_to(ROOT).as_posix()) for p in sorted((ROOT / 'gdriveshelf.koplugin').rglob('*')) if p.is_file()]
    members.append((ROOT / 'LICENSE', 'gdriveshelf.koplugin/LICENSE'))
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as handle:
        for source, name in members:
            if source.is_symlink() or source.suffix not in {'.lua', '.pem', '.md', '.py', '.png'} and source.name != 'LICENSE':
                raise ValueError(f'Unexpected package member: {name}')
            if any(word in source.name.lower() for word in ['credential', 'refresh_token', '.part']):
                raise ValueError('Private/runtime file in package input')
            data = source.read_bytes()
            if re.search(rb'(?:gh[pousr]_[A-Za-z0-9]{30,}|GOCSPX-[A-Za-z0-9_-]{15,}|AIza[A-Za-z0-9_-]{30,})', data):
                raise ValueError(f'Possible credential in {name}')
            info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            handle.writestr(info, data)
        info = zipfile.ZipInfo('gdriveshelf.koplugin/PACKAGE_VERSION', (2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        handle.writestr(info, version + '\n')
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix('.zip.sha256').write_text(f'{digest}  {archive.name}\n')
    with zipfile.ZipFile(archive) as handle:
        assert handle.testzip() is None
        assert 'gdriveshelf.koplugin/main.lua' in handle.namelist()
        assert all(p.startswith('gdriveshelf.koplugin/') for p in handle.namelist())
        assert not any('/build/' in p or 'credentials' in p.lower() for p in handle.namelist())
    helper = output / 'gdriveshelf-authorize.py'
    helper.write_bytes((ROOT / 'tools/authorize.py').read_bytes())
    digest = hashlib.sha256(helper.read_bytes()).hexdigest()
    helper.with_suffix('.py.sha256').write_text(f'{digest}  {helper.name}\n')
    return archive

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default='0.1.0')
    args = parser.parse_args()
    print(package(args.version).relative_to(ROOT))
