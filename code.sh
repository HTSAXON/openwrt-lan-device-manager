cat << 'EOF' > /www/cgi-bin/manage
#!/bin/sh

# Ensure states database exists
touch /tmp/shaping_limits.db

# Parse HTTP Query Parameters (GET request variables)
action=$(echo "$QUERY_STRING" | grep -oE "action=[a-zA-Z0-9_-]+" | cut -d= -f2)
mac=$(echo "$QUERY_STRING" | grep -oE "mac=[a-fA-F0-9:]+" | cut -d= -f2 | tr 'A-Z' 'a-z')
ip=$(echo "$QUERY_STRING" | grep -oE "ip=[0-9.]+" | cut -d= -f2)
down_rate=$(echo "$QUERY_STRING" | grep -oE "down_rate=[0-9a-zA-Z]+" | cut -d= -f2)
up_rate=$(echo "$QUERY_STRING" | grep -oE "up_rate=[0-9a-zA-Z]+" | cut -d= -f2)

# --- ACTION HANDLERS: MUST RUN BEFORE ANY HTML CONTENT HEADERS ARE PRINTED ---

# BLOCK HANDLER: Blacklists MAC in all wireless interfaces and evicts them
if [ "$action" = "block" ] && [ -n "$mac" ]; then
    for section in $(uci show wireless 2>/dev/null | grep "=wifi-iface" | cut -d. -f2 | cut -d= -f1); do
        uci set "wireless.${section}.macfilter=deny"
        if ! uci -q get "wireless.${section}.maclist" | grep -qi "$mac"; then
            uci add_list "wireless.${section}.maclist=$mac"
        fi
    done
    uci commit wireless
    /sbin/wifi reload >/dev/null 2>&1
    
    echo "Status: 302 Found"
    echo "Location: manage"
    echo ""
    exit 0
fi

# UNBLOCK HANDLER: Removes MAC from the blacklist on all wireless interfaces
if [ "$action" = "unblock" ] && [ -n "$mac" ]; then
    for section in $(uci show wireless 2>/dev/null | grep "=wifi-iface" | cut -d. -f2 | cut -d= -f1); do
        uci del_list "wireless.${section}.maclist=$mac"
    done
    uci commit wireless
    /sbin/wifi reload >/dev/null 2>&1
    
    echo "Status: 302 Found"
    echo "Location: manage"
    echo ""
    exit 0
fi

# LIMIT HANDLER: Restricts upload/download bandwidth on br-lan (if supported)
if [ "$action" = "limit" ] && [ -n "$ip" ]; then
    octet=$(echo "$ip" | cut -d. -f4)
    classid="1:$octet"

    # 1. Apply Download limits (Egress shaping on LAN)
    tc qdisc add dev br-lan root handle 1: htb default 10 2>/dev/null
    tc class add dev br-lan parent 1: classid 1:10 htb rate 1000mbit 2>/dev/null
    
    tc filter del dev br-lan parent 1: protocol ip prio 1 u32 match ip dst "$ip" 2>/dev/null
    tc class del dev br-lan parent 1: classid "$classid" 2>/dev/null
    
    if [ -n "$down_rate" ]; then
        tc class add dev br-lan parent 1: classid "$classid" htb rate "$down_rate" 2>/dev/null
        tc filter add dev br-lan parent 1: protocol ip prio 1 u32 match ip dst "$ip" flowid "$classid" 2>/dev/null
    fi

    # 2. Apply Upload limits (Ingress policing on LAN)
    tc qdisc add dev br-lan handle ffff: ingress 2>/dev/null
    tc filter del dev br-lan parent ffff: protocol ip prio 1 u32 match ip src "$ip" 2>/dev/null
    
    if [ -n "$up_rate" ]; then
        tc filter add dev br-lan parent ffff: protocol ip prio 1 u32 match ip src "$ip" police rate "$up_rate" burst 15k drop flowid :1 2>/dev/null
    fi

    # 3. Update state database
    grep -v "^$ip|" /tmp/shaping_limits.db > /tmp/shaping_limits.db.tmp 2>/dev/null
    mv /tmp/shaping_limits.db.tmp /tmp/shaping_limits.db
    echo "$ip|$down_rate|$up_rate" >> /tmp/shaping_limits.db
    
    echo "Status: 302 Found"
    echo "Location: manage"
    echo ""
    exit 0
