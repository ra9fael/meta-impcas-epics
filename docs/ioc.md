# IOC applications

English | [简体中文](zh-CN/ioc.zh-CN.md)

Part of the [meta-impcas-epics documentation](README.md).

An IOC application is a `makeBaseApp`-style tree: an application directory with
a `configure/`, an `*App/src` that produces the IOC executable and its `.dbd`,
an `*App/Db` with the records, and an `iocBoot/<ioc>` with `st.cmd`.

Three pieces cooperate:

* `epics-ioc` (inherits `epics-module`) builds and packages the application.
* `epics-ioc-systemd` (inherits `epics-ioc`) registers instances: it installs
  each instance's env file into the host-wide registry
  (`/etc/epics/instances/<name>.env`) and can enable instances at image
  build time.
* `epics-ioc-scripts` is the runtime every IOC shares: one generic systemd
  template (`epics-ioc@.service`), the `ioc-start.sh` dispatcher and the
  port-slot helpers. An instance is identified by its host-global name only.

`epics-asyn-scope-ioc` in `recipes-examples/epics-asyn-scope-ioc/` is a complete
example: it builds asyn's own simulated oscilloscope test IOC
(`testAsynPortDriver`) straight from the asyn sources. Read its recipe alongside
this document.

## Install layout

```text
/usr/lib/systemd/system/epics-ioc@.service     # one generic template for every IOC
/usr/libexec/epics-ioc/{ioc-start.sh,ioc-ports.sh,epics-ioc-env}
/usr/bin/{ioc-ports,ioc-manager,ioc-instance-add}
/etc/epics/instances/{scope01.env,scope02.env} # the instance registry (fleet layer)
/opt/epics/iocs/asyn-scope-ioc -> asyn-scope-ioc-1.0
/opt/epics/iocs/asyn-scope-ioc-1.0/
├── bin/linux-aarch64/testAsynPortDriver
├── lib/linux-aarch64/libtestAsynPortDriverSupport.so
├── db/testAsynPortDriver.db
├── dbd/testAsynPortDriver.dbd
└── iocBoot/ioctestAsynPortDriver/{st.cmd,envPaths}
```

Applications install under `${EPICS_PREFIX}/iocs` (`EPICS_INSTALL_BASE`), the
same way support modules install under `${EPICS_PREFIX}/modules`.

## Writing an IOC recipe

```bitbake
inherit epics-ioc-systemd

EPICS_MODULE_NAME = "my-ioc"
DEPENDS += "epics-asyn epics-autosave"
RDEPENDS:${PN} += "epics-asyn epics-autosave"

EPICS_RELEASE_EXTRA = "\
    ASYN = ${RECIPE_SYSROOT}${EPICS_PREFIX}/modules/asyn\n\
    AUTOSAVE = ${RECIPE_SYSROOT}${EPICS_PREFIX}/modules/autosave"
EPICS_IOC_LIBDIRS = "${EPICS_PREFIX}/modules/asyn/lib/${EPICS_TARGET_ARCH} \
                     ${EPICS_PREFIX}/modules/autosave/lib/${EPICS_TARGET_ARCH}"

IOC_APP_NAME = "myIoc"
IOC_PATH     = "iocBoot/iocmy"

# one instance named "myscope" (see below for the env file's keys)
EPICS_IOC_INSTANCE_ENVS = "${WORKDIR}/myscope.env"
EPICS_IOC_INSTANCES     = "myscope"
EPICS_IOC_AUTO_ENABLE   = "enable"
```

Variables the classes read:

