#!/bin/bash
# Brutal Doom 64 Startup script. Allows a per user configuration directory and makes sure essential IWAD are available for the game. Requires Zenity and Bash.
# Author: Adriano Moura <adriano.lols@gmail.com>
# License: GPL2

zen_message() {
    echo -e "$@"
    zenity --width 400 --warning --text "$@" 2> /dev/null
    return $?
}

zen_fail() {
    local ret="$1"
    shift
    zen_message "$@"
    exit "$ret"
}

CONFIG_DIR="$HOME/.config/brutal-doom-64/"
CONFIG_SOURCE='/usr/share/games/brutal-doom-64/gzdoom.ini'
CONFIG_TARGET="$CONFIG_DIR/gzdoom.ini"

# Sanity checks.
if [[ ! -d "$HOME" ]]; then
    zen_fail 2 "ERROR: Could not access user home directory"
fi

if [[ ! -e "$CONFIG_SOURCE" ]]; then
    zen_fail 3 "ERROR: Missing Brutal Doom 64 main configuration file: $CONFIG_SOURCE"
fi

mkdir -p "$CONFIG_DIR" 2> /dev/null
if [[ ! -d "$CONFIG_DIR" ]]; then
    zen_fail 4 "ERROR: Could not create or access brutal-doom-64 XDG config directory"
fi

if [[ ! -e "$CONFIG_TARGET" ]]; then
    cp "$CONFIG_SOURCE" "$CONFIG_TARGET" || { zen_fail 5 "ERROR: Could not spawn brutal-doom-64 config file"; }
fi

# Loads IWAD paths from config.
declare -a DOOMWAD_PATHS
PARSEDIRS=0
while read -a LINE; do
    if [[ "${LINE[0]}" == '[IWADSearch.Directories]' ]]; then
        PARSEDIRS=1
    fi
    if [[ $PARSEDIRS == 1 && "${LINE[0]}" =~ ^'Path=' ]]; then
        DOOMWAD_PATHS+=( ${LINE[@]/Path=} )
    fi
    if [[ "${LINE[0]}" =~ ^'[' && ! "${LINE[0]}" == '[IWADSearch.Directories]' ]]; then 
        PARSEDIRS=0
    fi
done < "$CONFIG_TARGET" || zen_fail 6 "ERROR: Could not read $CONFIG_TARGET"

CONFIG_WRITE=0
DOOMWAD_FOUND=0
DOOMWAD_VALID='doom.wad tnt.wad plutonia.wad'
MSG_WRITE_FAIL='ERROR: Failed to write modified configuration file'
while [[ "$DOOMWAD_FOUND" != 1 ]]; do
    # Search each WAD in each IWAD directory, case unsensitive.
    for DIR in "${DOOMWAD_PATHS[@]}" "$DOOMWAD_PATH"; do
        if [[ -d "$DIR" ]]; then
            for WAD in $DOOMWAD_VALID; do
                if [[ -n $(find "$DIR" -maxdepth 1 -iname "$WAD" 2> /dev/null) ]]; then
                    DOOMWAD_FOUND=1
                fi
            done
        fi
    done
    
    # Writes new IWAD directory to config file.
    if [[ "$CONFIG_WRITE" == 1 && $DOOMWAD_FOUND == 1 ]]; then
        while read -a LINE; do
            echo "${LINE[@]}"
            if [[ "${LINE[0]}" == '[IWADSearch.Directories]' ]]; then
                echo "Path=$DOOMWAD_PATH"
            fi
        done < "$CONFIG_TARGET" > "$CONFIG_TARGET.new" || zen_fail 7 "$MSG_WRITE_FAIL"
        mv "$CONFIG_TARGET" "$CONFIG_TARGET.bk" || zen_fail 7 "$MSG_WRITE_FAIL"
        mv "$CONFIG_TARGET.new" "$CONFIG_TARGET" || zen_fail 7 "$MSG_WRITE_FAIL"
    fi
    
    # Asks the user for a new IWAD directory, if no valid WAD was found.
    if [[ $DOOMWAD_FOUND != 1 ]]; then
        zen_message "Brutal Doom 64 rquires one of the following WADs:\n - ${DOOMWAD_VALID// /$'\n - '}\n\nPlease specify a WAD directory containing at least one of these."
        if [[ $? != 0 ]]; then
            exit 0
        fi

        DOOMWAD_PATH="$(zenity --file-selection --directory 2> /dev/null)"
        if [[ $? != 0 ]]; then
            exit 0
        fi

        if [[ -d "$DOOMWAD_PATH" ]]; then
            CONFIG_WRITE=1
        else 
            unset DOOMWAD_PATH
        fi
    fi
done

gzdoom -config "$CONFIG_TARGET" &
disown

exit 0
