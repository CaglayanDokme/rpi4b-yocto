FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://rauc-boot-select.sh"

do_install:append() {
    # Install custom bootloader hook script for A/B slot switching
    install -d ${D}${libdir}/rauc
    install -m 0755 ${WORKDIR}/rauc-boot-select.sh ${D}${libdir}/rauc/boot-select.sh

    # Create persistent state directory for RAUC status file
    install -d ${D}${localstatedir}/lib/rauc
}
