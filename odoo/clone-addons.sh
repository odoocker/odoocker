#!/bin/bash

set -e

# Function to clone and copy modules based on conditions
clone_and_copy_modules() {
    local repo_type=$1
    local repo_url=$2
    shift 2
    local modules_conditions=("$@")

    # Extract repo name from the URL
    repo_name=$(basename -s .git "$repo_url")

    # Determine the clone command based on repo type
    local clone_cmd
    if [[ $repo_type == "private" ]]; then
        clone_cmd="git clone https://${GITHUB_USER}:${GITHUB_ACCESS_TOKEN}@${repo_url#https://}"
    else
        clone_cmd="git clone $repo_url"
    fi

    # Iterate over modules and conditions
    for (( i=0; i<${#modules_conditions[@]}; i+=2 )); do
        local module=${modules_conditions[i]}
        local condition=${modules_conditions[i+1]}

        # Check if the condition is true and clone and copy if needed
        if [[ $condition == true ]]; then
            # Clone the repository if not already cloned
            if [ ! -d "$repo_name" ]; then
                echo "Cloning $clone_cmd --depth 1 --branch ${ODOO_TAG} --single-branch --no-tags"
                $clone_cmd --depth 1 --branch ${ODOO_TAG} --single-branch --no-tags
            fi
            # Copy the module
            echo "Copying ${module} from ${repo_name} into ${THIRD_PARTY_ADDONS}"
            cp -r /${repo_name}/${module} ${THIRD_PARTY_ADDONS}/${module}
        fi
    done
}

# Function to manually expand environment variables in a string
expand_env_vars() {
    while IFS=' ' read -r -a words; do
        for word in "${words[@]}"; do
            if [[ $word == \$* ]]; then
                varname=${word:2:-1} # Extract the variable name
                echo -n "${!varname} " # Substitute with its value
            else
                echo -n "$word "
            fi
        done
        echo
    done <<< "$1"
}

# Read the configuration file and process each line
while IFS= read -r line; do
    # Skip empty lines and lines starting with '#'
    if [[ -z "$line" || "$line" == \#* ]]; then
        continue
    fi

    # Manually replace environment variables in the line with their values
    processed_line=$(expand_env_vars "$line")
    # Split the processed line into an array
    IFS=' ' read -r -a repo_info <<< "$processed_line"
    # Call the function with the repository type, URL, and modules with conditions
    clone_and_copy_modules "${repo_info[@]}"
done < "third-party-addons.txt"
