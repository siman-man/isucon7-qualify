.DEFAULT_GOAL := help

restart: ## copy configs from repository to conf
	@make -s nginx-restart
	@make -s db-restart
	@make -s ruby-restart

app: ## copy configs from repository to conf
	@make -s nginx-restart
	@make -s ruby-restart

ruby-restart: ## Restart isuxi.ruby
	@cd ruby;/home/isucon/local/ruby/bin/bundle install --path=vendor/bundle > /dev/null
	sudo systemctl restart isubata.ruby
	@echo 'Restart isubata.ruby'

mysql: ## Restart db server
	@sudo cp config/my.cnf /etc/mysql/
	@sudo service mysql restart
	@echo 'Restart mysql'

db-restart: #Restart mysql
	@sudo cp config/my.cnf /etc/mysql/
	sudo systemctl restart mysql
	@echo 'Restart mysql'

nginx-restart: ## Restart nginx
	sudo cp config/nginx.conf /etc/nginx/
	sudo cp config/nginx.service /lib/systemd/system/nginx.service
	sudo systemctl daemon-reload
	sudo /usr/local/openresty/nginx/sbin/nginx -t
	sudo systemctl restart nginx
	@echo 'Restart nginx'

nginx-reset-log: ## reest log and restart nginx
	@sudo rm /var/log/nginx/access.log;sudo service nginx restart

nginx-log: ## tail nginx access.log
	@sudo tail -f /var/log/nginx/access.log

nginx-error-log: ## tail nginx error.log
	@sudo tail -f /var/log/nginx/error.log

myprofiler: ## Run myprofiler
	@myprofiler -user=root

db-slow-query: ## tail slow query log
	@sudo tail -f /var/log/mysql/mysql-slow.log

alp: ## nginx analyzer
	@sudo /usr/local/bin/alp -f /var/log/nginx/access.log  --sum  -r --aggregates '/icons/\w+, /channel/\d+, /profile/\w+, /history/\d+' --start-time-duration 2m --include-statuses='20[0-9],30[0-2]'
bench: ## Run benchmark
	../benchmark --workload 3

unicorn: ## Run Unicorn
	@cd ruby;bundle exec unicorn -c unicorn_config.rb

puma: ## Run Puma
	@cd ruby; /home/isucon/local/ruby/bin/bundle exec puma -p 5000 -t 10

install-goose: ## Install Goose
	go get bitbucket.org/liamstask/goose/cmd/goose

install-alp: ## Install alp
	wget https://github.com/tkuchiki/alp/releases/download/v0.3.1/alp_linux_amd64.zip
	unzip alp_linux_amd64.zip
	rm alp_linux_amd64.zip
	sudo mv alp /usr/local/bin/alp
	sudo chown root:root /usr/local/bin/alp

install-myprofiler: ## Install myprofiler
	wget https://github.com/KLab/myprofiler/releases/download/0.2/myprofiler.linux_amd64.tar.gz
	tar xf myprofiler.linux_amd64.tar.gz
	rm myprofiler.linux_amd64.tar.gz
	sudo mv myprofiler /usr/local/bin


.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
