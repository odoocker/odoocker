# Setup
1. Clone the repository:
```
git clone git@github.com:yhaelopez/odoocker.git
```
2. Copy the `.env.example` and `docker-compose.override.local.yml`
```
cp .env.example .env && cp docker-compose.override.local.yml docker-compose.override.yml
```
3. Manually add entry to your `hosts` file as below (Local)
```
echo '127.0.0.1 erp.odoo.test' | sudo tee -a /etc/hosts
echo '127.0.0.1 pgadmin.odoo.test' | sudo tee -a /etc/hosts
```
- For Windows, go to `C:\Windows\System32\drivers\etc\`, and add this line:
```
127.0.0.1 erp.odoo.test
127.0.0.1 pgadmin.odoo.test
```

In order to understand how each environment works, take a look at `odoo/entrypoint.sh`.

```
Master Password: odoo
```

## Fresh Environment
This environment will have no database created.
The `env.example` is ready for this stage, no modifications are needed on `.env`.
1. Make sure `APP_ENV=fresh`.
2. Run
```
docker-compose up --build -d && docker-compose logs -f odoo
```
3. Navigate to the `DOMAIN` in your browser.
4. Create Database form will be displayed.
5. Create Fresh DB.
6. Stop the Odoo container:
```
docker-compose stop odoo
```
7. Set [`Local`](https://github.com/yhaelopez/odoocker#local-environment) environment.

## Full Environment
This environment will initialize a database with `DB_NAME` and install the `INSTALLED_MODULES`.
This allows us to have a fresh database will all modules installed in production.
1. Make sure `APP_ENV=full`.
2. Make sure `DB_NAME=odoo` or whatever name you want.
3. Run
```
docker-compose up -d --build && docker-compose logs -f odoo
```
4. Navigate to the `DOMAIN` in your browser.
5. Log in using the default credentials
```
Email: admin
Password: admin
```
6. Stop the Odoo container:
```
docker-compose stop odoo
```
7. Set [`Local`](https://github.com/yhaelopez/odoocker#local-environment) environment.

## Restore Environment
This environment will have no database created and it's ready to make an import on the production database.
1. Set `APP_ENV=restore`.
2. Run:
```
docker-compose up --build -d && docker-compose logs -f odoo
```
3. Navigate to the `DOMAIN` in your browser & Restore the production database
4. Stop the Odoo container:
```
docker-compose stop odoo
```
5. Set [`Local`](https://github.com/yhaelopez/odoocker#local-environment) environment.

--- If you are in a production server:

6. Set [`Staging`](https://github.com/yhaelopez/odoocker#staging-environment) environment.
7. Stop the Odoo container:
```
docker-compose stop odoo
```
8. Run the [`Production`](https://github.com/yhaelopez/odoocker#production-environment) environment.

## Local Environment
This environment will help us install / update the specific modules we are working on.
It's recommended to use this environment after [`Fresh`](https://github.com/yhaelopez/odoocker#fresh-environment), [`Full`](https://github.com/yhaelopez/odoocker#full-environment) or [`Restore`](https://github.com/yhaelopez/odoocker#fresh-environment) environments are run.

1. Make sure `APP_ENV=local`.
2. Make sure `DB_NAME` is set.
3. Set `ADDONS_TO_UPDATE=module1,module2,module3`.
4. Run:
```
docker-compose up --build -d odoo && docker-compose logs -f odoo
```
5. Navigate to the `DOMAIN` in your browser.
6. Start coding!
7. Any change you make to your packages, run:
```
docker-compose restart odoo && docker-compose logs -f odoo
```
- If you think your package is not being updated, run:
```
docker-compose up --build -d odoo && docker-compose logs -f odoo
```
8. Any time you add a new addon to `ADDONS_TO_UPDATE` re-run last step

## Additional Local Help

### Creating new Odoo Addons
1. Log into the odoo container
```
docker-compose exec -u root odoo
```
2. Navigate to custom addons folder inside the container
```
cd /usr/lib/python3/dist-packages/odoo/custom-addons
```
3. Create new addons running:
```
odoo scaffold <addon_name>
```
- The new addon will be available in the `odoo/custom_addons` folder in this project.

### Using Odoo Shell
1. Log into the odoo container
```
docker-compose exec odoo bash
```
2. Start Odoo shell running:
```
odoo shell --http-port=8071
```

5. Connect to database through any Postgres Database Manager using `localhost` and the `.env` credentials

## Testing Environment (Work in progress...) DO NOT USE
This environment will help us test all modules to ensure a safe deployment.
It's recommneded to use this environment after importing production database in a Fresh environment.
1. Replace `docker-compose.override.yml` with `docker-compose.override.testing.yml`
This will set up the Odoo container will all the packages installed needed to run the tests.
```
cp docker-compose.override.testing.yml docker-compose.override.yml
```
2. Clone Production Database as `test_${DB_NAME}`.
3. Set `APP_ENV=testing`.
4. Set `DB_NAME=test_${DB_NAME}` or whatever db you set before.
5. Run:
```
docker-compose down && docker-compose pull && docker-compose build --no-cache && docker-compose up -d && docker-compose logs -f odoo
```

## Staging
This environment allows us to perfom a full update on all installed modules to test if they all can be upgraded at once.
This also allows to install new packages through `ADDONS_TO_INSTALL`
1. Set `APP_ENV=staging`
2. Set `DB_NAME` to the desired one.
3. Set `ADDONS_TO_INSTALL` if there are any.
5. Run
```
git pull && docker-compose down && docker-compose pull && docker-compose build --no-cache && docker-compose up -d && docker-compose logs -f odoo
```
7. Check Odoo continues to work as expected.
8. Change environment immediatly after finish testing.

**Do not bring down & up again unless you want to perform the whole update again.**

# Production
1. Set `APP_ENV=production`
2. Set prod `DB_NAME`.
3. Set prod `DB_PASSWORD`.
4. Set prod `ADMIN_PASSWD`.
5. Set prod `DOMAIN`.
6. Setup `Fresh` environment
7. Setup `Staging` environment.
8. Repace the `docker-compose.override.yml` with the production one.
This will bring Let's Encrypt (Nginx-Proxy/Acme-Companion) container
```
cp docker-compose.override.production.yml docker-compose.override.yml
```
9. Rebuild the containers
```
docker-compose down && docker-compose up -d --build && docker-compose logs odoo
```

## Deployment
1. Backup the production Databases from `/web/database/manager`.
2. Run
```
sudo apt update && sudo apt upgrade -y
```
- If packages are kept, install them
```
sudo apt install <kept packages>
```
3. Restart the server
```
sudo reboot
```
- Make sure there are no more upgrades or possible kept packages
```
sudo apt update && sudo apt upgrade -y
```
4. Go to the project folder in /home/ubuntu or (~)
```
cd ~/odoocker
```
5. Pull the latest `main` branch changes.
```
git pull origin main
```
6. Set Staging environment
7. Make sure everything continues to work as expected.
8. Set `APP_ENV=production`
9. Take down the containers, pull the latest images from docker hub, and rebuild the containers.
```
docker-compose down && docker-compose pull && docker-compose build --no-cache && docker-compose up -d && docker-compose logs -f odoo
```