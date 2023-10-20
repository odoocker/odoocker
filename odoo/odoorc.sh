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

# Check the USE_REDIS to add base_attachment_object_storage & session_redis to LOAD variable
if [[ $USE_REDIS == "true" ]]; then
    LOAD+=",base_attachment_object_storage"
    LOAD+=",session_redis"
fi

# Check the USE_REDIS to add attachment_s3 to LOAD variable
if [[ $USE_S3 == "true" ]]; then
    LOAD+=",attachment_s3"
fi

# Check the USE_REDIS to add sentry to LOAD variable
if [[ $USE_SENTRY == "true" ]]; then
    LOAD+=",sentry"
fi

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
