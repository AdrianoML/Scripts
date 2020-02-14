#!/bin/bash

cd "$@"

rand="$RANDOM"

if (($rand <= 24000)); then
    ./party.pl &
fi

rand="$RANDOM"
if (($rand <= 3000)); then
    sl -a
elif (($rand <= 5000)); then
    sl -l
elif (($rand <= 9000)); then
    sl -al
elif (($rand <= 10000)); then
    sl -F
else
    sl
fi
