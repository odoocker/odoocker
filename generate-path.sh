set -e
if [ ! -f "$ODOO_RC" ]; then
    touch "$ODOO_RC" || true
    echo "The configuration file $ODOO_RC does not exist. A new one has been created."
fi

# Function to find and process folders
function search_and_process {
    local dir="$1"

    # Verify if the directory is not empty before calling ls
    if [ -n "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
        for subdir in "$dir"/*; do
            if [ -d "$subdir" ]; then
                if [ -f "$subdir/__manifest__.py" ]; then
                    echo "Found __manifest__.py in: $subdir"
                    add_to_conf "$dir" || true
                    break
                fi
                if [ -d "$subdir" ]; then
                    search_and_process "$subdir" || true
                fi
            fi
        done
    else
        echo "Error: Could not list the directory $dir."
        echo "Directory: $dir"
    fi
}

# Function to add the path to the configuration file
function add_to_conf {
    local path="$1"
    if grep -q "addons_path" "$ODOO_RC"; then
        sed -i "s|addons_path *= *.*|&,$path|" "$ODOO_RC" || true
    else
        echo "addons_path=$path" >> "$ODOO_RC" || true
    fi
}

# Process the folders in the environment variables if they are defined
for var in THIRD_PARTY_ADDONS; do
    if [ -n "${!var}" ]; then
        IFS=',' read -ra ADDON_DIRS <<< "${!var}"
        for addon_dir in "${ADDON_DIRS[@]}"; do
            if [ -d "$addon_dir" ]; then
                echo "Searching in: $(realpath "$addon_dir")"
                search_and_process "$(realpath "$addon_dir")" || true
            else
                echo "The directory $addon_dir does not exist."
            fi
        done
    else
        echo "The environment variable $var is not defined."
    fi
done

# Search and process the folders in the provided directory
search_and_process "$DIRECTORY" || true

echo "compute-conf process completed."