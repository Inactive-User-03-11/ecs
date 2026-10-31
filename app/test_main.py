from datetime import datetime
from main import schedule_retry, IST


def at(h, m):
    return datetime(2026, 11, 2, h, m, tzinfo=IST)


def test_0730_lands_on_window_open():
    assert schedule_retry(0, at(7, 30)) == at(8, 0)        # 07:30 + 30m = 08:00, allowed


def test_1845_pushed_to_next_morning():
    assert schedule_retry(0, at(18, 45)) == datetime(2026, 11, 3, 8, 0, tzinfo=IST)   # 19:15


def test_2300_pushed_to_next_morning():
    assert schedule_retry(0, at(23, 0)) == datetime(2026, 11, 3, 8, 0, tzinfo=IST)    # 23:30


def test_after_midnight_goes_to_same_day_morning():
    assert schedule_retry(0, at(23, 50)) == datetime(2026, 11, 3, 8, 0, tzinfo=IST)   # 00:20


def test_exhausted():
    assert schedule_retry(3, at(10, 0)) is None