FROM postgres:15.1

RUN apt-get update && apt-get install postgresql-contrib

COPY ./entrypoint.sh /docker-entrypoint-initdb.d/entrypoint.sh