#!/bin/bash

set -e

# Define default values for environment variables
set -a
source /.env
set +a

declare -A defaults
defaults=(
    [ADMIN_PASSWD]=${ADMIN_PASSWD}
    [CSV_INTERNAL_SEP]=${CSV_INTERNAL_SEP}
    [PUBLISHER_WARRANTY_URL]=${PUBLISHER_WARRANTY_URL}
    [ROOT_PATH]=${ROOT_PATH}
    [REPORTGZ]=${REPORTGZ}
    [WEBSOCKET_KEEP_ALIVE_TIMEOUT]=${WEBSOCKET_KEEP_ALIVE_TIMEOUT}
    [WEBSOCKET_RATE_LIMIT_BURST]=${WEBSOCKET_RATE_LIMIT_BURST}
    [WEBSOCKET_RATE_LIMIT_DELAY]=${WEBSOCKET_RATE_LIMIT_DELAY}

    [ODOO_RC]=${ODOO_RC}
    [SAVE]=${SAVE}
    [INIT]=${INIT}
    [UPDATE]=${UPDATE}
    [DEMO]=${DEMO}
    [WITHOUT_DEMO]=${WITHOUT_DEMO}
    [IMPORT_PARTIAL]=${IMPORT_PARTIAL}
    [PIDFILE]=${PIDFILE}
    [ADDONS_PATH]=${ADDONS_PATH}
    [UPGRADE_PATH]=${UPGRADE_PATH}
    [SERVER_WIDE_MODULES]=${SERVER_WIDE_MODULES}
    [DATA_DIR]=${DATA_DIR}

    [HTTP_INTERFACE]=${HTTP_INTERFACE}
    [HTTP_PORT]=${HTTP_PORT}
    [XMLRPCS_INTERFACE]=${XMLRPCS_INTERFACE}
    [XMLRPCS_PORT]=${XMLRPCS_PORT}
    [GEVENT_PORT]=${GEVENT_PORT}
    [HTTP_ENABLE]=${HTTP_ENABLE}
    [XMLRPCS]=${XMLRPCS}
    [PROXY_MODE]=${PROXY_MODE}
    [X_SENDFILE]=${X_SENDFILE}

    [DBFILTER]=${DBFILTER}

    [TEST_FILE]=${TEST_FILE}
    [TEST_ENABLE]=${TEST_ENABLE}
    [TEST_TAGS]=${TEST_TAGS}
    [SCREENCASTS]=${SCREENCASTS}
    [SCREENSHOTS]=${SCREENSHOTS}

    [LOGFILE]=${LOGFILE}
    [SYSLOG]=${SYSLOG}
    [LOG_HANDLER]=${LOG_HANDLER}
    [LOG_DB]=${LOG_DB}
    [LOG_DB_LEVEL]=${LOG_DB_LEVEL}
    [LOG_LEVEL]=${LOG_LEVEL}

    [EMAIL_FROM]=${EMAIL_FROM}
    [FROM_FILTER]=${FROM_FILTER}
    [SMTP_SERVER]=${SMTP_SERVER}
    [SMTP_PORT]=${SMTP_PORT}
    [SMTP_SSL]=${SMTP_SSL}
    [SMTP_USER]=${SMTP_USER}
    [SMTP_PASSWORD]=${SMTP_PASSWORD}
    [SMTP_SSL_CERTIFICATE_FILENAME]=${SMTP_SSL_CERTIFICATE_FILENAME}
    [SMTP_SSL_PRIVATE_KEY_FILENAME]=${SMTP_SSL_PRIVATE_KEY_FILENAME}

    [DB_NAME]=${DB_NAME}
    [DB_USER]=${DB_USER}
    [DB_PASSWORD]=${DB_PASSWORD}
    [PG_PATH]=${PG_PATH}
    [DB_HOST]=${DB_HOST}
    [DB_PORT]=${DB_PORT}
    [DB_SSLMODE]=${DB_SSLMODE}
    [DB_MAXCONN]=${DB_MAXCONN}
    [DB_TEMPLATE]=${DB_TEMPLATE}

    [LOAD_LANGUAGE]=${LOAD_LANGUAGE}
    [LANGUAGE]=${LANGUAGE}
    [TRANSLATE_OUT]=${TRANSLATE_OUT}
    [TRANSLATE_IN]=${TRANSLATE_IN}
    [OVERWRITE_EXISTING_TRANSLATIONS]=${OVERWRITE_EXISTING_TRANSLATIONS}
    [TRANSLATE_MODULES]=${TRANSLATE_MODULES}

    [LIST_DB]=${LIST_DB}

    [DEV_MODE]=${DEV_MODE}
    [SHELL_INTERFACE]=${SHELL_INTERFACE}
    [STOP_AFTER_INIT]=${STOP_AFTER_INIT}
    [OSV_MEMORY_COUNT_LIMIT]=${OSV_MEMORY_COUNT_LIMIT}
    [TRANSIENT_AGE_LIMIT]=${TRANSIENT_AGE_LIMIT}
    [MAX_CRON_THREADS]=${MAX_CRON_THREADS}
    [UNACCENT]=${UNACCENT}
    [GEOIP_DATABASE]=${GEOIP_DATABASE}
    [WORKERS]=${WORKERS}
    [LIMIT_MEMORY_SOFT]=${LIMIT_MEMORY_SOFT}
    [LIMIT_MEMORY_HARD]=${LIMIT_MEMORY_HARD}
    [LIMIT_TIME_CPU]=${LIMIT_TIME_CPU}
    [LIMIT_TIME_REAL]=${LIMIT_TIME_REAL}
    [LIMIT_TIME_REAL_CRON]=${LIMIT_TIME_REAL_CRON}
    [LIMIT_REQUEST]=${LIMIT_REQUEST}

    [ODOO_SESSION_REDIS]=${ODOO_SESSION_REDIS}
    [ODOO_SESSION_REDIS_HOST]=${ODOO_SESSION_REDIS_HOST}
    [ODOO_SESSION_REDIS_PORT]=${ODOO_SESSION_REDIS_PORT}
    [ODOO_SESSION_REDIS_PASSWORD]=${ODOO_SESSION_REDIS_PASSWORD}
    [ODOO_SESSION_REDIS_URL]=${ODOO_SESSION_REDIS_URL}
    [ODOO_SESSION_REDIS_PREFIX]=${ODOO_SESSION_REDIS_PREFIX}
    [ODOO_SESSION_REDIS_EXPIRATION]=${ODOO_SESSION_REDIS_EXPIRATION}
    [ODOO_SESSION_REDIS_EXPIRATION_ANONYMOUS]=${ODOO_SESSION_REDIS_EXPIRATION_ANONYMOUS}

    [DISABLE_ATTACHMENT_STORAGE]=${DISABLE_ATTACHMENT_STORAGE}
    [AWS_HOST]=${AWS_HOST}
    [AWS_REGION]=${AWS_REGION}
    [AWS_ACCESS_KEY_ID]=${AWS_ACCESS_KEY_ID}
    [AWS_SECRET_ACCESS_KEY]=${AWS_SECRET_ACCESS_KEY}
    [AWS_BUCKETNAME]=${AWS_BUCKETNAME}
)

