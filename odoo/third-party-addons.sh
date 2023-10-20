#!/bin/bash

set -e

# Check if the repository directory exists and either Redis or S3 is to be used
if [[ ! -d "odoo-cloud-platform" && ( $USE_REDIS -eq 1 || $USE_S3 -eq 1 ) ]]; then
    git clone https://github.com/odoocker/odoo-cloud-platform.git --depth 1 --branch ${ODOO_TAG} --single-branch --no-tags;
fi

# Check the USE_REDIS variable to decide whether to copy Redis directories
if [[ $USE_REDIS -eq 1 ]]; then
    cp -r odoo-cloud-platform/session_redis ${THIRD_PARTY_ADDONS}/session_redis
fi

# Check the USE_S3 variable to decide whether to copy S3 directories
if [[ $USE_S3 -eq 1 ]]; then
    cp -r odoo-cloud-platform/base_attachment_object_storage ${THIRD_PARTY_ADDONS}/base_attachment_object_storage
    cp -r odoo-cloud-platform/attachment_s3 ${THIRD_PARTY_ADDONS}/attachment_s3
fi

# Check if the repository directory exists and Sentry is to be used
if [[ ! -d "server-tools" && $USE_SENTRY -eq 1 ]]; then
    git clone https://github.com/odoocker/server-tools.git --depth 1 --branch ${ODOO_TAG} --single-branch --no-tags;
    cp -r server-tools/sentry ${THIRD_PARTY_ADDONS}/sentry
fi
