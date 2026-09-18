#!/bin/sh
# SPDX-FileCopyrightText: 2026 IMPCAS
#
# SPDX-License-Identifier: MIT

# Console-port slots for EPICS IOC instances managed by the epics-ioc@
# template, plus the helper entry points around them.
#
# Every site-level value comes from the epics-ioc-env file next to this
# script; this file contains only logic, so it can be read and tested without
# a build.

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -r "$HERE/epics-ioc-env" ] || { echo "$0: missing $HERE/epics-ioc-env" >&2; exit 1; }
. "$HERE/epics-ioc-env"

IOC_PORT_STRIDE=10
IOC_INSTANCE_MAX=99

# Resolve the console and application ports for $IOC_INSTANCE_INDEX. Values
# already set by the instance env file are kept, so a port can be pinned.
# CA_PORT/PVA_PORT are deliberately not derived: the EPICS service ports stay
# dynamic unless the instance env pins them. See docs/port-allocation.md.
ioc_ports_resolve() {
    [ -n "$IOC_INSTANCE_INDEX" ] || IOC_INSTANCE_INDEX=0
    _base=$(( PORT_BASE + IOC_INSTANCE_INDEX * IOC_PORT_STRIDE ))
    [ -n "$PS_PORT" ] || PS_PORT=$_base
    [ -n "$APP_PORT_1" ] || APP_PORT_1=$(( _base + 1 ))
    [ -n "$APP_PORT_2" ] || APP_PORT_2=$(( _base + 2 ))
    export IOC_INSTANCE_INDEX PS_PORT APP_PORT_1 APP_PORT_2
    }

ioc_ports_show() {
    # Always resolve: a preset PS_PORT alone must not leave the app ports empty.
    ioc_ports_resolve
    echo "ioc=$PN instance=$IOC_INSTANCE_INDEX"
    echo "PS_PORT=$PS_PORT APP_PORT_1=$APP_PORT_1 APP_PORT_2=$APP_PORT_2"
    if [ -n "$CA_PORT" ]; then
        echo "EPICS_CA_SERVER_PORT=$CA_PORT (pinned)"
    else
        echo "EPICS_CA_SERVER_PORT=dynamic (first IOC gets 5064)"
    fi
    if [ -n "$PVA_PORT" ]; then
        echo "EPICS_PVAS_SERVER_PORT=$PVA_PORT (pinned)"
    else
        echo "EPICS_PVAS_SERVER_PORT=dynamic (first IOC gets 5075)"
    fi
    if [ -n "$1" ] && [ -r "$RUN_DIR/$1.info" ]; then
        echo "--- procServ endpoints ($RUN_DIR/$1.info)"
        cat "$RUN_DIR/$1.info"
    fi
    }

_ioc_ports_env_files() {
    # The instance registry spans two layers: the fleet-wide env files in the
    # image and the optional machine-level overrides on the BOOT partition.
    # A console port collides across layers just as it does within one, so
    # both are scanned.
    for _f in "$ENV_ROOT"/*.env "$MACHINE_ENV_ROOT"/*/*.env; do
        [ -e "$_f" ] || continue
        echo "$_f"
    done
    }

_ioc_ports_file_index() {
    sed -n 's/^[[:space:]]*IOC_INSTANCE_INDEX=\([0-9][0-9]*\).*/\1/p' "$1" | tail -n 1
    }

ioc_ports_next() {
    _used=" "
    for _f in $(_ioc_ports_env_files); do
        _idx=$(_ioc_ports_file_index "$_f")
        _used="$_used${_idx:-0} "
    done
    _n=0
    while [ "$_n" -le "$IOC_INSTANCE_MAX" ]; do
        case "$_used" in
            *" $_n "*) ;;
            *) echo "$_n"; return 0 ;;
        esac
        _n=$(( _n + 1 ))
    done
    echo "no free instance index (max $IOC_INSTANCE_MAX)" >&2
    return 1
    }

ioc_ports_audit() {
    _rc=0
    _seen=" "
    for _f in $(_ioc_ports_env_files); do
        _idx=$(_ioc_ports_file_index "$_f")
        _idx="${_idx:-0}"
        case "$_seen" in
            *" $_idx "*)
                echo "collision: IOC_INSTANCE_INDEX=$_idx used again by $_f -> PS_PORT=$(( PORT_BASE + _idx * IOC_PORT_STRIDE ))" >&2
                _rc=1 ;;
        esac
        _seen="$_seen$_idx "
    done
    [ "$_rc" = 0 ] && echo "ok: no console-port collisions under $ENV_ROOT"
    return $_rc
    }

_ioc_ports_dispatch() {
    case "$1" in
        --show)  shift; ioc_ports_show "$@" ;;
        --next)  ioc_ports_next ;;
        --audit) ioc_ports_audit ;;
        *) echo "usage: $0 [--show [instance]|--next|--audit]" >&2; return 2 ;;
    esac
    }
# Act only when executed, not when sourced by ioc-start.sh. An if statement
# keeps the status at 0 for the sourcing caller (which runs with set -e);
# a trailing "[ ... ] && ..." guard would abort it here.
if [ "$(basename "$0")" = "ioc-ports.sh" ]; then
    _ioc_ports_dispatch "$@"
fi
