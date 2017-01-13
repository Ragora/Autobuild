#!/bin/bash

# chroot-execute.sh
# Inner execution script for the chroot-build.sh script. Currently, this only builds OpenTESArena.
#
# Copyright (c) 2016 Robert MacGregor
# This software is licensed under the MIT license. See LICENSE.txt for more information.

buildFilename=$1

if [ ! -f "/var/www/html/build-$tag.tar.gz" ]
then
    make clean
    cmake . -DCMAKE_BUILD_TYPE=Release
    make -j2

    # Prepare the dist
    cp -R /etc/autobuild/template /tmp/currentBuild
    cp TESArena /tmp/currentBuild

    # Use the repository data and options if we have them in the repository
    if [ -d "data" ] then
        rm -rf /tmp/currentBuild/data
        cp -R data /tmp/currentBuild
    fi

    if [ -d "options" ] then
        rm -rf /tmp/currentBuild/options
        cp -R options /tmp/currentBuild
    fi

    mkdir /tmp/currentBuild/libs
    packagedLibraries=( "libSDL2-2.0.so"  "libWildMidi.so" )
    for libraryName in "${packagedLibraries[@]}"
    do
        libraryData=$(ldd TESArena | grep $libraryName)
        absolutePath=$(awk '{print $3}' <<< $libraryData)
        realName=$(awk '{print $1}' <<< $libraryData)
                   if [ $? -ne 0 ]
        then
            echo "Failed to library $libraryName"
            continue
        fi

        echo "Found library $libraryName (as $realName) at $absolutePath"
        cp $absolutePath /tmp/currentBuild/libs/$realName
    done

    pushd /tmp/currentBuild
    tar -zcvf $buildFilename *
    mv $buildFilename $buildLocalPath
    popd

    chown www-data:www-data $buildLocalPath
    rm -rf /tmp/currentBuild
else
    echo "Not building tag $tag : Already built."
fi