fi

# REMOVE LIMIT HANDLER
if [ "$action" = "unlimit" ] && [ -n "$ip" ]; then
    octet=$(echo "$ip" | cut -d. -f4)
    classid="1:$octet"
    
    # Remove download classes/filters
    tc filter del dev br-lan parent 1: protocol ip prio 1 u32 match ip dst "$ip" 2>/dev/null
    tc class del dev br-lan parent 1: classid "$classid" 2>/dev/null
    
    # Remove upload filters
    tc filter del dev br-lan parent ffff: protocol ip prio 1 u32 match ip src "$ip" 2>/dev/null
    
    # Remove from local database
    grep -v "^$ip|" /tmp/shaping_limits.db > /tmp/shaping_limits.db.tmp 2>/dev/null
    mv /tmp/shaping_limits.db.tmp /tmp/shaping_limits.db
    
    echo "Status: 302 Found"
    echo "Location: manage"
    echo ""
    exit 0
fi


# --- IF NO ACTION EXITED, INITIALIZE HTML OUTPUT HEADERS ---
echo "Content-type: text/html"
echo ""

# Evaluate system package support
has_tc=0
if command -v tc >/dev/null 2>&1; then
    has_tc=1
fi

# --- REAL-TIME SPEED MEASUREMENT SNAPS ---
sysctl -w net.netfilter.nf_conntrack_acct=1 >/dev/null 2>&1

SNAP1=$(mktemp)
SNAP2=$(mktemp)

# Snapshot 1 parsing logic
awk '
{
    src1=""
    bytes1=0
    bytes2=0
    for (i=1; i<=NF; i++) {
        if ($i ~ /^src=/) {
            split($i, a, "=")
            if (a[2] ~ /^(192\.168\.|10\.|172\.)/) {
                src1 = a[2]
            }
        }
        if ($i ~ /^bytes=/) {
            split($i, b, "=")
            if (bytes1 == 0) {
                bytes1 = b[2]
            } else {
                bytes2 = b[2]
            }
        }
    }
    if (src1 != "") {
        up[src1] += bytes1
        down[src1] += bytes2
    }
}
END {
    for (ip in up) {
        print ip, up[ip], down[ip]
    }
}
' /proc/net/nf_conntrack > "$SNAP1"

sleep 1

# Snapshot 2 parsing logic
awk '
{
    src1=""
    bytes1=0
    bytes2=0
    for (i=1; i<=NF; i++) {
        if ($i ~ /^src=/) {
            split($i, a, "=")
            if (a[2] ~ /^(192\.168\.|10\.|172\.)/) {
                src1 = a[2]
            }
        }
        if ($i ~ /^bytes=/) {
            split($i, b, "=")
            if (bytes1 == 0) {
                bytes1 = b[2]
            } else {
                bytes2 = b[2]
            }
        }
    }
    if (src1 != "") {
        up[src1] += bytes1
        down[src1] += bytes2
    }
}
END {
    for (ip in up) {
        print ip, up[ip], down[ip]
    }
}
' /proc/net/nf_conntrack > "$SNAP2"


format_speed() {
    bytes=$1
    if [ "$bytes" -ge 1048576 ]; then
        mb=$(awk -v b="$bytes" 'BEGIN {printf "%.1f", b/1048576}')
        echo "${mb} MB/s"
    elif [ "$bytes" -ge 1024 ]; then
        kb=$(awk -v b="$bytes" 'BEGIN {printf "%.1f", b/1024}')
        echo "${kb} KB/s"
    else
        echo "${bytes} B/s"
    fi
}

# --- ACTIVE CLIENT & INTERFACE LOG COMPILATION ---
WIFI_TEMP=$(mktemp)
ACTIVE_MACS_TEMP=$(mktemp)

