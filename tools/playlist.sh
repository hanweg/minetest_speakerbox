#!/bin/bash
# Convert a folder of music into the Ogg Vorbis a playlist speaker can play.
#
#   playlist.sh [folder]        default: the mod's own playlist/ directory
#   playlist.sh --list [folder] say what is there, convert nothing
#
# Luanti decodes Ogg Vorbis and nothing else, so an mp3, m4a, flac or the
# audio of an mp4 has to be converted first. Each source file gets a .ogg of
# the same basename beside it, so 01-foo.mp3 becomes 01-foo.ogg and the
# playing order is still filename order. The mod ignores everything that is
# not .ogg, so the originals can stay where they are.
#
# Mono by default, because a world-mode speaker cannot pan a stereo buffer and
# a stereo track makes every client log a warning per track. Stereo is fine for
# a room-mode speaker:
#
#   CHANNELS=2 RATE=44100 BITRATE=96k NORMALIZE=0 ./playlist.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
LIST=0
if [ "${1:-}" = "--list" ]; then
    LIST=1
    shift
fi
DIR=${1:-$HERE/playlist}

CHANNELS=${CHANNELS:-1}
RATE=${RATE:-22050}
BITRATE=${BITRATE:-48k}
# Levels across a mixed folder are all over the place; one pass of loudnorm is
# approximate but much better than letting one track arrive twice as loud.
NORMALIZE=${NORMALIZE:-1}

[ -d "$DIR" ] || { echo "no such directory: $DIR" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg is not installed" >&2; exit 1; }

shopt -s nullglob nocaseglob

playable=0
for f in "$DIR"/*.ogg; do
    playable=$((playable + 1))
done

if [ "$LIST" = 1 ]; then
    echo "$DIR"
    for f in "$DIR"/*.ogg; do
        d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null)
        c=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$f" 2>/dev/null)
        printf '  playable  %-50s %6.1fs %sch\n' "$(basename "$f")" "${d:-0}" "${c:-?}"
    done
    for f in "$DIR"/*.mp3 "$DIR"/*.m4a "$DIR"/*.aac "$DIR"/*.flac "$DIR"/*.wav \
             "$DIR"/*.opus "$DIR"/*.mp4 "$DIR"/*.mkv "$DIR"/*.webm "$DIR"/*.m4v; do
        printf '  convert   %s\n' "$(basename "$f")"
    done
    echo "$playable playable track(s)"
    exit 0
fi

made=0
kept=0
failed=0
for f in "$DIR"/*.mp3 "$DIR"/*.m4a "$DIR"/*.aac "$DIR"/*.flac "$DIR"/*.wav \
         "$DIR"/*.opus "$DIR"/*.mp4 "$DIR"/*.mkv "$DIR"/*.webm "$DIR"/*.m4v; do
    out="${f%.*}.ogg"
    if [ -f "$out" ] && [ "$out" -nt "$f" ]; then
        kept=$((kept + 1))
        continue
    fi
    printf '%s\n' "$(basename "$f")"
    filter=()
    [ "$NORMALIZE" = 1 ] && filter=(-af "loudnorm=I=-16:TP=-1.5:LRA=11")
    # -vn drops the video of an mp4; -map_metadata -1 keeps tags out of the way
    if ffmpeg -hide_banner -loglevel error -y -i "$f" \
            -vn -map_metadata -1 "${filter[@]}" \
            -ac "$CHANNELS" -ar "$RATE" -c:a libvorbis -b:a "$BITRATE" \
            "$out"; then
        made=$((made + 1))
    else
        echo "  FAILED: $(basename "$f")" >&2
        rm -f "$out"
        failed=$((failed + 1))
    fi
done

total=0
for f in "$DIR"/*.ogg; do
    total=$((total + 1))
done
echo
echo "converted $made, already current $kept, failed $failed"
echo "$total playable track(s) in $DIR"
[ "$CHANNELS" = 1 ] || echo "note: stereo tracks are only panned correctly by a room-mode speaker"
