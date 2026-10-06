#!/usr/bin/env python3
"""Offline publication gate. Findings never include source paths or matched bytes."""
from __future__ import annotations
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile

# Construct detectors so the detector source is not itself a private fixture.
RULES = [
    ('personal-name', r'(?i)\b' + 'Rodo' + 'lfo' + r'\b'),
    ('host-storage', r'/(?:mnt|media)/(?:user|disk\d+|cache|ssd|private|secrets)(?:/|\b)'),
    ('host-home', r'(?<![A-Za-z0-9])/(?:home/[a-z_][a-z0-9_-]*|root)(?:/|\b)'),
    ('private-ip', r'\b(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b'),
    ('hostname', r'(?i)\b[a-z0-9-]+\.(?:lan|local)\b|\b' + 'media' + r':/'),
    ('session-literal', r'(?i)(?:sess(?:ion|ão)|session_id)[\s`"\x27:=]+[0-9a-f]{12,64}\b'),
    ('known-session', '7cf' + '9865' + 'dd435'),
    ('known-operator-contact', '85034' + '64394'),
    ('known-account-handle', '@the_ai_' + 'crowd_jen_bot'),
    ('known-credential-fingerprint', 'b74895' + 'c5f7f3'),
    ('known-job-id', 'd79831' + 'e43d3c' + '|' + '1b8fd9' + '06f1f6'),
    ('telegram-recipient', r'(?i)(?:TELEGRAM_(?:ALLOWED_USERS|HOME_CHANNEL)|chat[_ ]?id)\s*[=:]\s*["\x27]?-?\d{5,}'),
    ('bot-token', r'\b\d{6,12}:[A-Za-z0-9_-]{30,}\b'),
    ('private-key', r'-----BEGIN (?:OPENSSH|RSA|EC|DSA|ENCRYPTED PRIVATE|PRIVATE) KEY-----'),
    ('credential', r'(?i)(?:api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|password|bot[_-]?token|token|secret)["\x27]?\s*[=:]\s*(?!os\.environ\b|env:|\$\{)["\x27]?[A-Za-z0-9_./+=-]{20,}'),
    ('bearer-credential', r'(?i)Authorization["\x27]?\s*:\s*["\x27]?Bearer\s+[A-Za-z0-9_./+=-]{20,}'),
    ('provider-key', r'\bsk-[A-Za-z0-9_-]{20,}|\bgh[pousr]_[A-Za-z0-9]{20,}|\bAKIA[A-Z0-9]{16}\b'),
]
PROTECTED = {'private', 'runtime', 'state', 'env', 'auth', 'logs', 'cache', 'sessions', 'checkpoints', 'memories', 'secrets'}
FORBIDDEN_NAMES = {'.env', 'auth.json', 'auth.lock', 'config.yaml', '.anthropic_oauth.json'}
WITHDRAWN_PREFIXES = ('ops/moss-', 'ops/delegation-categories/', 'ops/providers/',
                      'ops/build-inputs/', 'ops/supervisor/', 'ops/scripts/',
                      'ops/release/', 'ops/overlays/', 'ops/images/')
WITHDRAWN_FILES = {'ops/deploy-moss-all-in-one.sh', 'ops/install-runtime-backup-retention.sh',
                   'ops/runtime-backup-retention-wrapper.sh', 'ops/repair-agent-permissions.sh',
                   'ops/manifests/base-images.lock.json', 'ops/manifests/hermes-base-v4.lock.json',
                   'ops/manifests/protected-hermes-a2a-base.lock.json',
                   'docs/proposals/model-provider-distribution.md',
                   'docs/operations/staging-reconciliation.md'}


def git(root: Path, *args: str) -> bytes:
    return subprocess.check_output(['git', *args], cwd=root, stderr=subprocess.DEVNULL,
                                   env=os.environ | {'GIT_NO_REPLACE_OBJECTS': '1'})


