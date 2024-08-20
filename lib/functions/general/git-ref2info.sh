#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (c) 2013-2023 Igor Pecovnik, igor@armbian.com
#
# This file is a part of the Armbian Build Framework
# https://github.com/armbian/build/

# This works under memoize-cached.sh::run_memoized() -- which is full of tricks.
# Nested functions are used because the source of the momoized function is used as part of the cache hash.
function memoized_git_ref_to_info() {
	declare -n MEMO_DICT="${1}" # nameref
	declare ref_type ref_name
	declare -a refs_to_try=()

	git_parse_ref "${MEMO_DICT[GIT_REF]}"
	MEMO_DICT+=(["REF_TYPE"]="${ref_type}")
	MEMO_DICT+=(["REF_NAME"]="${ref_name}")

	# Small detour here; if it's a tag, ask for the dereferenced commit, to avoid the annotated tag's sha1, instead get the commit tag points to.
	# Also, try 'refs/heads/xxx' first. Some repos have Gerrit-style "refs/for/xxx" refs, which are not what we want.
	if [[ "${ref_type}" == "tag" ]]; then
		refs_to_try+=("refs/heads/${ref_name}^{}" "refs/heads/${ref_name}" "${ref_name}^{}" "${ref_name}") # try first with a tag dereference, then just the tag. for annotated tags support.
	elif [[ "${ref_type}" == "branch" ]]; then
		refs_to_try+=("refs/heads/${ref_name}" "${ref_name}")
	else
		refs_to_try+=("${ref_name}")
	fi

	# Get the SHA1 of the commit
	declare sha1

	# Enter loop. The first that resolves to a valid sha1 wins.
	declare to_try
	for to_try in "${refs_to_try[@]}"; do
		display_alert "Fetching SHA1 of '${ref_type}' '${to_try}'" "${MEMO_DICT[GIT_SOURCE]}" "info"
		case "${ref_type}" in
			commit)
				sha1="${to_try}"
				;;
			*)
				case "${GITHUB_MIRROR}" in
					"ghproxy")
						case "${MEMO_DICT[GIT_SOURCE]}" in
							"https://github.com/"*)
								sha1="$(git ls-remote --exit-code "https://ghproxy.com/${MEMO_DICT[GIT_SOURCE]}" "${to_try}" | cut -f1)"
								;;
							*)
								sha1="$(git ls-remote --exit-code "${MEMO_DICT[GIT_SOURCE]}" "${to_try}" | cut -f1)"
								;;
						esac
						;;
					*)
						if [[ "${GH_FETCH_MODE}" == "jwt" ]]; then
							chopped_git_source="$(echo "${MEMO_DICT[GIT_SOURCE]}" | sed 's/.*github/github/')"
							authenticated_git_url="https://${GH_APP_NAME}:${GH_JWT_TOKEN}@${chopped_git_source}"
							sha1="$(git ls-remote --exit-code "${authenticated_git_url}" "${to_try}" | cut -f1)"
						else
							sha1="$(git ls-remote --exit-code "${MEMO_DICT[GIT_SOURCE]}" "${to_try}" | cut -f1)"
						fi
						;;
				esac
				;;
		esac

		display_alert "SHA1 of ${ref_type} ${to_try}" "ref value: '${ref_value}' '${sha1}'" "info"

		# Test if sha1 is valid, using a regex
		if [[ "${sha1}" =~ ^[0-9a-f]{40}$ ]]; then
			# sha1 is valid, break out of the loop
			break
		else
			# sha1 is invalid, try the next one
			display_alert "Failed to fetch SHA1 of '${ref_type}' '${to_try}'" "${MEMO_DICT[GIT_SOURCE]}" "info"
		fi
	done

	# Test again for sanity out of the loop.
	if [[ ! "${sha1}" =~ ^[0-9a-f]{40}$ ]]; then
		exit_with_error "Failed to fetch SHA1 of '${MEMO_DICT[GIT_SOURCE]}' '${ref_type}' '${ref_name}' - make sure it's correct"
	fi

	MEMO_DICT+=(["SHA1"]="${sha1}")

	if [[ "${2}" == "include_makefile_body" ]]; then

		function obtain_makefile_body_from_git() {
			declare git_source="${1}"
			declare sha1="${2}"
			makefile_body="undetermined"     # outer scope
			makefile_url="undetermined"      # outer scope
			makefile_version="undetermined"  # outer scope
			makefile_codename="undetermined" # outer scope

			declare url="undetermined"
			case "${git_source}" in

				"https://git.kernel.org/pub/scm/linux/kernel/"*)
					url="${git_source}/plain/Makefile?h=${sha1}"
					;;

				"https://kernel.googlesource.com/pub/scm/linux/kernel/git/stable/linux-stable" | "https://mirrors.tuna.tsinghua.edu.cn/git/linux-stable.git" | "https://mirrors.bfsu.edu.cn/git/linux-stable.git")
					# for mainline kernel source, only the origin source support curl
					url="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/Makefile?h=${sha1}"
					;;

				"https://github.com/"*)
					# parse org/repo from https://github.com/org/repo
					declare org_and_repo=""
					org_and_repo="$(echo "${git_source}" | cut -d/ -f4-5)"
					org_and_repo="${org_and_repo%.git}" # remove .git if present
					case "${GITHUB_MIRROR}" in
						"ghproxy")
							url="https://ghproxy.com/https://raw.githubusercontent.com/${org_and_repo}/${sha1}/Makefile"
							;;
						*)
							url="https://raw.githubusercontent.com/${org_and_repo}/${sha1}/Makefile"
							;;
					esac
					;;

				"https://gitlab.com/"* | "https://source.denx.de/"* | "https://gitlab.collabora.com/"*)
					# GitLab is more complex than GitHub, there can be more levels.
					# This code is incomplete... but it works for now.
					# Example: input:  https://gitlab.com/rk3588_linux/rk/kernel.git
					#          output: https://gitlab.com/rk3588_linux/rk/kernel/-/raw/linux-5.10/Makefile
					declare gitlab_path="${git_source%.git}" # remove .git
					url="${gitlab_path}/-/raw/${sha1}/Makefile"
					;;

				*)
					exit_with_error "Unknown git source '${git_source}'"
					;;
			esac

			display_alert "Fetching Makefile via HTTP" "${url}" "info"
			makefile_url="${url}"

			# Lets do a retry loop here, because GitHub/others are unreliable...
			declare makefile_body="undetermined"
			do_with_retries 5 obtain_makefile_body_from_url "${url}" "${org_and_repo}" "${sha1}" "Makefile"

			parse_makefile_version "${makefile_body}"

			return 0
		}

		# Constructs the GitHub API URL based on the input parameters
		# 1: ORG/REPO - organization name/repo-name
		# 2: Resource type: blob, file, commit, ref, tag
		# 3: The resource key (SHA1, file name, reference, commit, tag name)
		function construct_github_api_url() {
			if [[ "$#" != "3" ]]; then
				exit_with_error "Invalid number of arguments specified for GitHub API fetch"
			fi
			local lc_orgrepo="${1}"
			local lc_type="${2}"
			local lc_key="${3}"
			local lc_url="https://api.github.com/repos/${lc_orgrepo}"

			case $lc_type in

				blob)
					echo "Type is BLOB, key should be an SHA1 hash: ${lc_key}"
					lc_url="${lc_url}/git/blobs/${lc_key}"
					;;
				file)
					echo "Type is FILE, key should be filename path in repo: ${lc_key}"
					lc_url="${lc_url}/contents/${lc_key}"
					;;
				commit)
					echo "Type is COMMIT, key should be an SHA1 hash: ${lc_key}"
					lc_url="${lc_url}/git/commits/${lc_key}"
					;;
				ref)
					echo "Type is REF, key should be a Git reference: ${lc_key}"
					lc_url="${lc_url}/git/ref/${lc_key}"
					;;
				tag)
					echo "Type is TAG, key should be an SHA1 hash: ${lc_key}"
					lc_url="${lc_url}/git/tags/${lc_key}"
					;;
				*)
					echo "Unknown type, returning error"
					exit_with_error "Type specified for GitHub API fetch is unknown: ${lc_type}; please correct"
					;;
			esac

			echo "${lc_url}"
		}

		# Constructs the GitHub Raw proxy URL based on the input parameters
		# 1: Org/Repo - organization name/repo-name
		# 2: The resource key (SHA1)
		# 3: The resource name (file name with path)
		function construct_github_raw_url_from_hash_and_name() {
			if [[ "$#" != "3" ]]; then
				exit_with_error "Invalid number of arguments specified for GitHub Raw Hash fetch"
			fi
			local lc_orgrepo="${1}"
			local lc_key="${2}"
			local lc_name="${3}"
			local lc_url="https://raw.githubusercontent.com/${lc_orgrepo}/${lc_key}/${lc_name}"
			echo "${lc_url}"
		}

		# Constructs the GitHub Raw proxy URL based on a JWT authorization via token
		# 1: GitHub JWT token
		# 2: Org/Repo - organization name/repo-name
		# 3: The resource key (SHA1)
		# 4: The resource name (file name and path)
		function construct_github_raw_url_from_jwt_token_hash() {
			if [[ "$#" != "4" ]]; then
				exit_with_error "Invalid number of arguments specified for GitHub Raw Hash JWT fetch"
			fi
			local lc_jwt="${1}"
			local lc_orgrepo="${2}"
			local lc_key="${3}"
			local lc_name="${4}"
			local lc_url="https://${lc_jwt}@raw.githubusercontent.com/${lc_orgrepo}/${lc_key}/${lc_name}"
			echo "${lc_url}"
		}

		# Constructs the GitHub Raw proxy URL based on a JWT authorization via token and name
		# 1: GitHub APP name
		# 2: GitHub JWT token
		# 3: Org/Repo - organization name/repo-name
		# 4: The resource key (SHA1)
		# 5: The resource name (file name and path)
		function construct_github_raw_url_from_jwt_token_hash_and_name() {
			if [[ "$#" != "5" ]]; then
				exit_with_error "Invalid number of arguments specified for GitHub Raw Hash JWT fetch"
			fi
			local lc_appname="${1}"
			local lc_jwt="${2}"
			local lc_orgrepo="${3}"
			local lc_key="${4}"
			local lc_name="${5}"
			local lc_url="https://${lc_appname}:${lc_jwt}@raw.githubusercontent.com/${lc_orgrepo}/${lc_key}/${lc_name}"
			echo "${lc_url}"
		}

		# Fetches a file or a blob from GitHub via the raw GitHub server but with a bearer token
		# Parameters:
		# 1: Org/Repo
		# 2: Key (SHA1)
		# 3: File path and file name
		function obtain_file_contents_from_url_gh() {
			local lc_org_repo="${1}"
			local lc_key=${2}
			local lc_filename=${3}
			local api_token=""
			if [[ "${GH_FETCH_MODE}" == "https" ]]; then
				api_token="${GH_TOKEN}"
				local accept_header="Accept: application/vnd.github.v3.raw"
				local auth_header="Authorization: Bearer ${api_token}"
				local api_version="X-GitHub-Api-Version: 2022-11-28"
				local final_url="$(construct_github_raw_url_from_hash_and_name "${lc_org_repo}" "${lc_key}" "${lc_filename}")"
				display_alert "Fetching Makefile from GitHub API" "URL=${final_url}" "info"

				makefile_body="$(curl -sL --fail -H "${accept_header}" -H "${auth_header}" -H "${api_version}" ${final_url})"
				if [[ -z "${makefile_body}" ]]; then
					display_alert "Failed to fetch Makefile from GH API URL"
				else
					display_alert "Fetched Makefile from GH API URL" "${final_url}" "info"
				fi
			elif [[ "${GH_FETCH_MODE}" == "jwt" ]]; then
				api_token="${GH_JWT_TOKEN}"
				local accept_header="Accept: application/vnd.github.v3.raw"
				local auth_header="Authorization: Bearer ${api_token}"
				local api_version="X-GitHub-Api-Version: 2022-11-28"
				local final_url="$(construct_github_raw_url_from_hash_and_name "${lc_org_repo}" "${lc_key}" "${lc_filename}")"
				local final_jwt_token_url="$(construct_github_raw_url_from_jwt_token_hash "${api_token}" "${lc_org_repo}" "${lc_key}" "${lc_filename}")"
				local final_jwt_token_name_url="$(construct_github_raw_url_from_jwt_token_hash_and_name "${GH_APP_NAME}" "${api_token}" "${lc_org_repo}" "${lc_key}" "${lc_filename}")"


				display_alert "Fetching Makefile from GitHub using JWT token as Bearer" "URL is masked" "info"
				makefile_body="$(curl -sL --fail -H "${accept_header}" -H "${auth_header}" -H "${api_version}" ${final_url})"
				if [[ -z "${makefile_body}" ]]; then
					display_alert "Failed to fetch makefile using JWT as just a bearer token, trying with the modified URL (just JWT token)"
					makefile_body="$(curl -sL --fail -H "${accept_header}" -H "${auth_header}" -H "${api_version}" ${final_jwt_token_url})"
				fi

				if [[ -z "${makefile_body}" ]]; then
					display_alert "Failed to fetch makefile using a modified URL (just JWT token), trying with app name and JWT token"
					makefile_body="$(curl -sL --fail -H "${accept_header}" -H "${auth_header}" -H "${api_version}" ${final_jwt_token_name_url})"
				fi

				if [[ -z "${makefile_body}" ]]; then
					display_alert "Failed to fetch makefile using the GitHub API via the JWT token" "JWT Failed" "warn"
				else
					display_alert "Fetched Makefile from GH API URL using JWT token" "URL is masked" "info"
				fi
			fi
			return 0
		}

		function obtain_makefile_body_from_url() {
			makefile_body="$(curl -sL --fail "${1}")" || {
				display_alert "Failed to fetch Makefile from URL with standard approach - trying with token approach" "org_repo=${2}, key=${3}, file=${4}" "info"
				obtain_file_contents_from_url_gh "${2}" "${3}" "${4}"
				if [[ -z "${makefile_body}" ]]; then
					echo "Failed to fetch Makefile"
					return 1
				fi
				return 0
			}
			display_alert "Fetched Makefile from URL" "${1}" "info"
			return 0
		}

		function parse_makefile_version() {
			declare makefile_body="${1}"
			makefile_version="undetermined"      # outer scope
			makefile_codename="undetermined"     # outer scope
			makefile_full_version="undetermined" # outer scope

			local ver=()
			ver[0]=$(grep "^VERSION" <(echo "${makefile_body}") | head -1 | awk '{print $(NF)}' | grep -oE '^[[:digit:]]+' || true)
			ver[1]=$(grep "^PATCHLEVEL" <(echo "${makefile_body}") | head -1 | awk '{print $(NF)}' | grep -oE '^[[:digit:]]+' || true)
			ver[2]=$(grep "^SUBLEVEL" <(echo "${makefile_body}") | head -1 | awk '{print $(NF)}' | grep -oE '^[[:digit:]]+' || true)
			ver[3]=$(grep "^EXTRAVERSION" <(echo "${makefile_body}") | head -1 | awk '{print $(NF)}' | grep -oE '^-rc[[:digit:]]+' || true)
			makefile_version="${ver[0]:-0}${ver[1]:+.${ver[1]}}${ver[2]:+.${ver[2]}}${ver[3]}"

			# validate sanity
			if [[ "${makefile_version}" == "0" ]]; then
				exit_with_error "Unable to parse Makefile version '${makefile_version}' from body '${makefile_body}'"
			fi

			makefile_full_version="${makefile_version}"
			if [[ "${ver[3]}" == "-rc"* ]]; then # contentious:, if an "-rc" EXTRAVERSION, don't include the SUBLEVEL
				makefile_version="${ver[0]:-0}${ver[1]:+.${ver[1]}}${ver[3]}"
			fi
			display_alert "Parsed Makefile version" "Version: [${makefile_version}] Full Version: [${makefile_full_version}]" "info"

			# grab the codename while we're at it
			makefile_codename="$(grep "^NAME\ =\ " <(echo "${makefile_body}") | head -1 | cut -d '=' -f 2 | sed -e "s|'||g" | xargs echo -n || true)"
			# remove any starting whitespace left
			makefile_codename="${makefile_codename#"${makefile_codename%%[![:space:]]*}"}"
			# remove any trailing whitespace left
			makefile_codename="${makefile_codename%"${makefile_codename##*[![:space:]]}"}"
			display_alert "Parsed Makefile codename" "Codename: [${makefile_codename}]" "info"

			return 0
		}

		display_alert "Fetching Makefile body" "${ref_name}" "info"
		declare makefile_body makefile_url
		declare makefile_version makefile_codename makefile_full_version
		obtain_makefile_body_from_git "${MEMO_DICT[GIT_SOURCE]}" "${sha1}"
		MEMO_DICT+=(["MAKEFILE_URL"]="${makefile_url}")
		#MEMO_DICT+=(["MAKEFILE_BODY"]="${makefile_body}") # large, don't store
		MEMO_DICT+=(["MAKEFILE_VERSION"]="${makefile_version}")
		MEMO_DICT+=(["MAKEFILE_FULL_VERSION"]="${makefile_full_version}")
		MEMO_DICT+=(["MAKEFILE_CODENAME"]="${makefile_codename}")
	fi

}
