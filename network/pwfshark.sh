#!/bin/bash
IFACE='wlp3s0'
QUALITY_MAX=70
SAMPLES_MAX=30000
SAMPLES_VALID_MAX=2000

declare -A base_bssid_essid
declare -A base_bssid_quality
declare -A base_bssid_encryption

scan_aps() {
    while read -a LINE; do
        #echo "DEBUG: ${LINE[@]}"
        if [[ "${LINE[0]}" == 'Cell' ]]; then
            if [[ "${LINE[3]}" == 'Address:' ]]; then
               BSSID="${LINE[4]^^}"
            fi
        fi
        if [[ "${LINE[0]}" =~ ^'Quality=' ]]; then
           base_bssid_quality[$BSSID]="${LINE[0]/#Quality=/}"
           base_bssid_quality[$BSSID]="${base_bssid_quality[$BSSID]/\/$QUALITY_MAX/}"
        fi
        if [[ "${LINE[0]}" == 'Encryption' ]]; then
           base_bssid_encryption[$BSSID]="${LINE[1]}"
        fi
        if [[ "${LINE[0]}" =~ ^'ESSID:' ]]; then
           base_bssid_essid[$BSSID]="${LINE[@]/#ESSID:\"/}"
           base_bssid_essid[$BSSID]="${base_bssid_essid[$BSSID]/%\"/}"
        fi
        if [[ "${LINE[0]}" == "$IFACE" && "${LINE[@]}" =~ 'Device or resource busy' ]]; then
            return 1
        fi
    done < <(iwlist "$IFACE" scanning 2>&1)
    return 0
}

if [[ "$(whoami)" != 'root' ]]; then
    echo "Must be run as root"
    exit 1
fi

echo -en Collecting scanning data..
declare -i TRY=0
while (( $TRY <= 4 )); do
    echo -en '.'
    if scan_aps; then
        TRY+=1
    fi
    sleep 0.5
done
echo ''

nmcli d set "$IFACE" managed no
nmcli networking off 
sleep 1
modprobe -r iwldvm iwlwifi
sleep 0.2
modprobe iwlwifi
sleep 0.3
ip link set up "$IFACE"
sleep 0.4

coproc DUMPCOP { tcpdump -i $IFACE -nn -I -e | grep -Ev '(Beacon|Probe|Acknowledgment)'; }

declare -A base_gwmac_bssid
declare -A -i base_gwmac_hits

declare -a -i dump_valid
declare dump_valid_list

regex_ip='^[0-9]*(\.[0-9]*){3}'
TIMEOUT=$(($(date +%s) + 120))
shopt -s extglob nocasematch
declare -i sample=0
declare -i sample_valid=0
while read -u ${DUMPCOP[0]} -a LINE; do
    declare -i n=0
    declare -i n_max="${#LINE[@]}"
    #unset ${!dump*}
    dump_valid[$sample]=0
    while (( $n < $n_max )); do
        declare -i jump=1
        if [[ "${LINE[$n]}" =~ ^'SA:' ]]; then
            dump_sa[$sample]="${LINE[$n]/#SA:/}"
            dump_sa[$sample]="${dump_sa[$sample]^^}"
        elif [[ "${LINE[$n]}" =~ ^'DA:' ]]; then
            dump_da[$sample]="${LINE[$n]/#DA:/}"
            dump_da[$sample]="${dump_da[$sample]^^}"
        elif [[ "${LINE[$n]}" =~ ^'BSSID:' ]]; then
            dump_bssid[$sample]="${LINE[$n]/#BSSID:/}"
            dump_bssid[$sample]="${dump_bssid[$sample]^^}"
        elif [[ "${LINE[$n]}" == 'ethertype' && "${LINE[$n+1]}" == 'IPv4' ]]; then
            if [[ "${LINE[$n+3]}" =~ $regex_ip ]]; then
                dump_sip[$sample]="$BASH_REMATCH"
                dump_sipp[$sample]="${LINE[$n+3]/#${dump_sip[$sample]}?(:|.)/}"
                dump_valid[$sample]+=1
            fi
            if [[ "${LINE[$n+5]}" =~ $regex_ip ]]; then
                dump_dip[$sample]="$BASH_REMATCH"
                dump_dipp[$sample]="${LINE[$n+5]/#${dump_dip[$sample]}?(:|.)/}"
                dump_valid[$sample]+=2
                ## remove : from dump_dipp='<portn>:'
            fi
            if (( ${dump_valid[$sample]} & 1 )) && 
               [[ "$(ipcalc "${dump_sip[$sample]}")" =~ 'Internet' ]]; then
                dump_sipwan[$sample]=1
                base_gwmac_hits[${dump_sa[$sample]}]+=1
                base_gwmac_bssid[${dump_sa[$sample]}]=${dump_bssid[$sample]}
            elif (( ${dump_valid[$sample]} & 2 )) &&
                 [[ "$(ipcalc "${dump_dip[$sample]}")" =~ 'Internet' ]]; then
                dump_dipwan[$sample]=1
                base_gwmac_hits[${dump_da[$sample]}]+=1
                base_gwmac_bssid[${dump_da[$sample]}]=${dump_bssid[$sample]}
            fi
            jump+=5
        fi
        n+=$jump
    done

    if (( ${dump_valid[$sample]} >= 3 )); then
        #echo "DEBUG: ${LINE[@]}"
        dump_valid_list+=" $sample"
        sample_valid+=1
        echo -e "BSSID: ${dump_bssid[$sample]} SA: ${dump_sa[$sample]} DA: ${dump_da[$sample]}\n\
                        SIP: ${dump_sip[$sample]}     DIP: ${dump_dip[$sample]}\n"
                        #SIPP: ${dump_sipp[$sample]}         DIPP: ${dump_dipp[$sample]}\n"
        if [[ -z "${dump_bssid[$sample]}" ]]; then
            echo WARNING: NULL BSSID!
        fi
    fi
    sample+=1
    if (( $sample >= $SAMPLES_MAX || $sample_valid >= $SAMPLES_VALID_MAX )); then
        break
    fi
    if (( $(date +%s) >= $TIMEOUT )); then
        break
    fi
