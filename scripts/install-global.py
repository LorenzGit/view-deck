#!/usr/bin/env python3
"""Install the built ViewDeck CLI, companion app, and shared agent skill."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import uuid


def tree_digest(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


def is_viewdeck_skill(path):
    source = path / 'SKILL.md'
    return source.is_file() and re.search(
        r'''(?m)^name:\s*['"]?viewdeck-qa['"]?\s*$''', source.read_text()) is not None


def install(repo, home, hosts):
    binary = repo / 'dist/native/viewdeck'
    app = repo / 'dist/native/ViewDeck.app'
    skill_source = repo / '.agents/skills/viewdeck-qa'
    if not binary.is_file() or not app.is_dir() or not is_viewdeck_skill(skill_source):
        raise RuntimeError('Build ViewDeck first with zsh scripts/build-native-app.sh.')
    prefix = home / '.local/share/viewdeck'
    canonical = home / '.agents/skills/viewdeck-qa'
    executable = prefix / 'viewdeck'
    cli_link = home / '.local/bin/viewdeck'
    roots = {'codex': '.codex/skills', 'claude': '.claude/skills', 'hermes': '.hermes/skills'}
    links = [home / roots[host] / 'viewdeck-qa' for host in hosts]
    # Preflight every destination before changing any existing installation.
    marker = prefix / 'installation.json'
    if prefix.exists() and any(prefix.iterdir()) and not marker.is_file():
        raise RuntimeError(f'Refusing to overwrite an unmanaged directory: {prefix}')
    if canonical.is_symlink():
        raise RuntimeError(f'The canonical skill must be a complete directory, not a symlink: {canonical}')
    if canonical.exists() and not is_viewdeck_skill(canonical):
        raise RuntimeError(f'Unrelated canonical destination exists: {canonical}')
    for link in links:
        if link.is_symlink() and link.resolve() == canonical.resolve():
            continue
        if link.exists() or link.is_symlink():
            if not is_viewdeck_skill(link):
                raise RuntimeError(f'Unrelated skill installation exists: {link}')
    if cli_link.exists() or cli_link.is_symlink():
        if not cli_link.is_symlink() or cli_link.resolve() not in [executable.resolve(), binary.resolve()]:
            raise RuntimeError(f'Preserving an existing unrelated executable: {cli_link}')
    prefix.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:6]
    backup_root = prefix / 'backups' / stamp
    backups = []

    def backup(path):
        destination = backup_root / str(path.relative_to(home))
        destination.parent.mkdir(parents=True, exist_ok=True)
        path.rename(destination)
        backups.append(str(destination))

    # Replace executable inodes atomically, allowing existing sessions to finish.
    temporary_binary = prefix / ('.viewdeck-' + uuid.uuid4().hex)
    shutil.copy2(binary, temporary_binary)
    temporary_binary.chmod(0o755)
    os.replace(temporary_binary, executable)
    installed_app = prefix / 'ViewDeck.app'
    staging_app = prefix / ('.ViewDeck-' + uuid.uuid4().hex + '.app')
    shutil.copytree(app, staging_app, symlinks=True)
    if installed_app.exists():
        backup(installed_app)
    os.replace(staging_app, installed_app)
    if not canonical.exists() or tree_digest(canonical) != tree_digest(skill_source):
        staging_skill = prefix / ('.skill-' + uuid.uuid4().hex)
        shutil.copytree(skill_source, staging_skill)
        canonical.parent.mkdir(parents=True, exist_ok=True)
        if canonical.exists():
            backup(canonical)
        os.replace(staging_skill, canonical)
    for link, target in [(cli_link, executable)] + [(link, canonical) for link in links]:
        if link.is_symlink() and link.resolve() == target.resolve():
            continue
        link.parent.mkdir(parents=True, exist_ok=True)
        if link.exists() or link.is_symlink():
            backup(link)
        link.symlink_to(target, target_is_directory=target.is_dir())
    for link in links:
        if link.resolve() != canonical.resolve() or not (link / 'SKILL.md').is_file():
            raise RuntimeError(f'Skill link verification failed: {link}')
    if cli_link.resolve() != executable.resolve() or not os.access(cli_link, os.X_OK):
        raise RuntimeError('CLI installation verification failed.')
    result = {'cli': str(cli_link), 'executable': str(executable), 'app': str(installed_app),
              'canonicalSkill': str(canonical), 'skillLinks': [str(p) for p in links],
              'backups': backups, 'source': str(repo), 'installedAt': stamp}
    marker.write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--home', type=Path, default=Path.home(), help='User home directory (also supports isolated installation tests)')
    parser.add_argument('--host', action='append', choices=['codex', 'claude', 'hermes'], help='Assistant links to install; default: Codex and Claude Code')
    args = parser.parse_args()
    try:
        print(json.dumps(install(args.repo.resolve(), args.home.resolve(), args.host or ['codex', 'claude']), indent=2))
    except (RuntimeError, OSError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
