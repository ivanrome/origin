#!/bin/bash

set -ex

local_subnet_gateway=$1
local_subnet_cidr=$2
local_subnet_mask_len=$3
cluster_network_cidr=$4
service_network_cidr=$5
multitenant=$6
printf 'Container network is "%s"; local host has subnet "%s" and gateway "%s".\n' "${cluster_network_cidr}" "${local_subnet_cidr}" "${local_subnet_gateway}"
TUN=tun0

# Delete the subnet routing entry created because of ip link up on device
# ip link adds local subnet route entry asynchronously
# So check for the new route entry every 100 ms upto timeout of 2 secs and
# delete the route entry.
function delete_local_subnet_route() {
    local device=$1
    local time_interval=0.1  # 100 milli secs
    local max_intervals=20   # timeout: 2 secs
    local num_intervals=0
    local cmd="ip route | grep -q '${local_subnet_cidr} dev ${device}'"

    until $(eval $cmd) || [ $num_intervals -ge $max_intervals ]; do
        sleep $time_interval
        num_intervals=$((num_intervals + 1))
    done

    if [ $num_intervals -ge $max_intervals ]; then
        echo "Error: ${local_subnet_cidr} route not found for dev ${device}" >&2
        return 1
    fi
    ip route del ${local_subnet_cidr} dev ${device} proto kernel scope link
}

