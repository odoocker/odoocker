#------------------------#
#     Odoo Community     #
#------------------------#
ARG ODOO_TAG
FROM odoo:${ODOO_TAG}

# Switch to root user
USER root

# Receive ARGs from docker-compose.yml & convert them into ENVs
ARG ODOO_TAG
ARG ROOT_PATH
ARG LOG_PATH
ARG GITHUB_USER
ARG GITHUB_ACCESS_TOKEN
ARG ENTERPRISE_ADDONS
ARG THIRD_PARTY_ADDONS
ARG ODOO_RC

ENV ODOO_TAG=${ODOO_TAG} \
    LOG_PATH=${LOG_PATH} \
    GITHUB_USER=${GITHUB_USER} \
    GITHUB_ACCESS_TOKEN=${GITHUB_ACCESS_TOKEN} \
    ENTERPRISE_ADDONS=${ENTERPRISE_ADDONS} \
    THIRD_PARTY_ADDONS=${THIRD_PARTY_ADDONS} \
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

#---------------------#
#   PIP Dependecies   #
#---------------------#
# Upgrade pip
RUN pip3 install --upgrade pip

# Copy & Install PIP requirements
COPY --chown=odoo:odoo ./odoo/requirements.txt /tmp/requirements.txt

RUN python3 -m pip install -r /tmp/requirements.txt && \
    rm /tmp/requirements.txt

#-----------------------#
#    Odoo Enterprise    #
#-----------------------#

# Create Enterprise addons directory
RUN mkdir -p ${ENTERPRISE_ADDONS} && \
    chown odoo:odoo -R ${ENTERPRISE_ADDONS}

# Clone Enterprise addons if user and token are present
RUN if [ -n "$GITHUB_USER" ] && [ -n "$GITHUB_ACCESS_TOKEN" ]; then \
        git clone https://${GITHUB_USER}:${GITHUB_ACCESS_TOKEN}@github.com/odoo/enterprise.git ${ENTERPRISE_ADDONS} --depth 1 --branch ${ODOO_TAG} --single-branch --no-tags; \
    fi

#-------------------------#
#    Odoo Extra Addons    #
#-------------------------#

RUN mkdir -p ${THIRD_PARTY_ADDONS} && chown odoo:odoo -R ${THIRD_PARTY_ADDONS}

COPY --chown=odoo:odoo ./odoo/fix-manifest.py /
COPY --chown=odoo:odoo ./odoo/third-party-addons.sh /
RUN /third-party-addons.sh

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
COPY --chown=odoo:odoo ./odoo/odoo.conf /
COPY --chown=odoo:odoo ./odoo/odoorc.sh /

# Generate odoo.conf
RUN /odoorc.sh && chown odoo:odoo ${ODOO_RC}

# Switch back to odoo user
USER odoo
