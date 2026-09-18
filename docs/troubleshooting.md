# Troubleshooting

English | [简体中文](zh-CN/troubleshooting.zh-CN.md)

Part of the [documentation index](README.md).

Symptom first, then cause and fix. Build-side items name the file and line in
the upstream sources where the behaviour comes from.

## QA findings

### `File ... contains reference to TMPDIR [buildpaths]`

* **What it is.** The check scans every packaged file for the build directory
  string (`poky/meta/classes-global/insane.bbclass`, `QAPATHTEST[buildpaths]`).
  It is a warning by default; it only fails a build if a project promotes
  `buildpaths` to `ERROR_QA`.
* **Impact.** Reproducibility and build-layout disclosure. Nothing stops
  working.
* **What this layer already does.** `envPaths` and `*.local` files are scrubbed,
  `IOCS_APPL_TOP` points Base's own IOCs and every IOC application at the
  installed location, and the debug-source package of Base waives the check for
  its generated provenance comments.
* **When a new file trips it.** Find the string first:
  `strings -a <file> | grep <tmpdir>`. Then either fix it at the source -- a
  knob such as `IOCS_APPL_TOP` or `FINAL_LOCATION` is almost always the right
  answer -- or waive it for that package with
  `INSANE_SKIP:<package> += "buildpaths"` and record why in a comment.

### `dev-so`

The classes ship versioned `.so` symlinks in the runtime package on purpose, so
the target tree stays usable for development. Expected.

## Configure and build failures

### `EPICS_BASE must be set in a configure/RELEASE file`

`configure/CONFIG` refuses to build unless `EPICS_BASE` is assigned in a RELEASE
file. The class appends it in `epics_generate_release`; a recipe that overrides
`do_configure` without calling it, or that sets `EPICS_WRITE_RELEASE = "0"`
outside Base, loses the assignment.

### Release consistency errors during the host pass

`CHECK_RELEASE` compares the dependency paths recorded in each module's
`configure/RELEASE` with the ones the consumer resolves. Staged modules record
their own build sysroot, which never matches the consumer's, so the check
reports false mismatches. Both generated `CONFIG_SITE` files set
`CHECK_RELEASE = NO`; if a recipe re-enables it, that is the cause.

### Link errors for `lib/linux-x86_64/lib<module>.a`

EPICS makes every cross-architecture target depend on the host-architecture one
(`configure/RULES_ARCHS` generates `install.<cross> : install.<host>`), so a
build tries to link a host copy against host module libraries that are
deliberately not packaged. IOC applications clear `CROSS_ARCHS` through
`EPICS_MAKE_EXTRA`; a support module that links other modules needs the same
treatment (see [modules.md](modules.md)).

### `Can't open perl script .../base/bin/<host-arch>/<tool>.pl`

Module and IOC builds run Base's host tools. They are staged into the sysroot
after packaging (`epics_stage_host_tools` in the `epics-base` recipe); if they
are missing, the sysroot was populated from a Base build that predates that
staging -- clean and rebuild `epics-base`.

### `envPaths` mentions the build directory or the sysroot

The IOC class rewrites `IOCS_APPL_TOP` and strips the sysroot prefix
(`do_install:append` in `classes/epics-ioc.bbclass`). A file that still carries
them was added to the package without going through that scrub.

### `unparsed line` while parsing a `.bbclass`

BitBake ends a shell function body on a line that is exactly `}`. Inside a
heredoc that writes a shell script, indent the closing brace of every nested
function; a column-zero brace truncates the surrounding task and the rest of the
class is parsed as BitBake syntax. A `${lowercase}` shell variable in a task
body can also collide with a same-named BitBake variable (`libdir` is
`/usr/lib`).

### `undefined reference to pvar_dset_...` or missing device support

Feature macros such as asyn's `-DHAVE_DEVINT64` are added by module Makefiles
with `+=`. Passing flags on the make command line turns that `+=` into a no-op,
so the macros are lost while the `.dbd` still declares the devices. Flags must
reach the build through the generated `CONFIG_SITE`, never as command-line
variables.