for iface in $(iwinfo | grep -E '^[a-zA-Z0-9.-]+' | awk '{print $1}'); do
    SSID=$(iwinfo "$iface" info | grep "ESSID" | sed -n 's/.*ESSID: "\(.*\)".*/\1/p')
    [ -z "$SSID" ] && SSID="Hidden"
    
    # Method 1: Get Wi-Fi stations using iwinfo
    iwinfo "$iface" assoclist 2>/dev/null | grep -E '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | while read -r line; do
        mac_assoc=$(echo "$line" | awk '{print tolower($1)}')
        signal=$(echo "$line" | awk '{print $2 " " $3}')
        echo "$mac_assoc|WiFi ($SSID)|$signal" >> "$WIFI_TEMP"
    done
    
    # Method 2: Get Wi-Fi stations using standard Linux 'iw' (driver fallback)
    if command -v iw >/dev/null 2>&1; then
        iw dev "$iface" station dump 2>/dev/null | awk -v ssid="$SSID" '
        /^Station/ { mac = tolower($2) }
        /signal:/ { 
            sig_val = ""
            for(i=1; i<=NF; i++) {
                if($i ~ /^-/) {
                    sig_val = $i " dBm"
                    break
                }
            }
            if (sig_val == "") sig_val = $2 " " $3
            print mac "|WiFi (" ssid ")|" sig_val
        }
        ' >> "$WIFI_TEMP"
    fi
done

# De-duplicate temporary Wi-Fi database
if [ -s "$WIFI_TEMP" ]; then
    sort -u "$WIFI_TEMP" > "${WIFI_TEMP}.sorted"
    mv "${WIFI_TEMP}.sorted" "$WIFI_TEMP"
fi

# Build strictly active MAC list
# 1. Add active Wi-Fi MACs
if [ -s "$WIFI_TEMP" ]; then
    cut -d'|' -f1 "$WIFI_TEMP" >> "$ACTIVE_MACS_TEMP"
fi

# 2. Add active LAN/Ethernet clients from neighbor table
ip neigh show 2>/dev/null | grep -E 'REACHABLE|DELAY|PROBE' | awk '{for(i=1;i<=NF;i++) if($i=="lladdr") print tolower($(i+1))}' >> "$ACTIVE_MACS_TEMP"

# 3. Add active physical switch ports from Bridge FDB
if command -v bridge >/dev/null 2>&1; then
    bridge fdb show 2>/dev/null | grep -v "permanent" | grep -v "self" | awk '{print tolower($1)}' >> "$ACTIVE_MACS_TEMP"
fi

sort -u "$ACTIVE_MACS_TEMP" > "${ACTIVE_MACS_TEMP}.sorted"
mv "${ACTIVE_MACS_TEMP}.sorted" "$ACTIVE_MACS_TEMP"


# --- BUFFER CLIENT ROWS AND DIVIDE BY SOURCE ---
ARP_TEMP=$(mktemp)
CATEGORIES_LIST="/tmp/shaping_cats_$$"
touch "$CATEGORIES_LIST"

total_up_rate=0
total_down_rate=0
active_client_count=0
blocked_count=0

grep -v "00:00:00:00:00:00" /proc/net/arp | grep -v "IP address" > "$ARP_TEMP"

