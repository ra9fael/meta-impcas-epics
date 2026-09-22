# Register IOC instances with the generic epics-ioc@.service runtime.
#
# The deployment unit is a host-global instance name, not an application
# package: one template unit (shipped by epics-ioc-scripts) serves every
# IOC, and an instance is a named registry entry that points at the packaged
# application and carries the instance identity. Two registry layers exist:
#
#   /etc/epics/instances/<name>.env   fleet layer, shipped by IOC packages
#   /boot/iocs/<name>.env             machine layer, optional, overrides
#
# Each entry sets at least IOC_APP_DIR, IOC_PATH and IOC_APP_NAME (where the
# application lives) plus the identity: IOC_INSTANCE_INDEX (the global
# console-slot number, console = PORT_BASE + 10 * index), IOC_PREFIX and
# IOC_STATE; CA_PORT/PVA_PORT/PS_PORT/APP_PORT_1/2 are optional pins.
# See docs/port-allocation.md.
#
# This class registers the packaged instances and, for the instances a recipe
# opts into, ships the systemd enable symlink; the unit file, scripts and
# procServ all belong to the epics-ioc-scripts runtime package.

inherit epics-ioc

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
