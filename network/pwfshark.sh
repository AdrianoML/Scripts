#!/bin/bash
IFACE='wlp3s0'
QUALITY_MAX=70
SAMPLES_MAX=3000

cell_list=''
noenc_list=''
declare -i cell=0
while read -a LINE; do
    #echo "DEBUG: ${LINE[@]}"
    if [[ "${LINE[0]}" == 'Cell' ]]; then
        cell="10#${LINE[1]}"
        if [[ "${LINE[3]}" == 'Address:' ]]; then
           iwlist_bssid[$cell]="${LINE[4]}"
        fi
        cell_list+=" $cell"
    fi
    if [[ "${LINE[0]}" =~ ^'Quality=' ]]; then
       iwlist_quality[$cell]="${LINE[0]/#Quality=/}"
       iwlist_quality[$cell]="${iwlist_quality[$cell]/\/$QUALITY_MAX/}"
    fi
    if [[ "${LINE[0]}" == 'Encryption' ]]; then
       iwlist_encryption[$cell]="${LINE[1]}"
    fi
    if [[ "${LINE[0]}" =~ ^'ESSID:' ]]; then
       iwlist_essid[$cell]="${LINE[0]/#ESSID:\"/}"
       iwlist_essid[$cell]="${iwlist_essid[$cell]/%\"/}"
    fi
    if [[ "${LINE[0]}" == "$IFACE" && "${LINE[@]}" =~ 'Device or resource busy' ]]; then
        echo ERROR
        break
    fi
done < <(iwlist "$IFACE" scanning 2>&1)

declare -A base_bssid_cell
for CELL in $cell_list; do
    base_bssid_cell["${iwlist_bssid[$CELL]}"]=$CELL
    if [[ "${iwlist_encryption[$CELL]}" == 'key:off' ]]; then
        noenc_list+=" $CELL"
        echo Cell: $CELL
        echo '  'ESSID: ${iwlist_essid[$CELL]}
        echo '  'BSSID: ${iwlist_bssid[$CELL]}
        echo '  'Quality: ${iwlist_quality[$CELL]}
        echo '  'Encryption: ${iwlist_encryption[$CELL]}
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

grep_bssid_filter=''
separator=''
for CELL in $noenc_list; do
    grep_bssid_filter+="${separator}${iwlist_bssid[$CELL]}"
    separator='|'
done
grep_bssid_filter="BSSID:($grep_bssid_filter)"

coproc DUMPCOP { tcpdump -i $IFACE -nn -I -e | grep -Ev '(Beacon|Probe|Acknowledgment)'; }

declare -A base_gwmac_bssid
declare -A -i base_gwmac_hits

regex_ip='^[0-9]*(\.[0-9]*){3}'
TIMEOUT=$(($(date +%s) + 60))
shopt -s extglob nocasematch
declare -i sample=0
while read -u ${DUMPCOP[0]} -a LINE; do
    declare -i n=0
    declare -i n_max="${#LINE[@]}"
    #unset ${!dump*}
    while (( $n < $n_max )); do
        declare -i jump=1
        if [[ "${LINE[$n]}" =~ ^'SA:' ]]; then
            dump_sa[$sample]="${LINE[$n]/#SA:/}"
        elif [[ "${LINE[$n]}" =~ ^'DA:' ]]; then
            dump_da[$sample]="${LINE[$n]/#DA:/}"
        elif [[ "${LINE[$n]}" =~ ^'BSSID:' ]]; then
            dump_bssid[$sample]="${LINE[$n]/#BSSID:/}"
        elif [[ "${LINE[$n]}" == 'ethertype' && "${LINE[$n+1]}" == 'IPv4' ]]; then
            if [[ "${LINE[$n+3]}" =~ $regex_ip ]]; then
                dump_sip[$sample]="$BASH_REMATCH"
                dump_sipp[$sample]="${LINE[$n+3]/#${dump_sip[$sample]}?(:|.)/}"
            fi
            if [[ "${LINE[$n+5]}" =~ $regex_ip ]]; then
                dump_dip[$sample]="$BASH_REMATCH"
                dump_dipp[$sample]="${LINE[$n+5]/#${dump_dip[$sample]}?(:|.)/}"
                ## remove : from dump_dipp='<portn>:'
            fi
            if [[ "$(ipcalc "${dump_sip[$sample]}")" =~ 'Internet' ]]; then
                dump_sipwan[$sample]=1
                base_gwmac_hits[${dump_sa[$sample]}]+=1
                base_gwmac_bssid[${dump_sa[$sample]}]=${dump_bssid[$sample]}
            elif [[ "$(ipcalc "${dump_dip[$sample]}")" =~ 'Internet' ]]; then
                dump_dipwan[$sample]=1
                base_gwmac_hits[${dump_da[$sample]}]+=1
                base_gwmac_bssid[${dump_da[$sample]}]=${dump_bssid[$sample]}
            fi
            jump+=5
            dump_valid[$sample]=1
        fi
        n+=$jump
    done

    if [[ ${dump_valid[$sample]} == 1 ]]; then
        #echo "DEBUG: ${LINE[@]}"
        echo -e "BSSID: ${dump_bssid[$sample]} SA: ${dump_sa[$sample]} DA: ${dump_da[$sample]}\n\
                        SIP: ${dump_sip[$sample]}     DIP: ${dump_dip[$sample]}\n"
                        #SIPP: ${dump_sipp[$sample]}         DIPP: ${dump_dipp[$sample]}\n"
        if [[ -z "${dump_bssid[$sample]}" ]]; then
            echo WARNING: NULL BSSID!
        fi
    fi
    sample+=1
    if (( $sample >= $SAMPLES_MAX )); then
        break
    fi
