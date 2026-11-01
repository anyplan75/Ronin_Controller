"""스팀 덱 프로그램 폴더를 파이썬이 찾도록 경로를 붙입니다."""

import sys
from pathlib import Path


def root() -> Path:
    return Path(__file__).resolve().parent


def ensure() -> Path:
    folder = root()
    text = str(folder)
    if text not in sys.path:
        sys.path.insert(0, text)
    return folder
