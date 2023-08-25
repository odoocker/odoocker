#------------------------#
#     Odoo Community     #
#------------------------#
ARG ODOO_VERSION
FROM odoo:${ODOO_VERSION}

# Switch to root user
USER root

# Receive ARGs from docker-compose.yml & convert them into ENVs
ARG ROOT_PATH
ARG LOG_PATH
ARG GITHUB_USER
ARG GITHUB_ACCESS_TOKEN
ARG ENTERPRISE_REPO
ARG ENTERPRISE_ADDONS
ARG ODOO_RC

ENV ODOO_VERSION=${ODOO_VERSION} \
    LOG_PATH=${LOG_PATH} \
    GITHUB_USER=${GITHUB_USER} \
    GITHUB_ACCESS_TOKEN=${GITHUB_ACCESS_TOKEN} \
    ENTERPRISE_REPO=${ENTERPRISE_REPO} \
    ENTERPRISE_ADDONS=${ENTERPRISE_ADDONS} \
    ODOO_RC=${ODOO_RC}

#------------------------#
#    APT Dependencies    #
#------------------------#
RUN apt-get update && apt-get install -y \
    apt-utils \
    git \
    git-man \
    less \
    libcbor0 \
    libcurl3-gnutls \
    libedit2 \
    liberror-perl \
    libxmuu1 \
    openssh-client \
    patch \
    xauth \
    # Clean up the apt cache to reduce the image size
    && rm -rf /var/lib/apt/lists/*

#-----------------------#
#    Odoo Enterprise    #
#-----------------------#

# Create Enterprise addons directory
RUN mkdir -p ${ENTERPRISE_ADDONS} && \
    chown odoo:odoo -R ${ENTERPRISE_ADDONS}

# Clone Enterprise addons if user and token are present
RUN if [ -n "$GITHUB_USER" ] && [ -n "$GITHUB_ACCESS_TOKEN" ]; then \
        git clone ${ENTERPRISE_REPO} ${ENTERPRISE_ADDONS} --depth 1 --branch ${ODOO_VERSION} --single-branch --no-tags; \
    fi

#---------------------#
#   PIP Dependecies   #
#---------------------#
# Upgrade pip
RUN pip3 install --upgrade pip

# Copy & Install PIP requirements
COPY --chown=odoo:odoo ./odoo/requirements.txt /tmp/requirements.txt

RUN python3 -m pip install --upgrade -r /tmp/requirements.txt && \
    rm /tmp/requirements.txt

#---------------------#
#       Logging       #
#---------------------#

# Create odoo.log file
RUN touch ${LOG_PATH} && chown odoo:odoo ${LOG_PATH}

#-----------------------#
#       Odoo Conf       #
#-----------------------#

# Copy environment variables & script to generate odoo.conf
COPY --chown=odoo:odoo ./.env /
COPY --chown=odoo:odoo ./odoo/odoorc.sh /

# Generate odoo.conf
RUN /odoorc.sh && chown odoo:odoo ${ODOO_RC}

# Switch back to odoo user
USER odoo
