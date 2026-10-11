"""Download the pinned model with resume and hash verification, reporting JSON-lines progress."""
import hashlib
import json
import sys
import threading
from pathlib import Path

from huggingface_hub import HfApi, snapshot_download

from worker.lautli_worker.model_spec import MODEL_ID, MODEL_REVISION


def emit(value: dict) -> None:
    print(json.dumps(value), flush=True)


def downloaded_bytes(target: Path) -> int:
    return sum(path.stat().st_size for path in target.rglob("*") if path.is_file() and path.suffix != ".lock")


def verify(target: Path, files) -> None:
    for entry in files:
        path = target / entry.rfilename
        if not path.is_file() or path.stat().st_size != entry.size:
            raise RuntimeError(f"{entry.rfilename} is missing or has the wrong size")
        if entry.lfs is not None:
            digest = hashlib.sha256()
            with path.open("rb") as handle:
                while block := handle.read(8 * 1024 * 1024):
                    digest.update(block)
            if digest.hexdigest() != entry.lfs.sha256:
                path.unlink()
                raise RuntimeError(f"{entry.rfilename} failed SHA-256 verification")


def run(target: Path) -> int:
    try:
        info = HfApi().model_info(MODEL_ID, revision=MODEL_REVISION, files_metadata=True)
        total = sum(entry.size for entry in info.siblings)
        failure: list[BaseException] = []

        def download() -> None:
            try:
                snapshot_download(MODEL_ID, revision=MODEL_REVISION, local_dir=target)
            except BaseException as error:
                failure.append(error)

        worker = threading.Thread(target=download, daemon=True)
        worker.start()
        while worker.is_alive():
            emit({"type": "progress", "bytes": min(downloaded_bytes(target), total), "total": total})
            worker.join(timeout=1)
        if failure:
            raise failure[0]
        emit({"type": "verifying"})
        verify(target, info.siblings)
        emit({"type": "done"})
        return 0
    except Exception as error:
        emit({"type": "failed", "message": f"{type(error).__name__}: {error}"})
        return 1


if __name__ == "__main__":
    raise SystemExit(run(Path(sys.argv[1])))
