#!/bin/sh

getbc() {
	local N
    local dig=$1
    local -i dec
	IFS='.'
    while read -a LINE; do
		if [[ -n "${LINE[0]}" ]]; then
 			N="${LINE[0]}"
	    fi
        dec="10#${LINE[1]:0:$dig}"
		N+="$dec"
    done <<< $(bc -l <<< "$2")
    unset IFS
    echo $N
}

splitdec() {
	local val=$2
    local digit=$1
	local vlen="${#val}"
	if (( "$vlen" > $digit )); then
		echo "${val:0:$(( $vlen - $digit ))}.${val:$(( $vlen - $digit )):$digit}"
	else
		printf "0.%0.${digit}d" $val
	fi
}

quit() {
	exit
}

trap TERM QUIT HUP quit

declare -i PI2="$(getbc 2 'scale=10; 8*a(1)')"
declare -i INC=20

declare -a sin_lut
for X in $(seq 0 $INC $(("$PI2"+400))); do
  sin_lut[X]="$(getbc 2 "scale=10; s($(splitdec 2 $X))")"
done

declare -i X=0;

while true; do
    printf "\033]10;#%02x%02x%02x\007" $((${sin_lut[$X]}+156)) $((${sin_lut[$X+200]}+156)) $((${sin_lut[$X+400]}+156))
	
    (( $X >= $PI2 )) && X=0 || X+=$INC
    sleep 0.02
done
