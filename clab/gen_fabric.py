#!/usr/bin/env python3
"""Generate a containerlab leaf/spine fabric + SR Linux startup configs.

Emits:
  clab/fabric.clab.yaml         - the containerlab topology
  clab/configs/<node>.cli       - per-node SR Linux startup config (eBGP CLOS)
  clab/gnmic.yaml               - gnmic subscription/collector config

Addressing plan (deterministic):
  loopbacks : leaf i  -> 10.0.0.<i>/32 ; spine j -> 10.0.1.<j>/32
  fabric /31: 10.<100+j>.<i>.0/31 ; spine=.0 leaf=.1
  ASN       : leaf i  -> 65000+i    ; spine j -> 65100+j   (eBGP)
Usage: gen_fabric.py --spines 2 --leaves 4 --image ghcr.io/nokia/srlinux:24.10.1
"""
import argparse
import os
import textwrap

SRL_USER = "admin"
SRL_PASS = "NokiaSrl1!"


def leaf_name(i: int) -> str:
    return f"leaf{i}"


def spine_name(j: int) -> str:
    return f"spine{j}"


def srl_config(node: str, is_leaf: bool, idx: int, spines: int, leaves: int) -> str:
    """Build an SR Linux CLI startup config for one node."""
    if is_leaf:
        loop = f"10.0.0.{idx}/32"
        asn = 65000 + idx
        peers = spines
    else:
        loop = f"10.0.1.{idx}/32"
        asn = 65100 + idx
        peers = leaves

    lines = []
    lines.append("set / system gnmi-server admin-state enable")
    lines.append("set / system gnmi-server network-instance mgmt admin-state enable")
    lines.append("set / system gnmi-server network-instance mgmt port 57400")
    lines.append("set / system gnmi-server network-instance mgmt tls-profile clab-profile")
    lines.append("set / system gnmi-server unix-socket admin-state enable")

    # loopback
    lines.append("set / interface system0 admin-state enable")
    lines.append(f"set / interface system0 subinterface 0 ipv4 admin-state enable")
    lines.append(f"set / interface system0 subinterface 0 ipv4 address {loop}")

    # fabric links + BGP neighbors
    neighbor_ips = []
    for p in range(1, peers + 1):
        # port index on THIS node toward peer p
        port = p
        eth = f"ethernet-1/{port}"
        if is_leaf:
            # leaf idx towards spine p -> subnet 10.(100+p).idx.0/31, leaf=.1
            net = f"10.{100 + p}.{idx}"
            local_ip = f"{net}.1"
            peer_ip = f"{net}.0"
        else:
            # spine idx towards leaf p -> subnet 10.(100+idx).p.0/31, spine=.0
            net = f"10.{100 + idx}.{p}"
            local_ip = f"{net}.0"
            peer_ip = f"{net}.1"
        neighbor_ips.append(peer_ip)
        lines.append(f"set / interface {eth} admin-state enable")
        lines.append(f"set / interface {eth} subinterface 0 ipv4 admin-state enable")
        lines.append(f"set / interface {eth} subinterface 0 ipv4 address {local_ip}/31")
        lines.append(f"set / network-instance default interface {eth}.0")

    lines.append("set / network-instance default type default")
    lines.append("set / network-instance default admin-state enable")
    lines.append("set / network-instance default interface system0.0")

    # BGP
    lines.append("set / network-instance default protocols bgp admin-state enable")
    lines.append(f"set / network-instance default protocols bgp autonomous-system {asn}")
    lines.append(f"set / network-instance default protocols bgp router-id 10.0.{0 if is_leaf else 1}.{idx}")
    lines.append("set / network-instance default protocols bgp afi-safi ipv4-unicast admin-state enable")
    lines.append("set / network-instance default protocols bgp group fabric export-policy [ export-all ]")
    lines.append("set / network-instance default protocols bgp group fabric import-policy [ import-all ]")
    lines.append("set / network-instance default protocols bgp ebgp-default-policy import-reject-all false")
    lines.append("set / network-instance default protocols bgp ebgp-default-policy export-reject-all false")
    for k, nip in enumerate(neighbor_ips, start=1):
        peer_asn = (65100 + k) if is_leaf else (65000 + k)
        lines.append(f"set / network-instance default protocols bgp neighbor {nip} peer-group fabric")
        lines.append(f"set / network-instance default protocols bgp neighbor {nip} peer-as {peer_asn}")

    # permissive routing policy so loopbacks propagate (lab-grade)
    lines.append("set / routing-policy policy export-all default-action policy-result accept")
    lines.append("set / routing-policy policy import-all default-action policy-result accept")

    return "\n".join(lines) + "\n"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--spines", type=int, default=int(os.environ.get("FABRIC_SPINES", 2)))
    ap.add_argument("--leaves", type=int, default=int(os.environ.get("FABRIC_LEAVES", 4)))
    ap.add_argument("--image", default=os.environ.get("SRL_IMAGE", "ghcr.io/nokia/srlinux:24.10.1"))
    ap.add_argument("--name", default="fabric")
    ap.add_argument("--outdir", default=os.path.dirname(os.path.abspath(__file__)))
    args = ap.parse_args()

    cfgdir = os.path.join(args.outdir, "configs")
    os.makedirs(cfgdir, exist_ok=True)

    nodes = {}
    for j in range(1, args.spines + 1):
        nodes[spine_name(j)] = ("spine", j)
    for i in range(1, args.leaves + 1):
        nodes[leaf_name(i)] = ("leaf", i)

    # write per-node configs
    for name, (role, idx) in nodes.items():
        cfg = srl_config(name, role == "leaf", idx, args.spines, args.leaves)
        with open(os.path.join(cfgdir, f"{name}.cli"), "w") as fh:
            fh.write(cfg)

    # topology yaml
    topo = [f"name: {args.name}", "", "topology:", "  nodes:"]
    for name in nodes:
        topo.append(f"    {name}:")
        topo.append("      kind: nokia_srlinux")
        topo.append(f"      image: {args.image}")
        topo.append(f"      startup-config: configs/{name}.cli")
        topo.append(f"      labels:")
        role = nodes[name][0]
        topo.append(f"        fabric-role: {role}")
    topo.append("  links:")
    # full leaf-spine mesh
    for i in range(1, args.leaves + 1):
        for j in range(1, args.spines + 1):
            # leaf i port j <-> spine j port i
            topo.append(
                f'    - endpoints: ["{leaf_name(i)}:e1-{j}", "{spine_name(j)}:e1-{i}"]'
            )
    with open(os.path.join(args.outdir, "fabric.clab.yaml"), "w") as fh:
        fh.write("\n".join(topo) + "\n")

    # gnmic collector config
    targets = "\n".join(
        f"    clab-{args.name}-{n}:57400:" for n in nodes
    )
    gnmic = textwrap.dedent(
        f"""\
        # gnmic collector: subscribes to interface + BGP telemetry from every NOS
        # node and exposes it as a Prometheus endpoint on :9273/metrics.
        username: {SRL_USER}
        password: {SRL_PASS}
        skip-verify: true
        encoding: json_ietf

        targets:
        {targets}

        subscriptions:
          if-counters:
            paths:
              - /interface[name=*]/statistics/in-octets
              - /interface[name=*]/statistics/out-octets
              - /interface[name=*]/statistics/in-discarded-packets
              - /interface[name=*]/statistics/out-discarded-packets
              - /interface[name=*]/oper-state
            stream-mode: sample
            sample-interval: 5s
          bgp:
            paths:
              - /network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/session-state
            stream-mode: sample
            sample-interval: 10s

        outputs:
          prom:
            type: prometheus
            listen: ":9273"
            path: /metrics
            metric-prefix: fabric
            append-subscription-name: true

        api-server:
          address: ":7890"
        """
    )
    with open(os.path.join(args.outdir, "gnmic.yaml"), "w") as fh:
        fh.write(gnmic)

    print(f"generated fabric: {args.spines} spines x {args.leaves} leaves "
          f"({len(nodes)} nodes), configs in {cfgdir}")


if __name__ == "__main__":
    main()
