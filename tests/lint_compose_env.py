#!/usr/bin/env python3
"""Offline environment contract lint for the public JSON-subset Compose scaffold.

Does not render Compose, read .env/env_file, inspect images or contact Docker.
Diagnostics deliberately omit source values, including malformed input snippets.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ROOT / 'ops/policies/compose-environment.json'


class InvalidSource(ValueError):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            # Do not echo arbitrary keys: a malformed key itself may be sensitive.
            raise InvalidSource('duplicate-key: repeated object key (before overwrite)')
        if key == '<<':
            raise InvalidSource('merge-key: merge overrides are not allowed')
        result[key] = value
    return result


def load(path):
    try:
        return json.loads(path.read_text(), object_pairs_hook=unique_object,
                          parse_constant=lambda _: reject_constant())
    except json.JSONDecodeError as error:
        raise InvalidSource(f'json-subset: quoted JSON-subset syntax required at '
                            f'line {error.lineno}, column {error.colno}; no YAML aliases/merges') from None


def reject_constant():
    raise InvalidSource('json-subset: non-finite numbers are not valid JSON')


def lint(model, contract):
    errors = []

    def fail(location, rule):
        errors.append(f'{location}: {rule}')

    if not isinstance(model, dict):
        return ['document: mapping-required']
    if set(model) != {'name', 'services', 'networks'}:
        fail('document', 'scaffold-fields: expected name, services, networks only')
    services = model.get('services')
    if not isinstance(services, dict):
        return errors + ['services: mapping-required']
    if set(services) != set(contract['services']):
        fail('services', 'service-set: use the reviewed persona roster')
    for agent in contract['services']:
        if agent not in services:
            continue
        service = services[agent]
        loc = f'services.{agent}'
        if not isinstance(service, dict):
            fail(loc, 'mapping-required')
            continue
        if 'env_file' in service:
            fail(loc, 'env-file-not-in-scaffold: requires separate private review')
        if set(service) - {'image', 'environment', 'volumes', 'networks'}:
            fail(loc, 'scaffold-fields: unexpected service field')
        env = service.get('environment')
        if not isinstance(env, dict):
            fail(loc + '.environment', 'mapping-required: no list or implicit passthrough')
        else:
            expected = contract['environment']
            if set(env) - set(expected):
                fail(loc + '.environment', 'unexpected-variable: update consumer contract after review')
            if set(expected) - set(env):
                fail(loc + '.environment', 'missing-variable: preserve reviewed bindings')
            if list(env) != sorted(env):
                fail(loc + '.environment', 'environment-order: use alphabetical keys')
            for key, value in env.items():
                # Use only allowlisted names in diagnostics, never arbitrary input names/values.
                varloc = loc + '.environment.' + (key if key in expected else '<unreviewed>')
                if not isinstance(value, str):
                    fail(varloc, 'string-required: no null, boolean, number or passthrough')
                    continue
                sensitive = re.search(r'(?:^|_)(?:KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)(?:_|$)', key)
                digest = key.endswith('_SHA256') and re.fullmatch(r'[a-fA-F0-9]{64}', value)
                reference = re.fullmatch(r'\$\{[A-Z_][A-Z0-9_]*(?::\?[^}]+)?\}', value)
                if sensitive and value and not reference and not digest:
                    fail(varloc, 'secret-literal: use separately reviewed private delivery')
                if key in expected and value != expected[key]['binding'].format(service=agent):
                    fail(varloc, 'binding-mismatch: preserve consumer contract')
        prefix = agent.upper().replace('-', '_')
        bindings = {'IMAGE': service.get('image')}
        volumes = service.get('volumes')
        if not isinstance(volumes, list):
            fail(loc + '.volumes', 'mount-mapping-required')
            volumes = []
        for target, suffix in [('/runtime', 'RUNTIME_ROOT'), ('/workspace', 'WORKSPACE_ROOT')]:
            matches = [v for v in volumes if isinstance(v, dict) and v.get('target') == target]
            if len(matches) != 1:
                fail(loc + '.volumes', 'mount-mapping-required: exactly one per environment target')
            bindings[suffix] = matches[0].get('source') if len(matches) == 1 else None
        for suffix, value in bindings.items():
            pattern = r'\$\{' + prefix + '_' + suffix + r':\?[^}]+\}'
            if not isinstance(value, str) or not re.fullmatch(pattern, value):
                fail(loc + '.' + suffix, 'required-interpolation: preserve persona-specific :? input')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compose', type=Path, default=ROOT / 'compose.yaml')
    parser.add_argument('--scope', choices=['scaffold', 'operational'], default='scaffold')
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--contract', type=Path, default=CONTRACT)
    args = parser.parse_args()
    from compose_env_operational import OperationalError, load_yaml, lint_operational
    try:
        if args.scope == 'operational':
            if args.baseline is None:
                raise OperationalError('baseline-required: bind an exact private preimage')
            errors = lint_operational(load_yaml(args.compose), load_yaml(args.baseline, legacy_baseline=True), load(args.contract))
        else:
            errors = lint(load(args.compose), load(args.contract))
    except (InvalidSource, OperationalError) as error:
        errors = [str(error)]
    except (OSError, UnicodeError, RecursionError):
        errors = ['source: read-error (check file existence, encoding and depth)']
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    print('compose_env_lint_ok')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
