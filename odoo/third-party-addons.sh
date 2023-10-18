#!/bin/bash

set -e

# Check if the repository directory exists
if [ ! -d "odoo-cloud-platform" ]; then
    git clone https://github.com/odoocker/odoo-cloud-platform.git --depth 1 --branch ${ODOO_TAG} --single-branch --no-tags;
    cp -r odoo-cloud-platform/session_redis ${THIRD_PARTY_ADDONS}/session_redis
    cp -r odoo-cloud-platform/base_attachment_object_storage ${THIRD_PARTY_ADDONS}/base_attachment_object_storage
    cp -r odoo-cloud-platform/attachment_s3 ${THIRD_PARTY_ADDONS}/attachment_s3
fi

# Check if the repository directory exists
if [ ! -d "server-tools" ]; then
    git clone https://github.com/odoocker/server-tools.git --depth 1 --branch ${ODOO_TAG} --single-branch --no-tags;
    cp -r server-tools/sentry ${THIRD_PARTY_ADDONS}/sentry
fi
