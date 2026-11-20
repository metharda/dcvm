#!/usr/bin/env bash
# Shrink the GIFs VHS writes to docs/demo/: 8 fps and a 64-colour palette
# built from all pixels (stats_mode=full keeps the small coloured labels).
# quickstart.gif also drops the scrolling apt part (7 s to 22 s of playback)
# to 1 fps, which takes it from ~40 MB to ~3.3 MB.
# Needs ffmpeg; the VHS Docker image has it. Run from the repository root.
set -euo pipefail

palette="split[x][y];[x]palettegen=max_colors=64:stats_mode=full:reserve_transparent=0[p];[y][p]paletteuse=dither=none:diff_mode=rectangle"

[ $# -gt 0 ] || set -- docs/demo/hero.gif docs/demo/quickstart.gif docs/demo/backup.gif docs/demo/daily.gif

for g in "$@"; do
  if [ "$(basename "$g")" = quickstart.gif ]; then
    filter="[0:v]split=3[a][b][c];[a]trim=0:7,setpts=PTS-STARTPTS,fps=8[a1];[b]trim=7:22,setpts=PTS-STARTPTS,fps=1[b1];[c]trim=22,setpts=PTS-STARTPTS,fps=8[c1];[a1][b1][c1]concat=n=3:v=1:a=0,$palette"
  else
    filter="[0:v]fps=8,$palette"
  fi
  ffmpeg -v error -i "$g" -filter_complex "$filter" -y "$g.tmp.gif"
  mv "$g.tmp.gif" "$g"
  echo "$g: $(du -h "$g" | cut -f1)"
done
