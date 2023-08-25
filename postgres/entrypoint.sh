psql -p 5432 -U odoo -d postgres -c "CREATE DATABASE unaccent_template WITH TEMPLATE = template0"
psql -p 5432 -U odoo -d postgres -c "\\c unaccent_template"
psql -p 5432 -U odoo -d postgres -c "CREATE EXTENSION IF NOT EXISTS unaccent;"
