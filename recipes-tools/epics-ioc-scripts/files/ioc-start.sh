#!/bin/sh
# SPDX-FileCopyrightText: 2026 IMPCAS
#
# SPDX-License-Identifier: MIT

# Start an EPICS IOC instance under procServ on behalf of the generic
# epics-ioc@.service template. The instance name selects an entry in the
# instance registry:
#
#   /etc/epics/instances/<name>.env      fleet layer, shipped in the image
#   /boot/iocs/<name>/<name>.env         machine layer, optional, overrides
#
# The registry entry points at the IOC application directory and carries the
# instance identity (console slot, PV prefix, state directory, optional
# CA/PVA/console-port pins). Instance names are host-global and lowercase
# [a-z0-9-]; the console port is PORT_BASE + 10 * IOC_INSTANCE_INDEX.

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -r "$HERE/epics-ioc-env" ] || { echo "$0: missing $HERE/epics-ioc-env" >&2; exit 1; }
. "$HERE/epics-ioc-env"

INSTANCE="$1"
if [ -z "$INSTANCE" ] || case "$INSTANCE" in *[!a-z0-9-]*) true ;; *) false ;; esac; then
    echo "usage: $0 <instance-name>   (lowercase [a-z0-9-], host-global)" >&2
    exit 2
fi

# The machine layer of the registry lives on the FAT BOOT partition, which is
# the part of the card someone without shell access can edit -- from Windows,
# where Notepad ends every line with CR. A plain `.` there folds the CR into
# every value: an invisible suffix on P (so no client can match the record
# names) and a port number that will not parse. Source a CR-free copy instead
# and say so, so the journal names the file that needs fixing.
load_env() {
    if grep -q "$(printf '\r')" "$1"; then
        echo "$0: warning: $1 has CRLF line endings (edited on Windows?), stripping CR" >&2
        _src=/tmp/ioc-env.$$.conf
        tr -d '\r' < "$1" > "$_src"
        trap 'rm -f "$_src"' 0
        . "$_src"
    else
        . "$1"
    fi
}

[ -r "$ENV_ROOT/$INSTANCE.env" ] || {
    echo "$0: no registry entry $ENV_ROOT/$INSTANCE.env" >&2
    echo "$0: create one with ioc-instance-add $INSTANCE" >&2
    exit 1
}
load_env "$ENV_ROOT/$INSTANCE.env"

# Machine-level overrides (site config on the writable BOOT partition), last
# one wins: P, R, IOC_STATE, IOC_STATE_DIRS, CA_PORT/PVA_PORT, PS_PORT,
# APP_PORT_1/2. Note that inside the IOC an envPaths epicsEnvSet outranks these
# environment values (it runs later, from st.cmd) -- which is why the IOC
# recipes delete or retarget the lines they want the registry to own.
if [ -r "$MACHINE_ENV_ROOT/$INSTANCE/$INSTANCE.env" ]; then
    load_env "$MACHINE_ENV_ROOT/$INSTANCE/$INSTANCE.env"
fi

for key in IOC_APP_DIR IOC_PATH; do
    eval "value=\${$key}"
    [ -n "$value" ] || {
        echo "$0: $INSTANCE.env does not set $key" >&2
        exit 1
    }
done

# Optional anti-copy-paste guard, borrowed from NSLS2's systemd-softioc: an
# instance pinned to one machine refuses to start on another.
if [ -n "$IOC_HOST" ]; then
    if [ "$IOC_HOST" != "$(hostname -s)" ] && [ "$IOC_HOST" != "$(hostname -f)" ]; then
        echo "$0: instance $INSTANCE is pinned to host '$IOC_HOST', this is '$(hostname -s)'" >&2
        exit 1
    fi
fi

app_dir="$IOC_APP_DIR/$IOC_PATH"
[ -d "$app_dir" ] || {
    echo "$0: application directory $app_dir does not exist" >&2
    exit 1
}

. "$HERE/ioc-ports.sh"
ioc_ports_resolve

