# Register IOC instances with the generic epics-ioc@.service runtime.
#
# The deployment unit is a host-global instance name, not an application
# package: one template unit (shipped by epics-ioc-scripts) serves every
# IOC, and an instance is a named registry entry that points at the packaged
# application and carries the instance identity. Two registry layers exist:
#
#   /etc/epics/instances/<name>.env   fleet layer, shipped by IOC packages
#   /boot/iocs/<name>/<name>.env      machine layer, optional, overrides
#
# Each entry sets at least IOC_APP_DIR, IOC_PATH and IOC_APP_NAME (where the
# application lives) plus the identity: IOC_INSTANCE_INDEX (the global
# console-slot number, console = PORT_BASE + 10 * index), P (and optionally
# R) for the record macros, and IOC_STATE with its IOC_STATE_DIRS -- the
# directory the dispatcher creates for this instance and the subdirectories of
# it the application writes into; CA_PORT/PVA_PORT/PS_PORT/APP_PORT_1/2 are
# optional pins. See docs/port-allocation.md.
#
# This class registers the packaged instances and, for the instances a recipe
# opts into, ships the systemd enable symlink; the unit file, scripts and
# procServ all belong to the epics-ioc-scripts runtime package.

inherit epics-ioc
inherit deploy

# The runtime package owns the unit file and the scripts. DEPENDS only
# sequences the build -- the runtime has to be RDEPENDS'd or it never
# reaches the rootfs and every instance fails with a missing ExecStart.
DEPENDS += "epics-ioc-scripts"
RDEPENDS:${PN} += "epics-ioc-scripts procserv"

# Registry root. Must match epics-ioc-scripts' EPICS_IOC_ENV_ROOT; redefined
# here because recipe variables do not cross package boundaries.
EPICS_IOC_ENV_ROOT ?= "/etc/epics/instances"

# Registry entries to install, as source paths; the basename must be the
# host-global instance name.
EPICS_IOC_INSTANCE_ENVS ?= ""
# Instances of this package to enable at image build time, e.g.
# EPICS_IOC_INSTANCES = "blm". Every name must have a matching
# EPICS_IOC_INSTANCE_ENVS entry.
EPICS_IOC_INSTANCES ?= ""
# enable (ship the systemd enable symlink) or disable (install only).
EPICS_IOC_AUTO_ENABLE ?= "disable"

# The registry directory is shared by every IOC package; the runtime package
# owns it.
FILES:${PN} += "${EPICS_IOC_ENV_ROOT}"

do_install:append() {
    env_root=${D}${EPICS_IOC_ENV_ROOT}
    install -d ${env_root}
    for instance in ${EPICS_IOC_INSTANCE_ENVS}; do
        install -m 0644 "$instance" "${env_root}/$(basename "$instance")"
    done

    # The unit file lives in the runtime package, so enabling an instance
    # cannot go through SYSTEMD_SERVICE -- that check only finds units
    # packaged by the same recipe. A systemd preset cannot do it either:
    # preset-all iterates unit files present on disk, and an instance of
    # epics-ioc@.service has no file of its own, so nothing in a preset ever
    # matches its name. Ship the enable symlink itself, the way
    # systemd-serialgetty does for serial-getty@<tty>. It is exactly what
    # `ioc-manager enable <name>` creates, so the runtime commands keep
    # working on top of it.
    if [ -n "${EPICS_IOC_INSTANCES}" ] && [ "${EPICS_IOC_AUTO_ENABLE}" = "enable" ]; then
        wants=${D}${sysconfdir}/systemd/system/multi-user.target.wants
        install -d $wants
        for instance in ${EPICS_IOC_INSTANCES}; do
            ln -sf ${systemd_system_unitdir}/epics-ioc@.service \
                $wants/epics-ioc@$instance.service
        done
    fi
}

# Where the machine layer of the registry lives on the target, and where that
# partition is mounted. Re-declared here for the same reason as
# EPICS_IOC_ENV_ROOT: recipe variables do not cross package boundaries, and
# epics-ioc-scripts owns the runtime copies of both.
EPICS_IOC_MACHINE_ROOT ?= "/boot/iocs"
EPICS_IOC_CARD_MOUNT ?= "/boot"

