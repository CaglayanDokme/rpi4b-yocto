# Fix missing cyfmac43455-sdio.bin symlink
# The package creates symlinks pointing to this file but doesn't provide it

do_install:append() {
    # Create the missing symlink target that other symlinks reference
    if [ -e ${D}${nonarch_base_libdir}/firmware/cypress/cyfmac43455-sdio-standard.bin ]; then
        ln -sf cyfmac43455-sdio-standard.bin ${D}${nonarch_base_libdir}/firmware/cypress/cyfmac43455-sdio.bin
    fi
}
