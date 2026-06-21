#!/bin/bash
#
# Scan the LAN for free IPs OUTSIDE the Fritzbox DHCP pool.
# DHCP pool is .20-.200, so static-safe ranges are .2-.19 and .201-.254.
# Usage: ./scan-free-ips.sh [subnet]   (default subnet: 192.168.10)
#
set -u

SUBNET="${1:-192.168.10}"

# Build candidate list (static-safe ranges only)
candidates=()
for n in $(seq 2 19) $(seq 201 254); do
    candidates+=("${SUBNET}.${n}")
done

echo "Scanning ${SUBNET}.2-19 and ${SUBNET}.201-254 (outside DHCP pool .20-.200)..."
echo

# Ping in parallel; print the ones that DON'T answer (= free), sorted by last octet
free=$(printf '%s\n' "${candidates[@]}" \
    | xargs -P 32 -I{} sh -c 'ping -c1 -t1 "{}" >/dev/null 2>&1 || echo "{}"' \
    | sort -t. -k4 -n)

echo "Free IPs:"
echo "$free" | sed 's/^/  /'
echo

# Highlight easy-to-remember candidates
echo "Easy-to-remember free picks:"
echo "$free" | awk -F. '
    { last=$4 }
    last==2 || last==3 || last==4 || last==5 || last==8 || last==10 || last==11 \
    || last==202 || last==222 || last==210 || last==250 || last==253 || last==254 \
    { print "  " $0 }
'
