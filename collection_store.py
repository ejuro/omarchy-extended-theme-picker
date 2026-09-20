#!/usr/bin/env python3
"""Read/write explicit theme collections independently of usage history."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def validate(data):
    if not isinstance(data, dict) or data.get('version') != 1:
        raise ValueError('Unsupported collections file version')
    def slugs(values):
        if not isinstance(values, list) or any(not isinstance(v, str) or not re.fullmatch(r'[\w-][\w.-]*', v) for v in values):
            raise ValueError('Invalid theme list')
        return list(dict.fromkeys(values))
    groups = data.get('collections', [])
    if not isinstance(groups, list) or len(groups) > 100:
        raise ValueError('Too many collections (maximum 100)')
    result = {'version': 1, 'favorites': slugs(data.get('favorites', [])), 'collections': []}
    if 'lastCollection' in data:
        if not isinstance(data['lastCollection'], str) or not re.fullmatch(r'[a-zA-Z0-9_-]{1,80}', data['lastCollection']):
            raise ValueError('Invalid last collection')
        result['lastCollection'] = data['lastCollection']
    if 'layout' in data:
        if data['layout'] not in ('cards', 'grid'):
            raise ValueError('Unknown picker layout')
        result['layout'] = data['layout']
    ids, names = {'defaults', 'favorites', 'custom'}, {'omarchy defaults', 'favorites', 'custom'}
    for group in groups:
        if not isinstance(group, dict):
            raise ValueError('Invalid collection')
        ident, name = group.get('id'), group.get('name')
        if not isinstance(ident, str) or not re.fullmatch(r'[a-zA-Z0-9_-]{1,80}', ident) or ident in ids:
            raise ValueError('Invalid or duplicate collection ID')
        if not isinstance(name, str) or not 1 <= len(name.strip()) <= 40 or any(ord(c) < 32 for c in name):
            raise ValueError('Use a collection name between 1 and 40 characters')
        name = name.strip()
        if name.casefold() in names:
            raise ValueError('A collection with that name already exists')
        ids.add(ident)
        names.add(name.casefold())
        result['collections'].append({'id': ident, 'name': name, 'themes': slugs(group.get('themes', []))})
    return result


def read(path):
    if not path.exists():
        return {'version': 1, 'favorites': [], 'collections': []}
    return validate(json.loads(path.read_text()))


def save(path, data):
    data = validate(data)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.with_suffix('.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        # Do not silently overwrite a file we cannot understand.
        read(path)
        if path.exists():
            shutil.copy2(path, path.with_suffix('.json.bak'))
        fd, temporary = tempfile.mkstemp(prefix='.theme-collections-', dir=path.parent)
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(data, stream, ensure_ascii=False, indent=2)
                stream.write('\n')
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    return data


def uninstall(slug, config, stock, home):
    if not isinstance(slug, str) or not re.fullmatch(r'[\w-][\w.-]*', slug):
        raise ValueError('Invalid theme name')
    if (stock / slug).exists():
        raise ValueError('Omarchy defaults cannot be uninstalled here.')
    current = home / '.local/state/omarchy/current/theme.name'
    if current.exists() and current.read_text().strip() == slug:
        raise ValueError('Apply another theme before uninstalling this one.')
    target = home / '.config/omarchy/themes' / slug
    if not target.is_dir():
        raise ValueError('This theme is no longer installed.')
    # Validate saved collections before changing the installation.
    read(config)
    result = subprocess.run(['omarchy', 'theme', 'remove', slug], capture_output=True, text=True)
    if result.returncode or target.exists() or target.is_symlink():
        raise ValueError('Could not uninstall the theme. ' + (result.stderr or result.stdout).strip()[:300])
    response = {'removed': slug}
    try:
        data = read(config)
        data['favorites'] = [name for name in data['favorites'] if name != slug]
        for group in data['collections']:
            group['themes'] = [name for name in group['themes'] if name != slug]
        response['data'] = save(config, data)
    except (OSError, ValueError, TypeError) as error:
        response['error'] = 'Theme uninstalled, but saved memberships could not be updated: ' + str(error)
    return response


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['load', 'save', 'uninstall'])
    parser.add_argument('payload', nargs='?')
    parser.add_argument('--config', type=Path, default=Path.home() / '.config/omarchy/theme-collections.json')
    parser.add_argument('--stock', type=Path, default=Path(os.environ.get('OMARCHY_PATH', '/usr/share/omarchy')) / 'themes')
    args = parser.parse_args()
    try:
        if args.action == 'uninstall':
            response = uninstall(args.payload, args.config, args.stock, Path.home())
        else:
            response = {'data': save(args.config, json.loads(sys.stdin.readline() if args.payload == '-' else args.payload)) if args.action == 'save' else read(args.config)}
        if 'data' in response:
            data = response['data']
            data['stock'] = sorted(p.name for p in args.stock.iterdir() if p.is_dir())
            user_themes = Path.home() / '.config/omarchy/themes'
            data['installed'] = sorted(p.name for p in user_themes.iterdir() if p.is_dir()) if user_themes.exists() else []
            current = Path.home() / '.local/state/omarchy/current/theme.name'
            data['current'] = current.read_text().strip() if current.exists() else ''
        print(json.dumps(response))
    except (OSError, ValueError, TypeError) as error:
        print(json.dumps({'error': str(error)}))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
