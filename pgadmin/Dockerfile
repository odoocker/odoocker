#------------------------#
#     PGAdmin Server     #
#------------------------#
ARG PGADMIN_TAG
FROM dpage/pgadmin4:${PGADMIN_TAG}

# Receive ARGs from docker-compose.yml & convert them into ENVs
ARG PGADMIN_DEFAULT_EMAIL

ENV PGADMIN_DEFAULT_EMAIL=${PGADMIN_DEFAULT_EMAIL}

# Switch to root user
USER root

# Install bash
RUN apk add --no-cache bash jq sqlite

# Conditionally copy the private key if it exists
COPY --chown=pgadmin:root ./pgadmin/private_key /pgadmin4/private_key
# Set permissions for the private key

# Copy your script file into the Docker image
COPY --chown=pgadmin:root ./.env /
COPY ./pgadmin/start_pgadmin.sh /var/lib/pgadmin/start_pgadmin.sh

# Make the script executable
RUN chmod +x /var/lib/pgadmin/start_pgadmin.sh
# Run your script
RUN /var/lib/pgadmin/start_pgadmin.sh

# Expose the necessary port
EXPOSE 80
