FROM postgres:15.2

# Update apt packages
RUN apt-get update && apt-get upgrade -y

#------------------------#
#    APT Dependencies    #
#------------------------#
# Unaccent extension dependencies
RUN apt-get install -y postgresql-contrib

# Copy the script to create the unaccent template
COPY ./entrypoint.sh /docker-entrypoint-initdb.d/entrypoint.sh