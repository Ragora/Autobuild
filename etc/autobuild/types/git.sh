#!/bin/bash
# GIT project type.

mode=$1

source "/etc/autobuild/settings.sh"
source "/etc/autobuild/projectSettings.sh"

if [ $mode == "build" ]
then
    # Does the project already exist?
    if [ ! -d "/tmp/$projectName" ]
    then
        cd /tmp
        git clone $projectSource $projectName
    fi

    cd "/tmp/$projectName"
    git pull origin

    for tagName in $(git tag)
    do
        tagName=$(basename $tagName)
        buildFilename="build-$tagName.tar.gz"
        buildOutputPath="$outputDirectory/$buildFilename"

        if [ -f $buildOutputPath ]
        then
            echo "Not building tag $tagName because it is already built."
        else
            echo "Building tag $tagName .. "
            git checkout $tagName

            # TODO: Implement build types too
            /etc/autobuild/build.sh $buildOutputPath $buildFilename
        fi
    done
elif [ $mode == "bootstrap" ]
then
    apt-get install -y git
fi
