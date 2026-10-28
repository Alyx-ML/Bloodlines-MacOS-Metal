#!/bin/zsh
# Sharper intro movies: each of the game's Bink movies (<game>/Vampire/media/*.bik) decoded
# with ffmpeg, every frame upscaled 4x with Real-ESRGAN's general model (realesrgan-x4plus,
# from realesrgan-ncnn-vulkan, https://github.com/xinntao/Real-ESRGAN, BSD-3; the player
# downloads it), brought down to 2x and written as HEVC video, frame for frame:
#
#     tools/movie_upscale.sh <realesrgan-ncnn-vulkan dir> [--game <game dir>] [movie ...]
#
# The game directory is the one holding Vampire/ (by default the folder above native/).
# Writes build/hires/movies/<movie>.mov (no sound: Bink still plays the movie, its sound and
# its timing) and <movie>.sig, each of the original's frames shrunk to 8x8 RGB, which the
# renderer finds Bink's frame by and draws the same frame of the .mov in its place (see
# d3d9/movie_hires.m). Like the textures, they are the player's own and never committed.
#
# Movies already written are skipped. Frames that repeat (the black and still frames most
# movies hold) are upscaled once. The work folder (build/movie_work/<movie>) keeps the
# upscaled frames until the movie is written, so a stopped run goes on where it was; a
# frame or movie is only ever under its final name once it is whole.
set -e
here=${0:A:h}
root=$here/..
esr=${1:?realesrgan-ncnn-vulkan dir}; shift
game=$root/..
if [[ $1 == --game ]]; then game=${2:?game dir}; shift 2; fi
media=$game/Vampire/media
[[ -d $media ]] || { echo "no $media: pass the game directory with --game" >&2; exit 1; }
out=$root/build/hires/movies
work=$root/build/movie_work
mkdir -p $out $work
movies=("$@")
[[ ${#movies} -gt 0 ]] || movies=($media/*.bik(:t:r))
for m in $movies; do
    [[ -f $out/$m.mov && -f $out/$m.sig ]] && { echo "$m: done before"; continue; }
    w=$work/$m
    rate=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 $media/$m.bik)
    size=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 $media/$m.bik)
    # Every frame, into a folder that only gets its name once all are written.
    if [[ ! -d $w/in ]]; then
        rm -rf $w/in.part && mkdir -p $w/in.part
        ffmpeg -v error -y -i $media/$m.bik -fps_mode passthrough $w/in.part/%05d.png
        mv $w/in.part $w/in
    fi
    frames=($w/in/*.png(:t))
    n=${#frames}
    # One of each different frame (by its contents) goes to the upscaler.
    mkdir -p $w/uniq $w/x4
    typeset -A first like
    md5 -r $w/in/*.png | while read h f; do
        f=${f:t}
        [[ -n ${first[$h]} ]] || { first[$h]=$f; [[ -f $w/x4/$f ]] || ln -f $w/in/$f $w/uniq/$f; }
        like[$f]=${first[$h]}
    done
    todo=($w/uniq/*.png(N))
    if [[ ${#todo} -gt 0 ]]; then
        echo "$m: $n frames of $size, ${#first} different, ${#todo} to upscale"
        rm -rf $w/x4.part && mkdir -p $w/x4.part
        $esr/realesrgan-ncnn-vulkan -i $w/uniq -o $w/x4.part -n realesrgan-x4plus -s 4 -m $esr/models -f png
        for f in $w/x4.part/*.png(N); do mv $f $w/x4/${f:t} && rm -f $w/uniq/${f:t}; done
        [[ -z $(ls $w/uniq) ]] || { echo "$m: frames left un-upscaled in $w/uniq" >&2; exit 1; }
    fi
    # Each frame as its first like it, then the movie and its signatures.
    mkdir -p $w/all
    for f in $frames; do [[ -f $w/all/$f ]] || ln -f $w/x4/${like[$f]} $w/all/$f; done
    W=$((${size%x*} * 2)) H=$((${size#*x} * 2))
    ffmpeg -v error -y -framerate $rate -pattern_type glob -i "$w/all/*.png" -vf scale=${W}:${H}:flags=lanczos \
        -c:v hevc_videotoolbox -q:v 80 -tag:v hvc1 -pix_fmt yuv420p -f mov $out/$m.mov.part
    ffmpeg -v error -y -i $media/$m.bik -fps_mode passthrough -vf scale=8:8:flags=area,format=rgb24 \
        -f rawvideo $out/$m.sig.part
    [[ $(( $(stat -f %z $out/$m.sig.part) / 192 )) == $n ]] || { echo "$m: signature frame count differs" >&2; exit 1; }
    mv $out/$m.mov.part $out/$m.mov
    mv $out/$m.sig.part $out/$m.sig
    echo "$m: $n frames at ${W}x$H written"
    unset first like
    rm -rf $w
done
