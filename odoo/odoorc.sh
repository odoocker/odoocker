#!/bin/bash

set -e

# Define the path to the example configuration file
TEMPLATE_CONF="odoo.conf"

# First pass: Evaluate any nested variables within .env file and export them
while IFS='=' read -r key value || [[ -n $key ]]; do
    # Skip comments and empty lines
    [[ $key =~ ^#.* ]] || [[ -z $key ]] && continue
    
    # Removing any quotes around the value
    value=${value%\"}
    value=${value#\"}
    
    # Evaluate any variables within value
    eval "value=\"$value\""
    
    export "$key=$value"
done < .env

# Check the USE_REDIS variable to decide whether to copy Redis directories
if [[ $USE_REDIS == "true" ]]; then
    LOAD+=",session_redis"
fi

# Check the USE_S3 variable to decide whether to copy S3 directories
if [[ $USE_S3 == "true" ]]; then
    LOAD+=",base_attachment_object_storage,attachment_s3"
fi

# Check if the repository directory exists and Sentry is to be used
if [[ $USE_SENTRY == "true" ]]; then
    LOAD+=",sentry"
fi

echo "Loading addons: $LOAD"

# Copy the example conf to the destination to start replacing the variables
cp "$TEMPLATE_CONF" "$ODOO_RC"

# Second pass: Replace the variables in $ODOO_RC
while IFS='=' read -r key value || [[ -n $key ]]; do
    # Skip comments and empty lines
    [[ $key =~ ^#.* ]] || [[ -z $key ]] && continue
    
    value=${!key} # Get the value of the variable whose name is $key
    
    # Escape characters which are special to sed
    value_escaped=$(echo "$value" | sed 's/[\/&]/\\&/g')
    
    # Replace occurrences of the key with the value in $ODOO_RC
    sed -i "s/\${$key}/${value_escaped}/g" "$ODOO_RC"
done < .env

echo "Configuration file is generated at $ODOO_RC"