# The conventional EPICS macros: registry entries set P (and optionally R)
# with their separators included, so st.cmd and dbLoadRecords use $(P)$(R)
# directly. An envPaths epicsEnvSet sourced by st.cmd outranks them.
[ -n "$P" ] && export P
[ -n "$R" ] && export R
[ -n "$IOC_STATE" ] || IOC_STATE="/var/lib/epics-ioc/$INSTANCE"
export INSTANCE IOC_STATE EPICS_TARGET_ARCH

# The EPICS service ports stay dynamic unless the instance pins them. rsrv
# reads EPICS_CA_SERVER_PORT when its server starts, pvAccess reads
# EPICS_PVAS_SERVER_PORT, so exporting here is early enough.
if [ -n "$CA_PORT" ]; then
    export EPICS_CA_SERVER_PORT="$CA_PORT"
fi
if [ -n "$PVA_PORT" ]; then
    export EPICS_PVAS_SERVER_PORT="$PVA_PORT"
fi

# The instance's state directory and the subdirectories its entry declares.
# Nothing else can make them: autosave only ever stores the path it is handed
# and a driver that writes beside its target needs that target to exist, so a
# missing directory loses data while the IOC looks healthy. They are created
# here, under whatever medium IOC_STATE names, so moving an instance to
# another partition moves its data with it without provisioning a second time.
mkdir -p "$IOC_STATE" "$RUN_DIR"
for dir in $IOC_STATE_DIRS; do
    case $dir in
        /* | .. | */../* | ../* | */..)
            echo "$0: $INSTANCE.env: IOC_STATE_DIRS entry '$dir' is not a subdirectory of IOC_STATE" >&2
            exit 1
            ;;
    esac
    mkdir -p "$IOC_STATE/$dir"
done
cd "$app_dir"

# Optional fleet-level hook, e.g. an external device simulator bound to
# $APP_PORT_1. It runs as a sibling process in this service's cgroup, so
# systemd stops it together with the IOC.
if [ -r ./ioc-start.pre ]; then
    . ./ioc-start.pre
fi

# eval, not plain expansion: a quoted hook body must see the values the
# overrides left behind, and a bare function call must still work.
[ -n "$IOC_START_PRE" ] && eval "$IOC_START_PRE"

# The executable either comes from bin/<target-arch> or the st.cmd is run
# directly through its shebang.
if [ -n "$IOC_APP_NAME" ]; then
    set -- "$IOC_APP_DIR/bin/$EPICS_TARGET_ARCH/$IOC_APP_NAME" "${IOC_ST_CMD:-st.cmd}"
else
    set -- "./${IOC_ST_CMD:-st.cmd}"
fi

# procServ reports a console port that is already taken as "Bad file
# descriptor" plus a bare errno number, which names neither the port nor the
# owner. Every running server leaves its PID and endpoints in
# <RUN_DIR>/<instance>.info ("pid:<n>", "tcp:<addr>:<port>"), so the
# conflicting instance can be named before procServ is even started. Warning
# only: procServ stays the authority on whether the bind succeeds.
# The infofiles of running servers live as <RUN_DIR>/<instance>.info. The
# extra glob covers a per-application subdirectory layout, which still exists
# on boards whose rootfs was updated in place from an older image.
console_port_conflict_warn() {
    for _f in "$RUN_DIR"/*.info "$RUN_DIR"/*/*.info; do
        [ -f "$_f" ] || continue
        grep -q "tcp:[^:]*:$PS_PORT\$" "$_f" || continue
        _pid=$(sed -n 's/^pid:\([0-9][0-9]*\).*/\1/p' "$_f" | head -n 1)
        echo "$0: warning: console port $PS_PORT is already served by instance" \
             "$(basename "$_f" .info) (pid ${_pid:-unknown})" >&2
        echo "$0: warning: two instances must not share a slot; run 'ioc-manager report'" >&2
    done
}
console_port_conflict_warn

# -I makes procServ record PID and endpoints, so the running instance can be
# found without knowing the port in advance. --oneshot (in PROCSERV_ARGS)
# hands restart policy to systemd.
exec procServ -f -L - --name="$INSTANCE" -I "$RUN_DIR/$INSTANCE.info" \
    -P "$PS_PORT" $PROCSERV_ARGS "$@"