#    if (( $(date +%s) >= $TIMEOUT )); then
#        break
#    fi
done

shopt -u nocasematch
sleep 0.2

## Check for mac address case problems!
declare -A base_bssid_gwmac
for GWMAC in ${!base_gwmac_bssid[@]}; do
    base_bssid_gwmac[${base_gwmac_bssid[$GWMAC]}]+=" $GWMAC"
    echo "DEBUG: Gateway: $GWMAC BSSID: ${base_gwmac_bssid[$GWMAC]} hits ${base_gwmac_hits[$GWMAC]}"
done

for BSSID in ${!base_bssid_gwmac[@]}; do
    declare -i biggest_hits=0
    declare biggest_gwmac
    for GWMAC in ${base_bssid_gwmac[$BSSID]}; do
        if (( ${base_gwmac_hits[$GWMAC]} > $biggest_hits )); then
            biggest_hits=${base_gwmac_hits[$GWMAC]}
            biggest_gwmac="$GWMAC"
        fi
    done
    base_bssid_gwmac[$BSSID]=$biggest_gwmac
done

for BSSID in ${!base_bssid_gwmac[@]}; do
    echo "Gateway: ${base_bssid_gwmac[$BSSID]} BSSID: $BSSID hits ${base_gwmac_hits[${base_bssid_gwmac[$BSSID]}]}"
done

declare -A base_ip_bssid
declare -A base_ip_mac
declare -A -i base_ip_hits
sample=0
while (( $sample < $SAMPLES_MAX )); do
    if [[ ${dump_valid[$sample]} == 1 ]]; then
        BSSID="${dump_bssid[$sample]}"
        GWMAC="${base_bssid_gwmac[$BSSID]}"
        if [[ ${dump_sa[$sample]} == $GWMAC && -n "${dump_dip[$sample]}" ]]; then
            base_ip_bssid[${dump_dip[$sample]}]=${dump_bssid[$sample]}
            base_ip_mac[${dump_dip[$sample]}]="${dump_da[$sample]}"
            base_ip_hits[${dump_dip[$sample]}]+=1
        elif [[ ${dump_da[$sample]} == $GWMAC && -n "${dump_sip[$sample]}" ]]; then
            base_ip_bssid[${dump_sip[$sample]}]=${dump_bssid[$sample]}
            base_ip_mac[${dump_sip[$sample]}]="${dump_sa[$sample]}"
            base_ip_hits[${dump_sip[$sample]}]+=1
        fi
    fi
    sample+=1
done


shopt -s extglob nocasematch
for IP in ${!base_ip_mac[@]}; do
    BSSID=${base_ip_bssid[$IP]^^}
    ESSID=${iwlist_essid[${base_bssid_cell[$BSSID]}]:-???}
    echo "$ESSID ($BSSID) -- $IP (${base_ip_mac[$IP]}): ${base_ip_hits[$IP]}"
done

modprobe -r iwldvm iwlwifi
sleep 0.1
modprobe iwlwifi
sleep 0.2
nmcli networking on
nmcli d set "$IFACE" managed yes
