import hashlib
from types import SimpleNamespace

import pytest

from worker.lautli_worker.download_model import downloaded_bytes, verify


def _entry(name, data, lfs=True):
    digest = hashlib.sha256(data).hexdigest()
    return SimpleNamespace(rfilename=name, size=len(data), lfs=SimpleNamespace(sha256=digest) if lfs else None)


def test_verify_accepts_matching_files(tmp_path):
    (tmp_path / "model.safetensors").write_bytes(b"weights")
    (tmp_path / "config.json").write_bytes(b"{}")
    verify(tmp_path, [_entry("model.safetensors", b"weights"), _entry("config.json", b"{}", lfs=False)])


def test_verify_deletes_and_rejects_corrupt_lfs_file(tmp_path):
    (tmp_path / "model.safetensors").write_bytes(b"weighTs")
    with pytest.raises(RuntimeError, match="SHA-256"):
        verify(tmp_path, [_entry("model.safetensors", b"weights")])
    assert not (tmp_path / "model.safetensors").exists()


def test_verify_rejects_missing_file(tmp_path):
    with pytest.raises(RuntimeError, match="missing"):
        verify(tmp_path, [_entry("model.safetensors", b"weights")])


def test_downloaded_bytes_counts_partial_files_but_not_locks(tmp_path):
    (tmp_path / ".cache").mkdir()
    (tmp_path / ".cache" / "model.incomplete").write_bytes(b"123")
    (tmp_path / "a.lock").write_bytes(b"ignored")
    (tmp_path / "b.json").write_bytes(b"45")
    assert downloaded_bytes(tmp_path) == 5
