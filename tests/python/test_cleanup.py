from worker.lautli_worker.cleanup import apply_replacements, collapse_repetitions, is_hallucination, parse_vocabulary


def test_repetition_loops_are_collapsed_but_normal_doubles_survive():
    assert collapse_repetitions("Guter, guter, guter, guter, guter Plan") == "Guter, Guter Plan"
    assert collapse_repetitions("ja ja ja ja") == "ja, ja"
    assert collapse_repetitions("Nein, nein, das stimmt.") == "Nein, nein, das stimmt."


def test_known_subtitle_hallucinations_are_detected():
    assert is_hallucination("Mit Untertiteln von SWISS TXT")
    assert not is_hallucination("Wir besprechen die Untertitelung nächste Woche")


def test_vocabulary_file_yields_prompt_terms_and_replacements():
    terms, replacements = parse_vocabulary("# people\nAmeet\nAmit => Ameet\n\nXY => Acme AG  # company\n")
    assert terms == ["Ameet", "Ameet", "Acme AG"]
    assert replacements == {"Amit": "Ameet", "XY": "Acme AG"}


def test_replacements_match_whole_words_only():
    assert apply_replacements("Amit und Amitabh", {"Amit": "Ameet"}) == "Ameet und Amitabh"