class Gate:
    def __init__(self):
        self.findings: set[tuple[str, str, str]] = set()
        self.counts = {'files': 0, 'commits': 0, 'objects': 0, 'refs': 0}

    def fail(self, surface: str, locator: str, rule: str):
        # Locator hash permits private investigation without echoing sensitive names.
        self.findings.add((surface, hashlib.sha256(locator.encode()).hexdigest()[:16], rule))

    def scan(self, surface: str, locator: str, data: bytes):
        text = data.decode('utf-8', errors='replace')
        for rule, pattern in RULES:
            if re.search(pattern, text):
                self.fail(surface, locator, rule)

    def path(self, surface: str, name: str, mode: str = ''):
        self.scan(surface, name, name.encode())
        parts = PurePosixPath(name).parts
        if not parts or name.startswith('/') or '..' in parts:
            self.fail(surface, name, 'unsafe-path')
        if set(parts) & PROTECTED or PurePosixPath(name).name in FORBIDDEN_NAMES:
            self.fail(surface, name, 'protected-runtime-path')
        if name.startswith(WITHDRAWN_PREFIXES) or name in WITHDRAWN_FILES:
            self.fail(surface, name, 'withdrawn-operational-path')
        if mode == '160000':
            self.fail(surface, name, 'gitlink')

    def tree(self, root: Path):
        # Index + untracked visible files, not ignored local runtime state. Missing
        # tracked files are pending removals; committed/archive gates inspect those.
        names = git(root, 'ls-files', '--cached', '--others', '--exclude-standard', '-z').split(b'\0')
        modes = {}
        for row in git(root, 'ls-files', '--stage', '-z').split(b'\0'):
            if row:
                metadata, name = row.split(b'\t', 1)
                modes[name] = metadata.split()[0].decode()
        for raw in set(names) - {b''}:
            name = os.fsdecode(raw)
            path = root / name
            if not path.exists() and not path.is_symlink():
                if modes.get(raw) == '160000':
                    self.path('tree', name, '160000')
                continue
            self.path('tree', name, modes.get(raw, ''))
            self.counts['files'] += 1
            if path.is_symlink():
                target = os.readlink(path)
                self.scan('tree', name, target.encode())
                if Path(target).is_absolute() or not (path.parent / target).resolve().is_relative_to(root.resolve()):
                    self.fail('tree', name, 'escaping-symlink')
            elif path.is_file():
                self.scan('tree', name, path.read_bytes())
            else:
                self.fail('tree', name, 'non-file')

    def archive(self, root: Path, revision: str):
        records = {}
        for row in git(root, 'ls-tree', '-r', '-z', revision).split(b'\0'):
            if row:
                metadata, raw = row.split(b'\t', 1)
                mode, kind, oid = metadata.decode().split()
                name = os.fsdecode(raw)
                self.path('tracked', name, mode)
                records[name] = (mode, kind, oid)
        archive = git(root, 'archive', '--format=tar', revision)
        actual = {}
        actual_modes = {}
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            for member in tar:
                if member.isdir():
                    continue
                self.path('archive', member.name)
                if member.issym():
                    data = member.linkname.encode()
                    if member.linkname.startswith('/') or '..' in PurePosixPath(member.linkname).parts:
                        self.fail('archive', member.name, 'escaping-symlink')
                elif member.isfile():
                    stream = tar.extractfile(member)
                    if stream is None:
                        raise ValueError('missing archive member')
                    data = stream.read()
                else:
                    self.fail('archive', member.name, 'non-file')
                    continue
                actual[member.name] = data
                actual_modes[member.name] = '120000' if member.issym() else ('100755' if member.mode & 0o111 else '100644')
                self.scan('archive', member.name, data)
        # export-ignore and export-subst cannot conceal tracked bytes or mutate
        # the published payload. Gitlinks are always forbidden, even omitted ones.
        if set(actual) != set(records):
            self.fail('archive', revision, 'tracked-archive-parity')
        for name, (mode, kind, oid) in records.items():
            if kind == 'blob':
                data = git(root, 'cat-file', 'blob', oid)
                self.scan('tracked', name, data)
                if name in actual and actual[name] != data:
                    self.fail('archive', name, 'tracked-archive-bytes')
                if name in actual_modes and actual_modes[name] != mode:
                    self.fail('archive', name, 'tracked-archive-mode')

    def history(self, root: Path):
        if git(root, 'rev-parse', '--is-shallow-repository').strip() == b'true':
            self.fail('history', 'repository', 'shallow-history')
        grafts = Path(os.fsdecode(git(root, 'rev-parse', '--git-path', 'info/grafts').strip()))
        if not grafts.is_absolute():
            grafts = root / grafts
        if grafts.exists() and grafts.read_bytes().strip():
            self.fail('history', 'repository', 'grafted-history')
        refs = git(root, 'for-each-ref', '--format=%(refname)', 'refs/heads', 'refs/tags').decode().splitlines()
        self.counts['refs'] = len(refs)
        if not refs:
            self.fail('history', 'refs', 'no-public-refs')
            return
        for ref in refs:
            self.scan('ref', ref, ref.encode())
        # No revision path filters. Every object reachable from every head/tag,
        # including annotated tags, messages, old trees, renamed/deleted blobs.
        oids = git(root, 'rev-list', '--objects', '--no-object-names', *refs).decode().splitlines()
        for oid in set(oids):
            kind = git(root, 'cat-file', '-t', oid).decode().strip()
            self.counts['objects'] += 1
            if kind in {'commit', 'tag', 'blob'}:
                self.scan('history-' + kind, oid, git(root, 'cat-file', kind, oid))
            if kind == 'commit':
                self.counts['commits'] += 1
            if kind == 'tree':
                for row in git(root, 'ls-tree', '-z', oid).split(b'\0'):
                    if row:
                        metadata, name = row.split(b'\t', 1)
                        self.path('history-path', os.fsdecode(name), metadata.decode().split()[0])
        # Full paths matter for nested protected roots too.
        commits = git(root, 'rev-list', *refs).decode().splitlines()
        for commit in commits:
            for row in git(root, 'ls-tree', '-r', '-z', commit).split(b'\0'):
                if row:
                    metadata, name = row.split(b'\t', 1)
                    self.path('history-path', os.fsdecode(name), metadata.decode().split()[0])

    def report(self):
        return {'ok': not self.findings, 'counts': self.counts,
                'findings': [{'surface': s, 'locator_sha256_prefix': p, 'rule': r}
                             for s, p, r in sorted(self.findings)]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path('.'))
    parser.add_argument('--mode', choices=['tree', 'archive', 'history', 'all'], default='all')
    parser.add_argument('--revision', default='HEAD')
    args = parser.parse_args()
    gate = Gate()
    try:
        if args.mode in {'tree', 'all'}:
            gate.tree(args.repo)
        if args.mode in {'archive', 'all'}:
            gate.archive(args.repo, args.revision)
        if args.mode in {'history', 'all'}:
            gate.history(args.repo)
    except (OSError, ValueError, tarfile.TarError, subprocess.CalledProcessError):
        gate.fail('gate', 'execution', 'inspection-error')
    print(json.dumps(gate.report(), sort_keys=True))
    return int(bool(gate.findings))


if __name__ == '__main__':
    raise SystemExit(main())
