"""Strict offline operational model validation. No interpolation or env value loading.

PyYAML is optional for the public scaffold, required only for this scope. All
operational diagnostics are rule IDs: never echo private keys, values or paths.
"""
import copy
import json
import re


class OperationalError(ValueError):
    pass


def load_yaml(path, *, legacy_baseline=False):
    try:
        import yaml
    except ImportError:
        raise OperationalError('yaml-dependency: install reviewed PyYAML in the validation interpreter') from None

    class StrictLoader(yaml.SafeLoader):
        def compose_node(self, parent, index):
            if self.check_event(yaml.AliasEvent) and not legacy_baseline:
                raise OperationalError('alias: hidden shared bindings prohibited')
            return super().compose_node(parent, index)

        def construct_mapping(self, node, deep=False):
            # Legacy baseline may contain reviewed inheritance. Detect repeated
            # explicit keys BEFORE flattening; a declared override of an inherited
            # key is baseline semantics, not an accidental duplicate.
            if legacy_baseline:
                seen = set()
                for key_node, _ in node.value:
                    if not isinstance(key_node, yaml.ScalarNode) or key_node.tag not in ('tag:yaml.org,2002:str', 'tag:yaml.org,2002:merge'):
                        raise OperationalError('mapping-key: string required')
                    key = key_node.value
                    if key in seen:
                        raise OperationalError('duplicate-key: repeated baseline mapping key')
                    seen.add(key)
                self.flatten_mapping(node)
                return super().construct_mapping(node, deep=deep)
            result = {}
            for key_node, value_node in node.value:
                if key_node.value == '<<':
                    raise OperationalError('merge-key: hidden overrides prohibited')
                key = self.construct_object(key_node, deep=deep)
                if not isinstance(key, str):
                    raise OperationalError('mapping-key: string required')
                if key in result:
                    raise OperationalError('duplicate-key: repeated mapping key before overwrite')
                result[key] = self.construct_object(value_node, deep=deep)
            return result

    try:
        return yaml.load(path.read_text(), Loader=StrictLoader)
    except OperationalError:
        raise
    except (yaml.YAMLError, ValueError, TypeError, OverflowError):
        raise OperationalError('yaml-syntax: invalid document (details redacted)') from None


def normalize_environment(value):
    """Baseline-only conversion; refuse ambiguous passthrough and duplicate lists."""
    if isinstance(value, list):
        result = {}
        for item in value:
            if not isinstance(item, str) or '=' not in item:
                raise OperationalError('baseline-passthrough: explicit bindings required')
            key, item = item.split('=', 1)
            if key in result:
                raise OperationalError('duplicate-key: repeated baseline list name')
            result[key] = item
        return result
    if not isinstance(value, dict):
        raise OperationalError('baseline-environment: mapping or explicit list required')
    result = {}
    for key, item in value.items():
        if isinstance(item, str):
            result[key] = item
        elif isinstance(item, (int, float)) and not isinstance(item, bool):
            result[key] = str(item)
        else:
            raise OperationalError('baseline-passthrough: ambiguous scalar prohibited')
    return result


def canonical(model):
    result = copy.deepcopy(model)
    for service in result['services'].values():
        if 'environment' in service:
            service['environment'] = normalize_environment(service['environment'])
    return result


def sensitive_literal(key, value):
    # These are identifiers, not credentials; still bound to baseline/catalog.
    if key.endswith(('_API_KEY_ENV', '_SESSION_KEY_PREFIX')):
        return False
    digest_name = key.endswith('_SHA256')
    if digest_name and re.fullmatch(r'[a-fA-F0-9]{64}', value):
        return False
    if not digest_name and not re.search(r'(?:^|_)(?:KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)(?:_|$)', key):
        return False
    if value == '':
        return False
    # Only exact references, empty defaults or required diagnostics. Nonempty
    # defaults can leak credentials even when the value also contains ${...}.
    return re.fullmatch(r'\$\{[A-Z_][A-Z0-9_]*(?:(?::-|-)|(?::\?|\?)[^}]+)?\}', value) is None


def lint_operational(model, baseline, catalog):
    errors = []
    fail = errors.append
    if not isinstance(model, dict) or not isinstance(model.get('services'), dict):
        return ['services: mapping-required']
    if not isinstance(baseline, dict) or not isinstance(baseline.get('services'), dict):
        return ['baseline: mapping-required']
    if not isinstance(catalog, dict) or catalog.get('version') != 1 or not isinstance(catalog.get('services'), dict) or not isinstance(catalog.get('env_files'), dict):
        return ['consumer-contract: invalid catalog']
    contracts = catalog['services']
    if set(model['services']) != set(contracts) or set(baseline['services']) != set(contracts):
        fail('service-set: preserve reviewed services')
    for name, service in model['services'].items():
        if name not in contracts:
            continue
        contract = contracts[name]
        if not isinstance(service, dict) or not isinstance(contract, dict):
            fail('service: mapping-required'); continue
        expected = contract.get('environment')
        if not isinstance(expected, dict):
            fail('consumer-contract: missing environment catalog'); continue
        for entry in expected.values():
            if not isinstance(entry, dict) or entry.get('status') not in ('keep', 'uncertain') or not isinstance(entry.get('consumer'), str) or not entry['consumer'].strip():
                fail('consumer-contract: require keep/uncertain and evidence/reason')
        env = service.get('environment', {})
        if not isinstance(env, dict):
            fail('environment: mapping-required'); continue
        if set(env) != set(expected):
            fail('environment-set: preserve reviewed names')
        if list(env) != sorted(env):
            fail('environment-order: alphabetical keys required')
        delivered = set()
        duplicates = set()
        files = service.get('env_file', [])
        if files != contract.get('env_file') or not isinstance(files, list) or not all(isinstance(f, str) for f in files):
            fail('env-file-order: preserve explicit ordered paths'); files = []
        for path in files:
            names = catalog['env_files'].get(path)
            if not isinstance(names, dict) or not all(isinstance(k, str) for k in names):
                fail('env-file-uninventoried: missing per-name consumer manifest'); continue
            for entry in names.values():
                if not isinstance(entry, dict) or entry.get('status') not in ('keep', 'uncertain') or not isinstance(entry.get('consumer'), str) or not entry['consumer'].strip():
                    fail('consumer-contract: env-file name requires disposition/evidence')
            duplicates.update(delivered & set(names)); delivered.update(names)
        duplicates.update(delivered & set(env))
        overrides = contract.get('overrides', [])
        if not isinstance(overrides, list) or not all(isinstance(k, str) for k in overrides):
            fail('consumer-contract: invalid overrides'); overrides = []
        if duplicates != set(overrides):
            fail('unreviewed-layer-override: catalog must enumerate exact duplicate names')
        delivered.update(env)
        for key, value in env.items():
            if not isinstance(value, str):
                fail('string-required: no null/number/boolean/passthrough'); continue
            if sensitive_literal(key, value):
                fail('secret-literal: explicit private reference required')
            if key.endswith('_API_KEY_ENV') and (not re.fullmatch(r'[A-Z_][A-Z0-9_]*', value) or value not in delivered):
                fail('indirection-missing: target name must be delivered')
    try:
        # JSON spellings preserve scalar types; Python equality conflates 1/True.
        before = json.dumps(canonical(baseline), sort_keys=True, allow_nan=False)
        after = json.dumps(canonical(model), sort_keys=True, allow_nan=False)
        if after != before:
            fail('semantic-drift: complete model/bindings differ from baseline')
    except (OperationalError, AttributeError, TypeError, KeyError, ValueError):
        fail('semantic-drift: baseline or candidate cannot be normalized safely')
    return errors
