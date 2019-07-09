#!/usr/bin/env bash


libpq_dir=/var/vcap/packages/libpq
mysqlclient_dir=/var/vcap/packages/mysql

source /var/vcap/packages/ruby-2.6.3-r0.14.0/bosh/compile.env

gem install /var/vcap/packages/bundler/bundler.gem
bundle update --bundler

bundle config build.pg \
  --with-pg-lib=$libpq_dir/lib \
  --with-pg-include=$libpq_dir/include

bundle install


