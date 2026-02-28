SUMMARY = "Pre-configured NetworkManager Wi-Fi connections for Raspberry Pi"
DESCRIPTION = "Provides pre-configured NetworkManager connection profiles for \
automatic Wi-Fi connection at system boot on Raspberry Pi 4B"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit allarch

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI += "file://wifi.nmconnection"

S = "${WORKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/NetworkManager/system-connections
    install -m 0600 ${WORKDIR}/wifi.nmconnection ${D}${sysconfdir}/NetworkManager/system-connections/
}

FILES:${PN} = "${sysconfdir}/NetworkManager/system-connections/*"
RDEPENDS:${PN} = "networkmanager"
