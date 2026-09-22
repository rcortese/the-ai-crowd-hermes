import importlib.util
import io
from pathlib import Path

import pytest

spec=importlib.util.spec_from_file_location('backup_stream',Path(__file__).resolve().parents[1]/'backup_stream.py')
backup=importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


@pytest.mark.parametrize('data',[b'',b'hello',b'a'*(backup.CHUNK+123)])
def test_backup_round_trip(data):
    encrypted=io.BytesIO()
    key=bytes(range(32))
    backup.encrypt(io.BytesIO(data),encrypted,key)
    assert data==b'' or data not in encrypted.getvalue()
    restored=io.BytesIO()
    backup.decrypt(io.BytesIO(encrypted.getvalue()),restored,key)
    assert restored.getvalue()==data


def test_backup_tamper_truncation_wrong_key():
    key=bytes(range(32))
    out=io.BytesIO()
    backup.encrypt(io.BytesIO(b'fixture-not-user-data'),out,key)
    encrypted=out.getvalue()
    for bad in [encrypted[:-1],encrypted[:10],encrypted+b'extra',encrypted[:30]+bytes([encrypted[30]^1])+encrypted[31:]]:
        with pytest.raises(Exception):
            backup.decrypt(io.BytesIO(bad),io.BytesIO(),key)
    with pytest.raises(Exception):
        backup.decrypt(io.BytesIO(encrypted),io.BytesIO(),b'x'*32)
