# mikrotik/routing.rsc
# RouterOS script: route VPN-bound traffic through the shorti gateway host
#
# Assumptions:
#   - shorti gateway host LAN IP: 192.168.1.50  (change to match yours)
#   - VPN subnets: 10.0.0.0/8                    (change to match your VPN's pushed routes)
#
# Apply with: /import file=routing.rsc

# Static route: send VPN subnet traffic to the gateway host instead of the default gateway
/ip route
add dst-address=10.0.0.0/8 gateway=192.168.1.50 comment="shorti: VPN via gateway host"

# Optional: if your VPN uses a different subnet (e.g. 172.16.0.0/12) add another route:
# add dst-address=172.16.0.0/12 gateway=192.168.1.50 comment="shorti: VPN via gateway host"
