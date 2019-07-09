#!/bin/bash

gem fetch bundler --platform=x86_64-linux
bosh add-blob ./bundler*.gem bundler/bundler.gem
