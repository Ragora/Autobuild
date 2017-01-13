#!/bin/bash

projectType="git"
projectName="OpenTESArena"
projectSource="https://github.com/afritz1/OpenTESArena.git"
buildRoot="/tmp/"

# GIT Specific settings
gitIgnoreTags=""

# Builds in a chroot if this specified. If not specified, then the build scripts are ran on the host machine which can
# be undesirable. Using chroot's is recommended.
# The dist format is as follows:
# dist-name-arch
buildChroot=(ubuntu-trusty-i386 ubuntu-trusty-amd64 ubuntu-xenial-i386 ubuntu-xenial-amd64)
