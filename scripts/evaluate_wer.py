"""Measure word error rate over a folder of paired recordings: name.wav (16 kHz) and name.txt (reference)."""
import argparse
import json
import re
from pathlib import Path


def words(text: str) -> list[str]:
    return re.findall(r"\w+", text.lower())


def edit_distance(reference: list[str], hypothesis: list[str]) -> int:
    previous = list(range(len(hypothesis) + 1))
    for i, ref_word in enumerate(reference, 1):
        current = [i]
        for j, hyp_word in enumerate(hypothesis, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ref_word != hyp_word)))
        previous = current
    return previous[-1]


def wer(reference: str, hypothesis: str) -> float:
    reference_words = words(reference)
    if not reference_words:
        raise ValueError("reference transcript is empty")
    return edit_distance(reference_words, words(hypothesis)) / len(reference_words)


def evaluate(folder: Path, model_path: Path) -> dict:
    from scripts.asr_probe import transcribe

    rows, errors, total_words = [], 0, 0
    for audio in sorted(folder.glob("*.wav")):
        reference = audio.with_suffix(".txt").read_text(encoding="utf-8")
        result = transcribe(audio, model_path)
        reference_words = words(reference)
        distance = edit_distance(reference_words, words(result["text"]))
        errors += distance
        total_words += len(reference_words)
        rows.append({"file": audio.name, "wer": round(distance / len(reference_words), 3),
                     "real_time_factor": result["real_time_factor"], "peak_rss_gb": result["peak_rss_gb"]})
    if not rows:
        raise SystemExit(f"No .wav files with matching .txt references in {folder}")
    return {"files": rows, "overall_wer": round(errors / total_words, 3)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    parser.add_argument("--model", type=Path, default=Path(".models/flix-swissgerman-full"))
    args = parser.parse_args()
    print(json.dumps(evaluate(args.folder, args.model), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
