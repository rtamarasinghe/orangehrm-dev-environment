# OrangeHRM Development Environment
[![Docker Automated](https://img.shields.io/docker/automated/orangehrm/orangehrm-environment-images.svg)](https://hub.docker.com/r/orangehrm/orangehrm-environment-images/) [![Docker Status](https://img.shields.io/docker/build/orangehrm/orangehrm-environment-images.svg)](https://hub.docker.com/r/orangehrm/orangehrm-environment-images/) [![Docker Pulls](https://img.shields.io/docker/pulls/orangehrm/orangehrm-environment-images.svg)](https://hub.docker.com/r/orangehrm/orangehrm-environment-images/) [![Build Status](https://travis-ci.org/orangehrm/orangehrm-dev-environment.svg?branch=master)](https://travis-ci.org/orangehrm/orangehrm-dev-environment) [![BCH compliance](https://bettercodehub.com/edge/badge/orangehrm/orangehrm-dev-environment?branch=master)](https://bettercodehub.com/)

## Introduction
orangehrm-dev-environment is a dockerized development environment for [OrangeHRM](https://www.orangehrm.com/). This dev environment mainly contains three layers as follows,

- Proxy Layer 
- Web Layer
- Database Layer

Configurations in each layer have been added according to the OrangeHRM application requirements.


## Prerequisites
- Docker engine installed.([Get docker](https://docs.docker.com/engine/installation/))
- Minimum docker version 17.3
- Minimum docker-compose version 1.12. ([Get docker compose](https://docs.docker.com/compose/install/))

## Architecture
![OrangeHRM Dev Environment Architecture](./utils/doc-helpers/architecture_diagram.png)

## How to use ?

The Dev environment has been configured to use **443** port as the default web port. So make sure that the 443 port of your host machine is been used by none of the other services (eg:- apache, tomcat, nginx, etc). 
##### Installation

1. Download the zip
2. Extract the zip anywhere you want
3. run the command `docker-compose up -d`. This will up the basic OrangeHRM dev environment (PHP 5.6, PHP 7.1, PHP 7.2, nginx, phpmyadmin, RabbitMQ, MySQL 5.5 and MariaDB 10.2 containers).
4. For a customized docker development environment, See the section "How to use custom containers?".

##### Host an instance
After the installation add below URLs to your /etc/hosts file.
- phpmyadmin.orangehrmdev.com
- rabbitmq.orangehrmdev.com

###### Enterprise Hosting
- You can **NAME** your instance directory as you like (Please do not use **SPACES**)
- Document Root: /var/www/html/OHRMStandalone/TEST
- Use different environments 
  - web56: **NAME**.test-web56.orangehrmdev.com
  - web71: **NAME**.test-web71.orangehrmdev.com
  - web72: **NAME**.test-web72.orangehrmdev.com
  - web73: **NAME**.test-web73.orangehrmdev.com
  
###### Opensource Hosting
- You can **NAME** your instance directory as you like (Please do not use **SPACES**)
- Document Root: /var/www/html/OHRMStandalone/OPENSOURCE
- Use different environments 
  - web56: **NAME**.os-web56.orangehrmdev.com
  - web71: **NAME**.os-web71.orangehrmdev.com
  - web72: **NAME**.os-web72.orangehrmdev.com
  - web73: **NAME**.os-web73.orangehrmdev.com

Replace the **NAME** with any name you want for your instance.


## Containers

| Container Name   | Service Name in docker-compose.yml | Description    | IP Address | Ports (Inside the Container) | Ports (Host Machine)|
|------------------|------------------------------------|----------------|------------|------------------------------|---------------------|
| nginx            | nginx                              | PHP 5.6        | 10.5.2.1   | 443                          | 443                 |
| dev_web_56       | web56                              | PHP 5.6        | 10.5.0.56  | 443                          | -                   |
| dev_web_71       | web71                              | PHP 7.1        | 10.5.0.71  | 443                          | -                   |
| dev_web_72       | web72                              | PHP 7.2        | 10.5.0.72  | 443                          | -                   |
| dev_web_73       | web73                              | PHP 7.3        | 10.5.0.73  | 443                          | -                   |
| dev_web_74       | web74                              | PHP 7.4        | 10.5.0.74  | 443                          | -                   |
| dev_web_74_rh    | web74rh                            | PHP 7.4        | 10.5.0.174 | 443                          | -                   |
| dev_mysql_57     | db57                               | MySQL 5.7      | 10.5.1.57  | 3306                         | -                   |
| dev_mariadb_102  | db102                              | MariaDB 10.2   | 10.5.1.102 | 3306                         | -                   |
| dev_mariadb_10114| db10114                            | MariaDB 10.11.4| 10.5.1.122 | 3306                         | -                   |
| dev_mariadb_10117| db10117                            | MariaDB 10.11.7| 10.5.1.117 | 3306                         | -                   |
| dev_phpmyadmin   | phpmyadmin                         | phpMyAdmin     | 10.5.2.2   | 80                           | -                   |
| dev_rabbitmq     | rabbitmq                           | RabbitMQ 3.6   | 10.5.2.3   | 15671,5671                   | 15671               |
| dev_saml         | saml                               | SimpleSAMLphp 2.4.1 | 10.5.2.7 | 80                        | -                   |

## How to add custom PHP configurations
- Add custom PHP configurations to the file **./config/<WEB_CONTAINER>/php/custom_php.ini**. And then reload the apache service (inside the relevant container). **WEB_CONTAINER** can be web71, web72, web56 ,etc.

## How to run composer update - inside a web container
Use following command if you want to run composer install/update

`php -d allow_url_fopen=on /usr/local/bin/composer install`


## How to use custom containers?
- Compose files for custom containers have been located under ./custom-compose directory. Run `php env-start.php` and select the "Custom Environment" option. Then select the containers you need as you wish (Use **ARROW_KEYS** to move up and down and press **SPACE** to do the selection. And press **ENTER** to continue.).
 
- Available custom containers
   - db55 - MySQL 5.5
   - db56 - MySQL 5.6
   - ldap - openldap and phpldapadmin
   - mariadb103 - MariaDB 10.3
   - mongodb - mongo DB Database
   - oracle11 - Oracle 11 Database
   - ubuntuweb71 - Ubuntu 18.04 PHP 7.1 container
   - web 54 - CentOS 7 PHP 5.4 container
   - web 70 - CentOS 7 PHP 7.0 container
   - web 74 - CentOS 7 PHP 7.4 container
   - web 74 rh - RedHat 8 PHP 7.4 container
   - xhgui - XhGUI profiling tool
  
- Moving from custom version to basic version -  `docker-compose up -d --remove-orphans`

## SAML test container

`dev_saml` is an opt-in SimpleSAMLphp 2.4.1 container at `https://saml.test`, for testing SAML logins against any enterprise tree under `html/OHRMStandalone/TEST` (`<tree>.test-webubuntu83.orangehrmdev.com`). It plays both sides:

- **Container as IdP, tree as SP** (the usual customer setup, like Okta). The tree's login page shows a SAML button. The test IdP asks for a username only, with no password, and asserts whatever you type. A username the tree doesn't have tests the tree's failure path.
- **Container as SP, tree as IdP.** You log in at the tree, and the container shows what the tree sent.

Both directions work SP-initiated and IdP-initiated, and several trees can be linked at once. `saml.test` is a different site from the trees, so the browser applies the same cookie rules as with a real external IdP. `docker-compose up -d` never starts `dev_saml`, and nginx keeps serving the trees while it is down.

### Commands

| Command | What it does |
|---|---|
| `ohrm saml up` | Sets up whatever is missing, then builds the image if needed and starts `dev_saml` alone. |
| `ohrm saml down` | Stops and removes `dev_saml`. Keys, certificate, nginx block and linked trees stay. |
| `ohrm saml status` | Whether `dev_saml` runs, what `https://saml.test/` answers, and one line per linked tree: `<tree>  ok`, or `<tree>  missing: …`. |
| `ohrm saml link <tree>` | Sets the tree's `domain.name` to its host, creates the tree's IdP key and certificate if they are missing (listed in the tree's `.git/info/exclude`), adds an IdP and an SP provider row named `SAML test container`, registers the tree with the container, and clears the tree's cache. |
| `ohrm saml unlink <tree>` | Puts the tree back as `link` found it: `domain.name`, files, exclude lines and provider rows. |

`ohrm` hands `saml` to `utils/ohrm-saml.sh`; `ohrm saml --help` has the details. `link` needs `up` to have run once, and `link` and `unlink` both work while `dev_saml` is down.

### First run

The first `ohrm saml up` generates the container's signing keys, an mkcert certificate for `saml.test` in `config/nginx/cert/saml/`, and the nginx block `config/nginx/virtual-servers/saml.conf`. It also adds `127.0.0.1 saml.test` to `/etc/hosts`. That is the only step that needs `sudo`, and it asks first (`--yes` answers yes). Without a terminal it prints the line for you to add yourself.

Your browser must trust the mkcert CA. Run `mkcert -install` once. Firefox keeps its own trust store, and `mkcert -install` updates it only when `certutil` is installed (`brew install nss`). See `config/nginx/cert/README.md`.

### Pages

- `https://saml.test/`: the apps page. For each linked tree, "Sign in to &lt;tree&gt;" signs you in to the tree through the test IdP (IdP-initiated), and "Start at &lt;tree&gt;'s IdP" logs you in at the tree and sends you to the container SP (IdP-initiated).
- `https://saml.test/sp/`: the container SP. "Log in at &lt;tree&gt;" starts an SP-initiated login at that tree. The result page shows the flow, tree, issuer, NameID, what was signed, the assertion count, and every attribute received. "Clear SP session" logs you out of the container SP only.
- The tree's own login page: its SAML button sends you to the test IdP (SP-initiated).

The test IdP keeps a normal SSO session, as a real IdP does: after one sign-in, the next login in the same browser skips the username page and asserts the same user. To sign in as someone else, use a private window or clear the browser's cookies for `saml.test`. "Clear SP session" does not end the IdP session.

Single logout is not supported. When you log out of a tree that still holds a SAML session from the test IdP, the tree sends a logout request to `saml.test`, which answers with a SimpleSAMLphp error page ("Could not find a supported SingleLogoutService endpoint"). You are still logged out of the tree: reopening it shows its login page.

### Activity left behind

`unlink` restores configuration, not activity. Test logins leave these in the tree's database:

- login history rows;
- first-dashboard-load rows;
- `SimpleSAMLphp_kvstore` rows;
- one `ohrm_saml_user_identity` row per user who logged in through SAML, each time the tree is linked. After `unlink` these rows remain, with `provider_id = NULL`.

### Reading `acs.log`

Every SAML response posted to the container SP adds one JSON line to `custom-compose/config/saml/data/acs.log`. The line is written before SimpleSAMLphp checks the response, so refused responses are logged too.

```shell
tail -n 3 custom-compose/config/saml/data/acs.log | jq .
```

| Key | Meaning |
|---|---|
| `time` | When the response arrived, UTC. |
| `issuer`, `destination` | As in the `samlp:Response`. |
| `inResponseTo` | The request the response answers; `null` for an IdP-initiated login. |
| `responseSigned` | The Response carries a signature. |
| `assertionSigned` | Every Assertion carries a signature (`false` when there is none). |
| `assertionCount`, `encrypted` | How many Assertions, and whether an `EncryptedAssertion` is present. |
| `nameId` | The first Assertion's NameID. |
| `error` | Why the response could not be read, else `null`. |

A key is `null` when the response doesn't have it. The log only locates signatures. SimpleSAMLphp verifies them, and when a check fails its error page says which. On the tree side, the tree's own SimpleSAMLphp log is `symfony/log/<YYYY-MM-DD>-saml.log` in the tree.