| Variable                    | Default                              | Meaning |
|-----------------------------|--------------------------------------|---------|
| `EPICS_MODULE_NAME`         | `${BPN}`                             | Directory name under `iocs/`. |
| `EPICS_INSTALL_BASE`        | `${EPICS_PREFIX}/iocs`               | Install root. |
| `EPICS_RELEASE_EXTRA`       | `""`                                 | `configure/RELEASE` entries; separate several with `\n`. |
| `EPICS_IOC_LIBDIRS`         | `""`                                 | Runtime library directories of the linked modules; turned into rpath entries. |
| `IOC_APP_NAME`              | `""`                                 | Executable under `bin/<target-arch>/`; empty to run `st.cmd` through its shebang. Build-time value; the registry entry repeats it. |
| `IOC_PATH`                  | `""`                                 | Directory with `st.cmd`, e.g. `iocBoot/iocmy`. Build-time value. |
| `IOC_ST_CMD`                | `"st.cmd"`                           | Name of the startup script. Build-time value. |
| `EPICS_IOC_INSTANCE_ENVS`   | `""`                                 | Registry entries to install, as source paths (basename = instance name). |
| `EPICS_IOC_INSTANCES`       | `""`                                 | Instances `EPICS_IOC_AUTO_ENABLE` enables at image build time. |
| `EPICS_IOC_AUTO_ENABLE`     | `"disable"`                          | `enable` ships the systemd enable symlink for `EPICS_IOC_INSTANCES`. |

`RDEPENDS` must list every module whose library the IOC links; shlibs scanning
does not see anything under `${EPICS_PREFIX}`, so it cannot work them out.

Use `/opt/epics` paths in `configure/RELEASE`, not the build sysroot — the
sysroot only applies at build time.

## Instances

An instance is a host-global name (`scope01`, `blm`, ...) with a registry
entry -- a plain `KEY=value` env file. Two layers exist, later wins:

* `/etc/epics/instances/<name>.env` -- the fleet layer, shipped in the image
  by the IOC package;
* `/boot/iocs/<name>/<name>.env` -- the machine layer on the writable BOOT
  partition, for per-machine overrides. For every instance the image
  auto-starts, `epics-ioc-systemd` deploys that file's starting point: the
  fleet entry projected down to the keys a machine may decide --
  `EPICS_IOC_MACHINE_KEYS`, by default `P`, `R`, `IOC_STATE`, `IOC_STATE_DIRS`
  and `IOC_HOST` -- and `inflate-sd.sh` stages the folder onto the card, so on
  a deployed machine it exists whether anyone edited it or not.

Deployment staff edit that layer from Windows, so every file the boot chain
reads off `/boot` tolerates CRLF line endings: `ioc-start.sh`, `bootcfg` and
`fpgacfg` all detect the CR, warn, and parse the stripped copy.

The registry entry points at the application and carries the identity:

```sh
IOC_APP_DIR=/opt/epics/iocs/asyn-scope-ioc   # where the application lives
IOC_PATH=iocBoot/ioctestAsynPortDriver       # below IOC_APP_DIR
IOC_APP_NAME=testAsynPortDriver              # empty: run st.cmd via shebang
IOC_INSTANCE_INDEX=1                         # console 21010; global across every IOC
P=ioc1:                                      # record prefix (separators included)
R=scope1:                                    # optional device root: records are $(P)$(R)...
IOC_STATE=/var/lib/asyn-scope-ioc/scope01    # writable state dir the dispatcher creates
IOC_STATE_DIRS="autosave"                    # subdirectories of IOC_STATE to create

#CA_PORT=21013                              # optional: pin the CA server port (else dynamic)
#PVA_PORT=21014                             # optional: pin the PVA server port (else dynamic)
#PS_PORT=...                                # optional: override the console port
#APP_PORT_1=...                             # optional: for IOCs that open their own sockets
#APP_PORT_2=...
#IOC_HOST=blm01                             # optional: refuse to start on any other machine
```

An instance pinned with `IOC_HOST` refuses to start anywhere else -- the
guard against copying a fleet machine's registry entry to the wrong SD card.

### Instance name vs PV prefix

The instance name and the PV prefix are two unrelated identities:

| Identity | Example | Defined by | Scope |
|---|---|---|---|
| Instance name | `blm` | the registry file name | ops only; uniform across the fleet |
| `IOC_HOST` | `blm01` | optional key in the registry entry | anti-copy-paste guard |
| `P` (PV prefix) | `XRAY:BLM00` | per machine, on the BOOT partition | what clients see |

