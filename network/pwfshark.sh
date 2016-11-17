#!/bin/bash
IFACE='wlp3s0'
QUALITY_MAX=70
#GATEWAY_MAC='00:0a:f4:7c:10:e1' #bpp
GATEWAY_MAC='00:0c:29:d8:b3:89' #ufpr
GATEWAY_MAC='D4:CA:6D:AF:AC:BF' #saanga
SAMPLES_MAX=3000

cell_list=''
noenc_list=''
declare -i cell=0
while read -a LINE; do
    #echo "DEBUG: ${LINE[@]}"
    if [[ "${LINE[0]}" == 'Cell' ]]; then
        cell="10#${LINE[1]}"
        if [[ "${LINE[3]}" == 'Address:' ]]; then
           ap[$cell]="${LINE[4]}"
        fi
        cell_list+=" $cell"
    fi
    if [[ "${LINE[0]}" =~ ^'Quality=' ]]; then
       quality[$cell]="${LINE[0]/#Quality=/}"
       quality[$cell]="${quality[$cell]/\/$QUALITY_MAX/}"
    fi
    if [[ "${LINE[0]}" == 'Encryption' ]]; then
       encryption[$cell]="${LINE[1]}"
    fi
    if [[ "${LINE[0]}" =~ ^'ESSID:' ]]; then
       essid[$cell]="${LINE[0]/#ESSID:\"/}"
       essid[$cell]="${essid[$cell]/%\"/}"
    fi
done < <(iwlist "$IFACE" scanning)

declare -A base_bssid_cell
for CELL in $cell_list; do
    base_bssid_cell["${ap[$CELL]}"]=$CELL
    if [[ "${encryption[$CELL]}" == 'key:off' ]]; then
        noenc_list+=" $CELL"
        echo Cell: $CELL
        echo '  'AP: ${ap[$CELL]}
        echo '  'Quality: ${quality[$CELL]}
        echo '  'Encryption: ${encryption[$CELL]}
        echo '  'ESSID: ${essid[$CELL]}
    fi
done

nmcli d set "$IFACE" managed no
nmcli networking off 
sleep 1
modprobe -r iwldvm iwlwifi
sleep 0.2
modprobe iwlwifi
sleep 0.3
ip link set up "$IFACE"
sleep 0.4

grep_ap_filter=''
separator=''
for CELL in $noenc_list; do
    grep_ap_filter+="${separator}${ap[$CELL]}"
    separator='|'
done
grep_ap_filter="BSSID:($grep_ap_filter)"
#echo $grep_ap_filter

## Allow execution limited by a timmer rather than only samples.
coproc DUMPCOP { tcpdump -i $IFACE -nn -I -e | grep -Ev '(Beacon|Probe|Acknowledgment)'; }

declare -A base_ip_bssid
declare -A base_ip_mac
declare -A -i base_ip_hits

TIMEOUT=$(($(date +%s) + 60))
shopt -s extglob nocasematch
declare -i samples=0
while read -u ${DUMPCOP[0]} -a LINE; do
    declare -i n=0
    declare -i n_max="${#LINE[@]}"
    detected=''
    unset ${!dump*}
    while (( $n < $n_max )); do
        declare -i jump=1
        if [[ "${LINE[$n]}" =~ ^'SA:' ]]; then
            dump_sa="${LINE[$n]/#SA:/}"
            detected=1
        elif [[ "${LINE[$n]}" =~ ^'DA:' ]]; then
            dump_da="${LINE[$n]/#DA:/}"
            detected=1
        elif [[ "${LINE[$n]}" =~ ^'BSSID:' ]]; then
            dump_bssid="${LINE[$n]/#BSSID:/}"
            detected=1
        elif [[ "${LINE[$n]}" == 'ethertype' && "${LINE[$n+1]}" == 'IPv4' ]]; then
            dump_sip="${LINE[$n+3]/%.*([0-9])/}"
            dump_sipp="${LINE[$n+3]/#$dump_sip./}"
            dump_dip="${LINE[$n+5]/%.*([0-9]):/}"
            dump_dipp="${LINE[$n+5]/#$dump_dip./}" ## remove ':'

            jump+=5
            detected=1
        fi
        n+=$jump
    done

    if [[ -n "$detected" ]]; then
        #echo "DEBUG: ${LINE[@]}"
        echo -e "BSSID: $dump_bssid SA: $dump_sa DA: $dump_da\n\
                        SIP: $dump_sip     DIP: $dump_dip\n"
                       #SIPP: $dump_sipp         DIPP: $dump_dipp"
        if [[ -z "$dump_bssid" ]]; then
            echo WARNING: NULL BSSID!
        fi

        if [[ $dump_sa == $GATEWAY_MAC && -n "$dump_dip" ]]; then
            base_ip_bssid[$dump_dip]=$dump_bssid
            base_ip_mac[$dump_dip]="$dump_da"
            base_ip_hits[$dump_dip]+=1
        elif [[ $dump_da == $GATEWAY_MAC && -n "$dump_sip" ]]; then
            base_ip_bssid[$dump_sip]=$dump_bssid
            base_ip_mac[$dump_sip]="$dump_sa"
            base_ip_hits[$dump_sip]+=1
        fi

    fi
    samples+=1
    if (( $samples >= $SAMPLES_MAX )); then
        break
    fi
#    if (( $(date +%s) >= $TIMEOUT )); then
#        break
#    fi
done

shopt -u nocasematch

sleep 0.2

shopt -s extglob nocasematch
for IP in ${!base_ip_mac[@]}; do
    BSSID=${base_ip_bssid[$IP]^^}
    ESSID=${essid[${base_bssid_cell[$BSSID]}]:-???}
    echo "$ESSID ($BSSID) -- $IP (${base_ip_mac[$IP]}): ${base_ip_hits[$IP]}"
done

modprobe -r iwldvm iwlwifi
sleep 0.1
modprobe iwlwifi
sleep 0.2
nmcli networking on
nmcli d set "$IFACE" managed yes
