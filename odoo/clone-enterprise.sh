#!/bin/bash

set -e

if [ -n "$ENTERPRISE_USER" ] && [ -n "$ENTERPRISE_ACCESS_TOKEN" ]; then \
    git clone https://${ENTERPRISE_USER}:${ENTERPRISE_ACCESS_TOKEN}@github.com/odoo/enterprise.git ${ENTERPRISE_ADDONS} --depth 1 --branch ${ODOO_TAG} --single-branch --no-tags
fi