# Define the template
template=$(cat << EOF
[options]
;------------------------------------------;
; Options not exposed on the command line. ;
;------------------------------------------;

admin_passwd = {ADMIN_PASSWD}
csv_internal_sep = {CSV_INTERNAL_SEP}
publisher_warranty_url = {PUBLISHER_WARRANTY_URL}
root_path = {ROOT_PATH}
reportgz = {REPORTGZ}
websocket_keep_alive_timeout = {WEBSOCKET_KEEP_ALIVE_TIMEOUT}
websocket_rate_limit_burst = {WEBSOCKET_RATE_LIMIT_BURST}
websocket_rate_limit_delay = {WEBSOCKET_RATE_LIMIT_DELAY}

;-----------------------;
; Server startup config ;
;-----------------------;
; --config | -c
config = {ODOO_RC}

; --save
save = {SAVE}

; --init | -i
init = {INIT}

; --update | -u
update = {UPDATE}

; --without-demo
demo = {DEMO}
without_demo = {WITHOUT_DEMO}

; --import-partial
import_partial = {IMPORT_PARTIAL}

; --pidfile
pidfile = {PIDFILE}

; --addons-path
addons_path = {ADDONS_PATH}

; --upgrade-path
upgrade_path = {UPGRADE_PATH}

; --load
server_wide_modules = {SERVER_WIDE_MODULES}

; --data-dir
data_dir = {DATA_DIR}

;------;
; HTTP ;
;------;
; --http-interface | --xmlrpc-interface
http_interface = {HTTP_INTERFACE}

; --http-port | -p | --xmlrpc-port
http_port = {HTTP_PORT}

; --xmlrpcs-interface
xmlrpcs_interface = {XMLRPCS_INTERFACE}

; --xmlrpcs-port
xmlrpcs_port = {XMLRPCS_PORT}

; --gevent-port | --longpolling_port (deprecated)
gevent_port = {GEVENT_PORT}

; --no-http | --no-xmlrpc
http_enable = {HTTP_ENABLE}

; --no-xmlrpcs
xmlrpcs = {XMLRPCS}

; --proxy-mode
proxy_mode = {PROXY_MODE}

; --x-sendfile
x_sendfile = {X_SENDFILE}

;---------------;
; Testing Group ;
;---------------;
; --test-file
test_file = {TEST_FILE}

; --test-enable
test_enable = {TEST_ENABLE}

; --test-tags
test_tags = {TEST_FILE}

; --screencasts
screencasts = {SCREENCASTS}

; --screenshots
screenshots = {SCREENSHOTS}

;---------------;
; Logging Group ;
;---------------;
; --logfile
logfile = {LOGFILE}

; --syslog
syslog = {SYSLOG}

; --log-handler | --log-web (--log-handler=odoo.http:DEBUG) | --log-sql (--log-handler=odoo.sql_db:DEBUG)
log_handler = {LOG_HANDLER}

; --log-db
log_db = {LOG_DB}

; --log-db-level
log_db_level = {LOG_DB_LEVEL}

; --log-level
log_level = {LOG_LEVEL}

;------------;
; SMTP Group ;
;------------;
; --email-from
email_from = {EMAIL_FROM}

; --from-filter
from_filter = {FROM_FILTER}

; --smtp
smtp_server = {SMTP_SERVER}

; --smtp-port
smtp_port = {SMTP_PORT}

; --smtp-ssl
smtp_ssl = {SMTP_SSL}

; --smtp-user
smtp_user = {SMTP_USER}

; --smtp-password
smtp_password = {SMTP_PASSWORD}

; --smtp-ssl-certificate-filename
smtp_ssl_certificate_filename = {SMTP_SSL_CERTIFICATE_FILENAME}

; --smtp-ssl-private-key-filename
smtp_ssl_private_key_filename = {SMTP_SSL_PRIVATE_KEY_FILENAME}

;----------;
; DB Group ;
;----------;
; --database | -d
db_name = {DB_NAME}

; --db_user | -r
db_user = {DB_USER}

; --db_password | -w
db_password = {DB_PASSWORD}

; --pg_path
pg_path = {PG_PATH}

; --db_host
db_host = {DB_HOST}

; --db_port
db_port = {DB_PORT}

; --db_sslmode
db_sslmode = {DB_SSLMODE}

; --db_maxconn
db_maxconn = {DB_MAXCONN}

; --db-template
db_template = {DB_TEMPLATE}

;------------------------------;
; Internationalisation options ;
;------------------------------;
; --load-language
load_language = {LOAD_LANGUAGE}

; --language
language = {LANGUAGE}

; --i18n-export
translate_out = {TRANSLATE_OUT}

; --i18n-import
translate_in = {TRANSLATE_IN}

; --i18n-overwrite
overwrite_existing_translations = {OVERWRITE_EXISTING_TRANSLATIONS}

; --modules 
translate_modules = {TRANSLATE_MODULES}

;----------;
; Security ;
;----------;
; --no-database-list
list_db = {LIST_DB}

;-----;
; WEB ;
;-----;
; --db-filter
dbfilter = {DBFILTER}

;------------------;
; Advanced options ;
;------------------;
; --dev
dev_mode = {DEV_MODE}

; --shell-interface
shell_interface = {SHELL_INTERFACE}

; --stop-after-init
stop_after_init = {STOP_AFTER_INIT}

; --osv-memory-count-limit
osv_memory_count_limit = {OSV_MEMORY_COUNT_LIMIT}

; --transient-age-limit | --osv-memory-age-limit (deprecated)
transient_age_limit = {TRANSIENT_AGE_LIMIT}

; --max-cron-threads
max_cron_threads = {MAX_CRON_THREADS}

; --unaccent
unaccent = {UNACCENT}

; --geoip-db
geoip_database = {GEOIP_DATABASE}

; --workers
workers = {WORKERS}

; --limit-memory-soft
limit_memory_soft = {LIMIT_MEMORY_SOFT}

; --limit-memory-hard
limit_memory_hard = {LIMIT_MEMORY_HARD}

; --limit-time-cpu
limit_time_cpu = {LIMIT_TIME_CPU}

; --limit-time-real
limit_time_real = {LIMIT_TIME_REAL}

; --limit-time-real-cron
limit_time_real_cron = {LIMIT_TIME_REAL_CRON}

; --limit-request
limit_request = {LIMIT_REQUEST}

;-------------;
;    Redis    ;
;-------------;
; has to be 1 or true
ODOO_SESSION_REDIS = {ODOO_SESSION_REDIS}

; is the redis hostname (default is localhost)
ODOO_SESSION_REDIS_HOST = {ODOO_SESSION_REDIS_HOST}

; is the redis port (default is 6379)
ODOO_SESSION_REDIS_PORT = {ODOO_SESSION_REDIS_PORT}

; is the password for the AUTH command (optional)
ODOO_SESSION_REDIS_PASSWORD = {ODOO_SESSION_REDIS_PASSWORD}

; is an alternative way to define the Redis server address. It's the preferred way when you're using the rediss:// protocol.
ODOO_SESSION_REDIS_URL = {ODOO_SESSION_REDIS_URL}

; is the prefix for the session keys (optional)
ODOO_SESSION_REDIS_PREFIX = {ODOO_SESSION_REDIS_PREFIX}

; is the time in seconds before expiration of the sessions (default is 7 days)
ODOO_SESSION_REDIS_EXPIRATION = {ODOO_SESSION_REDIS_EXPIRATION}

; the time in seconds before expiration of the anonymous sessions (default is 3 hours)
ODOO_SESSION_REDIS_EXPIRATION_ANONYMOUS = {ODOO_SESSION_REDIS_EXPIRATION_ANONYMOUS}

EOF
)

# Override defaults with values from environment variables
for key in "${!defaults[@]}"; do
    if [[ ! ${defaults[$key]} =~ ^\{.*\}$ ]]; then
        value=${!key:-${defaults[$key]}}
        template="${template//\{$key\}/$value}"
    fi
done

# Store the result to the odoo.conf file
echo "$template" > ${ODOO_RC}
