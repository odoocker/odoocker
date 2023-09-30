git clone https://github.com/camptocamp/odoo-cloud-platform.git --depth 1 --branch ${ODOO_TAG} --single-branch --no-tags;
cp -r odoo-cloud-platform/session_redis ${THIRD_PARTY_ADDONS}/session_redis
