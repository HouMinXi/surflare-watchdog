#!/usr/bin/env python3
import sys
import ipaddress

def parse_apnic(file_path, version='ipv4'):
    cidrs = []
    with open(file_path) as f:
        for line in f:
            parts = line.strip().split('|')
            if len(parts) >= 5 and parts[1] == 'CN' and parts[2] == version:
                ip_str = parts[3]
                count = int(parts[4])
                if version == 'ipv4':
                    start_ip = int(ipaddress.IPv4Address(ip_str))
                    end_ip = start_ip + count - 1
                    for net in ipaddress.summarize_address_range(
                        ipaddress.IPv4Address(start_ip),
                        ipaddress.IPv4Address(end_ip)):
                        cidrs.append(net)
                else:
                    cidrs.append(ipaddress.IPv6Network(f"{ip_str}/{count}"))
    return list(ipaddress.collapse_addresses(cidrs))

def parse_bgp(file_path, version='ipv4'):
    cidrs = []
    with open(file_path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                try:
                    if version == 'ipv4':
                        cidrs.append(ipaddress.IPv4Network(line))
                    else:
                        cidrs.append(ipaddress.IPv6Network(line))
                except Exception:
                    pass
    return list(ipaddress.collapse_addresses(cidrs))

def calculate_overlap(bgp_nets, apnic_nets):
    def get_intervals(nets):
        return [(int(n.network_address), int(n.broadcast_address)) for n in nets]
    
    bgp_ivs = sorted(get_intervals(bgp_nets))
    apnic_ivs = sorted(get_intervals(apnic_nets))
    
    overlap_ips = 0
    bgp_total = 0
    apnic_idx = 0
    apnic_len = len(apnic_ivs)
    
    for bgp_start, bgp_end in bgp_ivs:
        bgp_total += (bgp_end - bgp_start + 1)
        while apnic_idx < apnic_len and apnic_ivs[apnic_idx][1] < bgp_start:
            apnic_idx += 1
            
        temp_idx = apnic_idx
        while temp_idx < apnic_len and apnic_ivs[temp_idx][0] <= bgp_end:
            a_start, a_end = apnic_ivs[temp_idx]
            intersect_start = max(bgp_start, a_start)
            intersect_end = min(bgp_end, a_end)
            if intersect_start <= intersect_end:
                overlap_ips += (intersect_end - intersect_start + 1)
            temp_idx += 1
            
    if bgp_total == 0:
        return 0.0
    return overlap_ips / bgp_total

if __name__ == '__main__':
    version = sys.argv[1] # "ipv4" or "ipv6"
    bgp_path = sys.argv[2]
    apnic_path = sys.argv[3]

    bgp_nets = parse_bgp(bgp_path, version)
    apnic_nets = parse_apnic(apnic_path, version)

    ratio = calculate_overlap(bgp_nets, apnic_nets)
    
    # We require at least 95% of the BGP dumped IPs to be within APNIC's China delegation
    if ratio >= 0.95:
        print(f"PASS: {version} BGP routes are {ratio*100:.2f}% covered by APNIC CN delegation")
        sys.exit(0)
    else:
        print(f"FAIL: {version} BGP routes are only {ratio*100:.2f}% covered by APNIC CN delegation (threshold: 95%)")
        sys.exit(1)
