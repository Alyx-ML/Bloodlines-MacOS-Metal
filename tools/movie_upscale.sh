#!/bin/zsh
# Sharper intro movies: each of the game's Bink movies (Vampire/media/*.bik) decoded with
# ffmpeg, every frame upscaled 4x with Real-ESRGAN's general model (realesrgan-x4plus, from
# realesrgan-ncnn-vulkan, https://github.com/xinntao/Real-ESRGAN, BSD-3; the player
# downloads it), brought down to 2x and written as HEVC video, frame for frame:
#
#     tools/movie_upscale.sh <realesrgan-ncnn-vulkan dir> [movie ...]
#
# Writes build/hires/movies/<movie>.mov (no sound: Bink still plays the movie, its sound and
# its timing; the renderer draws frame N of the .mov in place of Bink's frame N, see
# d3d9/movie_hires.m). Like the textures, they are the player's own and never committed.
# Movies already written are skipped; the work folder (build/movie_work) keeps the 4x
# frames of a movie until it is written.
set -e
here=${0:A:h}
root=$here/..
esr=${1:?realesrgan-ncnn-vulkan dir}; shift
media=$root/../Vampire/media
out=$root/build/hires/movies
work=$root/build/movie_work
mkdir -p $out $work
movies=("$@")
[[ ${#movies} -gt 0 ]] || movies=($media/*.bik(:t:r))
for m in $movies; do
    [[ -f $out/$m.mov ]] && { echo "$m: done before"; continue; }
    w=$work/$m
    mkdir -p $w/in $w/x4
    rate=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 $media/$m.bik)
    size=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 $media/$m.bik)
    [[ -f $w/in/0001.png ]] || ffmpeg -v error -y -i $media/$m.bik -fps_mode passthrough $w/in/%04d.png
    n=$(ls $w/in | wc -l | tr -d ' ')
    if [[ $(ls $w/x4 | wc -l | tr -d ' ') != $n ]]; then
        echo "$m: $n frames of $size, upscaling"
        $esr/realesrgan-ncnn-vulkan -i $w/in -o $w/x4 -n realesrgan-x4plus -s 4 -m $esr/models -f png
    fi
    W=$((${size%x*} * 2)) H=$((${size#*x} * 2))
    ffmpeg -v error -y -framerate $rate -i $w/x4/%04d.png -vf scale=${W}:${H}:flags=lanczos \
        -c:v hevc_videotoolbox -q:v 80 -tag:v hvc1 -pix_fmt yuv420p $out/$m.mov
    echo "$m: $n frames at ${W}x$H written"
    rm -rf $w
done