# Put the machine layer on the card as a directory that already exists -- with
# the instance's data folders in it -- because deploying a BLM board is a job
# for someone who only ever sees the FAT partition from Windows. Creating
# iocs/blm/blm.env by hand means typing an exact name into a dialog whose .txt
# extension is hidden, and blm.env.txt is silently not a registry entry: the
# IOC starts, publishes the fleet prefix, and nothing looks wrong until the
# records are named. A folder that is already there removes that way to fail.
#
# The file itself is the installed entry projected down to its assignments --
# every KEY=value line, in the entry's order, comments dropped, nothing added.
# No key list lives here because the entry already is one: it declares every
# key this instance reads, and a second list could only drift from it. A key
# the fleet leaves unset appears with an empty value, which ioc-start.sh treats
# exactly as "not set" (`[ -n "$R" ] && export R` and friends), so the line is a
# placeholder to fill in or to delete.
#
# That makes the card a menu rather than an override. Every line starts at the
# value the image ships, so a projection nobody touched behaves as if the file
# did not exist. The deployment then edits the one line that is this machine's
# own -- P, the PV prefix -- and deletes the lines this machine does not decide.
# Deleting is the safe direction: a key absent from the card follows the image.
# It is also what keeps `ioc-manager show` readable, since that attributes a key
# to the machine layer only when the card gives it a non-empty value -- so what
# is left on the card is exactly what this board decided. A card trimmed too far
# gets its full projection back by deleting the folder and re-running
# inflate-sd.sh, which never replaces what the card already holds.
#
# deploy.bbclass only gives do_deploy its directories, so this is the whole
# task rather than an :append.
do_deploy() {
    if [ -z "${EPICS_IOC_INSTANCES}" ]; then
        return 0
    fi

    # Read one key out of an installed entry the way the shell that sources it
    # would: last assignment wins, a CR left by a Windows edit is dropped, and
    # the quotes around a value belong to the file, not to the data.
    entry_key() {
        sed -n "s/^[[:space:]]*$2=//p" "$1" | tr -d '\r' | tail -n 1 |
            sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
    }

    mount=${EPICS_IOC_CARD_MOUNT}
    root=${EPICS_IOC_MACHINE_ROOT}
    # The card holds its registry under the same tree the target mounts it at,
    # so the deployed layout mirrors the target's with the mount point removed.
    card_iocs=${root#${mount}/}

    for instance in ${EPICS_IOC_INSTANCES}; do
        entry=${D}${EPICS_IOC_ENV_ROOT}/$instance.env
        if [ ! -r "$entry" ]; then
            echo "do_deploy: $instance is enabled but EPICS_IOC_INSTANCE_ENVS" >&2
            echo "do_deploy: has no $instance.env to project onto the card" >&2
            exit 1
        fi
        inst_dir=${DEPLOYDIR}/${card_iocs}/$instance
        install -d $inst_dir

        # The projection: assignments only, leading whitespace normalized, CR
        # dropped. LF on the card is what lets the deployer -- and anyone after
        # them -- diff it against the entry it came from.
        sed -e 's/^[[:space:]]*//' -n \
            -e '/^[A-Za-z_][A-Za-z0-9_]*=/p' "$entry" | tr -d '\r' \
            > $inst_dir/$instance.env

        # Not a list of card keys: these two say where this instance's data
        # folders are, which is the one thing do_deploy has to know about.
        state=$(entry_key "$entry" IOC_STATE)
        dirs=$(entry_key "$entry" IOC_STATE_DIRS)
        [ -n "$state" ] || state="/var/lib/epics-ioc/$instance"
        # Data folders are only staged when the entry puts them on the card,
        # and only inside this instance's own folder: anything else would land
        # outside the directory plnx_deploy copies (see PACKAGES_LIST below).
        case $state in
            $root/$instance|$root/$instance/*) on_card=1 ;;
            *) on_card=0 ;;
        esac

        if [ "$on_card" = 1 ]; then
            # Empty on purpose: the folders are here so the deployer sees where
            # the board's own files go, and so a re-imaged rootfs finds the
            # machine's data where the entry says it is. ioc-start.sh creates
            # them too -- the card only guarantees they exist on this medium.
            for dir in $dirs; do
                install -d ${DEPLOYDIR}/${state#${mount}/}/$dir
            done
        fi
    done
}
addtask deploy after do_install before do_build

# plnx_deploy (meta-petalinux) copies each src:dst pair of PACKAGES_LIST[<PN>]
# from DEPLOYDIR into the project's images/linux. A pair is the per-instance
# DIRECTORY, never the shared iocs/: copy_files() rmtree's its destination and
# re-copies, so a shared directory would let whichever IOC recipe deploys last
# take every other recipe's card folders with it. The parent images/linux/iocs
# is one level down from a pair, which is all copy_files() creates, and each
# instance folder is owned by exactly one recipe -- including the data folders,
# which the on-card rule above keeps inside ${card_iocs}/$instance. The flag
# name has to be the package name, and BitBake parses no expansion inside a
# flag name, so this is set from python.
python __anonymous() {
    instances = (d.getVar('EPICS_IOC_INSTANCES') or "").split()
    if not instances:
        return
    root = d.getVar('EPICS_IOC_MACHINE_ROOT') or '/boot/iocs'
    mount = d.getVar('EPICS_IOC_CARD_MOUNT') or '/boot'
    card_iocs = root[len(mount) + 1:]
    d.setVarFlag('PACKAGES_LIST', d.getVar('PN'), " ".join(
        '%s/%s:%s/%s' % (card_iocs, i, card_iocs, i) for i in instances))
    d.appendVarFlag('do_deploy', 'postfuncs', ' plnx_deploy')
    d.appendVarFlag('do_deploy_setscene', 'postfuncs', ' plnx_deploy')
}
