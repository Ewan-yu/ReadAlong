from types import SimpleNamespace

from app.providers.align.stable_ts import StableTsWordAligner


def test_stable_ts_output_skips_malformed_words_and_repairs_overlaps() -> None:
    result = SimpleNamespace(
        segments=[
            SimpleNamespace(
                words=[
                    SimpleNamespace(word="before", start=1.0, end=1.1),
                    SimpleNamespace(word="to", start=1.09, end=1.1),
                    SimpleNamespace(word="bad", start=float("nan"), end=1.2),
                    SimpleNamespace(word="after", start=1.1, end=1.3),
                ]
            )
        ]
    )

    timings = StableTsWordAligner._timings_from_result(result)

    assert [item.word for item in timings] == ["before", "to", "after"]
    assert all(item.t_end > item.t_start for item in timings)
    assert all(current.t_start >= previous.t_end for previous, current in zip(timings, timings[1:]))


def test_stable_ts_output_returns_empty_for_missing_word_times() -> None:
    result = SimpleNamespace(
        segments=[SimpleNamespace(words=[SimpleNamespace(word="missing", start=None, end=None)])]
    )

    assert StableTsWordAligner._timings_from_result(result) == ()
