#!/usr/bin/env sh

# Exit on errors
set -e

cd "${TRAVIS_BUILD_DIR}"

if [ "${TRAVIS_PULL_REQUEST}" != "false" ]; then
	print_warning "Not packaging pull-requests for deployment"
	exit 0
fi

# GNU extensions for sed are not supported; on Linux, --posix mimicks this behaviour
VERSION=$(sed -ne 's,^Version:[[:space:]]\([0-9.]\{3\,\}\)$,\1,p' src/sysc/systemc.pc)
echo "VERSION = ${VERSION}"

GIT_HASH=$(git --git-dir=".git" show --no-patch --pretty="%h")
echo "GIT_HASH = ${GIT_HASH}"

GIT_DATE=$(git --git-dir=".git" show --no-patch --pretty="%ci")
echo "GIT_DATE = ${GIT_DATE}"

DATE_HASH=$(date -u +"%Y%m%d%H%M")
echo "DATE_HASH = ${DATE_HASH}"

if [ "${TRAVIS_OS_NAME}" = "linux" ]; then
	RELEASE_DATE=$(date -u +"%Y-%m-%dT%H:%M:%S%z" --date="${GIT_DATE}")
elif [ "${TRAVIS_OS_NAME}" = "osx" ]; then
	RELEASE_DATE=$(date -ujf "%Y-%m-%d %H:%M:%S %z" "${GIT_DATE}" "+%Y-%m-%dT%H:%M:%S%z")
else
	print_error "Unsupported operating system '${TRAVIS_OS_NAME}'"
	exit 1
fi
echo "RELEASE_DATE = ${RELEASE_DATE}"

VERSION_NAME="${VERSION}-${DATE_HASH}-git_${GIT_HASH}"
echo "VERSION_NAME = ${VERSION_NAME}"

if [ "${TARGET_OS}" = "linux" -a "${TRAVIS_OS_NAME}" = "linux" ]; then
	DEBDATE=$(date -R)

	echo "DEBDATE = $DEBDATE"
	echo "DEB_MAINTAINER_NAME = $DEB_MAINTAINER_NAME"
	echo "DEB_MAINTAINER_EMAIL = $DEB_MAINTAINER_EMAIL"
	if [ -z "${DEB_MAINTAINER_NAME}" -o -z "${DEB_MAINTAINER_EMAIL}" -o -z "${DEB_PASSPHRASE}" -o -z "${LAUNCHPAD_DISTROS}" ]; then
		echo "DEB_MAINTAINER_NAME and/or DEB_MAINTAINER_EMAIL and/or DEB_PASSPHRASE and/or LAUNCHPAD_DISTROS are not set"
		exit 0
	fi
	#openssl aes-256-cbc -K $encrypted_54846cac3f0f_key -iv $encrypted_54846cac3f0f_iv -in "${TRAVIS_BUILD_DIR}/.travis/launchpad/key.asc.enc" -out "${TRAVIS_BUILD_DIR}/.travis/launchpad/key.asc" -d
	#gpg --import "${TRAVIS_BUILD_DIR}/.travis/launchpad/key.asc"

	for DISTRO in ${LAUNCHPAD_DISTROS}; do
		echo "Packging for ${DISTRO}"
		DEB_VERSION=$(echo "${VERSION_NAME}" | tr "_-" "~")"~${DISTRO}"
		echo -n "   "
		echo "DEB_VERSION = $DEB_VERSION"

		DEBDIR="${BUILDDIR}/systemc-${DEB_VERSION}"
		print_info "   exporting sources to ${DEBDIR}"
		mkdir -p "${DEBDIR}"
		cd "${TRAVIS_BUILD_DIR}" && git archive --format=tar HEAD  | tar -x -C "${DEBDIR}" -f -

		print_info "   copying debian directory"
		cp -r "${TRAVIS_BUILD_DIR}/.travis/launchpad/debian" "${DEBDIR}"

		if [ -f "${TRAVIS_BUILD_DIR}/.travis/launchpad/${DISTRO}.patch" ]; then
			print_info "   applying ${DISTRO}.patch"
			patch -d "${DEBDIR}" -p0 < "${TRAVIS_BUILD_DIR}/.travis/launchpad/${DISTRO}.patch"
		fi


		print_info "   preparing copyright"
		sed -i -e "s/<AUTHOR>/${DEB_MAINTAINER_NAME}/g" -e "s/<DATE>/${DEBDATE}/g" "${DEBDIR}/debian/copyright"

		print_info "   preparing changelog"
		echo "systemc (${DEB_VERSION}) ${DISTRO}; urgency=low\n" > "${DEBDIR}/debian/changelog"
		if [ -z "${TRAVIS_TAG}" ]; then
			git log --reverse --pretty=format:"%w(80,4,6)* %s" ${TRAVIS_COMMIT_RANGE} >> "${DEBDIR}/debian/changelog"
			echo "" >> "${DEBDIR}/debian/changelog" # git log does not append a newline
		else
			NEWS=$(sed -n "/^Release ${VERSION}/,/^Release/p" ${TRAVIS_BUILD_DIR}/NEWS | sed -e '/^Release/d' -e 's/^\t/    /')
			echo "$NEWS" >> "${DEBDIR}/debian/changelog"
		fi
		echo "\n -- ${DEB_MAINTAINER_NAME} <${DEB_MAINTAINER_EMAIL}>  ${DEBDATE}" >> "${DEBDIR}/debian/changelog"

		print_info "   building package"
		cd "${DEBDIR}"

		echo -n "" > "/tmp/passphrase.txt" || print_error "Failed to create /tmp/passphrase.txt"
		# Write the passphrase to the file several times; debuild (debsign)
		# will try to sign (at least) the .dsc file and the .changes files,
		# thus reading the passphrase from the pipe several times
		# NB: --passphrase-file seems to be broken somehow
		for i in $(seq 10); do
			echo "${DEB_PASSPHRASE}" >> "/tmp/passphrase.txt" 2> /dev/null || print_error "Failed to write to /tmp/passphrase.txt"
		done
		debuild -k00582F84 -p"gpg --no-tty --batch --passphrase-fd 0" -S < /tmp/passphrase.txt && DEBUILD_RETVAL=$? || DEBUILD_RETVAL=$?
		rm -f /tmp/passphrase.txt

		if [ $DEBUILD_RETVAL -ne 0 ]; then
			print_warning "   debuild failed with status code ${DEBUILD_RETVAL}"
			continue
		fi
		cd ..

		DEBFILE="systemc_${DEB_VERSION}_source.changes"
		if [ -z "${TRAVIS_TAG}" ]; then
			PPA="ppa:archc/ppa"
		else
			PPA="ppa:archc/stable"
		fi
		print_info "   scheduling to upload ${DEBFILE} to ${PPA}"

		echo "dput \"${PPA}\" \"${BUILDDIR}/${DEBFILE}\"" >> "${TRAVIS_BUILD_DIR}/.travis/dput-launchpad.sh"
	done
elif [ "${TARGET_OS}" = "osx" -a "${TRAVIS_OS_NAME}" = "osx" ]; then
	print_info "Not packaging for '${TRAVIS_OS_NAME}/${TARGET_OS}'"
else
	echo "Skipping unsupported host/target combination '${TRAVIS_OS_NAME}/${TARGET_OS}'"
fi

cd "${TRAVIS_BUILD_DIR}"

echo "Deployment preparation successful"
