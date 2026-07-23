#!/bin/bash

set -e

# Function to construct the clone command
construct_clone_command() {
    local repo_type=$1
    local repo_url=$2
    case $repo_type in
        private) echo "git clone https://${GITHUB_USER}:${GITHUB_ACCESS_TOKEN}@${repo_url#https://}" ;;
        enterprise) echo "git clone https://${ENTERPRISE_USER}:${ENTERPRISE_ACCESS_TOKEN}@${repo_url#https://} ${ENTERPRISE_ADDONS}" ;;
        public) echo "git clone $repo_url" ;;
    esac
}

# Function to clone and copy modules based on conditions
clone_and_copy_modules() {
    local repo_type=$1
    local repo_url=$2
    local clone_cmd=$(construct_clone_command $repo_type $repo_url)
    local repo_name=$(basename -s .git "$repo_url")

    shift 2
    local modules_conditions=("$@")

    # ODOO_TAG is image-pinned in .env.example (`19.0@sha256:...`) for supply
    # chain safety, but git can't accept a SHA-digest-suffixed string as a
    # branch name. Strip the @sha256:... suffix to get the real branch.
    # Without this strip every clone falls through to --branch main (or fails
    # outright), silently shipping the image without 2 of 3 third-party
    # addon sets — verified by P2.1's validate-third-party-addons CI job.
    local odoo_branch="${ODOO_TAG%%@*}"

    # Clone and copy logic for enterprise repository
    if [[ $repo_type == "enterprise" ]]; then
        if [ -n "$GITHUB_USER" ] && [ -n "$GITHUB_ACCESS_TOKEN" ]; then
            $clone_cmd --depth 1 --branch ${odoo_branch} --single-branch --no-tags
        fi
    else
        # Determine if any module has a true condition
        local should_clone=false
        if [[ ${#modules_conditions[@]} -eq 1 ]]; then
            [[ ${modules_conditions[0]} == true ]] && should_clone=true
        else
            for (( i=1; i<${#modules_conditions[@]}; i+=2 )); do
                if [[ ${modules_conditions[i]} == true ]]; then
                    should_clone=true
                    break
                fi
            done
        fi

        # Clone the repo if should_clone is true and it's not already cloned.
        # Uses odoo_branch (with @sha256:... stripped above) instead of raw ODOO_TAG.
        if [[ $should_clone == true && ! -d "$repo_name" ]]; then
            if ! $clone_cmd --depth 1 --branch ${odoo_branch} --single-branch --no-tags 2>/dev/null; then
                echo "WARN: branch ${odoo_branch} not found for ${repo_name}, trying main..."
                $clone_cmd --depth 1 --branch main --single-branch --no-tags 2>/dev/null || \
                echo "WARN: skipping ${repo_name} — no compatible branch found"
            fi
        fi

        # Copy the modules if the condition is true.
        # Guarded against missing /${repo_name} so a clone that fell through
        # both --branch ${ODOO_TAG} and --branch main (and printed a WARN
        # above) doesn't blow up the whole build via `cp` + `set -e`. The
        # missing-module log is ERROR-level so production build logs make it
        # easy to grep `^ERROR:` and verify every expected addon shipped.
        if [[ $should_clone == true ]]; then
            for (( i=0; i<${#modules_conditions[@]}; i+=2 )); do
                local module=${modules_conditions[i]}
                local condition=${modules_conditions[i+1]}
                if [[ $condition == true ]]; then
                    if [ -d "/${repo_name}/${module}" ]; then
                        echo "Copying ${module} from ${repo_name} into ${THIRD_PARTY_ADDONS}"
                        cp -r "/${repo_name}/${module}" "${THIRD_PARTY_ADDONS}/${module}"
                    else
                        echo "ERROR: module ${module} not found at /${repo_name}/${module} — clone of ${repo_name} likely failed or branch lacks this module. Skipping." >&2
                    fi
                fi
            done
        fi
    fi
}

# Function to manually expand environment variables in a string
expand_env_vars() {
    while IFS=' ' read -r -a words; do
        for word in "${words[@]}"; do
            if [[ $word == \$\{* ]]; then
                # Remove the leading '${' and the trailing '}' from the word
                varname=${word:2:-1}
                # Check if the variable is set and not empty
                if [ -n "${!varname+x}" ]; then
                    echo -n "${!varname} " # Substitute with its value
                else
                    echo -n "false " # Default to false if not set
                fi
            else
                echo -n "$word "
            fi
        done
        echo
    done <<< "$1"
}

# Read the configuration file and process each line
while IFS= read -r line; do
    mkdir -p ${ENTERPRISE_ADDONS}
    mkdir -p ${THIRD_PARTY_ADDONS}
    [[ -z "$line" || "$line" == \#* ]] && continue
    clone_and_copy_modules $(expand_env_vars "$line")
done < "third-party-addons.txt"