The instance name is constrained to lowercase `[a-z0-9-]` (systemd's `%i` and
the dispatcher's validation reject colons and upper case), and since every
machine runs the same image it must be the same everywhere: `blm` on all
twenty machines. What differs per machine is the PV prefix; the image carries
at most a bench default for it, never a machine's own:

* a generic IOC takes `P` (and `R`) from the registry keys -- which the
  optional `/boot/iocs/<name>/<name>.env` machine layer overrides. Inside the
  IOC an envPaths `epicsEnvSet` outranks the environment: it runs later, from
  st.cmd.
* the BLM IOC is built around exactly that precedence. Its recipe deletes the
  `epicsEnvSet("P", ...)` line from the installed `envPaths`, retargets the two
  writable paths the application hard-codes to `$(IOC_STATE)/autosave` and
  `$(IOC_STATE)/calibrations`, and drops the line that sourced a
  `/boot/iocs/.../envPaths`, so the prefix and the state directory are both
  ordinary registry keys and one file per machine is enough:

  ```sh
  # /boot/iocs/blm/blm.env -- what is left on the card once deployed
  P=XRAY:BLM00
  ```

  Named after the instance, not after the iocBoot directory: the folder an
  operator touches is `iocs/blm/`. The autosave library only ever stores the
  path it is given and the BLM driver only opens a file beside its target, so
  neither can make a directory -- which is what `IOC_STATE` plus
  `IOC_STATE_DIRS` are for: the dispatcher creates the tree before exec'ing
  procServ, on whatever medium the entry names. `IOC_STATE=/boot/iocs/blm`
  keeps this board's tuned thresholds and its calibration through a rootfs
  re-imaging and lets them travel with the machine; an entry that leaves the
  key out gets `/var/lib/epics-ioc/blm` instead, and nothing else changes.

  `IOC_STATE` and `IOC_STATE_DIRS` are on the card because which medium this
  board's data lives on is not something the fleet can decide for it: a board
  with no separate BOOT partition has to say so. That comes with a hazard worth
  stating plainly. The two are a pair -- the recipe rewrites the application's
  paths to `$(IOC_STATE)/<dir>` -- so changing one without the other splits one
  board's data over two places. And retargeting `IOC_STATE` on a machine that
  already has saves makes the IOC open a different, most likely empty set of
  them: restore nothing at pass 0, write the record defaults back as this
  machine's own settings, and no symptom anyone would notice before an interlock
  fires. `ioc-manager doctor` checks that the directory it names is writable,
  which catches a mistyped path; it cannot tell an empty directory from this
  board's own.

Colon style follows the database: the record names in the `.db` templates
already carry the separator (`$(P):CH0:...`), so `P` values are written
without a trailing colon.

Instance names are lowercase `[a-z0-9-]` and unique across the host.
`IOC_INSTANCE_INDEX` is the only number that has to be unique, and it is
unique across every IOC on the target. `ioc-instance-add <name>` creates an
entry with the smallest free slot, and `ioc-ports --show [instance]`
prints the ports (and, for a running instance, the actual endpoints):

```sh
ioc-instance-add myscope
ioc-ports --show scope01
ioc-ports --next
ioc-ports --audit
```

`ioc-manager` is the day-to-day front end over the registry and systemd:

```sh
ioc-manager list                  # instances from both layers + state
ioc-manager report                # name / slot / port / prefix / app
ioc-manager status                # one line per instance
ioc-manager start blm             # start one instance
ioc-manager stop blm              # stop one instance
ioc-manager restart blm           # restart one instance
ioc-manager enable blm            # enable auto-start at boot
ioc-manager disable blm           # disable auto-start at boot
ioc-manager startall | stopall | restartall
ioc-manager status scope01        # full systemctl status for one instance
ioc-manager console scope01       # attach to its procServ console
ioc-manager logs blm -f           # journal of one instance (no name: all);
                                  # -n N lines, -- passes args to journalctl
ioc-manager show blm              # merged registry entry, layer per key
ioc-manager doctor                # cross-check registry, systemd, runtime
ioc-manager wait blm 120          # block until active and console bound
```

`doctor` reports, not manages: missing application directories, `IOC_HOST`
pins that no longer match this machine, an entry with no `P` (its record names
lose the prefix, or gain a literal `${P}`), a running instance whose
`IOC_STATE` is absent or read-only (autosave drops every save in silence),
slot collisions, enabled-but-not running and running-but-unregistered
instances, and stale `$RUN_DIR` console infofiles. `wait` is for boot and
acceptance scripts: it returns 0 only once the unit is active *and* procServ
has written the instance infofile (the console bound means the IOC process is
alive), and exits 1 on a failed unit or timeout.

## The start dispatcher

systemd cannot do the port arithmetic or the registry lookup, so `ExecStart`
is a script, not procServ directly. `ioc-start.sh <instance>`:

1. sources the site values (`epics-ioc-env`: registry roots, `PORT_BASE`,
   `RUN_DIR`, `PROCSERV_ARGS`),
2. loads `/etc/epics/instances/<instance>.env`, then the optional
   `/boot/iocs/<instance>/<instance>.env` machine overrides,
3. checks that `$IOC_APP_DIR/$IOC_PATH` exists,
4. derives the console and application ports (`ioc-ports.sh`),
5. exports `EPICS_CA_SERVER_PORT` / `EPICS_PVAS_SERVER_PORT` when the entry
   pinned `CA_PORT` / `PVA_PORT` (the servers read them at startup),
6. exports the conventional `P` / `R` macros when the entry sets them, defaults
   `IOC_STATE` and creates it along with every subdirectory `IOC_STATE_DIRS`
   names (neither autosave nor an application's own directory creation can
   make a path that does not exist yet, so an instance whose data lives in
   subfolders has to declare them),
7. `cd`s into `$IOC_APP_DIR/$IOC_PATH`, sources the optional `ioc-start.pre`
   hook and runs `$IOC_START_PRE`,
8. `exec procServ -f -L - --name=<instance> -I <info file> -P "$PS_PORT" ...`.

`P`, `R` and `IOC_STATE` are exported, and iocsh reads `.cmd` macros from
the process environment, so `st.cmd` can use `$(P)`, `$(R)`, `$(IOC_STATE)` or
any other instance setting directly. The `-I` info file under
`/run/epics/` records the running server's PID and endpoints;
`ioc-ports --show <instance>` reads it.

The hook file `<IOC_APP_DIR>/<IOC_PATH>/ioc-start.pre` is sourced, so it can
define the function named by `IOC_START_PRE` -- for example starting an
external device simulator on `$APP_PORT_1`. It runs as a sibling process in
the service's cgroup, so systemd stops it together with the IOC.

## Target operations

```bash
systemctl is-enabled 'epics-ioc@scope01'      # disabled: installed, not enabled
systemctl enable --now 'epics-ioc@scope01'
systemctl enable --now 'epics-ioc@scope02'
netstat -ltnp | grep -E ':210[0-2][0-9]'      # consoles 21000 (blm) / 21010 / 21020
cat /run/epics/scope02.info                   # PID and endpoints of the running IOC

ioc-manager console scope01                   # console on this board (any port)
telnet <board-ip> 21010                       # same console from another host
telnet <board-ip> 21020                       # scope02's console from there
```

`ioc-manager console <name>` resolves the endpoint from the instance infofile
(so a pinned `PS_PORT` and a wildcard bind are both handled) and execs whatever
client the image has: telnet, socat or nc. procServ gives console **control**
to the first attached client and serves further ones read-only.

The console is an iocsh prompt for the running IOC (`help`, `dbpr`, ...).
procServ runs one-shot: when the IOC exits -- crash or `^X` from the console
-- procServ exits with the child's status and the unit stays **failed**, with
the full journal as the crash scene. There is deliberately no automatic
restart: a dead IOC is a fault to investigate. An instance that should come
back on its own opts in with an instance drop-in
(`/etc/systemd/system/epics-ioc@<name>.service.d/restart.conf`,
`[Service]` + `Restart=always` + `RestartSec=5s`).

Records are reached over CA with no client-side configuration, because every
instance on the host receives the broadcast search and replies with its own
port:

```bash
caget ioc0:scope1:UpdateTime                # a writable ao record
caget ioc0:scope1:Waveform_RBV              # the simulated waveform
caget ioc1:scope1:Waveform_RBV              # the other instance, still no config
```

The waveform records of this IOC are read-only (`Waveform_RBV`,
`TimeBase_RBV`); the writable records are `Run`, `VoltOffset`, `TriggerDelay`,
`NoiseAmplitude`, `UpdateTime` and the three `*Select` enumerations. A Phoebus
display for the oscilloscope is installed on the target at
`/opt/epics/iocs/asyn-scope-ioc-1.0/opi/asyn-scope-ioc0.bob` -- copy it to the
client and open it in Phoebus. Its default macros are `P=ioc0:`, `R=scope1:`,
so it points at the ioc0 instance out of the box; another instance only needs
`-m "P=ioc1:"` in the client.

The simulated oscilloscope does not open sockets of its own, so its instances
use no application ports. An IOC that does -- one that acts as a Modbus or
stream-device server, say -- pins them in its env file and documents them in
the port table of [port-allocation.md](port-allocation.md).

## Testing the startup chain on the target

The whole chain -- bootmount, bootcfg, fpgacfg, the instance registry, the
dispatcher -- is only exercised together on the target. After rebuilding the
image and redeploying (`petalinux-build`, `inflate-sd.sh`), this machine's site
files on the BOOT partition are:

```text
machine/machine.cfg            # HOSTNAME / IP / mask / gateway / DNS / NTP
iocs/blm/blm.env               # the keys a machine may decide; P is this machine's
iocs/blm/autosave/             # this machine's autosave data, written by the IOC
iocs/blm/calibrations/         # optional: ADC calibration files for this board
fpga/<name>.bit.bin            # optional bitstream pool
fpga/active.conf               # optional: BITSTREAM=<pool file name>
```

`inflate-sd.sh` stages all of it: the two site files from the templates bootcfg
and fpgacfg deploy, and `iocs/blm/` from the tree `epics-ioc-systemd` deploys
for every instance the image auto-starts -- the projected env file plus the
instance's data folders, empty, so the card is ready before anyone touches it.
Staging never replaces anything the card already holds: the build's copy is a
template, the card's copy is this machine's configuration and its data, so
re-imaging a board keeps its prefix, its calibrations and its saved thresholds.

The projected file holds the machine keys and nothing else -- one line each, in
the order `EPICS_IOC_MACHINE_KEYS` lists them, each with the value this image
ships:

```text
P=XRAY:BLM00
R=
IOC_STATE=/boot/iocs/blm
IOC_STATE_DIRS="autosave calibrations"
IOC_HOST=
```

Every line starts at the value this image ships, so a file nobody edited behaves
exactly as if it were absent. Deployment is one edit and, usually, some
deletions: set `P` to this machine's prefix, and drop the lines this machine does
not decide -- `R=` and `IOC_HOST=` on almost every board. Leaving them is not
wrong either; it just says less. Deleting is always the safe direction: an absent
key follows the image.

What the whitelist keeps *off* the card is half its purpose. Where the
application lives (`IOC_APP_DIR`, `IOC_PATH`, `IOC_APP_NAME`) and which console
slot it holds (`IOC_INSTANCE_INDEX`) are the image's business: a mistyped path is
a unit that does not start at all, a mistyped slot is a console on a port nobody
expects, and neither is something a deployer should be able to type in the first
place. What is left is the answer to "what does this machine do differently" --
`ioc-manager show blm` labels a key `machine` only when the card gives it a
non-empty value. A card trimmed too far gets its full projection back by deleting
`iocs/blm/` and running `inflate-sd.sh` again.

That is also why the template is a directory rather than a name to type:
creating `blm.env` from Windows means typing an exact filename into a dialog
whose `.txt` extension is hidden by default, and `blm.env.txt` is silently not a
registry entry -- the IOC starts and publishes the fleet prefix, and nothing
looks wrong until the records are named.

Then boot and walk the chain:

```bash
# 1. the four services, in order
systemctl status bootmount bootcfg fpgacfg epics-ioc@blm --no-pager
findmnt /boot                              # mounted by label, not device
hostname; ip -4 addr show eth0             # machine.cfg applied

# 2. registry and state
ioc-manager list                           # blm enabled/active; scope01/02 installed
ioc-manager report                         # slot / port / prefix / application

# 3. data plane: console banner carries the instance name, records carry P
telnet 127.0.0.1 21000                     # iocsh; dbl shows XRAY:BLM00:CH0:...
caget XRAY:BLM00:CH0:ADC_WARN_TH           # from the board or any client
```

Failure semantics (deliberate, see above): kill the IOC with `^X` in the
console and the unit stays **failed** -- `ioc-manager status` shows it, the
journal holds the crash scene, nothing restarts behind your back. Bring it
back with `systemctl start epics-ioc@blm` after investigating.

Two negative tests are worth running once per image:

* **Machine overrides and the host guard.** Fill in the `IOC_HOST=` line the
  projection leaves empty as `other-machine` and restart the unit: it must
  refuse to start with the pinned-host message. Fix the name, restart, done.
* **The PL must be verifiably configured.** Two cases, same requirement from
  different directions:
  - *A failed bitstream load must stop the IOC.* Put two `.bit.bin` files in
    `/boot/fpga` without `active.conf` and reboot: `fpgacfg` fails listing the
    candidates, and `epics-ioc@blm` stays down because it *requires* fpgacfg
    -- publishing interlock data from an unconfigured PL would be worse.
  - *An empty pool must stop the IOC too.* Remove every `*.bin` from
    `/boot/fpga` and reboot: `fpgacfg` succeeds as a no-op ("nothing to
    load") -- an exit code cannot distinguish that from a real load -- but
    it leaves no `/run/fpgacfg.loaded` credential, and `epics-ioc@blm` is
    skipped by its `ConditionPathExists`. Starting the IOC there would let
    the driver read a PL address no bitstream drives, which wedges the NoC
    and hangs the machine. On a board whose PL is configured from BOOT.BIN,
    declare it with the marker `/boot/fpga/preconfigured` and fpgacfg
    writes the credential on the FSBL's behalf.

An instance that should self-heal opts in explicitly:

```bash
mkdir -p /etc/systemd/system/epics-ioc@blm.service.d
printf '[Service]\nRestart=always\nRestartSec=5s\n' \
    > /etc/systemd/system/epics-ioc@blm.service.d/restart.conf
systemctl daemon-reload && systemctl restart epics-ioc@blm
```

One pitfall is worth knowing before it bites. Two instances must never share a
slot: slot 0 belongs to the fleet BLM IOC and the example instances use 1 and
2, and `ioc-ports --audit` reports collisions across both registry layers. A
slot conflict surfaces as `procServ: Exiting with error code: 98` next to a
misleading `Bad file descriptor` in the journal -- 98 is `EADDRINUSE`, and the
`perror` text comes from procServ clobbering `errno` while unwinding.

The other is a build one: `petalinux-build` needs the network for AUTOREV, so
on a flaky proxy switch the BLM recipe to its local `file://` SRC_URI block.

## Why the classes do what they do

Useful when an IOC build misbehaves:

* **`envPaths` is host-only.** `iocBoot/<ioc>/Makefile` pins
  `ARCH = $(EPICS_HOST_ARCH)` and runs `convertRelease.pl` only through its host
  `buildInstall` target, so the class runs that action explicitly after the
  target compile.
* **No host-architecture build.** EPICS makes a cross target depend on the host
  one (`configure/RULES_ARCHS`), which would link a host IOC against host module
  libraries that are deliberately not packaged. `EPICS_MAKE_EXTRA` clears
  `CROSS_ARCHS` so only the target is built.
* **`IOCS_APPL_TOP`.** EPICS records the application top in `envPaths` and in the
  generated `*_registerRecordDeviceDriver.cpp`, which compares it against the
  runtime `TOP` at `iocInit`. Left alone it is the build directory, which embeds
  a build path in the binary and warns on every start, so the class points it at
  the install location.
* **rpath instead of `LD_LIBRARY_PATH`.** The target gets explicit rpath entries
  for Base and for `EPICS_IOC_LIBDIRS`, so an IOC starts without any environment
  setup. `envPaths`, meanwhile, records the sysroot path from
  `configure/RELEASE`; the class strips it and rewrites the versioned install
  directory to the version-independent symlink.
