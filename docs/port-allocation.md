# IOC port management

English | [简体中文](zh-CN/port-allocation.zh-CN.md)

Part of the [meta-impcas-epics documentation](README.md).

Several IOC instances on one target each need a console port and, depending on
the application, their own service ports. EPICS itself already manages most of
this: the first IOC on a host gets the default CA/PVA ports, and every further
IOC automatically falls back to a dynamic port that its beacons advertise. The
one port EPICS knows nothing about is the procServ console, so that is the only
one this layer allocates statically.

| Layer | Port | Managed by |
|-------|------|------------|
| procServ console | `21000 + 10 * slot` (21000, 21010, ...) | **static slot allocation** |
| IOC application listeners (`APP_PORT_1/2`) | `+1`/`+2` of the slot, overridable | optional, for IOCs that open sockets |
| CA server | none: dynamic (first IOC gets 5064) | EPICS; optionally pinned |
| PVA server | none: dynamic (first IOC gets 5075) | EPICS; optionally pinned |
| CA beacon/repeater, PVA broadcast | 5065 / 5076 | shared by all IOCs on the host |

See [ioc.md](ioc.md) for how a recipe and its instances are set up.

## The slot index

`IOC_INSTANCE_INDEX` (0-99) is the single number an operator assigns. It is
**global to the target**: two different IOC types and two instances of one type
draw from the same pool, because what must not collide is the console port.

The instance env file sets it:

```sh
IOC_INSTANCE_INDEX=1        # console 21010, app ports 21011/21012
P=ioc1:
R=scope1:
IOC_STATE=/var/lib/<PN>/ioc1
```

The mapper is the `ioc-ports` command (a thin wrapper over
`/usr/libexec/epics-ioc/ioc-ports.sh`):

```sh
ioc-ports --show [instance]  # derived ports, plus the running endpoints
ioc-ports --next             # first free slot, across every IOC on the target
ioc-ports --audit            # report slot collisions across the registry layers
```

A new instance is created from the shipped example:

```sh
cp /etc/epics/instances/<example>.env /etc/epics/instances/<name>.env
# edit IOC_APP_DIR / IOC_INSTANCE_INDEX / P, then
systemctl enable --now 'epics-ioc@<name>'
```

A machine-specific override for one instance lives in
`/boot/iocs/<name>/<name>.env` on the BOOT partition and wins over the shipped
entry.

## procServ console (the statically managed port)

The console has no discovery mechanism -- procServ registers nowhere -- so each
instance gets the deterministic port `EPICS_IOC_PORT_BASE + 10 * index`, and a
collision makes the second IOC fail visibly instead of silently.

Two aids come with it:

* procServ runs with `-I /run/epics/<instance>.info`, so the running
  server's PID and actual endpoints are on disk; `ioc-ports --show <instance>`
  prints them.
* The console is plain telnet and, with the default
  `PROCSERV_ARGS="--oneshot --allow"`, reachable from any host. `--allow` has
  no short form (`-A` does not exist -- only the long option does), and the
  compile-time default alone does not widen the bind. Drop `--allow` to bind
  localhost only, or restrict it with a firewall over the 21000 range;
  procServ can also serve the console on a UNIX domain socket
  (`unix:/path` endpoint) if no TCP port should be used at all.

## CA and PVA (dynamic, optionally pinned)

No allocation is needed. The CA server's UDP search socket is opened with
address fanout (`SO_REUSEPORT`), so a broadcast search reaches **every** IOC on
the host; the instance that owns the PV replies and the reply carries its own
TCP port. When an IOC cannot have the default port -- because another one has it
-- the server automatically retries with a dynamic port and announces it in its
beacons. PVA behaves the same way: its UDP search port (5076) is shared, its TCP
port is advertised in search replies and beacons.

So the first IOC on a target runs on 5064/5075 and every further one on a
dynamic port, with no configuration anywhere.

Pin a port only when determinism is required -- firewalls, cross-subnet clients,
or documented deployments:

```sh
# in the instance env file; recommended values keep the slot layout:
CA_PORT=21013        # base + 10*index + 3
PVA_PORT=21014       # base + 10*index + 4
```

The start script exports `EPICS_CA_SERVER_PORT` / `EPICS_PVAS_SERVER_PORT` from
these before the IOC starts.

## Client configuration

| Situation | CA (caget/caput/camonitor) | PVA (pvget/QSRV) |
|---|---|---|
| Client and board in one broadcast domain | nothing, for every slot | nothing, for every slot |
| Cross-subnet / firewall | pin the IOC's port (above), then `EPICS_CA_ADDR_LIST="<ip>:<ca-port>"`, space separated for several; `EPICS_CA_AUTO_ADDR_LIST=NO` for a fully explicit list | pin the IOC's port, then `EPICS_PVA_ADDR_LIST="<ip>:5076"` (the broadcast port is shared) |

Notes:

* Do **not** set `EPICS_CA_SERVER_PORT` on a client to reach a specific IOC: it
  is the client's own single search port, not a per-IOC selector.
* The console port and the application ports are not CA ports and never appear
  in `EPICS_CA_ADDR_LIST`.
* Broadcasts do not cross subnets, which is exactly why the pinned-port option
  exists.
