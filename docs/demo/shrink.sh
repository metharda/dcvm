#!/usr/bin/env bash
# Shrink the GIFs VHS writes to docs/demo/: 20 fps keeps typing and spinners
# smooth, and a 64-colour palette built from all pixels (stats_mode=full)
# keeps the small coloured labels.
# Needs ffmpeg; the VHS Docker image has it. Run from the repository root.
set -euo pipefail

[ $# -gt 0 ] || set -- docs/demo/hero.gif docs/demo/quickstart.gif docs/demo/backup.gif docs/demo/daily.gif

for g in "$@"; do
  [ -f "$g" ] || continue
  ffmpeg -v error -i "$g" -filter_complex \
    "[0:v]fps=20,split[x][y];[x]palettegen=max_colors=64:stats_mode=full:reserve_transparent=0[p];[y][p]paletteuse=dither=none:diff_mode=rectangle" \
    -y "$g.tmp.gif"
  mv "$g.tmp.gif" "$g"
  echo "$g: $(du -h "$g" | cut -f1)"
done
