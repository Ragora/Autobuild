#!/bin/bash

# The number of subprocesses for handling projects
subprocessCount="0"
# The number of project builds to run at once. This is used to handle chroot builds.
buildProcessCount="1"
# The number of threads to use in an actual build. This is fed to the -j parameter of make and the equivalent\
# for anything else used in the toolchain that can use custom thread settings.
buildThreadCount="4"

quietBuild="0"
measureTimes="1"
outputDirectory="/var/lib/autobuild"
statusFile="/var/lib/autobuild"
userName="root"

# Upload to a server
# Note the host key will be ignored, so don't do this with servers on the internet.
# uploadServer="192.168.2.7"
# When the upload is performed, it will be done using SSH auth as this user.
# uploadUser="autobuild"
# uploadDirectory="/var/www/html"
