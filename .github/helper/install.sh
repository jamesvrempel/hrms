#!/bin/bash

set -e

cd ~ || exit

# This fork runs on the ES ERP stack, not upstream ERPNext, so the branch being
# tested (main) has no counterpart in frappe/frappe. Each dependency is pinned
# to its own branch here; override through the environment when needed.
frappe_branch=${FRAPPE_BRANCH:-"version-15"}
es_erp_repo=${ES_ERP_REPO:-"https://github.com/jamesvrempel/es_erp"}
es_erp_branch=${ES_ERP_BRANCH:-"main"}
payments_repo=${PAYMENTS_REPO:-"https://github.com/jamesvrempel/payments"}
payments_branch=${PAYMENTS_BRANCH:-"main"}

sudo apt update
sudo apt remove mysql-server mysql-client
sudo apt install libcups2-dev redis-server mariadb-client

pip install frappe-bench

git clone https://github.com/frappe/frappe --branch "$frappe_branch" --depth 1
bench init --skip-assets --frappe-path ~/frappe --python "$(which python)" frappe-bench

mkdir ~/frappe-bench/sites/test_site
cp -r "${GITHUB_WORKSPACE}/.github/helper/site_config.json" ~/frappe-bench/sites/test_site/

printf '[client]\nskip-ssl\n' > ~/.my.cnf
mariadb --host 127.0.0.1 --port 3306 -u root -proot -e "SET GLOBAL character_set_server = 'utf8mb4'"
mariadb --host 127.0.0.1 --port 3306 -u root -proot -e "SET GLOBAL collation_server = 'utf8mb4_unicode_ci'"

mariadb --host 127.0.0.1 --port 3306 -u root -proot -e "CREATE USER 'test_frappe'@'localhost' IDENTIFIED BY 'test_frappe'"
mariadb --host 127.0.0.1 --port 3306 -u root -proot -e "CREATE DATABASE test_frappe"
mariadb --host 127.0.0.1 --port 3306 -u root -proot -e "GRANT ALL PRIVILEGES ON \`test_frappe\`.* TO 'test_frappe'@'localhost'"

mariadb --host 127.0.0.1 --port 3306 -u root -proot -e "FLUSH PRIVILEGES"

install_whktml() {
    wget -O /tmp/wkhtmltox.tar.xz https://github.com/frappe/wkhtmltopdf/raw/master/wkhtmltox-0.12.3_linux-generic-amd64.tar.xz
    tar -xf /tmp/wkhtmltox.tar.xz -C /tmp
    sudo mv /tmp/wkhtmltox/bin/wkhtmltopdf /usr/local/bin/wkhtmltopdf
    sudo chmod o+x /usr/local/bin/wkhtmltopdf
}
install_whktml &

cd ~/frappe-bench || exit

sed -i 's/watch:/# watch:/g' Procfile
sed -i 's/schedule:/# schedule:/g' Procfile
sed -i 's/socketio:/# socketio:/g' Procfile
sed -i 's/redis_socketio:/# redis_socketio:/g' Procfile

bench get-app "$payments_repo" --branch "$payments_branch"
bench get-app "$es_erp_repo" --branch "$es_erp_branch"
# Upstream frappe/lending imports the erpnext package, which does not exist on
# the ES ERP stack, so it is not installed. The loan tests are guarded by
# if_lending_app_installed and skip themselves without it.
bench get-app hrms "${GITHUB_WORKSPACE}"
bench setup requirements --dev

bench start &>> ~/frappe-bench/bench_start.log &
CI=Yes bench build --app frappe &
bench --site test_site reinstall --yes

bench --verbose --site test_site install-app hrms
