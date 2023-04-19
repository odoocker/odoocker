ARG ODOO_VERSION=16.0

FROM odoo:${ODOO_VERSION}

# Switch back to root user
USER root

# Update & Upgrade
RUN apt-get update && apt-get upgrade -y

# Upgrade pip
RUN pip3 install --upgrade pip

# Set Odoo root path
ARG ROOT_PATH=/usr/lib/python3/dist-packages/odoo

#---------------#
#    Logging    #
#---------------#
# Set Log variables
ARG LOGPATH=/var/log/odoo
ARG LOGFILE=${LOGPATH}/odoo.log

# Create odoo.log file and give permissions.
RUN touch ${LOGFILE} && chown odoo:odoo -R ${LOGPATH}

#-----------------------#
#    Odoo Enterprise    #
#-----------------------#
# Install git
RUN apt-get install git -y

# Set Github Credentials
ARG GITHUB_USER=yhaelopez
ARG GITHUB_ACCESS_TOKEN=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
ARG ENTERPRISE_REPO=https://${GITHUB_USER}:${GITHUB_ACCESS_TOKEN}@github.com/odoo/enterprise.git
ARG ENTERPRISE_PATH=${ROOT_PATH}/enterprise

# Create Enterprise Path & give permissions
RUN mkdir -p ${ENTERPRISE_PATH} && chown odoo:odoo -R ${ENTERPRISE_PATH}

# Clone Enterprise Repository
RUN git clone ${ENTERPRISE_REPO} ${ROOT_PATH}/enterprise --depth 1 --branch ${ODOO_VERSION} --single-branch --no-tags

#--------------------------------#
#    Fix Deprecation Warnings    #
#--------------------------------#

#------------------------#
#    APT Dependencies    #
#------------------------#

#-----------------------#
#   PIP Dependencies    #
#-----------------------#

#-----------------------#
#       Odoo Conf       #
#-----------------------#
# Copy environment variables at /
COPY ./.env /
# Copy script to generate odoo.conf
COPY ./odoo/odoorc.sh /
# Generate odoo.conf
RUN /odoorc.sh && chown odoo:odoo ${ODOO_RC}

# Switch back to odoo user
USER odoo