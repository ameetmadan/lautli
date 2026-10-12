import re

# Phrases Whisper-family models emit over silence or crosstalk because of their broadcast-subtitle training data.
HALLUCINATIONS = (
    "untertiteln von", "untertitel von", "swiss txt", "swisstxt", "ard text", "im auftrag von funk",
    "ich bedanke mich für die aufmerksamkeit", "vielen dank fürs zuschauen",
)

_WORD_RUN = re.compile(r"\b([\w']+)([,.!?]?\s+\1\b[,.!?]?){2,}", re.IGNORECASE)


def collapse_repetitions(text: str) -> str:
    """Keep two occurrences of any word repeated three or more times in a row ("warte, warte, warte, ..." loops)."""
    return _WORD_RUN.sub(lambda match: f"{match.group(1)}, {match.group(1)}", text)


def is_hallucination(text: str) -> bool:
    lowered = text.casefold()
    return any(phrase in lowered for phrase in HALLUCINATIONS)


def parse_vocabulary(content: str) -> tuple[list[str], dict[str, str]]:
    """One entry per line: `Term` biases the decoder; `wrong => Right` also rewrites the output. `#` starts a comment."""
    terms, replacements = [], {}
    for line in content.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        wrong, arrow, right = line.partition("=>")
        term = (right if arrow else wrong).strip()
        terms.append(term)
        if arrow and wrong.strip():
            replacements[wrong.strip()] = term
    return terms, replacements


def apply_replacements(text: str, replacements: dict[str, str]) -> str:
    for wrong, right in replacements.items():
        text = re.sub(rf"(?<!\w){re.escape(wrong)}(?!\w)", right, text, flags=re.IGNORECASE)
    return text
