#!/bin/bash

set -e

# Check if the repository directory exists and either Redis or S3 is to be used
if [[ ${USE_REDIS} == "true" || ${USE_S3} == "true" ]]; then
    git clone https://github.com/odoocker/odoo-cloud-platform.git --depth 1 --branch ${ODOO_TAG} --single-branch --no-tags;
fi

if [[ ${USE_REDIS} == "true" ]]; then
    cp -r odoo-cloud-platform/session_redis ${THIRD_PARTY_ADDONS}/session_redis
fi

# Check the USE_S3 variable to decide whether to copy S3 directories
if [[ ${USE_S3} == "true" ]]; then
    cp -r odoo-cloud-platform/base_attachment_object_storage ${THIRD_PARTY_ADDONS}/base_attachment_object_storage
    cp -r odoo-cloud-platform/attachment_s3 ${THIRD_PARTY_ADDONS}/attachment_s3
fi

# Check if the repository directory exists and Sentry is to be used
if [[ ${USE_SENTRY} == "true" ]]; then
    git clone https://github.com/odoocker/server-tools.git --depth 1 --branch ${ODOO_TAG} --single-branch --no-tags;
    cp -r server-tools/sentry ${THIRD_PARTY_ADDONS}/sentry
fi
