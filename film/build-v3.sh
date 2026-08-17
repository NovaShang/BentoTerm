#!/bin/zsh
# v3 — square cut, 71.0s, against audio/vo/full-gapped.wav (four silences
# inserted so the VOICE waits for the PICTURE: +2.5s hold after the shell
# command runs, +3.0s after the agent instruction lands, +1.5s each on
# iPad/iPhone). Changes vs v2:
#   * reveal is a real ZOOM-OUT (zoompan on the composed wide frame — it is
#     the same take, so the zoom reads as one continuous camera move)
#   * cold open gets a bottom gradient shade (the pane below the hero pane
#     leaked into the square crop); the shade fades away as the zoom starts
#   * voice beats extended (T3 0.4-11.0 shell / 23.8-36.4 agent), cut lands
#     exactly on "More importantly"
set -e
cd "$(dirname "$0")"
C=assets/clips-v2; G=assets/gen; K=assets/cards; O=out/seg3; mkdir -p $O
ENC=(-r 60 -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -an)

MACFIT="scale=2060:-2,pad=2160:2160:(ow-iw)/2:(oh-ih)/2:black"
GFIT="scale=2160:-2,pad=2160:2160:(ow-iw)/2:(oh-ih)/2:black"
PORT="scale=2160:2160:force_original_aspect_ratio=increase,crop=2160:2160,boxblur=40:2,eq=brightness=-0.15[bg];[fgsrc]scale=-2:1650[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2"

# 01+02 share ONE composed pipeline (4320-wide, no detail loss) so the cut
# between the pinned-zoom cold open and the animated zoom-out is pixel-
# continuous — rendering 01 as a raw source crop left a ~1% scale/sharpness
# jump at the joint.
COMP="scale=4120:-2,pad=4320:4320:(ow-iw)/2:(oh-ih)/2:black"
# 01 cold open (5.9) — zoom pinned at the start value + bottom shade
ffmpeg -y -loglevel error -ss 0.5 -t 5.9 -i $C/T1.mov -i assets/text/shade.png \
  -filter_complex "[0:v]$COMP,zoompan=z='2.526':x='2099.5-(iw/zoom)/2':y='1859.2-(ih/zoom)/2':d=1:s=2160x2160:fps=60[v];[v][1:v]overlay=0:0" $ENC $O/01.mp4
# 02 reveal (2.0+0.4 handle) — same composition, zoom animates from the same z;
# shade rides along and fades out in the first 0.7s
ffmpeg -y -loglevel error -ss 6.4 -t 2.4 -i $C/T1.mov -loop 1 -t 2.4 -i assets/text/shade.png \
  -filter_complex "[0:v]$COMP,zoompan=z='max(2.526-1.526*in/119,1)':x='2099.5-(iw/zoom)/2':y='1859.2-(ih/zoom)/2':d=1:s=2160x2160:fps=60[zv];[1:v]format=rgba,fade=t=out:st=0.1:d=0.7:alpha=1[sh];[zv][sh]overlay=0:0" \
  $ENC $O/02.mp4
# 03 layout edit (5.3+0.4), tail-aligned
ffmpeg -y -loglevel error -ss 27.7 -t 5.7 -i $C/T1.mov -vf "$MACFIT" $ENC $O/03.mp4
# 04 watch-static (4.9+0.4)
ffmpeg -y -loglevel error -ss 22.6 -t 5.3 -i $C/T2.mov -vf "$MACFIT" $ENC $O/04.mp4
# 05 amber at 2.5x (3.6+0.4)
ffmpeg -y -loglevel error -ss 13.0 -t 10.0 -i $C/T2.mov \
  -vf "setpts=PTS/2.5,fps=60,$MACFIT" $ENC $O/05.mp4
# 06 voice->shell (10.6+0.4) — wheel-locked, holds after the command runs
ffmpeg -y -loglevel error -ss 0.4 -t 11.0 -i $C/T3.mov \
  -vf "crop=1300:1300:40:180,scale=2160:2160" $ENC $O/06.mp4
# 07 voice->agent (12.6, chain tail) — holds while the agent starts working
ffmpeg -y -loglevel error -ss 23.8 -t 12.6 -i $C/T3.mov \
  -vf "crop=1300:1300:764:77,scale=2160:2160" $ENC $O/07.mp4

# chain: durs 02=2.0 03=5.3 04=4.9 05=3.6 06=10.6 07=12.6 → 39.0
ffmpeg -y -loglevel error \
  -i $O/02.mp4 -i $O/03.mp4 -i $O/04.mp4 -i $O/05.mp4 -i $O/06.mp4 -i $O/07.mp4 \
  -filter_complex "[0][1]xfade=transition=fade:duration=0.4:offset=2.0[x1];[x1][2]xfade=transition=fade:duration=0.4:offset=7.3[x2];[x2][3]xfade=transition=fade:duration=0.4:offset=12.2[x3];[x3][4]xfade=transition=fade:duration=0.4:offset=15.8[x4];[x4][5]xfade=transition=fade:duration=0.4:offset=26.4" \
  $ENC $O/chain.mp4

# tail: lid 3.1 · sofa 1.5 · iPad 3.4 · train 1.5 · iPhone 3.5 · claim 7.3 · end 5.8
ffmpeg -y -loglevel error -ss 3.2 -t 2.5 -i $G/G1.mp4 \
  -vf "tpad=stop_mode=clone:stop_duration=0.6,fade=t=out:st=2.2:d=0.8,$GFIT" $ENC $O/09.mp4
ffmpeg -y -loglevel error -ss 0.5 -t 1.5 -i $G/G2.mp4 -vf "$GFIT" $ENC $O/10.mp4
ffmpeg -y -loglevel error -ss 2.5 -t 3.4 -i $C/T4.mov \
  -filter_complex "[0:v]split[bgsrc][fgsrc];[bgsrc]$PORT" $ENC $O/11.mp4
ffmpeg -y -loglevel error -ss 0.5 -t 1.5 -i $G/G3.mp4 -vf "$GFIT" $ENC $O/12.mp4
ffmpeg -y -loglevel error -ss 10.5 -t 3.5 -i $C/T5.mov \
  -filter_complex "[0:v]split[bgsrc][fgsrc];[bgsrc]$PORT" $ENC $O/13.mp4
ffmpeg -y -loglevel error -loop 1 -t 7.3 -i $K/claim-sq.png -vf "fade=t=in:st=0.3:d=0.6" $ENC $O/14.mp4
ffmpeg -y -loglevel error -loop 1 -t 5.8 -i $K/end-sq.png -vf "fade=t=in:st=0.1:d=0.6" $ENC $O/15.mp4

for f in 01 chain 09 10 11 12 13 14 15; do echo "file 'seg3/$f.mp4'"; done > out/concat3.txt
ffmpeg -y -loglevel error -f concat -safe 0 -i out/concat3.txt -c copy out/video3.mp4
ffprobe -v error -show_entries format=duration -of csv=p=0 out/video3.mp4
echo SEGMENTS-DONE