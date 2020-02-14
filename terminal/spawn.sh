#!/bin/bash
DIR="$(dirname "$0")";
declare -i screenX=1366;
declare -i screenY=768;

declare -i blockX=7;
declare -i blockY=15;
declare -i sizeX=$(( 70 + ($RANDOM/600) ));
declare -i sizeY=24;

declare -i paddingX=$(($blockX*$sizeX)); #for zoom=1.0
declare -i paddingY=$(($blockY*$sizeY)); #for zoom=1.0

declare -i RAND_MAX=32767;
declare -i randX=$RANDOM;
declare -i randY=$RANDOM;

# Fun with integer divisions!
declare -i zoom=$(( 6700 + (($RANDOM/3)*10000/$RAND_MAX)  ));
if (($zoom <= 9500)); then
    strZoom="0.$zoom"
    paddingX=$(( $paddingX * 100 / (100*10000/$zoom) ))
    paddingY=$(( $paddingY * 100 / (100*10000/$zoom) ))
else
    strZoom="1.0"
fi

declare -i posX=$(( ((($screenX-$paddingX+50) * ($randX*10000000/$RAND_MAX)) / 10000000) -25 ));
declare -i posY=$(( ((($screenY-$paddingY+50) * ($randY*10000000/$RAND_MAX)) / 10000000) -25 ));

gnome-terminal --geometry "${sizeX}x${sizeY}+$posX+$posY" --zoom "$strZoom" -- "$DIR/fun.sh" "$DIR"