while read -r dev_ip hw flags dev_mac mask interface_device; do
    mac_lower=$(echo "$dev_mac" | tr 'A-Z' 'a-z')
    
    # Check if this MAC is blocked under Method 1 (in wireless config maclist)
    is_blocked=0
    if uci -q get wireless.@wifi-iface[0].maclist | grep -qi "$mac_lower"; then
        is_blocked=1
    fi
    
    # Skip rendering blocked clients in the active devices lists
    if [ "$is_blocked" -eq 1 ]; then
        continue
    fi
    
    # Filter out inactive stale entries
    if ! grep -q "^$mac_lower$" "$ACTIVE_MACS_TEMP" 2>/dev/null; then
        continue
    fi
    
    # FILTER OUT DUPLICATE STALE IP LEASES
    leased_ip=$(awk -v m="$mac_lower" 'tolower($2) == m {print $3}' /tmp/dhcp.leases | head -n 1)
    if [ -n "$leased_ip" ] && [ "$dev_ip" != "$leased_ip" ]; then
        continue
    fi
    
    # Resolve Hostnames
    hostname=$(awk -v m="$mac_lower" 'tolower($2) == m {print $4}' /tmp/dhcp.leases)
    if [ -z "$hostname" ] || [ "$hostname" = "*" ]; then
        hostname="Unknown"
    fi
    
    # Identify Connection Medium
    wifi_entry=$(grep "^$mac_lower|" "$WIFI_TEMP" 2>/dev/null | head -n 1)
    if [ -n "$wifi_entry" ]; then
        source_medium=$(echo "$wifi_entry" | cut -d'|' -f2)
        signal_level=$(echo "$wifi_entry" | cut -d'|' -f3)
        source_display="$source_medium ($signal_level)"
    else
        bridge_port=""
        if command -v bridge >/dev/null 2>&1; then
            bridge_port=$(bridge fdb show 2>/dev/null | grep -i "$mac_lower" | grep -v "permanent" | grep -v "self" | awk '{print $3}' | head -n 1)
        fi
        
        if [ -n "$bridge_port" ] && echo "$bridge_port" | grep -qiE 'wlan|ath'; then
            source_medium="WiFi (Offline / Idle)"
            source_display="WiFi (Offline / Idle)"
        else
            source_medium="Ethernet"
            if [ "$interface_device" = "br-lan" ]; then
                source_display="Ethernet"
            else
                source_display="Interface ($interface_device)"
            fi
        fi
    fi
    
    # Calculate real-time speed rates from conntrack snapshots
    up1=$(awk -v ip="$dev_ip" '$1==ip {print $2}' "$SNAP1")
    down1=$(awk -v ip="$dev_ip" '$1==ip {print $3}' "$SNAP1")
    [ -z "$up1" ] && up1=0
    [ -z "$down1" ] && down1=0

    up2=$(awk -v ip="$dev_ip" '$1==ip {print $2}' "$SNAP2")
    down2=$(awk -v ip="$dev_ip" '$1==ip {print $3}' "$SNAP2")
    [ -z "$up2" ] && up2=0
    [ -z "$down2" ] && down2=0

    if [ "$up2" -ge "$up1" ]; then up_rate=$((up2 - up1)); else up_rate=0; fi
    if [ "$down2" -ge "$down1" ]; then down_rate=$((down2 - down1)); else down_rate=0; fi

    total_up_rate=$((total_up_rate + up_rate))
    total_down_rate=$((total_down_rate + down_rate))
    active_client_count=$((active_client_count + 1))

    up_display=$(format_speed "$up_rate")
    down_display=$(format_speed "$down_rate")

    # Get active shaping parameters
    current_down_limit=$(awk -F'|' -v ip="$dev_ip" '$1==ip {print $2}' /tmp/shaping_limits.db)
    current_up_limit=$(awk -F'|' -v ip="$dev_ip" '$1==ip {print $3}' /tmp/shaping_limits.db)
    
    toggle_action="<a href='?action=block&mac=$mac_lower' class='inline-block px-3 py-1 bg-red-600 hover:bg-red-700 text-white rounded font-semibold text-xs shadow-sm transition'>Block</a>"
    
    # Build Dual Limit Panel (Tenda inspired layout)
    if [ "$has_tc" -eq 1 ]; then
        limit_action="<form action='manage' method='GET' class='inline-flex items-center gap-2'>"
        limit_action="$limit_action <input type='hidden' name='action' value='limit'>"
        limit_action="$limit_action <input type='hidden' name='ip' value='$dev_ip'>"
        limit_action="$limit_action <div class='flex flex-col gap-1 text-[10px] bg-slate-50 border border-slate-200 p-1.5 rounded-md'>"
        limit_action="$limit_action   <div class='flex items-center justify-between gap-1'>"
        limit_action="$limit_action     <span class='text-slate-400 font-bold uppercase text-[9px]'>Down:</span>"
        limit_action="$limit_action     <input type='text' name='down_rate' value='$current_down_limit' placeholder='e.g., 2mbit' class='w-24 text-[10px] border border-slate-300 rounded px-1.5 py-0.5 bg-white font-medium focus:ring-1 focus:ring-slate-500 focus:outline-none text-right'>"
        limit_action="$limit_action   </div>"
        limit_action="$limit_action   <div class='flex items-center justify-between gap-1'>"
        limit_action="$limit_action     <span class='text-slate-400 font-bold uppercase text-[9px]'>Up:</span>"
        limit_action="$limit_action     <input type='text' name='up_rate' value='$current_up_limit' placeholder='e.g., 512kbit' class='w-24 text-[10px] border border-slate-300 rounded px-1.5 py-0.5 bg-white font-medium focus:ring-1 focus:ring-slate-500 focus:outline-none text-right'>"
        limit_action="$limit_action   </div>"
        limit_action="$limit_action </div>"
        
        if [ -n "$current_down_limit" ] || [ -n "$current_up_limit" ]; then
            status_tag="<span class='px-2 py-1 text-xs font-semibold rounded-full bg-amber-100 text-amber-800 border border-amber-200'>Throttled</span>"
            limit_action="$limit_action <div class='flex flex-col gap-1'>"
            limit_action="$limit_action   <button type='submit' class='px-2.5 py-1 bg-slate-800 hover:bg-slate-900 text-white rounded font-semibold text-xs shadow transition'>Update</button>"
            limit_action="$limit_action   <a href='?action=unlimit&ip=$dev_ip' class='px-2.5 py-1 bg-slate-600 hover:bg-slate-700 text-white text-center rounded font-semibold text-xs shadow transition'>Remove</a>"
            limit_action="$limit_action </div>"
        else
            status_tag="<span class='px-2 py-1 text-xs font-semibold rounded-full bg-emerald-100 text-emerald-800 border border-emerald-200'>Active</span>"
            limit_action="$limit_action <button type='submit' class='px-3 py-1.5 bg-slate-800 hover:bg-slate-900 text-white rounded font-semibold text-xs shadow transition'>Limit</button>"
        fi
        limit_action="$limit_action </form>"
    else
        status_tag="<span class='px-2 py-1 text-xs font-semibold rounded-full bg-emerald-100 text-emerald-800 border border-emerald-200'>Active</span>"
        limit_action="" # Completely hide the Limit action form when tc is missing
    fi
    
    # Categorize output tables by interface/SSID
    safe_cat=$(echo "$source_medium" | tr -cd 'a-zA-Z0-9_')
    [ -z "$safe_cat" ] && safe_cat="Ethernet"
    
    # Save categories tracker
    echo "$safe_cat|$source_medium" >> "$CATEGORIES_LIST"
    
    # Buffer active table rows
    echo "<tr>" >> "/tmp/row_${$}_${safe_cat}"
    echo "  <td class='px-6 py-4 text-sm font-semibold text-slate-800'>$hostname</td>" >> "/tmp/row_${$}_${safe_cat}"
    echo "  <td class='px-6 py-4 text-sm text-slate-600'>$dev_ip</td>" >> "/tmp/row_${$}_${safe_cat}"
    echo "  <td class='px-6 py-4 text-sm font-mono text-slate-500'>$dev_mac</td>" >> "/tmp/row_${$}_${safe_cat}"
    echo "  <td class='px-6 py-4 text-sm text-slate-600'>$source_display</td>" >> "/tmp/row_${$}_${safe_cat}"
    echo "  <td class='px-6 py-4 text-sm font-semibold text-amber-600'>$up_display</td>" >> "/tmp/row_${$}_${safe_cat}"
    echo "  <td class='px-6 py-4 text-sm font-semibold text-blue-600'>$down_display</td>" >> "/tmp/row_${$}_${safe_cat}"
    echo "  <td class='px-6 py-4 text-sm'>$status_tag</td>" >> "/tmp/row_${$}_${safe_cat}"
    echo "  <td class='px-6 py-4 text-right text-sm flex justify-end gap-2'>$toggle_action $limit_action</td>" >> "/tmp/row_${$}_${safe_cat}"
    echo "</tr>" >> "/tmp/row_${$}_${safe_cat}"
