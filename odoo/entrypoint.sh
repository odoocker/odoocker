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
                # Ideal for a fresh install or restore a production database.
                echo odoo --config ${ODOO_RC} --database= --init= --update= --load=${SERVER_WIDE_MODULES} --log-level=${LOG_LEVEL} --load-language= --workers=0 --limit-time-cpu=3600 --limit-time-real=7200

                exec odoo --config ${ODOO_RC} --database= --init= --update= --load-language= --workers=0 --limit-time-cpu=3600 --limit-time-real=7200
            fi

            if [ ${APP_ENV} = 'full' ] ; then
                # Ideal for initializing a fresh database with a huge amount of addons.
                echo odoo --config ${ODOO_RC} --database=${DB_NAME} --init=${INIT} --update= --load=${SERVER_WIDE_MODULES} --log-level=${LOG_LEVEL} --load-language=${LOAD_LANGUAGE} --max-cron-threads=${MAX_CRON_THREADS} --limit-time-cpu=3600 --limit-time-real=7200

                exec odoo --config ${ODOO_RC} --update= --workers=0 --limit-time-cpu=3600 --limit-time-real=7200
            fi

            if [ ${APP_ENV} = 'local' ] ; then
                # Listens to all .env variables mapped into odoo.conf file.
                echo odoo --config ${ODOO_RC}

                exec odoo --config ${ODOO_RC}
            fi

            if [ ${APP_ENV} = 'debug' ] ; then
                # Same as local but you can debug you custom addons with your code editor (VSCode).
                echo debugpy odoo --config ${ODOO_RC}

                exec /usr/bin/python3 -m debugpy --listen ${DEBUG_INTERFACE}:${DEBUG_PORT} ${DEBUG_PATH} --config ${ODOO_RC}
            fi

            if [ ${APP_ENV} = 'testing' ] ; then
                # Initializies a fresh 'test_*' database, installs the addons to test, and runs tests you specify in the test tags.
                echo odoo --config ${ODOO_RC} --database=test_${DB_NAME} --test-enable --test-tags ${TEST_TAGS} --init=${ADDONS_TO_TEST} --update=${ADDONS_TO_TEST} --load=${SERVER_WIDE_MODULES} --log-level=${LOG_LEVEL} --without-demo= --workers=0 --stop-after-init

                exec odoo --config ${ODOO_RC} --database=test_${DB_NAME} --test-enable --test-tags ${TEST_TAGS} --init=${ADDONS_TO_TEST} --update=${ADDONS_TO_TEST} --without-demo= --workers=0 --stop-after-init
            fi

            if [ ${APP_ENV} = 'staging' ] ; then
                # Automagically upgrade all addons and install new ones. Ideal for deployment process.
                echo odoo --config ${ODOO_RC} --database=${DB_NAME} --init=${INIT} --update=all --load=${SERVER_WIDE_MODULES} --log-level=${LOG_LEVEL} --load-language=${LOAD_LANGUAGE} --limit-time-cpu=3600 --limit-time-real=7200

                exec odoo --config ${ODOO_RC} --update=all --without-demo=all --workers=0 --limit-time-cpu=3600 --limit-time-real=7200
            fi

            if [ ${APP_ENV} = 'production' ] ; then
                # Bring up Odoo ready for production.
                echo odoo --config ${ODOO_RC} --database= --init= --update= --load=${SERVER_WIDE_MODULES} --workers=${WORKERS} --log-level=${LOG_LEVEL} --load-language= --without-demo=all --dev=

                exec odoo --config ${ODOO_RC} --database= --init= --update= --load-language= --without-demo=all --dev=
            fi
        fi
        ;;
    -*)

        wait-for-psql.py --db_host ${DB_HOST} --db_port ${DB_PORT} --db_user ${DB_USER} --db_password ${DB_PASSWORD} --timeout=30
        echo odoo --config ${ODOO_RC}
        exec odoo --config ${ODOO_RC}
        ;;
    *)

        echo "$@"
        exec "$@"
esac

exit 1
