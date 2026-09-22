SUMMARY = "EPICS asyn simulated oscilloscope test IOC"
DESCRIPTION = "asyn's own testAsynPortDriver example: a simulated oscilloscope \
driver on top of asynPortDriver, packaged as an IOC application supervised by \
procServ."
HOMEPAGE = "https://github.com/epics-modules/asyn"

# Same source and license as the epics-asyn module recipe.
LICENSE = "EPICS"
LIC_FILES_CHKSUM = "file://LICENSE;md5=9f42f43716fb1d5e8498617125cb3c21"

# Pinned, not AUTOREV: the git fetcher stores the bare mirror in DL_DIR, where
# it is shared with the epics-asyn recipe, so the source is downloaded once and
# every later build checks it out locally without network access. When asyn is
# upgraded, change SRCREV here and in epics-asyn in the same commit.
SRC_URI = "git://github.com/epics-modules/asyn;protocol=https;branch=master \
           file://instances \
           file://opi \
"
SRCREV = "76f6164757d54b0b7dae22a911fe78fd20a95525"
S = "${WORKDIR}/git"

inherit epics-ioc-systemd

EPICS_MODULE_NAME = "asyn-scope-ioc"

# One entry replaces four declarations: DEPENDS and RDEPENDS gain epics-asyn,
# configure/RELEASE gains the staged ASYN path, and the IOC's rpath gains the
# asyn library directory.
EPICS_MODULES = "asyn"

# IOC_APP_NAME and IOC_PATH are build-time values (used by epics-ioc to
# install the iocBoot tree); the registry entries below repeat them as
# runtime data.
IOC_APP_NAME = "testAsynPortDriver"
IOC_PATH = "iocBoot/ioctestAsynPortDriver"

# Two instances in the host-wide registry; both are installed but stay off
# until the operator enables them (dev-board example IOC, not a fleet unit).
EPICS_IOC_INSTANCE_ENVS = "${WORKDIR}/instances/scope01.env ${WORKDIR}/instances/scope02.env"
# Spelled out rather than left to the class default: this recipe is the
# example every new IOC is copied from, and it must never auto-start.
EPICS_IOC_AUTO_ENABLE = "disable"

do_configure:append() {
    # Keep only what this IOC builds. Everything else -- the asyn library
    # itself, the other test applications, makeSupport -- is dropped: the
    # library comes from the staged epics-asyn module. Most DIRS lines sit
    # inside an ifneq and are indented, so the patterns must tolerate leading
    # whitespace. testAsynPortDriverApp orders itself after the dropped asyn
    # directory and iocBoot orders itself after the app, so those dependency
    # lines are the ones kept.
    awk '
        /^[ \t]*DIRS \+= / && $0 !~ /^[ \t]*DIRS \+= (configure|testAsynPortDriverApp|iocBoot)[ \t]*$/ { print "#" $0; next }
        /_DEPEND_DIRS/ && $0 !~ /testAsynPortDriverApp[ \t]*$/ { print "#" $0; next }
        { print }
    ' ${S}/Makefile > ${S}/Makefile.new
    mv ${S}/Makefile.new ${S}/Makefile

    # The iocBoot makefile picks up every *ioc* directory by wildcard and the
    # class generates envPaths for each of them; keep only the one this IOC
    # boots. -mindepth 1 keeps the iocBoot directory itself.
    find ${S}/iocBoot -mindepth 1 -maxdepth 1 -type d -name 'ioc*' \
        ! -name 'ioctestAsynPortDriver' -exec rm -rf {} +
}

do_install:append() {
    install_dir=${D}${EPICS_INSTALL_BASE}/${EPICS_MODULE_NAME}-${EPICS_MODULE_VERSION}

    # Phoebus display for the simulated oscilloscope. The default macros in
    # the file (P=ioc0:, R=scope1:) match the ioc0 instance env, so opening it
    # works unconfigured; other instances pass -m overrides in the client.
    install -d ${install_dir}/opi
    install -m 0644 ${WORKDIR}/opi/*.bob ${install_dir}/opi/

    # The instance env supplies the PV prefix; the asyn port name is internal to
    # the IOC process, so it stays as upstream wrote it.
    sed -i -e 's/P=testAPD:/P=$(P)/g' -e 's/R=scope1:/R=$(R)/g' \
        ${install_dir}/${IOC_PATH}/${IOC_ST_CMD}

    # asynRecord.db belongs to the installed asyn module; load it from there
    # through the ASYN variable that envPaths exports instead of shipping a
    # second copy.
    sed -i 's|\.\./\.\./db/asynRecord\.db|$(ASYN)/db/asynRecord.db|' \
        ${install_dir}/${IOC_PATH}/${IOC_ST_CMD}

    # asyn pins the iocBoot ARCH to the build host and also generates
    # cdCommands (vxWorks) and dllPath.bat (Windows); none of that is useful
    # here.
    rm -f ${install_dir}/${IOC_PATH}/cdCommands \
          ${install_dir}/${IOC_PATH}/dllPath.bat
}
