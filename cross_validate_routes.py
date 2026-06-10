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

def calculate_coverage(bgp_nets, apnic_nets):
    bgp_total = sum(net.num_addresses for net in bgp_nets)
    apnic_total = sum(net.num_addresses for net in apnic_nets)
    if apnic_total == 0:
        return 0
    return bgp_total / apnic_total

if __name__ == '__main__':
    version = sys.argv[1] # "ipv4" or "ipv6"
    bgp_path = sys.argv[2]
    apnic_path = sys.argv[3]

    bgp_nets = parse_bgp(bgp_path, version)
    apnic_nets = parse_apnic(apnic_path, version)

    ratio = calculate_coverage(bgp_nets, apnic_nets)
    
    # 0.7 to 1.3 is a reasonable threshold since BGP reflects actual routing which may slightly differ
    # from pure administrative APNIC assignments, but won't be 10x smaller or larger.
    if 0.7 <= ratio <= 1.3:
        print(f"PASS: {version} BGP coverage ratio {ratio:.3f}")
        sys.exit(0)
    else:
        print(f"FAIL: {version} BGP coverage ratio {ratio:.3f}")
        sys.exit(1)