## Packaging and runtime

### `libasyn.so: cannot open shared object file` when the IOC starts

Nothing resolves the module libraries. An IOC needs both the runtime dependency
and the search path: `RDEPENDS:${PN}` for the modules it links, and
`EPICS_IOC_LIBDIRS` for the rpath entries. Confirm with
`readelf -d <ioc> | grep -i path` -- Base, the IOC itself and every linked
module must be listed.

### The instance is installed but not enabled

The preset only enables the instances a recipe lists in `EPICS_IOC_INSTANCES`
with `EPICS_IOC_AUTO_ENABLE = "enable"`; everything else is installed but
off -- the same policy as the caRepeater unit: installing must not start an
IOC. Start it with `systemctl enable --now 'epics-ioc@<instance>'`. If
systemd cannot find the instance, check that
`/etc/epics/instances/<instance>.env` is in the image and that
`IOC_APP_DIR`/`IOC_PATH` inside it point at the installed application.

### autosave: `write_it: No such file or directory`

The save-file directory does not exist. `ioc-start.sh` creates `$IOC_STATE`
before starting the IOC; running the IOC by hand requires creating it first.

### asyn reads time out with `TIMEOUT INVALID`

`drvAsynIPPort` has no interrupt source, so `I/O Intr` scanning never fires and
a polling read without a terminator never completes. Terminate the exchange
explicitly: `asynOctetSetInputEos`/`asynOctetSetOutputEos`, and drive the
transfer from a record (`asynOctetWriteRead` takes the command from another
record, `asynOctetCmdResponse` bakes it into the link). A server port is
configured with `drvAsynIPServerPortConfigure`, whose argument must be
`<host>:<port>`.

### Two instances fight over the console port

The slot index is global to the target, so a duplicate `IOC_INSTANCE_INDEX`
between two *different* IOCs collides just like one within a single IOC.
`ioc-ports --audit` scans the registry layers and reports the offending
files; `--next` picks the first free slot. An explicit `PS_PORT` in an instance
env file overrides the derived one, which is the usual source of an accidental
collision.

How it shows up on the target: `procServ: Exiting with error code: 98` with a
misleading `Bad file descriptor` printed next to it. 98 is `EADDRINUSE`, and
the `perror` text is `errno` clobbered while the exception unwinds -- read the
number, not the words. `ioc-start.sh` names the owning instance and PID before
starting whenever another infofile already serves that console port.

The holder is not necessarily a current instance: a board whose rootfs was
updated in place instead of reflashed from scratch keeps units from an older
image together with their `.wants` symlinks, and those start at boot and take
the ports (observed with `epics-asyn-scope-ioc@ioc0.service` holding 21000).
`systemctl list-units --all | grep -i ioc` shows them; disable and delete the
leftovers, or reflash the rootfs partition from scratch.

### A client cannot reach one specific IOC

Same-subnet clients need no configuration: every IOC receives the broadcast
search and answers with its own port. If one instance is unreachable, check
whether it pinned its ports (then the client needs
`EPICS_CA_ADDR_LIST="<ip>:<ca-port>"`) or whether the client is on another
subnet, where broadcasts do not go. Do not use `EPICS_CA_SERVER_PORT` on the
client for this: it is the client's own single search port, not a per-IOC
selector.

## On the target

```bash
systemctl status 'epics-ioc@scope01' --no-pager
journalctl -u 'epics-ioc@scope01' -n 200
netstat -ltnp | grep -E ':210[0-2][0-9]'
cat /run/epics/scope01.info
telnet <board-ip> 21010          # procServ console -> iocsh prompt
```

The console is the fastest way in: `errlog` output is right there, and
`asynSetTraceMask("L0", 0, 0x321)` raises asyn logging for a port without
restarting the IOC. Masks: `0x121` errors/warnings/info, `0x321` adds debug,
`0x721` adds trace.
