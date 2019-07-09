#!/bin/bash

apt-get install -y git

# gem fetch bundler --platform=x86_64-linux
# bosh add-blob ./bundler*.gem bundler/bundler.gem

gem install ronn:'~> 0.7.3'
mkdir -p /tmp/bundler
pushd /tmp/bundler
  git clone https://github.com/bundler/bundler.git
  pushd bundler
    rake build
    # gem install pkg/bundler-*.gem -i /var/vcap/packages/bundler/gems
    bosh add-blob pkg/bundler*.gem bundler/bundler.gem
  popd
popd