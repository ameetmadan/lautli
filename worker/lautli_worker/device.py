import os

import torch

SUPPORTED_DEVICES = ("cuda", "mps", "cpu")


def pick_device() -> tuple[str, torch.dtype]:
    """Best available device, or the one named by LAUTLI_DEVICE (cpu, cuda or mps).

    An explicit choice never falls back silently: asking for CUDA on a machine without it is an error, so a
    CPU-versus-CUDA comparison cannot accidentally measure the wrong path.
    """
    requested = os.environ.get("LAUTLI_DEVICE", "").strip().lower()
    available = {
        "cuda": torch.cuda.is_available(),
        "mps": torch.backends.mps.is_available(),
        "cpu": True,
    }
    if requested:
        if requested not in SUPPORTED_DEVICES:
            raise ValueError(f"LAUTLI_DEVICE must be one of {', '.join(SUPPORTED_DEVICES)}")
        if not available[requested]:
            raise RuntimeError(f"LAUTLI_DEVICE={requested} is not available on this machine")
        device = requested
    else:
        device = next(name for name in SUPPORTED_DEVICES if available[name])
    return device, torch.float32 if device == "cpu" else torch.float16
