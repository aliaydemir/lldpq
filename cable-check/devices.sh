#!/bin/bash

# =============================================================================
# DEVICES.SH - LLDPq Network Device Configuration
# =============================================================================
#
# PURPOSE:
#   This file defines all network devices that LLDPq monitors. Contains device
#   IP addresses, SSH usernames, and hostnames for automated network monitoring.
#   Used by monitor.sh, check-lldp.sh, get-configs.sh, and assets.sh scripts.
#
# FORMAT:
#   Bash associative array where:
#   - KEY: Device IP address (management IP)
#   - VALUE: "username hostname" (space-separated)
#
# STRUCTURE:
#   declare -A devices=(
#       ["IP_ADDRESS"]="SSH_USERNAME HOSTNAME"
#       ["10.1.1.1"]="cumulus spine-01"
#   )
#
# USAGE BY SCRIPTS:
#   - monitor.sh:     Collects performance data via SSH
#   - check-lldp.sh:  Gathers LLDP topology information  
#   - get-configs.sh: Downloads device configurations
#   - assets.sh:      Collects device inventory data
#
# SSH REQUIREMENTS:
#   - SSH key-based authentication must be configured
#   - User must have sudo privileges on target devices
#   - Network connectivity required to management IPs
#
# DEVICE TYPES SUPPORTED:
#   - Cumulus Linux switches
#   - SONiC switches  
#   - Any Linux-based network device with NVUE/nv commands
#
# EXAMPLES:
#   ["10.101.100.1"]="cumulus BorderLeaf01"    # Border leaf switch
#   ["10.101.100.3"]="cumulus Spine01"         # Spine switch
#   ["10.101.100.12"]="cumulus Leaf01"         # Access leaf switch
#   ["192.168.1.10"]="admin Switch-Core-01"   # Core switch with different user
#
# MAINTENANCE:
#   - Add new devices by adding new array entries
#   - Remove devices by deleting their array entries
#   - Update IP addresses by changing the key
#   - Update usernames/hostnames by changing the value
#
# SECURITY NOTE:
#   This file contains network infrastructure information. Ensure proper
#   file permissions and access controls are in place.
#
# =============================================================================

declare -A devices=(

["10.101.100.1"]="cumulus BorderLeaf01"
["10.101.100.2"]="cumulus BorderLeaf02"
["10.101.100.3"]="cumulus Spine01"
["10.101.100.4"]="cumulus Spine02"
["10.101.100.12"]="cumulus Leaf01"
["10.101.100.13"]="cumulus Leaf02"
["10.101.100.14"]="cumulus Leaf03"
["10.101.100.15"]="cumulus Leaf04"

)
