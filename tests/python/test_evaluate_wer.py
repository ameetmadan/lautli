import pytest

from scripts.evaluate_wer import wer


def test_identical_text_ignoring_case_and_punctuation_has_zero_error():
    assert wer("Hoi zäme, wie geit's?", "hoi zäme wie geit s") == 0


def test_substitution_deletion_and_insertion_each_count_once():
    assert wer("a b c d", "a x c") == pytest.approx(0.5)
    assert wer("a b", "a b c d") == pytest.approx(1.0)


def test_empty_reference_is_rejected():
    with pytest.raises(ValueError):
        wer("...", "anything")
