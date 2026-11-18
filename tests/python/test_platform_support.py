import importlib
import io
import sys

import pytest

from worker.lautli_worker import device, mcp_server, platform_support


def test_peak_and_total_memory_are_plausible():
    assert 10 * 1024**2 < platform_support.peak_memory_bytes() < 1024**4
    total = platform_support.total_memory_bytes()
    assert total is None or total > 256 * 1024**2


def test_asr_probe_and_worker_import_without_the_posix_resource_module(monkeypatch):
    """`resource` does not exist on Windows; importing it at module level made the worker unstartable there."""
    from scripts import asr_probe
    from worker.lautli_worker import main

    monkeypatch.setitem(sys.modules, "resource", None)
    importlib.reload(asr_probe)
    importlib.reload(main)


def test_configure_stdio_forces_utf8_and_unix_newlines(monkeypatch):
    raw_out, raw_in = io.BytesIO(), io.BytesIO("Grüezi\n".encode())
    out = io.TextIOWrapper(raw_out, encoding="cp1252", newline="\r\n")
    stdin = io.TextIOWrapper(raw_in, encoding="cp1252")
    monkeypatch.setattr(sys, "stdout", out)
    monkeypatch.setattr(sys, "stdin", stdin)
    monkeypatch.setattr(sys, "stderr", io.TextIOWrapper(io.BytesIO(), encoding="cp1252"))
    platform_support.configure_stdio()
    sys.stdout.write("Grüezi ✓\n")
    sys.stdout.flush()
    assert raw_out.getvalue() == "Grüezi ✓\n".encode()
    assert sys.stdin.readline() == "Grüezi\n"


def test_configure_stdio_ignores_streams_that_cannot_be_reconfigured(monkeypatch):
    monkeypatch.setattr(sys, "stdout", object())
    platform_support.configure_stdio()


def test_device_defaults_to_best_available(monkeypatch):
    monkeypatch.delenv("LAUTLI_DEVICE", raising=False)
    monkeypatch.setattr(device.torch.cuda, "is_available", lambda: True)
    assert device.pick_device() == ("cuda", device.torch.float16)
    monkeypatch.setattr(device.torch.cuda, "is_available", lambda: False)
    monkeypatch.setattr(device.torch.backends.mps, "is_available", lambda: False)
    assert device.pick_device() == ("cpu", device.torch.float32)


def test_device_can_be_forced_to_cpu_even_when_cuda_exists(monkeypatch):
    monkeypatch.setattr(device.torch.cuda, "is_available", lambda: True)
    monkeypatch.setenv("LAUTLI_DEVICE", "CPU")
    assert device.pick_device() == ("cpu", device.torch.float32)


def test_forced_device_never_falls_back_silently(monkeypatch):
    monkeypatch.setattr(device.torch.cuda, "is_available", lambda: False)
    monkeypatch.setenv("LAUTLI_DEVICE", "cuda")
    with pytest.raises(RuntimeError, match="not available"):
        device.pick_device()
    monkeypatch.setenv("LAUTLI_DEVICE", "directml")
    with pytest.raises(ValueError, match="must be one of"):
        device.pick_device()


def test_documents_folder_is_absolute_and_transcript_folder_honors_override(monkeypatch, tmp_path):
    assert mcp_server.documents_folder().is_absolute()
    monkeypatch.delenv("LAUTLI_TRANSCRIPT_DIR", raising=False)
    assert mcp_server.transcript_folder() == mcp_server.documents_folder() / "lautli"
    monkeypatch.setenv("LAUTLI_TRANSCRIPT_DIR", str(tmp_path))
    assert mcp_server.transcript_folder() == tmp_path
