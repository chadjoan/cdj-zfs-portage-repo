# Copyright 1999-2020 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

# HACK: I changed PYTHON_COMPAT from ver 6+7 to versions 6 through 11.
# (I am not sure what the intent of PYTHON_COMPAT is, but it causes ebuilds to fail to run at all!
# If these python versions are a build-time dependency, then surely they should not be specified in
# the PYTHON_COMPAT variable. I suspect PYTHON_COMPAT is more about `portage` internals and ebuild tools
# than it is about package dependencies, at least based on portage behavior and the error messages I get.)
# -- Chad Joan 2023-01-17
DISTUTILS_OPTIONAL=1
PYTHON_COMPAT=( python3_{6,7,8,9,10,11} )

inherit bash-completion-r1 flag-o-matic linux-info distutils-r1 systemd udev usr-ldscript

DESCRIPTION="Userland utilities for ZFS Linux kernel module"
HOMEPAGE="https://zfsonlinux.org/"

#if [ ${PV} == "YYYY.MM.DD" ]; then
	inherit autotools git-r3 linux-mod
	EGIT_COMMIT="6ed4391da97a1d183dbabcbe667026deb6678612"
	EGIT_REPO_URI="https://github.com/openzfs/${PN}.git"
#else
#	SRC_URI="https://github.com/zfsonlinux/${PN}/releases/download/${P}/${P}.tar.gz"
#	KEYWORDS="~amd64"
#fi

LICENSE="BSD-2 CDDL MIT"
SLOT="0"
IUSE="custom-cflags debug kernel-builtin libressl python +rootfs test-suite static-libs"

DEPEND="
	${PYTHON_DEPS}
	net-libs/libtirpc[static-libs?]
	sys-apps/util-linux[static-libs?]
	sys-libs/zlib[static-libs(+)?]
	app-alternatives/awk
	virtual/libudev[static-libs(-)?]
	libressl? ( dev-libs/libressl:0=[static-libs?] )
	!libressl? ( dev-libs/openssl:0=[static-libs?] )
	python? (
		virtual/python-cffi[${PYTHON_USEDEP}]
	)
"

BDEPEND="app-alternatives/awk
	virtual/pkgconfig
	python? (
		dev-python/setuptools[${PYTHON_USEDEP}]
	)
"

RDEPEND="${DEPEND}
	!kernel-builtin? ( ~sys-fs/zfs-kmod-${PV} )
	!prefix? ( virtual/udev )
	sys-fs/udev-init-scripts
	rootfs? (
		app-arch/cpio
		app-misc/pax-utils
		!<sys-kernel/genkernel-3.5.1.1
	)
	test-suite? (
		sys-apps/util-linux
		sys-devel/bc
		sys-block/parted
		sys-fs/lsscsi
		sys-fs/mdadm
		sys-process/procps
		virtual/modutils
	)
"

REQUIRED_USE="${PYTHON_REQUIRED_USE}"

RESTRICT="test"

PATCHES=( "${FILESDIR}/bash-completion-sudo.patch" )

pkg_setup() {
	if use kernel_linux && use test-suite; then
		linux-info_pkg_setup

		if  ! linux_config_exists; then
			ewarn "Cannot check the linux kernel configuration."
		else
			if use test-suite; then
				if linux_chkconfig_present BLK_DEV_LOOP; then
					eerror "The ZFS test suite requires loop device support enabled."
					eerror "Please enable it:"
					eerror "    CONFIG_BLK_DEV_LOOP=y"
					eerror "in /usr/src/linux/.config or"
					eerror "    Device Drivers --->"
					eerror "        Block devices --->"
					eerror "            [X] Loopback device support"
				fi
			fi
		fi
	fi
}

