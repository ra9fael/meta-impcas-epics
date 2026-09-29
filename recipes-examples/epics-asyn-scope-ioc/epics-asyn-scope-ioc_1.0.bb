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
#
# The boot directory keeps the name upstream gave it, because in
# iocBoot/ioc<name> the <name> is the IOC's own name and this IOC is
# upstream's testAsynPortDriver, repackaged unchanged. The ioc prefix is not
# decoration: iocBoot/Makefile collects the directories it builds with
# $(wildcard *ioc*), so a boot dir without it would never get its envPaths --
# and this recipe's pruning below and the class's install action both work
# through that same wildcard. A tree of your own names its IOC instead (the
# BLM application boots from iocBoot/iocblm); the instance names never appear
# in the tree at all, they are registry entries.
IOC_APP_NAME = "testAsynPortDriver"
IOC_PATH = "iocBoot/ioctestAsynPortDriver"

# Two instances in the host-wide registry; both are installed but stay off
# until the operator enables them (dev-board example IOC, not a fleet unit).
# Named after the IOC, in the charset the registry allows -- lowercase
# [a-z0-9-], which ioc-start.sh enforces because the name doubles as the
# systemd unit instance, the state directory and the procServ name -- plus an
# ordinal for a second copy. That is the same rule that gives the BLM IOC its
# instance name blm; the CamelCase of the boot directory cannot cross into the
# registry, so tapd01 boots iocBoot/ioctestAsynPortDriver.
EPICS_IOC_INSTANCE_ENVS = "${WORKDIR}/instances/tapd01.env ${WORKDIR}/instances/tapd02.env"
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
    ioc_boot=${install_dir}/${IOC_PATH}

    # Phoebus display for the simulated oscilloscope. The default macros in
    # the file (P=TAPD01:, R=scope1:) match the tapd01 instance env, so opening
    # it works unconfigured; other instances pass -m overrides in the client,
    # which is why the file is named for the instance it defaults to.
    install -d ${install_dir}/opi
    install -m 0644 ${WORKDIR}/opi/*.bob ${install_dir}/opi/

    # Upstream wrote this boot script by hand, so it carries two paths relative
    # to the build tree and never sources the envPaths that the class generates
    # and installs beside it. Sourcing it is what makes the file the shape a
    # makeBaseApp tree documents -- a shebang, then $(TOP) for the application
    # and one macro per linked module -- and here it is also what makes it work:
    # ASYN has a value only inside envPaths, and a macro iocsh cannot resolve
    # stays in the text as written, so without that line the asynRecord.db load
    # asks for a file called "$(ASYN)/db/asynRecord.db" and those records are
    # absent while the IOC still boots. The dispatcher exports the registry keys
    # and nothing about the support modules, so a module path can only come from
    # envPaths; the instance env supplies the PV prefix, while the asyn port
    # name is internal to the IOC process and stays as upstream wrote it.
    #
    # Assert first: if upstream renames what these rewrites match, the build has
    # to fail here rather than ship a script that quietly loads half a database.
    grep -q '^dbLoadDatabase("\.\./\.\./dbd/testAsynPortDriver\.dbd")' ${ioc_boot}/${IOC_ST_CMD}
    grep -q '^dbLoadRecords("\.\./\.\./db/asynRecord\.db"' ${ioc_boot}/${IOC_ST_CMD}
    grep -q 'P=testAPD:,R=scope1:' ${ioc_boot}/${IOC_ST_CMD}
    # The cd back into the boot directory before iocInit is what gives $(IOC)
    # -- envPaths writes it from the directory name -- its reason to exist, and
    # it fails loudly if the registry's IOC_PATH and the installed tree ever
    # disagree.
    sed -i -e '1s|^|#!../../bin/${EPICS_TARGET_ARCH}/${IOC_APP_NAME}\n< envPaths\ncd "$(TOP)"\n|' \
        -e 's|\.\./\.\./dbd/|dbd/|' \
        -e 's|\.\./\.\./db/asynRecord\.db|$(ASYN)/db/asynRecord.db|' \
        -e 's|\.\./\.\./db/|db/|' \
        -e 's|P=testAPD:|P=$(P)|g' -e 's|R=scope1:|R=$(R)|g' \
        -e 's|^iocInit()|cd "$(TOP)/iocBoot/$(IOC)"\niocInit()|' \
        ${ioc_boot}/${IOC_ST_CMD}

    # asyn pins the iocBoot ARCH to the build host and also generates
    # cdCommands (vxWorks) and dllPath.bat (Windows); none of that is useful
    # here. st.cmd.vxWorks and nfsCommands are upstream's vxWorks originals,
    # the same dead weight in a Linux-only package.
    rm -f ${ioc_boot}/cdCommands \
          ${ioc_boot}/dllPath.bat \
          ${ioc_boot}/st.cmd.vxWorks \
          ${install_dir}/iocBoot/nfsCommands
}
