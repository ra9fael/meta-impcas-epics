SUMMARY = "Generic runtime for EPICS IOC instances under systemd"
DESCRIPTION = "The epics-ioc@.service template, the ioc-start.sh dispatcher \
and the port-slot helpers. An instance is a named registry entry \
(/etc/epics/instances/<name>.env in the image, optional overrides in \
/boot/iocs/<name>.env) that points at an IOC application directory and \
carries the instance identity; procServ runs one-shot so restart policy \
stays with systemd."
HOMEPAGE = "https://github.com/ra9fael/meta-impcas-epics"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://ioc-start.sh \
           file://ioc-ports.sh \
           file://ioc-instance-add \
           file://ioc-manager \
           file://epics-ioc@.service \
"
S = "${WORKDIR}"

inherit systemd

# epics-common supplies EPICS_TARGET_ARCH (TARGET_ARCH -> linux-aarch64 and
# friends), baked into the generated epics-ioc-env so ioc-start.sh can locate
# bin/<arch> executables of binary-mode IOC instances.
inherit epics-common

# Site-level defaults, written into the generated epics-ioc-env data file.
EPICS_IOC_ENV_ROOT ?= "/etc/epics/instances"
EPICS_IOC_MACHINE_ENV_ROOT ?= "/boot/iocs"
EPICS_IOC_PORT_BASE ?= "21000"
EPICS_IOC_RUN_DIR ?= "/run/epics"
# Restart policy stays with systemd (--oneshot). The console listener also
# needs --allow to be reachable from other hosts: it is a long-only option
# (there is no -A short form) and the compile-time default alone does not
# widen the bind. Remove --allow to serve the console on localhost only, and
# see docs/port-allocation.md before adding anything else here.
PROCSERV_ARGS ?= "--oneshot --allow"

SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "epics-ioc@.service"
SYSTEMD_AUTO_ENABLE:${PN} = "disable"

do_install() {
    install -d ${D}${libexecdir}/epics-ioc ${D}${bindir} ${D}${systemd_system_unitdir}
    install -d ${D}${EPICS_IOC_ENV_ROOT}

    # Static runtime data. EPICS_TARGET_ARCH is baked in: this package is
    # built for the target.
    cat > ${D}${libexecdir}/epics-ioc/epics-ioc-env <<EOF
# Site-level values for the epics-ioc runtime scripts (part of the
# epics-ioc-scripts package). Per-instance values live in the registry.
ENV_ROOT="${EPICS_IOC_ENV_ROOT}"
MACHINE_ENV_ROOT="${EPICS_IOC_MACHINE_ENV_ROOT}"
PORT_BASE="${EPICS_IOC_PORT_BASE}"
RUN_DIR="${EPICS_IOC_RUN_DIR}"
PROCSERV_ARGS="${PROCSERV_ARGS}"
EPICS_TARGET_ARCH="${EPICS_TARGET_ARCH}"
EOF

    install -m 0755 ${WORKDIR}/ioc-start.sh ${WORKDIR}/ioc-ports.sh \
        ${D}${libexecdir}/epics-ioc/
    install -m 0755 ${WORKDIR}/ioc-instance-add ${WORKDIR}/ioc-manager \
        ${D}${bindir}/

    # Thin wrapper so the port-slot helpers are reachable through PATH.
    printf '#!/bin/sh\nexec %s/epics-ioc/ioc-ports.sh "$@"\n' "${libexecdir}" \
        > ${D}${bindir}/ioc-ports
    chmod 0755 ${D}${bindir}/ioc-ports
    install -m 0644 ${WORKDIR}/epics-ioc@.service ${D}${systemd_system_unitdir}/epics-ioc@.service
    sed -i s,@LIBEXECDIR@,${libexecdir},g ${D}${systemd_system_unitdir}/epics-ioc@.service
}

FILES:${PN} = "${libexecdir}/epics-ioc/ \
               ${bindir}/ioc-ports ${bindir}/ioc-manager ${bindir}/ioc-instance-add \
               ${systemd_system_unitdir}/epics-ioc@.service \
               ${EPICS_IOC_ENV_ROOT} \
"

RDEPENDS:${PN} = "procserv"