src_prepare() {
	default

	#if [[ ${PV} == "YYYY.MM.DD" ]]; then
		eautoreconf
	#else
	#	# Set revision number
	#	sed -i "s/\(Release:\)\(.*\)1/\1\2${PR}-gentoo/" META || die "Could not set Gentoo release"
	#fi

	if use python; then
		pushd contrib/pyzfs >/dev/null || die
		distutils-r1_src_prepare
		popd >/dev/null || die
	fi

	# As of this openzfs version (git HEAD on 2020-04-30) or before, zfs.in
	# no longer exists. It seems to have been replaced by other init scripts,
	# such as zfs-import, zfs-mount, zfs-share, and zfs-zed.
	# I am not sure if this fix is still relevant, or if just commenting it
	# out (as below) is sufficient. At any rate, I seem to be invading some
	# unknown territory.
	# -- Chad Joan  2020-05-05
	## prevent errors showing up on zfs-mount stop, #647688
	## openrc will unmount all filesystems anyway.
	#sed -i "/^ZFS_UNMOUNT=/ s/yes/no/" etc/init.d/zfs.in || die

	# This should be fixed in PR-9955:
	# https://github.com/openzfs/zfs/pull/9955
	# -- Chad Joan  2020-05-05
	## needed to get files regenerated
	## https://github.com/zfsonlinux/zfs/issues/9443
	#rm -v etc/init.d/zfs{,-functions} || die
}

src_configure() {
	use custom-cflags || strip-flags
	python_setup

	local myconf=(
		--bindir="${EPREFIX}/bin"
		--enable-shared
		--enable-systemd
		--enable-sysvinit
		--localstatedir="${EPREFIX}/var"
		--sbindir="${EPREFIX}/sbin"
		--with-config=user
		--with-dracutdir="${EPREFIX}/usr/lib/dracut"
		--with-linux="${KV_DIR}"
		--with-linux-obj="${KV_OUT_DIR}"
		--with-udevdir="$(get_udevdir)"
		--with-python="${EPYTHON}"
		--with-systemdunitdir="$(systemd_get_systemunitdir)"
		--with-systemdpresetdir="${EPREFIX}/lib/systemd/system-preset"
		$(use_enable debug)
		$(use_enable python pyzfs)
		$(use_enable static-libs static)
	)

	econf "${myconf[@]}"
}

src_compile() {
	default
	if use python; then
		pushd contrib/pyzfs >/dev/null || die
		distutils-r1_src_compile
		popd >/dev/null || die
	fi
}

src_install() {
	default

	gen_usr_ldscript -a uutil nvpair zpool zfs zfs_core

	use test-suite || rm -rf "${ED}/usr/share/zfs"

	if ! use static-libs; then
		find "${ED}/" -name '*.la' -delete || die
	fi

	dobashcomp contrib/bash_completion.d/zfs
	bashcomp_alias zfs zpool

	# strip executable bit from conf.d file
	fperms 0644 /etc/conf.d/zfs

	if use python; then
		pushd contrib/pyzfs >/dev/null || die
		distutils-r1_src_install
		popd >/dev/null || die
	fi

	# enforce best available python implementation
	python_fix_shebang "${ED}/bin"

}

pkg_postinst() {
	if use rootfs; then
		if ! has_version sys-kernel/genkernel && ! has_version sys-kernel/dracut; then
			elog "root on zfs requires initramfs to boot"
			elog "the following packages known to provide one and tested on regular basis:"
			elog "  sys-kernel/dracut"
			elog "  sys-kernel/genkernel"
		fi

		if has_version "<=sys-kernel/genkernel-3.5.3.3"; then
			einfo "genkernel version 3.5.3.3 and earlier does NOT support"
			einfo " unlocking pools with native zfs encryption enabled at boot"
			einfo " use dracut or >=genkernel-4 if you requre this functionality"
		fi
	fi

	#if ! use kernel-builtin && [[ ${PV} = "YYYY.MM.DD" ]]; then
	if ! use kernel-builtin; then
		einfo "Adding ${P} to the module database to ensure that the"
		einfo "kernel modules and userland utilities stay in sync."
		update_moduledb
	fi

	[[ -e "${EROOT}/etc/runlevels/boot/zfs-import" ]] || \
		einfo "You should add zfs-import to the boot runlevel."
	[[ -e "${EROOT}/etc/runlevels/boot/zfs-mount" ]]|| \
		einfo "You should add zfs-mount to the boot runlevel."
	[[ -e "${EROOT}/etc/runlevels/default/zfs-share" ]] || \
		einfo "You should add zfs-share to the default runlevel."
	[[ -e "${EROOT}/etc/runlevels/default/zfs-zed" ]] || \
		einfo "You should add zfs-zed to the default runlevel."
}

pkg_postrm() {
	#if ! use kernel-builtin && [[ ${PV} == "YYYY.MM.DD" ]]; then
	if ! use kernel-builtin; then
		remove_moduledb
	fi
}
