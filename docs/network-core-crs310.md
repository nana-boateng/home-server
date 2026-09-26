# Network Core — MikroTik CRS310-8G+2S+IN

The CRS310 replaced the TP-Link switch as the core. This doc records the routing
decision, the port map, and the VLAN rollout procedure.

Related: [homelab-network-plan.md](./homelab-network-plan.md) ·
[DECISIONS.md](./DECISIONS.md) D15 · [hardware-inventory.md](./hardware-inventory.md)

---

## Hardware

| | |
|---|---|
| Model | MikroTik CRS310-8G+2S+IN |
| Ports | 8× 2.5GbE + 2× 10G SFP+ |
| Switch chip | Marvell 98DX226S |
| OS | RouterOS v7.24.4 (**stable** channel) |
| Management IP | `10.0.0.3` on the **bridge** interface |

**Management lives on the bridge, not a physical port.** An address on a bridge
member is unreliable and reachable from only one socket. Put it on the bridge.

---

## Decision: router-on-a-stick, not L3 switching

**The MikroTik owns all VLAN tagging and port assignment. The ER605 keeps
inter-VLAN routing and firewalling.**

This deserves its rationale recorded, because the opposite choice looks tempting
on the spec sheet:

The CRS310 *can* hardware-offload L3 routing. But **offloaded traffic bypasses the
CPU, and therefore bypasses the firewall** — you get speed or filtering, not both
on the same traffic. The VLANs here exist to *isolate* IoT and Guest, and
isolation is a firewall function. So the thing L3 switching would optimise is
precisely the traffic that is meant to be blocked. The optimisation targets the
wrong workload.

Keeping routing on the ER605 also keeps `10.0.0.1` as the gateway, which means
**Main never re-IPs** when VLANs are introduced.

---

## Port map

| Port | Device | Mode |
|---|---|---|
| ether1 | ER605 | trunk: tagged 20, 30; untagged PVID 10 |
| ether2 | Rhea | access PVID 10 |
| ether3 | Themis | access PVID 10 |
| ether4 | Hestia | access PVID 10 |
| ether5 | Tartarus | access PVID 10 |
| ether6 | EAP650 | trunk: tagged 20, 30; untagged PVID 10 |
| ether7 | seedbox | access PVID 10 |
| ether8 | workstation / spare | access PVID 10 |
| sfp+ 1–2 | free | future 10G to Tartarus |

---

## Current state: flat

One bridge, all ports, **`vlan-filtering` OFF**. The port map above is the target
configuration, not what is running today.

VLANs are **unblocked but deliberately deferred** until the flat 2.5G network is
proven. This is a change from earlier planning, which believed VLANs were blocked
on a working Omada controller — they are not, because the MikroTik does VLAN
tagging itself. The OC200 is now needed only for Omada AP management, which the
software controller also covers.

---

## VLAN rollout — procedure

When VLANs are turned on, the ordering matters more than the content.

> **Enable `vlan-filtering` LAST**, after every PVID and the full VLAN table are
> set. Enabling it first cuts off your own management path.

> **Learn WinBox MAC-connect before touching VLAN config.** It reaches the switch
> when IP configuration is broken, which is the situation you are most likely to
> create. Practise it while the network still works.

Steps:

1. Define the VLAN table on the CRS310 (10 Main, 20 IoT, 30 Guest).
2. Set PVIDs on every access port per the map above.
3. Set tagged membership on the two trunk ports (ether1, ether6).
4. Configure DHCP scopes and inter-VLAN isolation rules on the ER605.
5. Bring up the Omada software controller to tag the guest/IoT SSIDs on the EAP650.
6. **Only then** enable `vlan-filtering` on the bridge.

Addressing for the VLANs is the third-octet scheme in
[DECISIONS.md](./DECISIONS.md) D10 — VLAN 10 `10.0.0.0/24`, VLAN 20
`10.0.20.0/24`, VLAN 30 `10.0.30.0/24`, all under one `10.0.0.0/16` supernet.

---

## Known limitation: corosync shares a NIC

Each node has one port, so corosync shares its NIC with guest and storage
traffic. Corosync is latency-sensitive, and heavy NFS or backup traffic can make
it flap.

There is no fix today — one port per node. The free SFP+ ports make a dedicated
corosync link possible if NICs are ever added. Tracked as a known limitation, not
a task: [OPEN-QUESTIONS.md](./OPEN-QUESTIONS.md).
