#!/bin/bash

set -e

case "$1" in
    -- | odoo)
        shift
        if [[ "$1" == "scaffold" ]] ; then
            # Creates new module.
            exec odoo "$@"
        else
            wait-for-psql.py --db_host ${DB_HOST} --db_port ${DB_PORT} --db_user ${DB_USER} --db_password ${DB_PASSWORD} --timeout=30

            if [ ${APP_ENV} = 'fresh' ] || [ ${APP_ENV} = 'restore' ]; then
                echo odoo --config ${ODOO_RC} --database= --update= --init= --load=${SERVER_WIDE_MODULES} --workers=0 --log-handler=:INFO --log-level=info --max-cron-threads=2 --limit-time-cpu=3600 --limit-time-real=7200 --limit-time-real-cron=600 --limit-request=8192 --limit-memory-soft=2147483648 --limit-memory-hard=2684354560 --transient-age-limit=1.0 --load-language= --without-demo=True --import-partial=False --log-db= --dev=False

                exec odoo --config ${ODOO_RC} --database= --update= --init= --load=${SERVER_WIDE_MODULES} --workers=0 --log-handler=:INFO --log-level=info --max-cron-threads=2 --limit-time-cpu=3600 --limit-time-real=7200 --limit-time-real-cron=600 --limit-request=8192 --limit-memory-soft=2147483648 --limit-memory-hard=2684354560 --transient-age-limit=1.0 --load-language= --without-demo=True --import-partial=False --log-db= --dev=False
            fi

            if [ ${APP_ENV} = 'full' ] ; then
                echo odoo --config ${ODOO_RC} --database=${DB_NAME} --init=${INSTALLED_MODULES} --update= --load=${SERVER_WIDE_MODULES} --workers=0 --log-handler=:INFO --log-level=info --max-cron-threads=2 --limit-time-cpu=3600 --limit-time-real=7200 --limit-time-real-cron=600 --limit-request=8192 --limit-memory-soft=2147483648 --limit-memory-hard=2684354560 --transient-age-limit=1.0 --db-filter= --load-language=${LOAD_LANGUAGE} --without-demo=True --import-partial=False --log-db= --dev=False

                exec odoo --config ${ODOO_RC} --database=${DB_NAME} --init=${INSTALLED_MODULES} --update= --load=${SERVER_WIDE_MODULES} --workers=0 --log-handler=:INFO --log-level=info --max-cron-threads=2 --limit-time-cpu=3600 --limit-time-real=7200 --limit-time-real-cron=600 --limit-request=8192 --limit-memory-soft=2147483648 --limit-memory-hard=2684354560 --transient-age-limit=1.0 --db-filter= --load-language=${LOAD_LANGUAGE} --without-demo=True --import-partial=False --log-db= --dev=False
            fi

            if [ ${APP_ENV} = 'local' ] ; then
                # Automagically update the addons you are currently working on.
                echo odoo --config ${ODOO_RC} --database=${DB_NAME} --update=${UPDATE} --init=${INIT} --load=${SERVER_WIDE_MODULES} --dev=${DEV_MODE}

                exec odoo --config ${ODOO_RC} --database=${DB_NAME} --update=${UPDATE} --init=${INIT} --load=${SERVER_WIDE_MODULES} --dev=${DEV_MODE}
            fi

            if [ ${APP_ENV} = 'debug' ] ; then
                # Automagically update the addons you are currently working on.
                exec /usr/bin/python3 -m debugpy --listen 0.0.0.0:8888 /usr/bin/odoo --config ${ODOO_RC} --database=${DB_NAME} --update=${UPDATE} --init=${INIT} --load=${SERVER_WIDE_MODULES} --dev=${DEV_MODE}

                exec /usr/bin/python3 -m debugpy --listen 0.0.0.0:8888 /usr/bin/odoo --config ${ODOO_RC} --database=${DB_NAME} --update=${UPDATE} --init=${INIT} --load=${SERVER_WIDE_MODULES} --dev=${DEV_MODE}
            fi

            if [ ${APP_ENV} = 'testing' ] ; then
                # Work in progres... (DO NOT USE)
                echo odoo --config ${ODOO_RC} --database=test_${DB_NAME} --db-filter=test_${DB_NAME} --test-enable --test-commit --log-handler=:DEBUG --log-level=debug --workers=0 --init= --update=

                exec odoo --config ${ODOO_RC} --database=test_${DB_NAME} --db-filter=test_${DB_NAME} --test-enable --test-commit --log-handler=:DEBUG --log-level=debug --workers=0 --init= --update=
            fi

            if [ ${APP_ENV} = 'staging' ] ; then
                # Automagically install/upgrade all addons
                echo odoo --config ${ODOO_RC} --database=${DB_NAME} --init=${INIT} --update=all --load=${SERVER_WIDE_MODULES} --workers=0 --log-handler=:INFO --log-level=info --max-cron-threads=2 --limit-time-cpu=3600 --limit-time-real=7200 --limit-time-real-cron=600 --limit-request=8192 --limit-memory-soft=2147483648 --limit-memory-hard=2684354560 --transient-age-limit=1.0 --db-filter= --load-language=${LOAD_LANGUAGE} --without-demo=True --import-partial=False --log-db= --dev=False

                exec odoo --config ${ODOO_RC} --database=${DB_NAME} --init=${INIT} --update=all --load=${SERVER_WIDE_MODULES} --workers=0 --log-handler=:INFO --log-level=info --max-cron-threads=2 --limit-time-cpu=3600 --limit-time-real=7200 --limit-time-real-cron=600 --limit-request=8192 --limit-memory-soft=2147483648 --limit-memory-hard=2684354560 --transient-age-limit=1.0 --db-filter= --load-language=${LOAD_LANGUAGE} --without-demo=True --import-partial=False --log-db= --dev=False
            fi

            if [ ${APP_ENV} = 'production' ] ; then
                # Bring up Odoo without any addons to install/update.
                echo odoo --config ${ODOO_RC} --database= --init= --update= --load-language= --db-filter= --dev=False --import-partial=False --without-demo=True --log-handler=:INFO --log-level=info --log-db= --log-db-level=warning --workers=2 --max-cron-threads=2 --log-level=info --log-handler=:INFO --limit-time-cpu=120 --limit-time-real=240 --limit-request=8192 --limit-memory-soft=2147483648 --limit-memory-hard=2684354560 --transient-age-limit=1.0 --import-partial=False

                exec odoo --config ${ODOO_RC} --database= --init= --update= --load-language= --db-filter= --dev=False --import-partial=False --without-demo=True --log-handler=:INFO --log-level=info --log-db= --log-db-level=warning --workers=2 --max-cron-threads=2 --log-level=info --log-handler=:INFO --limit-time-cpu=120 --limit-time-real=240 --limit-request=8192 --limit-memory-soft=2147483648 --limit-memory-hard=2684354560 --transient-age-limit=1.0 --import-partial=False
            fi
        fi
        ;;
    -*)
        # TODO: check which cases end up here.
        wait-for-psql.py --db_host ${DB_HOST} --db_port ${DB_PORT} --db_user ${DB_USER} --db_password ${DB_PASSWORD} --timeout=30
        echo odoo --config ${ODOO_RC}
        exec odoo --config ${ODOO_RC}
        ;;
    *)

        # TODO: check which cases end up here.
        echo "$@"
        exec "$@"
esac

exit 1