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

    # Clone and copy logic for enterprise repository
    if [[ $repo_type == "enterprise" ]]; then
        if [[ ! -d "${ENTERPRISE_ADDONS}" ]] && [ -n "$GITHUB_USER" ] && [ -n "$GITHUB_ACCESS_TOKEN" ]; then
            $clone_cmd --depth 1 --branch ${ODOO_TAG} --single-branch --no-tags
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

        # Clone the repo if should_clone is true and it's not already cloned
        if [[ $should_clone == true && ! -d "$repo_name" ]]; then
            $clone_cmd --depth 1 --branch ${ODOO_TAG} --single-branch --no-tags
        fi

        # Copy the modules if the condition is true
        if [[ $should_clone == true ]]; then
            for (( i=0; i<${#modules_conditions[@]}; i+=2 )); do
                local module=${modules_conditions[i]}
                local condition=${modules_conditions[i+1]}
                if [[ $condition == true ]]; then
                    echo "Copying ${module} from ${repo_name} into ${THIRD_PARTY_ADDONS}"
                    cp -r /${repo_name}/${module} ${THIRD_PARTY_ADDONS}/${module}
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
    [[ -z "$line" || "$line" == \#* ]] && continue
    clone_and_copy_modules $(expand_env_vars "$line")
done < "third-party-addons.txt"
