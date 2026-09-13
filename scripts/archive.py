#!/usr/bin/env python3
"""Create portable source or host-specific release archives without local secrets."""
import argparse
import gzip
import hashlib
import os
from pathlib import Path
import re
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {'.git', 'node_modules', '_build', 'elm-stuff', 'test-results', 'dist',
            'data', 'uploads', 'tooling', '__pycache__', '.venv', '.build'}


def source_files():
    # Only project-owned roots are eligible: backups beside the checkout cannot
    # accidentally enter a release. Reject links instead of dereferencing them.
    roots = ['src', 'priv', 'web', 'native', 'scripts', 'test', 'deploy', 'docs']
    files = [p for p in ROOT.iterdir() if p.name in {
        'Makefile', 'VERSION', 'LICENSE', 'README.md', 'BUILD_STATUS.md',
        'rebar.config', 'rebar.lock', 'package.json', 'package-lock.json',
        '.gitignore', '.env.example', '.env.development.example'} or p.name.startswith('RELEASE_NOTES_') and p.suffix == '.md']
    for folder in roots:
        for base, dirs, names in os.walk(ROOT / folder, followlinks=False):
            for name in dirs:
                if (Path(base) / name).is_symlink():
                    raise ValueError('Refusing a source directory symlink')
            dirs[:] = sorted(d for d in dirs if d not in EXCLUDED)
            for name in sorted(names):
                p = Path(base) / name
                if name.startswith('.env') or name == 'erl_crash.dump' or name.startswith('.pw-media-quality.'):
                    continue
                if p.suffix.lower() in {'.pem', '.key', '.p12', '.pfx', '.beam', '.pyc', '.log', '.dump', '.bak', '.gz', '.zip'}:
                    continue
                if p.relative_to(ROOT).as_posix() == 'priv/bin/pw-media-quality':
                    continue
                files.append(p)
    return sorted(files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kind', choices=['source', 'release'])
    parser.add_argument('--profile', choices=['default', 'cluster'], default='default')
    args = parser.parse_args()
    version = (ROOT / 'VERSION').read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-\d+)?', version):
        raise ValueError('Invalid release version')
    epoch = int(os.environ.get('SOURCE_DATE_EPOCH', '0'))
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    if args.kind == 'source':
        filename = f'Plainwire-{version}.tar.gz'
        base = ROOT
        files = source_files()
        prefix = f'Plainwire-{version}/'
    else:
        filename = f'plainwire-relay-{version}-{args.profile}-{os.uname().machine}.tar.gz'
        base = ROOT / '_build' / args.profile / 'rel' / 'plainwire_relay'
        if not (base / 'bin/plainwire_relay').is_file():
            raise ValueError('Build and check the release first')
        files = sorted(base.rglob('*'))
        prefix = ''
    output = dist / filename
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=dist, delete=False) as raw:
            temporary = Path(raw.name)
            with gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=epoch) as zipped:
                with tarfile.open(fileobj=zipped, mode='w', format=tarfile.PAX_FORMAT) as archive:
                    for path in files:
                        if args.kind == 'source' and path.is_symlink():
                            raise ValueError('Refusing a source file symlink')
                        if path.is_symlink():
                            path.resolve().relative_to(base.resolve())
                        if not (path.is_file() or path.is_dir() or path.is_symlink()):
                            raise ValueError('Unsupported archive entry')
                        info = archive.gettarinfo(str(path), prefix + path.relative_to(base).as_posix())
                        info.uid = info.gid = 0
                        info.uname = info.gname = ''
                        info.mtime = epoch
                        info.mode = 0o755 if info.isdir() or info.mode & 0o111 else 0o644
                        if info.isfile():
                            with path.open('rb') as contents:
                                archive.addfile(info, contents)
                        else:
                            archive.addfile(info)
        temporary.replace(output)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    digest = hashlib.sha256()
    with output.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    output.with_suffix(output.suffix + '.sha256').write_text(f'{digest.hexdigest()}  {output.name}\n')
    print(output)


if __name__ == '__main__':
    main()