done
shopt -u nocasematch

sleep 0.1
modprobe -r iwldvm iwlwifi
sleep 0.1
modprobe iwlwifi
sleep 0.2
nmcli networking on
nmcli d set "$IFACE" managed yes
sleep 0.5

echo -en Collecting scanning data..
declare -i TRY=0
while (( $TRY <= 4 )); do
    echo -en '.'
    if scan_aps; then
        TRY+=1
    fi
    sleep 0.5
done
echo ''

## Check for mac address case problems!
declare -A base_bssid_gwmac
for GWMAC in ${!base_gwmac_bssid[@]}; do
    base_bssid_gwmac[${base_gwmac_bssid[$GWMAC]}]+=" $GWMAC"
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

for BSSID in ${!base_bssid_essid[@]}; do
    if [[ "${base_bssid_encryption[$BSSID]}" == 'key:off' ]]; then
        echo ESSID: ${base_bssid_essid[$BSSID]}
        echo '  'BSSID: $BSSID
        echo '  'Quality: ${base_bssid_quality[$BSSID]}
        echo '  'Encryption: ${base_bssid_encryption[$BSSID]}
        if [[ -n "${base_bssid_gwmac[$BSSID]}" ]]; then
            echo '  'Gateway:" ${base_bssid_gwmac[$BSSID]} (Hits: ${base_gwmac_hits[${base_bssid_gwmac[$BSSID]}]})"
        else
            echo '  'Gateway: Unknown
        fi
    fi
done

for BSSID in ${!base_bssid_gwmac[@]}; do
    echo "Gateway: ${base_bssid_gwmac[$BSSID]} BSSID: $BSSID hits ${base_gwmac_hits[${base_bssid_gwmac[$BSSID]}]}"
done

declare -A base_ip_bssid
declare -A base_ip_mac
declare -A -i base_ip_hits
for SAMPLE in $dump_valid_list; do
    if (( ${dump_valid[$SAMPLE]} >= 3 )); then
        BSSID="${dump_bssid[$SAMPLE]}"
        GWMAC="${base_bssid_gwmac[$BSSID]}"
        if [[ ${dump_sa[$SAMPLE]} == $GWMAC && -n "${dump_dip[$SAMPLE]}" ]]; then
            base_ip_bssid[${dump_dip[$SAMPLE]}]=${dump_bssid[$SAMPLE]}
            base_ip_mac[${dump_dip[$SAMPLE]}]="${dump_da[$SAMPLE]}"
            base_ip_hits[${dump_dip[$SAMPLE]}]+=1
        elif [[ ${dump_da[$SAMPLE]} == $GWMAC && -n "${dump_sip[$SAMPLE]}" ]]; then
            base_ip_bssid[${dump_sip[$SAMPLE]}]=${dump_bssid[$SAMPLE]}
            base_ip_mac[${dump_sip[$SAMPLE]}]="${dump_sa[$SAMPLE]}"
            base_ip_hits[${dump_sip[$SAMPLE]}]+=1
        fi
    fi
done

shopt -s extglob nocasematch
for IP in ${!base_ip_mac[@]}; do
    BSSID="${base_ip_bssid[$IP]^^}"
    ESSID="${base_bssid_essid[$BSSID]:-???}"
    echo "$ESSID ($BSSID) -- $IP (${base_ip_mac[$IP]}): ${base_ip_hits[$IP]}"
done

