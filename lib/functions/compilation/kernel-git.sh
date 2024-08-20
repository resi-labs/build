#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (c) 2013-2023 Igor Pecovnik, igor@armbian.com
#
# This file is a part of the Armbian Build Framework
# https://github.com/armbian/build/

function kernel_prepare_git() {
	[[ -z $KERNELSOURCE ]] && return 0 # do nothing if no kernel source... but again, why were we called then?

	# validate kernel_git_bare_tree is set
	if [[ -z "${kernel_git_bare_tree}" ]]; then
		exit_with_error "kernel_git_bare_tree is not set"
	fi

	display_alert "Downloading sources" "kernel" "git"

	if [[ "${GH_FETCH_MODE}" == "jwt" ]]; then
		echo "Fetching from $KERNELSOURCE the JWT way"

		# Remove https:// from the source URI
		local altered_kernel_source="$(echo "${KERNELSOURCE}" | sed -e "s@^https://@@")"
		# Recreate the URL with the Github app name and JWT token
		altered_kernel_source="https://${GH_APP_NAME}:${GH_JWT_TOKEN}@${altered_kernel_source}"

		GIT_FIXED_WORKDIR="${LINUXSOURCEDIR}" \
			GIT_BARE_REPO_FOR_WORKTREE="${kernel_git_bare_tree}" \
			GIT_BARE_REPO_INITIAL_BRANCH="master" \
			fetch_from_repo "${altered_kernel_source}" "kernel:${KERNEL_MAJOR_MINOR}" "${KERNELBRANCH}" "yes"
	else
		echo "Fetching from $KERNELSOURCE the non-JWT way"
		GIT_FIXED_WORKDIR="${LINUXSOURCEDIR}" \
			GIT_BARE_REPO_FOR_WORKTREE="${kernel_git_bare_tree}" \
			GIT_BARE_REPO_INITIAL_BRANCH="master" \
			fetch_from_repo "${KERNELSOURCE}" "kernel:${KERNEL_MAJOR_MINOR}" "${KERNELBRANCH}" "yes"
		# second parameter, "dir", is ignored, since we've passed GIT_FIXED_WORKDIR
	fi
}

function kernel_cleanup_bundle_artifacts() {
	[[ -z "${git_bundles_dir}" ]] && exit_with_error "git_bundles_dir is not set"

	if [[ -d "${git_bundles_dir}" ]]; then
		display_alert "Cleaning up Kernel git bundle artifacts" "no longer needed" "info"
		run_host_command_logged rm -rf "${git_bundles_dir}"
	fi

	return 0
}
