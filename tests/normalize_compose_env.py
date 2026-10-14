#!/usr/bin/env python3
"""Expand reviewed legacy inheritance and make service env explicit, offline.

Output is a private source candidate, NOT a deployment file promotion. Comments
are not retained. Full parsed model equality is checked by the paired lint.
"""
import argparse
import json
import os
from pathlib import Path
import sys
from compose_env_operational import OperationalError, load_yaml, canonical


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        model = canonical(load_yaml(args.baseline, legacy_baseline=True))
        for service in model['services'].values():
            if 'environment' in service:
                service['environment'] = dict(sorted(service['environment'].items()))
        text = json.dumps(model, indent=2, allow_nan=False) + '\n'
        # Exclusive create: never silently overwrite a candidate, baseline or
        # symlink target. Private mode does not depend on caller's umask.
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream:
            stream.write(text)
    except (OperationalError, OSError, UnicodeError, ValueError, KeyError, TypeError, AttributeError, RecursionError):
        print('normalization-failed: invalid/ambiguous model or output already exists (details redacted)', file=sys.stderr)
        return 1
    print('compose_env_normalized; run lint against the exact baseline and reviewed catalog')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
