#!/usr/bin/env bash
# 스팀 덱 데스크톱에서 로닌 컨트롤을 켭니다.
# 게임 모드에서 쓰려면 이 파일을 비 Steam 게임으로 등록하세요.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/ronin-deck"
VENV="$DATA/venv"

if [[ "${1:-}" == "--desktop" ]]; then
  mkdir -p "$HOME/.local/share/applications"
  cat > "$HOME/.local/share/applications/ronin-deck.desktop" << EOF
[Desktop Entry]
Type=Application
Name=로닌 컨트롤
Comment=스팀 덱에서 로닌과 카메라를 다룹니다
Exec=$ROOT/로닌컨트롤.sh
Path=$ROOT
Terminal=false
Categories=Utility;
EOF
  echo "프로그램 메뉴에 로닌 컨트롤을 넣었습니다."
  exit 0
fi

pick_python() {
  if [[ -x "$VENV/bin/python" ]]; then
    echo "$VENV/bin/python"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return
  fi
  echo ""
}

PY="$(pick_python)"
if [[ -z "$PY" ]]; then
  cat << 'EOF'
파이썬이 없습니다. 스팀 덱은 이렇게 준비합니다.

1. 전원 버튼을 짧게 누르고 데스크톱 모드로 전환합니다.
2. 콘솔(Konsole)을 엽니다.
3. 시스템 파이썬을 한 번 설치합니다. 스팀OS 업데이트가 지우면 다시 하면 됩니다.
   sudo steamos-readonly disable
   sudo pacman -S --needed python python-pip
   sudo steamos-readonly enable
4. 이 폴더에서 ./로닌컨트롤.sh 를 다시 실행합니다.

집 폴더에 만들어 두는 실행 환경은 업데이트 뒤에도 남습니다.
EOF
  exit 1
fi

if ! "$PY" -c "import pygame" >/dev/null 2>&1; then
  echo "화면 꾸러미를 집 폴더에 설치합니다."
  if ! "$PY" -m venv "$VENV"; then
    echo "가상 환경을 만들지 못했습니다. 위에 적힌 파이썬 설치를 먼저 하세요."
    exit 1
  fi
  "$VENV/bin/python" -m pip install --upgrade pip
  "$VENV/bin/python" -m pip install -r "$ROOT/requirements.txt"
  PY="$VENV/bin/python"
fi

export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"
export SDL_JOYSTICK_HIDAPI="${SDL_JOYSTICK_HIDAPI:-1}"
exec "$PY" -m 화면코드 "$@"
