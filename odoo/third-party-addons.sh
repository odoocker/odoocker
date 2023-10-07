#!/bin/bash

set -e

# Check if the repository directory exists
if [ ! -d "odoo-cloud-platform" ]; then
    git clone https://github.com/camptocamp/odoo-cloud-platform.git --depth 1 --branch ${ODOO_TAG} --single-branch --no-tags;
    cp -r odoo-cloud-platform/session_redis ${THIRD_PARTY_ADDONS}/session_redis
    cp -r odoo-cloud-platform/base_attachment_object_storage ${THIRD_PARTY_ADDONS}/base_attachment_object_storage
    cp -r odoo-cloud-platform/attachment_s3 ${THIRD_PARTY_ADDONS}/attachment_s3
fi

# Define the path to the manifest file
redis_manifest="${THIRD_PARTY_ADDONS}/session_redis/__manifest__.py"
# Define the path to the manifest file
s3_manifest="${THIRD_PARTY_ADDONS}/attachment_s3/__manifest__.py"

# Modify the manifest file
python3 /fix-manifest.py $redis_manifest
python3 /fix-manifest.py $s3_manifest
