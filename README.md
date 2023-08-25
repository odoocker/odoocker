# Setup
1. Clone the repository:
```
git clone git@github.com:yhaelopez/odoocker.git
```
2. Copy the `.env.example` and `docker-compose.override.local.yml`
```
cp .env.example .env && cp docker-compose.override.local.yml docker-compose.override.yml
```
3. Manually add entry to your `hosts` file as below
```
echo '127.0.0.1 erp.odoocker.test' | sudo tee -a /etc/hosts
echo '127.0.0.1 pgadmin.odoocker.test' | sudo tee -a /etc/hosts
```
- For Windows, go to `C:\Windows\System32\drivers\etc\`, and add this line:
```
127.0.0.1 erp.odoocker.test
127.0.0.1 pgadmin.odoocker.test
```

In order to understand how each environment works, take a look at `odoo/entrypoint.sh`.

**Default Master Password:** odoo

## Fresh Environment
This environment will have no database created.
The `env.example` is ready for this stage, no modifications are needed on `.env`.
1. Make sure `APP_ENV=fresh`.
2. Run
```
docker-compose up -d --build && docker-compose logs -f odoo
```
3. Navigate to the `DOMAIN` in your browser.
4. Create Database form will be displayed.
5. Create Fresh DB.
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
docker-compose up -d --build && docker-compose logs -f odoo
```
3. Navigate to the `DOMAIN` in your browser & Restore the production database
4. Stop the Odoo container:
```
docker-compose stop odoo
```
5. Set [`Local`](https://github.com/yhaelopez/odoocker#local-environment) environment.

#### If you are in a production server:

6. Run [`Staging`](https://github.com/yhaelopez/odoocker#staging-environment) environment.
7. Stop the Odoo container:
```
docker-compose stop odoo
```
8. Run the [`Production`](https://github.com/yhaelopez/odoocker#production-environment) environment.

## Full Environment
This environment will initialize a database with `DB_NAME` and install the `INSTALLED_MODULES`.
This allows us to have a fresh production database replica.
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

## Local Environment
This environment will help us install / update the specific modules we are working on.
It's recommended to use this environment after [`Fresh`](https://github.com/yhaelopez/odoocker#fresh-environment), [`Full`](https://github.com/yhaelopez/odoocker#full-environment) or [`Restore`](https://github.com/yhaelopez/odoocker#fresh-environment) environments are run.

1. Make sure `APP_ENV=local`.
2. Make sure `DB_NAME` is set.
3. Set `UPDATE=module1,module2,module3`.
4. Run:
```
docker-compose up -d --build && docker-compose logs -f odoo
```
5. Navigate to the `DOMAIN` in your browser.
6. Start coding!
7. Any change you make to your packages, run:
```
docker-compose restart odoo && docker-compose logs -f odoo
```
- If you need to change a .env variable, run:
```
docker-compose up -d --build && docker-compose logs -f odoo
```

## Debug Environment
This environment will bring up Odoo with `debugpy` library.
It's recommended to use this environment after [`Fresh`](https://github.com/yhaelopez/odoocker#fresh-environment), [`Full`](https://github.com/yhaelopez/odoocker#full-environment) or [`Restore`](https://github.com/yhaelopez/odoocker#fresh-environment) environments are run.
It works the same exact way as [`Local`](https://github.com/yhaelopez/odoocker#local-environment), since it respects any change in `.env` file.

1. Make sure `APP_ENV=debug`.
2. Make sure `DB_NAME` is set.
3. Set `UPDATE=module1,module2,module3`.
4. Run:
```
docker-compose up -d --build && docker-compose logs -f odoo
```
5. Navigate to the `DOMAIN` in your browser.
6. Mark breakpoints through the code.
7. Start VSCode Debugger
8. Start debugging!
9. Continue coding as if you were in [`Local`](https://github.com/yhaelopez/odoocker#local-environment)

## Testing Environment
This environment will help us test the modules we are developing to ensure a safe deployment.
A `test_*` database is automagically created, addons to test get installed, test are filtered and run by their tags.
Odoo will stop after running the tests.
1. Set `APP_ENV=testing`.
2. Set `ADDONS_TO_TEST=addon_1,addon_2`.
3. Set `TEST_TAGS=test_tag_1,test_tag_2` to fitler tests.
4. Run:
```
docker-compose down && docker-compose up -d --build && docker-compose logs -f odoo
```

## Staging Environment
This environment performs a full update on all installed modules to test if they all can be upgraded at once.
This also allows to install new packages through `INIT`
1. Set `APP_ENV=staging`
2. Set `DB_NAME` to the desired one.
3. Set `INIT` if there are any.
5. Run
```
git pull && docker-compose down && docker-compose pull && docker-compose build --no-cache && docker-compose up -d && docker-compose logs -f odoo
```
7. Check Odoo continues to work as expected.
8. Change environment immediatly after finish testing.

**Do not bring down & up again unless you want to perform a whole update again.**

## Production Environment
This environment has a preset of settings to work in production. Some `.env` variables won't work because are overwritten in the odoo command.

Let's imagine we are migrating a database from another server.

1. Set `APP_ENV=production`
2. Set prod `DB_NAME`.
3. Set prod `DB_PASSWORD`.
4. Set prod `ADMIN_PASSWD`.
5. Set prod `DOMAIN` (make sure DNS are pointing to your instance).
6. Run [`Restore`](https://github.com/yhaelopez/odoocker#restore-environment) environment
7. Run [`Staging`](https://github.com/yhaelopez/odoocker#staging-environment) environment.
8. Repace the `docker-compose.override.yml` with `docker-compose.override.production.yml`.
This will bring Let's Encrypt (Nginx-Proxy/Acme-Companion) container
```
cp docker-compose.override.production.yml docker-compose.override.yml
```
9. Rebuild the containers
```
docker-compose down && docker-compose up -d --build && docker-compose logs odoo
```

### Pro(d) Tips
The following tips will enhance your developing and production experience.

#### Define the following aliases:
```
alias odoo='cd odoocker'

alias hard-deploy='git pull && docker-compose down && docker-compose pull && docker-compose build --no-cache && docker-compose up -d && docker-compose logs -f odoo'

alias deploy='git pull && docker-compose down && docker-compose pull && docker-compose build && docker-compose up -d && docker-compose logs -f --tail 2000 odoo'

alias soft-deploy='git pull && docker-compose down && docker-compose up -d --build && docker-compose logs -f --tail 2000 odoo'

alias logs='docker-compose logs -f --tail 2000 odoo'
```

#### NEVER run
```
docker-compose down **-v**
```
...without having a tested backed up database

Have in mind that dropping volumes will destroy DB data, Odoo Conf & Filestore, Let's Encrypt certificates, and more!

Also, if you do this process several times in a short period of time, you may reach `Let's Encrypt` certificates limits and won't be able to generate new ones after **several hours**.

#### Colorize your branches
Add the following to `~/.bashrc`
```
# Color git branches
function parse_git_branch () {
  git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/(\1)/'
}

if [ "$color_prompt" = yes ]; then
    #PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
    # Color git branches
    PS1="${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w \[\033[01;31m\]\$(parse_git_branch)\[\033[00m\]\$ "
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
fi
unset color_prompt force_color_prompt
```

#### Creating new Odoo Addons
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

#### Using Odoo Shell
1. Log into the odoo container
```
docker-compose exec odoo bash
```
2. Start Odoo shell running:
```
odoo shell --http-port=8071
```

# DB Connection
- Any other Postgres Database Manager con connect to the DB using `.env` credentials.

## PgAdmin Container
- This project comes with a PgAdmin container which is loaded only in `docker-compose.override.pgadmin.yml`.
In order to manage DB we provide a pgAdmin container.
In order to bring this up, simply run:
```
docker-compose -f docker-compose.yml -f docker-compose.override.yml -f docker-compose.pgadmin.yml up -d --build
```
And to turn down
```
docker-compose -f docker-compose.yml -f docker-compose.override.yml -f docker-compose.pgadmin.yml down
```

If your instance has pgAdmin, make sure you adapt this to your aliases.

# Deployment Process
Note: the deployment process is easier & faster with aliases.

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
or with alias:
```
odoo
```
5. Pull the latest `main` branch changes.
```
git pull origin main
```
6. Set [`Staging`](https://github.com/yhaelopez/odoocker#staging-environment) environment
7. Set `APP_ENV=production`
8. Take down the containers, pull the latest images from docker hub, and rebuild the containers.
```
docker-compose down && docker-compose up -d --build && docker-compose logs -f odoo
```