done < "$ARP_TEMP"

# --- GENERATE BLOCKED DEVICE ROWS DIRECTLY FROM SYSTEM MACLIST ---
first_wifi_iface=$(uci show wireless 2>/dev/null | grep "=wifi-iface" | head -n 1 | cut -d. -f2 | cut -d= -f1)
if [ -n "$first_wifi_iface" ]; then
    blocked_macs=$(uci -q get "wireless.${first_wifi_iface}.maclist")
    for b_mac in $blocked_macs; do
        mac_lower=$(echo "$b_mac" | tr 'A-Z' 'a-z')
        [ -z "$mac_lower" ] && continue
        
        # Resolve hostnames and last known IPs for blocked devices
        hostname=$(awk -v m="$mac_lower" 'tolower($2) == m {print $4}' /tmp/dhcp.leases)
        if [ -z "$hostname" ] || [ "$hostname" = "*" ]; then
            hostname="Unknown"
        fi
        
        last_ip=$(awk -v m="$mac_lower" 'tolower($2) == m {print $3}' /tmp/dhcp.leases | head -n 1)
        [ -z "$last_ip" ] && last_ip="N/A"
        
        echo "<tr>" >> "/tmp/row_Blocked_$$"
        echo "  <td class='px-6 py-4 text-sm font-semibold text-slate-800'>$hostname</td>" >> "/tmp/row_Blocked_$$"
        echo "  <td class='px-6 py-4 text-sm text-slate-600'>$last_ip</td>" >> "/tmp/row_Blocked_$$"
        echo "  <td class='px-6 py-4 text-sm font-mono text-slate-500'>$b_mac</td>" >> "/tmp/row_Blocked_$$"
        echo "  <td class='px-6 py-4 text-sm text-slate-600'>WiFi (Evicted)</td>" >> "/tmp/row_Blocked_$$"
        echo "  <td class='px-6 py-4 text-sm'><span class='px-2 py-1 text-xs font-semibold rounded-full bg-red-100 text-red-800 border border-red-200'>Evicted</span></td>" >> "/tmp/row_Blocked_$$"
        echo "  <td class='px-6 py-4 text-right text-sm'><a href='?action=unblock&mac=$mac_lower' class='inline-block px-3 py-1 bg-emerald-600 hover:bg-emerald-700 text-white rounded font-semibold text-xs shadow-sm transition'>Unblock</a></td>" >> "/tmp/row_Blocked_$$"
        echo "</tr>" >> "/tmp/row_Blocked_$$"
        
        blocked_count=$((blocked_count + 1))
    done