function setup() {
    # clear config file
    rm -f /etc/openshift-sdn/config.env

    ## openvswitch
    ovs-vsctl del-br br0 || true
    ovs-vsctl add-br br0 -- set Bridge br0 fail-mode=secure
    ovs-vsctl set bridge br0 protocols=OpenFlow13
    ovs-vsctl del-port br0 vxlan0 || true
    ovs-vsctl add-port br0 vxlan0 -- set Interface vxlan0 type=vxlan options:remote_ip="flow" options:key="flow" ofport_request=1
    ovs-vsctl add-port br0 ${TUN} -- set Interface ${TUN} type=internal ofport_request=2

    ip link del vlinuxbr || true
    ip link add vlinuxbr type veth peer name vovsbr
    ip link set vlinuxbr up
    ip link set vovsbr up
    ip link set vlinuxbr txqueuelen 0
    ip link set vovsbr txqueuelen 0
    brctl addif lbr0 vlinuxbr

    ovs-vsctl del-port br0 vovsbr || true
    ovs-vsctl add-port br0 vovsbr -- set Interface vovsbr ofport_request=3

    # Table 0; VXLAN filtering; the first rule sends un-tunnelled packets
    # to table 1. Additional per-node rules are filled in by controller.go
    ovs-ofctl -O OpenFlow13 add-flow br0 "table=0, tun_src=0.0.0.0, actions=goto_table:1"
    # eg, "table=0, tun_src=${remote_node}, actions=goto_table:1"

    # Table 1; learn MAC addresses and continue with table 2
    ovs-ofctl -O OpenFlow13 add-flow br0 "table=1, actions=learn(table=9, priority=200, hard_timeout=900, NXM_OF_ETH_DST[]=NXM_OF_ETH_SRC[], load:NXM_NX_TUN_IPV4_SRC[]->NXM_NX_TUN_IPV4_DST[], output:NXM_OF_IN_PORT[]), goto_table:2"

    # Table 2; initial dispatch
    ovs-ofctl -O OpenFlow13 add-flow br0 "table=2, priority=200, arp, actions=goto_table:9"
    ovs-ofctl -O OpenFlow13 add-flow br0 "table=2, priority=100, in_port=1, actions=goto_table:3" # vxlan0
    ovs-ofctl -O OpenFlow13 add-flow br0 "table=2, priority=100, in_port=2, actions=goto_table:6" # tun0
    ovs-ofctl -O OpenFlow13 add-flow br0 "table=2, priority=100, in_port=3, actions=goto_table:6" # vovsbr
    ovs-ofctl -O OpenFlow13 add-flow br0 "table=2, priority=0, actions=goto_table:4"              # container

    # Table 3; incoming from vxlan
    ovs-ofctl -O OpenFlow13 add-flow br0 "table=3, priority=200, ip, nw_dst=${local_subnet_gateway}, actions=output:2"
    if [ "$multitenant" = "true" ]; then
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=3, priority=100, ip, nw_dst=${local_subnet_cidr}, actions=move:NXM_NX_TUN_ID[0..31]->NXM_NX_REG0[], goto_table:7"
    else
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=3, priority=100, ip, nw_dst=${local_subnet_cidr}, actions=goto_table:9"
    fi

    # Table 4; incoming from container; filled in by openshift-sdn-ovs
    # eg, single-tenant: "table=4, priority=100, in_port=${ovs_port}, ip, nw_src=${ipaddr}, goto_table:6"
    # multitenant: "table=4, priority=100, in_port=${ovs_port}, ip, nw_src=${ipaddr}, actions=load:${tenant_id}->NXM_NX_REG0[], goto_table:5"

    # Table 5; service isolation; mostly filled in by controller.go
    if [ "$multitenant" = "true" ]; then
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=5, priority=200, reg0=0, ip, nw_dst=${service_network_cidr}, actions=output:2"
	# eg, "table=5, priority=200, ${service_proto}, nw_dst=${service_ip}, tp_dst=${service_port}, actions=output:2"
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=5, priority=100, ip, nw_dst=${service_network_cidr}, actions=drop"
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=5, priority=0, actions=goto_table:6"
    fi

    # Table 6; general routing
    ovs-ofctl -O OpenFlow13 add-flow br0 "table=6, priority=200, ip, nw_dst=${local_subnet_gateway}, actions=output:2"
    if [ "$multitenant" = "true" ]; then
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=6, priority=150, ip, reg0=0, nw_dst=${local_subnet_cidr}, actions=goto_table:9"
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=6, priority=150, ip, nw_dst=${local_subnet_cidr}, actions=goto_table:7"
    else
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=6, priority=150, ip, nw_dst=${local_subnet_cidr}, actions=goto_table:9"
    fi
    ovs-ofctl -O OpenFlow13 add-flow br0 "table=6, priority=100, ip, nw_dst=${cluster_network_cidr}, actions=goto_table:8"
    ovs-ofctl -O OpenFlow13 add-flow br0 "table=6, priority=0, ip, actions=output:2"

    # Table 7; to local container with isolation; filled in by openshift-sdn-ovs
    # eg, "table=7, priority=100, ip, nw_dst=${ipaddr}, reg0=${tenant_id}, actions=output:${ovs_port}"

    # Table 8; to remote container; filled in by controller.go
    # eg, "table=8, priority=100, ip, nw_dst=${remote_subnet_cidr}, actions=move:NXM_NX_REG0[]->NXM_NX_TUN_ID[0..31], set_field:${remote_node_ip}->tun_dst,output:1"

    # Table 9; MAC dispatch / ARP, filled in by Table 0's learn() rule
    # and with per-node vxlan ARP rules by controller.go
    ovs-ofctl -O OpenFlow13 add-flow br0 "table=9, priority=0, arp, actions=flood"
    # eg, "table=9, priority=100, arp, nw_dst=${remote_subnet_cidr}, actions=move:NXM_NX_REG0[]->NXM_NX_TUN_ID[0..31], set_field:${remote_node_ip}->tun_dst,output:1"

    # setup tun address
    ip addr add ${local_subnet_gateway}/${local_subnet_mask_len} dev ${TUN}
    ip link set ${TUN} up
    ip route add ${cluster_network_cidr} dev ${TUN} proto kernel scope link

    # Cleanup docker0 since docker won't do it
    ip link set docker0 down || true
    brctl delbr docker0 || true

    mkdir -p /etc/openshift-sdn
    echo "export OPENSHIFT_CLUSTER_SUBNET=${cluster_network_cidr}" >> "/etc/openshift-sdn/config.env"

    # delete unnecessary routes
    delete_local_subnet_route lbr0 || true
    delete_local_subnet_route ${TUN} || true
}

setup
