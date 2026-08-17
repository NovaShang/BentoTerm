#!/bin/zsh
# TRUE 16:9 recompose (1920x1080), same 71s timeline as the square master.
# Wide Mac shots use the source's native 3:2 fit-height; closeups are re-framed
# as 16:9 crops; the reveal zoom is recomputed for this composition; G shots
# play native 16:9 full-frame.
set -e
cd "$(dirname "$0")"
C=assets/clips-v2; G=assets/gen; K=assets/cards; O=out/segL; mkdir -p $O
ENC=(-r 60 -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -an)

MFL="scale=-2:1080,pad=1920:1080:(ow-iw)/2:0:black"
COMPL="scale=-2:2160,pad=3840:2160:(ow-iw)/2:0:black"

# 01 cold open — 16:9 crop of the hero pane, via the shared composed pipeline
ffmpeg -y -loglevel error -ss 0.5 -t 5.9 -i $C/T1.mov \
  -vf "fps=60,$COMPL,zoompan=z='2.2642':x='1872-(iw/zoom)/2':y='625-(ih/zoom)/2':d=1:s=1920x1080:fps=60" $ENC $O/01.mp4
# 02 reveal — zoom out to the full window
ffmpeg -y -loglevel error -ss 6.4 -t 2.4 -i $C/T1.mov \
  -vf "fps=60,$COMPL,zoompan=z='max(2.2642-1.2642*in/119,1)':x='1872-(iw/zoom)/2':y='625-(ih/zoom)/2':d=1:s=1920x1080:fps=60" $ENC $O/02.mp4
ffmpeg -y -loglevel error -ss 27.7 -t 5.7 -i $C/T1.mov -vf "$MFL" $ENC $O/03.mp4
ffmpeg -y -loglevel error -ss 22.6 -t 5.3 -i $C/T2.mov -vf "$MFL" $ENC $O/04.mp4
ffmpeg -y -loglevel error -ss 13.0 -t 10.0 -i $C/T2.mov -vf "setpts=PTS/2.5,fps=60,$MFL" $ENC $O/05.mp4
# 06/07 voice — 16:9 wheel-locked crops
ffmpeg -y -loglevel error -ss 0.4 -t 11.0 -i $C/T3.mov -vf "crop=1600:900:0:350,scale=1920:1080" $ENC $O/06.mp4
ffmpeg -y -loglevel error -ss 25.0 -t 12.6 -i $C/T3.mov -vf "crop=1600:900:614:277,scale=1920:1080" $ENC $O/07.mp4

ffmpeg -y -loglevel error \
  -i $O/02.mp4 -i $O/03.mp4 -i $O/04.mp4 -i $O/05.mp4 -i $O/06.mp4 -i $O/07.mp4 \
  -filter_complex "[0][1]xfade=transition=fade:duration=0.4:offset=2.0[x1];[x1][2]xfade=transition=fade:duration=0.4:offset=7.3[x2];[x2][3]xfade=transition=fade:duration=0.4:offset=12.2[x3];[x3][4]xfade=transition=fade:duration=0.4:offset=15.8[x4];[x4][5]xfade=transition=fade:duration=0.4:offset=26.4" \
  $ENC $O/chain.mp4

ffmpeg -y -loglevel error -ss 3.2 -t 2.5 -i $G/G1.mp4 \
  -vf "tpad=stop_mode=clone:stop_duration=0.6,fade=t=out:st=2.2:d=0.8,scale=1920:1080" $ENC $O/09.mp4
ffmpeg -y -loglevel error -ss 0.5 -t 1.5 -i $G/G2.mp4 -vf "scale=1920:1080" $ENC $O/10.mp4
ffmpeg -y -loglevel error -ss 2.5 -t 3.4 -i $C/T4.mov \
  -filter_complex "[0:v]split[a][b];[a]scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,boxblur=40:2,eq=brightness=-0.15[bg];[b]scale=-2:1000[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2" $ENC $O/11.mp4
ffmpeg -y -loglevel error -ss 0.5 -t 1.5 -i $G/G3.mp4 -vf "scale=1920:1080" $ENC $O/12.mp4
ffmpeg -y -loglevel error -ss 10.5 -t 3.5 -i $C/T5.mov \
  -filter_complex "[0:v]split[a][b];[a]scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,boxblur=40:2,eq=brightness=-0.15[bg];[b]scale=-2:1000[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2" $ENC $O/13.mp4

for lang in "" "-zh"; do
  ffmpeg -y -loglevel error -loop 1 -t 7.3 -i $K/claim$lang-l.png -vf "scale=1920:1080,fade=t=in:st=0.3:d=0.6" $ENC $O/14$lang.mp4
  ffmpeg -y -loglevel error -loop 1 -t 5.8 -i $K/end$lang-l.png -vf "scale=1920:1080,fade=t=in:st=0.1:d=0.6" $ENC $O/15$lang.mp4
done
for lang in "" "-zh"; do
  for f in 01 chain 09 10 11 12 13 14$lang 15$lang; do echo "file 'segL/$f.mp4'"; done > out/concatL$lang.txt
  ffmpeg -y -loglevel error -f concat -safe 0 -i out/concatL$lang.txt -c copy out/videoL$lang.mp4
done
ffprobe -v error -show_entries format=duration -of csv=p=0 out/videoL.mp4
echo L-SEGMENTS-DONE