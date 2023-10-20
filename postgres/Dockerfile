ARG POSTGRES_TAG
FROM postgres:${POSTGRES_TAG}

#------------------------#
#    APT Dependencies    #
#------------------------#
# Update apt packages
RUN apt-get update && apt-get install -y \
    # Unaccent extension dependencies
    postgresql-contrib \
    apt-utils \
    # Clean up the apt cache to reduce the image size
    && rm -rf /var/lib/apt/lists/*

COPY --chown=postgres:postgres ./.env /

# Copy the script to create the unaccent template
COPY ./postgres/entrypoint.sh /docker-entrypoint-initdb.d/entrypoint.sh
