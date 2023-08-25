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
                echo odoo --config ${ODOO_RC} --database= --init= --update= --load=${SERVER_WIDE_MODULES} --log-handler=${LOG_HANDLER} --log-level=${LOG_LEVEL} --load-language= --workers=0 --limit-time-cpu=3600 --limit-time-real=7200

                exec odoo --config ${ODOO_RC} --database= --init= --update= --load=${SERVER_WIDE_MODULES} --log-handler=${LOG_HANDLER} --log-level=${LOG_LEVEL} --load-language= --workers=0 --limit-time-cpu=3600 --limit-time-real=7200
            fi

            if [ ${APP_ENV} = 'full' ] ; then
                echo odoo --config ${ODOO_RC} --database=${DB_NAME} --init=${INIT} --update= --load=${SERVER_WIDE_MODULES} --log-handler=${LOG_HANDLER} --log-level=${LOG_LEVEL} --load-language=${LOAD_LANGUAGE} --max-cron-threads=${MAX_CRON_THREADS} --limit-time-cpu=3600 --limit-time-real=7200 --workers=0 --without-demo=all

                exec odoo --config ${ODOO_RC} --database=${DB_NAME} --init=${INIT} --update= --load=${SERVER_WIDE_MODULES} --log-handler=${LOG_HANDLER} --log-level=${LOG_LEVEL} --load-language=${LOAD_LANGUAGE} --max-cron-threads=${MAX_CRON_THREADS} --limit-time-cpu=3600 --limit-time-real=7200 --workers=0 --without-demo=all
            fi

            if [ ${APP_ENV} = 'local' ] ; then
                # Automagically update the addons you are currently working on.
                echo odoo --config ${ODOO_RC} --database=${DB_NAME} --init=${INIT} --update=${UPDATE} --load=${SERVER_WIDE_MODULES} --log-handler=${LOG_HANDLER} --log-level=${LOG_LEVEL} --workers=${WORKERS} --dev=${DEV_MODE}

                exec odoo --config ${ODOO_RC} --database=${DB_NAME} --init=${INIT} --update=${UPDATE} --load=${SERVER_WIDE_MODULES} --log-handler=${LOG_HANDLER} --log-level=${LOG_LEVEL} --workers=${WORKERS} --dev=${DEV_MODE}
            fi

            if [ ${APP_ENV} = 'debug' ] ; then
                # Automagically update the addons you are currently working on.
                echo /usr/bin/python3 -m debugpy --listen ${DEBUG_INTERFACE}:${DEBUG_PORT} ${DEBUG_PATH} --config ${ODOO_RC} --database=${DB_NAME} --init=${INIT} --update=${UPDATE} --load=${SERVER_WIDE_MODULES} --log-handler=${LOG_HANDLER} --log-level=${LOG_LEVEL} --workers=${WORKERS} --dev=${DEV_MODE}

                exec /usr/bin/python3 -m debugpy --listen ${DEBUG_INTERFACE}:${DEBUG_PORT} ${DEBUG_PATH} --config ${ODOO_RC} --database=${DB_NAME} --init=${INIT} --update=${UPDATE} --load=${SERVER_WIDE_MODULES} --log-handler=${LOG_HANDLER} --log-level=${LOG_LEVEL} --workers=${WORKERS} --dev=${DEV_MODE}
            fi

            if [ ${APP_ENV} = 'testing' ] ; then
                # Runs the tests in a 'test_*' database for the addons you are currently working on via test tags.
                echo odoo --config ${ODOO_RC} --database=test_${DB_NAME} --test-enable --test-tags ${TEST_TAGS} --init=${ADDONS_TO_TEST} --update=${ADDONS_TO_TEST} --load=${SERVER_WIDE_MODULES} --log-handler=${LOG_HANDLER} --log-level=${LOG_LEVEL} --without-demo= --workers=0 --stop-after-init

                exec odoo --config ${ODOO_RC} --database=test_${DB_NAME} --test-enable --test-tags ${TEST_TAGS} --init=${ADDONS_TO_TEST} --update=${ADDONS_TO_TEST} --load=${SERVER_WIDE_MODULES} --log-handler=${LOG_HANDLER} --log-level=${LOG_LEVEL} --without-demo= --workers=0 --stop-after-init
            fi

            if [ ${APP_ENV} = 'staging' ] ; then
                # Automagically upgrade all addons and install new ones.
                echo odoo --config ${ODOO_RC} --database=${DB_NAME} --init=${INIT} --update=all --load=${SERVER_WIDE_MODULES} --log-handler=${LOG_HANDLER} --log-level=${LOG_LEVEL} --load-language=${LOAD_LANGUAGE} --limit-time-cpu=3600 --limit-time-real=7200 --workers=0 --without-demo=all

                exec odoo --config ${ODOO_RC} --database=${DB_NAME} --init=${INIT} --update=all --load=${SERVER_WIDE_MODULES} --log-handler=${LOG_HANDLER} --log-level=${LOG_LEVEL} --load-language=${LOAD_LANGUAGE} --limit-time-cpu=3600 --limit-time-real=7200 --workers=0 --without-demo=all
            fi

            if [ ${APP_ENV} = 'production' ] ; then
                # Bring up Odoo ready for production.
                echo odoo --config ${ODOO_RC} --database= --init= --update= --load=${SERVER_WIDE_MODULES} --workers=${WORKERS} --log-handler=${LOG_HANDLER} --log-level=${LOG_LEVEL} --load-language= --without-demo=all --dev=False

                exec odoo --config ${ODOO_RC} --database= --init= --update= --load=${SERVER_WIDE_MODULES} --workers=${WORKERS} --log-handler=${LOG_HANDLER} --log-level=${LOG_LEVEL} --load-language= --without-demo=all --dev=False
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