fi

total_up_display=$(format_speed "$total_up_rate")
total_down_display=$(format_speed "$total_down_rate")


# --- HTML RENDER: Page Header & Stats Cards ---
cat << HTML
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Router Client Controller</title>
    <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-slate-100 font-sans p-4 md:p-8">
    <div class="max-w-7xl mx-auto">
        <div class="flex items-center justify-between mb-6">
            <h1 class="text-3xl font-extrabold text-slate-800 font-sans tracking-tight">Local Device Controller</h1>
            <a href="manage" class="px-5 py-2.5 bg-slate-800 text-white font-semibold text-sm rounded shadow-sm hover:bg-slate-700 transition">Refresh Data</a>
        </div>
        
        <!-- Sum metrics cards -->
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-8">
            <div class="bg-white p-5 rounded-lg shadow-sm border border-slate-200">
                <div class="text-xs font-bold text-slate-400 uppercase tracking-wider">Cumulative Uplink (TX)</div>
                <div class="text-3xl font-black text-amber-600 mt-1">$total_up_display</div>
            </div>
            <div class="bg-white p-5 rounded-lg shadow-sm border border-slate-200">
                <div class="text-xs font-bold text-slate-400 uppercase tracking-wider">Cumulative Downlink (RX)</div>
                <div class="text-3xl font-black text-blue-600 mt-1">$total_down_display</div>
            </div>
            <div class="bg-white p-5 rounded-lg shadow-sm border border-slate-200">
                <div class="text-xs font-bold text-slate-400 uppercase tracking-wider">Active Connected Devices</div>
                <div class="text-3xl font-black text-slate-800 mt-1">$active_client_count</div>
            </div>
        </div>
HTML


