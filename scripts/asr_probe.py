import argparse
import json
import resource
import time
from pathlib import Path

import numpy as np
import soundfile as sf
from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor, pipeline

from worker.lautli_worker.device import pick_device
from worker.lautli_worker.model_spec import MODEL_ID, MODEL_REVISION



def load_audio(path: str | Path) -> tuple[np.ndarray, int]:
    samples, sample_rate = sf.read(path, dtype="float32", always_2d=True)
    if sample_rate != 16_000:
        raise ValueError(f"Expected 16 kHz audio, got {sample_rate} Hz")
    return samples.mean(axis=1, dtype=np.float32), sample_rate


def segment_records(result: dict) -> list[dict[str, int | str]]:
    segments = []
    for chunk in result.get("chunks", []):
        start, end = chunk.get("timestamp", (None, None))
        if start is None:
            continue
        segments.append(
            {
                "start_ms": round(start * 1000),
                "end_ms": round(end * 1000) if end is not None else 0,
                "text": chunk["text"].strip(),
            }
        )
    return segments


def transcribe(path: str | Path, model_path: str | Path) -> dict:
    samples, sample_rate = load_audio(path)
    device, dtype = pick_device()
    processor = AutoProcessor.from_pretrained(model_path, local_files_only=True)
    model = AutoModelForSpeechSeq2Seq.from_pretrained(
        model_path,
        dtype=dtype,
        low_cpu_mem_usage=True,
        use_safetensors=True,
        local_files_only=True,
    ).to(device)
    asr = pipeline(
        "automatic-speech-recognition",
        model=model,
        tokenizer=processor.tokenizer,
        feature_extractor=processor.feature_extractor,
        dtype=dtype,
        device=device,
    )

    audio_seconds = len(samples) / sample_rate
    started = time.perf_counter()
    result = asr(
        {"raw": samples, "sampling_rate": sample_rate},
        chunk_length_s=30,
        stride_length_s=(5, 5),
        return_timestamps=True,
        generate_kwargs={"language": "german", "task": "transcribe"},
    )
    inference_seconds = time.perf_counter() - started
    return {
        "model_id": MODEL_ID,
        "model_revision": MODEL_REVISION,
        "text": result["text"],
        "segments": segment_records(result),
        "audio_seconds": round(audio_seconds, 2),
        "inference_seconds": round(inference_seconds, 2),
        "real_time_factor": round(audio_seconds / inference_seconds, 2),
        "peak_rss_gb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024**3, 2),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmark local Swiss German Whisper inference")
    parser.add_argument("audio", type=Path)
    parser.add_argument("--model", type=Path, default=Path(".models/flix-swissgerman-full"))
    args = parser.parse_args()
    print(json.dumps(transcribe(args.audio, args.model), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
