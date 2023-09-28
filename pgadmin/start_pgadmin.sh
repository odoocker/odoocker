#!/bin/bash

set -e

# Source environment variables
set -a
source /.env
set +a

# Check if PGADMIN_DEFAULT_EMAIL is set
if [[ -z $PGADMIN_DEFAULT_EMAIL ]]; then
    echo "PGADMIN_DEFAULT_EMAIL is not set. Exiting..."
    exit 1
fi

# Modify the email to replace @ with _
DIR_NAME="/var/lib/pgadmin/storage/${PGADMIN_DEFAULT_EMAIL//@/_}"

# Create the directory using the modified name
mkdir -p "$DIR_NAME"

cp /pgadmin4/private_key "$DIR_NAME/private_key"
chown -R pgadmin:root "$DIR_NAME/private_key"

# Generate JSON for each matching variable
DB_PATH="/var/lib/pgadmin/pgadmin4.db"
json_output="{\"Servers\":{"
index=1
while true; do
    name_var="PGADMIN_DB${index}_NAME"
    if [[ -z ${!name_var} ]]; then
        break
    fi

    host_var="PGADMIN_DB${index}_HOST"
    port_var="PGADMIN_DB${index}_PORT"
    maintenance_db_var="PGADMIN_DB${index}_MAINTENANCE_DB"
    username_var="PGADMIN_DB${index}_USERNAME"
    tunnel_host_var="PGADMIN_DB${index}_TUNNEL_HOST"
    tunnel_port_var="PGADMIN_DB${index}_TUNNEL_PORT"
    tunnel_username_var="PGADMIN_DB${index}_TUNNEL_USERNAME"

    json_output+="\"$index\":$(jq -n \
        --arg name "${!name_var}" \
        --arg host "${!host_var:-localhost}" \
        --arg port "${!port_var:-5432}" \
        --arg db "${!maintenance_db_var:-${!name_var}}" \
        --arg username "${!username_var:-odoo}" \
        --arg thost "${!tunnel_host_var}" \
        --arg tport "${!tunnel_port_var:-22}" \
        --arg tuser "${!tunnel_username_var:-ubuntu}" \
        '{
            "Name": $name,
            "Group": "Servers",
            "Host": $host,
            "Port": $port|tonumber,
            "MaintenanceDB": $db,
            "Username": $username,
            "UseSSHTunnel": 1,
            "TunnelHost": $thost,
            "TunnelPort": $tport,
            "TunnelUsername": $tuser,
            "TunnelAuthentication": 1,
            "KerberosAuthentication": false,
            "ConnectionParameters": {
                "sslmode": "prefer",
                "connect_timeout": 10,
                "sslcert": "'"$DIR_NAME"'/.postgresql/postgresql.crt",
                "sslkey": "'"$DIR_NAME"'/.postgresql/postgresql.key"
            },
            "Shared": true
          }'),"

    index=$((index + 1))
done

# Remove trailing comma and close JSON braces
json_output=${json_output%,}
json_output+="}}"

# Save the well-formatted JSON to a file using jq
if [[ $PGADMIN_SERVERS_JSON ]]; then
    echo $json_output | jq '.' > "$PGADMIN_SERVERS_JSON"

    # Make the Servers.json file readable for all users
    chmod 755 "/pgadmin4/servers.json"

    echo "JSON configuration saved to $DIR_NAME/servers.json"
fi