# --- HTML RENDER: Separated Active Devices Tables ---
if [ -s "$CATEGORIES_LIST" ]; then
    sort -u "$CATEGORIES_LIST" | while read -r line; do
        safe_cat=$(echo "$line" | cut -d'|' -f1)
        display_name=$(echo "$line" | cut -d'|' -f2)
        
        cat << HTML
        <div class="mb-8">
            <div class="flex items-center gap-2 mb-4">
                <span class="w-3 h-3 bg-emerald-500 rounded-full"></span>
                <h2 class="text-xl font-bold text-slate-800 tracking-tight">$display_name Network Clients</h2>
            </div>
            <div class="bg-white shadow rounded-lg overflow-hidden border border-slate-200">
                <table class="min-w-full divide-y divide-slate-200">
                    <thead class="bg-slate-50">
                        <tr>
                            <th class="px-6 py-3 text-left text-xs font-semibold text-slate-500 uppercase">Device Hostname</th>
                            <th class="px-6 py-3 text-left text-xs font-semibold text-slate-500 uppercase">IP Address</th>
                            <th class="px-6 py-3 text-left text-xs font-semibold text-slate-500 uppercase">MAC Address</th>
                            <th class="px-6 py-3 text-left text-xs font-semibold text-slate-500 uppercase">Connection Source</th>
                            <th class="px-6 py-3 text-left text-xs font-semibold text-slate-500 uppercase">Uplink (TX)</th>
                            <th class="px-6 py-3 text-left text-xs font-semibold text-slate-500 uppercase">Downlink (RX)</th>
                            <th class="px-6 py-3 text-left text-xs font-semibold text-slate-500 uppercase">Status</th>
                            <th class="px-6 py-3 text-right text-xs font-semibold text-slate-500 uppercase">Actions</th>
                        </tr>
                    </thead>
                    <tbody class="divide-y divide-slate-200 bg-white">
HTML
        # Render table rows
        cat "/tmp/row_${$}_${safe_cat}" 2>/dev/null
        
        cat << HTML
                    </tbody>
                </table>
            </div>
        </div>
HTML
        # Clean categories row files
        rm -f "/tmp/row_${$}_${safe_cat}"
    done
else
    # Output empty message if no active devices are detected
    cat << HTML
    <div class="bg-white rounded-lg border border-slate-200 p-8 text-center text-slate-500 mb-8 font-semibold">
        No active connected devices detected. Click "Refresh Data" to re-scan interface links.
    </div>
HTML
fi


# --- HTML RENDER: Blocked Devices Table at the end ---
if [ "$blocked_count" -gt 0 ]; then
    cat << HTML
    <div class="mt-12 mb-8">
        <div class="flex items-center gap-2 mb-4">
            <span class="w-3 h-3 bg-red-500 rounded-full"></span>
            <h2 class="text-xl font-bold text-red-800 tracking-tight">Blocked Devices Repository</h2>
        </div>
        <div class="bg-white shadow rounded-lg overflow-hidden border border-red-200">
            <table class="min-w-full divide-y divide-red-200">
                <thead class="bg-red-50">
                    <tr>
                        <th class="px-6 py-3 text-left text-xs font-semibold text-red-500 uppercase">Device Hostname</th>
                        <th class="px-6 py-3 text-left text-xs font-semibold text-red-500 uppercase">IP Address</th>
                        <th class="px-6 py-3 text-left text-xs font-semibold text-red-500 uppercase">MAC Address</th>
                        <th class="px-6 py-3 text-left text-xs font-semibold text-red-500 uppercase">Connection Source</th>
                        <th class="px-6 py-3 text-left text-xs font-semibold text-red-500 uppercase">Status</th>
                        <th class="px-6 py-3 text-right text-xs font-semibold text-red-500 uppercase">Actions</th>
                    </tr>
                </thead>
                <tbody class="divide-y divide-red-200 bg-white">
HTML
    # Output buffered blocked devices rows
    cat "/tmp/row_Blocked_$$" 2>/dev/null
    
    cat << HTML
                </tbody>
            </table>
        </div>
    </div>
HTML
    rm -f "/tmp/row_Blocked_$$"
fi


# --- SANITIZE TEMP ENVIRONMENT FILES ---
rm -f "$WIFI_TEMP"
rm -f "$ACTIVE_MACS_TEMP"
rm -f "$ARP_TEMP"
rm -f "$SNAP1"
rm -f "$SNAP2"
rm -f "$CATEGORIES_LIST"


# Render closing footer HTML
cat << 'HTML'
        <div class="mt-8 text-[11px] text-slate-400 text-center space-y-1">
            <p><strong>Note:</strong> Active clients are resolved securely in real-time. Blocked clients are stored separately to keep active list matrices tidy.</p>
            <p>Limits support common shorthand notations (e.g., <code>512kbit</code>, <code>1mbit</code>, <code>4mbit</code>, <code>20mbit</code>).</p>
        </div>
    </div>
</body>
</html>
HTML
EOF