#!/bin/bash
# Ubuntu distribution setup script used in chroot's. It is executed from the outside of the chroot in the context of the host operating system
# so that any necessary operations that may not work within the context of the chroot can work as intended.

directory=$1
distribution=$2
version=$3
architecture=$4

targetFile="$directory/etc/apt/sources.list"
directoryName=$(dirname $targetFile)

if [ $directoryName == "/etc/apt" ]
then
    echo "!!! Internal error: Got a blank directory specification!"
    exit 1
fi

# Ensure that the package lists are good
echo "Installing package lists ..."
echo "deb http://archive.ubuntu.com/ubuntu/ $version main restricted universe multiverse" | tee -a "$targetFile"
echo "deb http://archive.ubuntu.com/ubuntu/ $version-security main restricted universe multiverse" | tee -a "$targetFile"
echo "deb http://archive.ubuntu.com/ubuntu/ $version-updates main restricted universe multiverse" | tee -a "$targetFile"
echo "deb http://archive.ubuntu.com/ubuntu/ $version-proposed main restricted universe multiverse" | tee -a "$targetFile"
echo "deb http://archive.ubuntu.com/ubuntu/ $version-backports main restricted universe multiverse" | tee -a "$targetFile"

apt-get update -y
apt-get upgrade -y

# FIXME: Move to a generated bootstrap script
apt-get install -y git
