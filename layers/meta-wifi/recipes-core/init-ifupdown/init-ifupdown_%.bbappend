# Remove wlan0 from /etc/network/interfaces to allow NetworkManager to manage it
# Otherwise, NetworkManager will detect wlan0 but won't manage it because it's already configured in /etc/network/interfaces
do_install:append() {
    if [ -f ${D}${sysconfdir}/network/interfaces ]; then
        # Remove wlan0 configuration block (from "iface wlan0" to "wpa-conf" line)
        sed -i '/^iface wlan0 inet dhcp/,/wpa-conf/d' ${D}${sysconfdir}/network/interfaces

        # Also remove the "# Wireless interfaces" comment if it becomes orphaned
        sed -i '/^# Wireless interfaces$/{ N; /^# Wireless interfaces\n$/d; }' ${D}${sysconfdir}/network/interfaces
    fi
}
