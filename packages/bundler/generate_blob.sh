#!/bin/bash

gem fetch bundler --platform=linux
bosh add-blob ./bundler*.gem bundler/bundler.gem