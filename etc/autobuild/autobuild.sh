#!/bin/bash

source /etc/autobuild/settings.sh

# Run all of the projects
runningSubprocesses=()
currentSubprocessCount=0
subprocessProjectNames=()

# Helper functions
# $1 = Value
# $2 = Array
function getArrayIndex()
{
    array=$2
    for index in "${!array[@]}"
    do
        if [ "${array[$index]}" == "$1" ]
        then
            return $index
        fi
    done
    return -1
}

# Processes the running subprocesses.
# $1 = If wait, then we will always enter the subprocess checking code.
function processSubProcesses()
{
    # Nothing to do
    if [ $subprocessCount -eq 0 ]
    then
        return 0
    fi

    if [[ $currentSubprocessCount -lt $subprocessCount && "$1" != "wait" ]]
    then
        return 0
    fi

    # If we have enough subprocesses, we have to wait for this one to end
    echo "Waiting for project subprocesses to complete ..."
    echo "Waiting on projects $currentSubprocessCount/$subprocessCount"

    while [ $currentSubprocessCount -ge $subprocessCount ] || [[ "$1" == "wait" && $currentSubprocessCount -ne 0 ]]
    do
        for subprocess in $runningSubprocesses
        do
            if ! ps -p $subprocess > /dev/null
            then
                # The return code is our index
                getArrayIndex $subprocess $runningSubprocesses
                processIndex=$?
                if [ $processIndex -le -1 ]
                then
                    echo "Internal error: Failed to find subprocess in the running subprocess list: $subprocess"
                    exit 1
                fi

                # FIXME: Properly remove from the list
                unset runningSubprocesses[$processIndex]
                currentSubprocessCount=$(($currentSubprocessCount-1))

                projectName=${subprocessProjectNames[$subprocess]}
                echo "Build for $projectName (pid $subprocess) completed."

                if [ $measureTimes -eq 1 ]
                then
                    timeFile="/tmp/$projectName.time"

                    if [ ! $timeFile ]
                    then
                        echo "!!! Warning: Timing has been enabled, but the timing output for this project cannot be found!"
                    else
                        echo "Build time for $projectName: "
                        cat $timeFile | grep "real" | awk '{print $1}'
                    fi
                fi

                echo "Waiting on projects $currentSubprocessCount/$subprocessCount"

                if [ $currentSubprocessCount -lt $subprocessCount ]
                then
                    echo "Done waiting on subprocesses."
                    return 0
                fi
            fi
        done

        sleep 1s
    done
}

function outputSystemInformation()
{
    processorModel=$(grep vendor_id < /proc/cpuinfo | head -n1 | awk '{print $3}')
    processorCores=$(grep processor < /proc/cpuinfo | wc -l)
    memoryGB=$(free -g | grep "Mem" | awk '{print $2}')

    echo "============= System information =================="
    echo "Processor Model: $processorModel"
    echo "Processor cores: $processorCores"
    echo "Memory: $memoryGB GB"
    echo "==================================================="
    echo ""
}

# Returns all supported distributions.
function getSupportedDistributions()
{
    distributions=$(find "/etc/autobuild/environments" -maxdepth 1 -mindepth 1 -type f -print)
    for distribution in $distributions
    do
        distribution=$(basename $distribution)
        distribution="${distribution%.*}"
        echo $distribution
    done

    return 0
}

# Gets the distribution support file for the given distribution.
# If return code = 0, then a good result was returned. Otherwise, an error has
# been encountered.
function getDistributionFile()
{
    distributionName=$(basename $1)
    distributionFile="/etc/autobuild/environments/$distributionName.sh"

    if [ -f $distributionFile ]
    then
        echo $distributionFile
        return 0
    fi

    return 1
}

# Gets the build type support file.
function getTypeFile()
{
    typeName=$(basename $1)
    typeFile="/etc/autobuild/types/$typeName.sh"

    if [ -f $typeFile ]
    then
        echo $typeFile
        return 0
    fi

    return 1
}

# $1 = build script path
# $2 = settings script path
# $3 = bootstrap script path
# $4 = project settings script path
# $5 = project type script path
# TODO: Implement subprocesses for each dist/arch
function buildProject()
{
    buildScript=$1
    settingsScript=$3
    bootstrapScript=$3
    projectSettingsScript=$4
    projectTypeScriptPath=$5

    # Always re-source settings because this can be threaded
    source $projectSettingsScript

    directoryName=$(dirname $1)

    # Deal with chroot builds if we have any
    if [ ! -z $buildChroot ]
    then
        echo "Building chroot's for $projectName"

        for chrootSpec in "${buildChroot[@]}"
        do
            distribution=$(cut -d- -f1 <<< $chrootSpec)
            version=$(cut -d- -f2 <<< $chrootSpec)
            architecture=$(cut -d- -f3 <<< $chrootSpec)

            distributionFile=$(getDistributionFile $distribution)
            if [ $? -ne 0 ]
            then
                echo "Unrecognized distribution: $distribution"
                echo "Valid distributions: "
                getSupportedDistributions
                return 1
            fi

            # FIXME: Handle dist's that might not have named versions
            chrootDestination="/var/lib/autobuild/chroot/$projectName-$distribution-$version-$architecture"

            if [ ! -d $chrootDestination ]
            then
                distributionScript=$(getDistributionFile $distribution)

                # FIXME: Handle other distributions
                echo "Building $distribution-$architecture chroot for $projectName ..."
                mkdir $chrootDestination
                debootstrap --variant=buildd --arch $architecture $version $chrootDestination http://ubuntu.cs.utah.edu/ubuntu/

                if [ $? -ne 0 ]
                then
                    echo "!!! Failed to build $distribution chroot!"
                    rm -rf $chrootDestination
                    continue
                fi

                # Put /etc/autobuild in the chroot to store scripts and settings files
                mkdir "$chrootDestination/etc/autobuild"
                mkdir "$chrootDestination/var/lib/autobuild"
                cp $projectSettingsScript "$chrootDestination/etc/autobuild/projectSettings.sh"
                cp $settingsScript "$chrootDestination/etc/autobuild/settings.sh"
                cp $projectTypeScriptPath "$chrootDestination/etc/autobuild/type.sh"

                # Run the distro bootstrap script
                echo "Running distribution bootstrap script ..."
                cp $distributionScript "$chrootDestination/etc/autobuild/distributionBootstrap.sh"
                $chrootDestination/etc/autobuild/distributionBootstrap.sh $chrootDestination $distribution $version $architecture

                if [ $? -ne 0 ]
                then
                    echo "!!! Failed to run distribution bootstrap script!"
                    rm $chrootDestination/etc/autobuild/distributionBootstrap.sh
                    continue
                fi

                # Run the project bootstrap script
                echo "Running project bootstrap script ..."
                cp $bootstrapScript "$chrootDestination/etc/autobuild/projectBootstrap.sh"
                chroot $chrootDestination /etc/autobuild/projectBootstrap.sh $distribution $version $architecture
            else
                echo "Detected chroot at $chrootDestination, reusing chroot."

                bootstrapFile="$chrootDestination/etc/autobuild/distributionBootstrap.sh"
                if [ ! -f $bootstrapFile ]
                then
                    distributionScript=$(getDistributionFile $distribution)
                    echo "Chroot appears to have not been correctly bootstrapped, retrying."

                    # FIXME: Duplicate code
                    echo "Re-running distribution bootstrap script ..."
                    cp $distributionScript "$chrootDestination/etc/autobuild/distributionBootstrap.sh"
                    $chrootDestination/etc/autobuild/distributionBootstrap.sh $chrootDestination $distribution $version $architecture

                    if [ $? -ne 0 ]
                    then
                        echo "!!! Failed to re-run distribution bootstrap script!"
                        rm $chrootDestination/etc/autobuild/distributionBootstrap.sh
                        continue
                    fi
                fi
            fi

            # Finally start the build within the chroot
            echo "===================== Entering Chroot =============================="
            echo "At $chrootDestination"

            cp $buildScript "$chrootDestination/build.sh"
            chroot $chrootDestination ./build.sh $distribution $version $architecture

            if [ $? -ne 0 ]
            then
                echo "!! Failed to run build script in chroot!"
            fi
            echo "===================== Exiting Chroot ==============================="
            echo ""
        done
    else
        echo "Building $projectName for host system."
    fi

    return 0
}

# $1 = build script path
# $2 = settings script path
# $3 = bootstrap script path
# $4 = project settings script path
# $5 = project type script path
function spoolProject()
{
    # Free up some subprocesses before we do anything
    processSubProcesses
    projectStatusFile="$outputDirectory/status-$projectName.txt"

    if [ $subprocessCount -eq 0 ]
    then
        # Quiet build
        if [ $quietBuild -eq 1 ]
        then
            # Measure times
            if [ $measureTimes -eq 1 ]
            then
                { time buildProject $1 $2 $3 $4 $5 > $projectStatusFile & } 2> /tmp/$projectName.time
                wait $?
            else
                buildProject $1 $2 $3 $4 $5 > $projectStatusFile
            fi
        else
            # Measure times
            if [ $measureTimes -eq 1 ]
            then
                { time buildProject $1 $2 $3 $4 $5 | tee $projectStatusFile & } 2> /tmp/$projectName.time
                wait $?
            else
                buildProject $1 $2 $3 $4 $5 > $projectStatusFile
            fi
        fi
    else
        # Measure times
        if [ $measureTimes -eq 1 ]
        then
            { time buildProject $1 $2 $3 $4 $5 > $projectStatusFile & } 2> /tmp/$projectName.time
        else
            buildProject $1 $2 $3 $4 $5 > $projectStatusFile &
        fi

        processPID=$!
        echo "Spooled subprocess for $projectName as PID $processPID"
        runningSubprocesses+=($processPID)
        subprocessProjectNames[$processPID]=$projectName
        currentSubprocessCount=$(($currentSubprocessCount+1))

        echo "$(($subprocessCount-$currentSubprocessCount))/$subprocessCount project subprocesses remain."
    fi
}

echo "Autobuild starting..."
outputSystemInformation

echo "Using $subprocessCount subprocesses."
echo "Using $buildProcessCount build processes."

# Scan for any projects
echo "Scanning for projects ..."

settingsFile="/etc/autobuild/settings.sh"
projects=$(find "/var/lib/autobuild/projects" -maxdepth 1 -mindepth 1 -type d -print)
for project in $projects
do
    projectSettingsFile="$project/settings.sh"
    buildFile="$project/build.sh"
    bootstrapFile="$project/bootstrap.sh"

    source $projectSettingsFile
    projectTypeFile=$(getTypeFile $projectType)
    if [ $? -ne 0 ]
    then
        echo "!!! Failed to load project type file for $projectType!"
        continue
    fi

    echo "Found project $projectName of type $projectType at $project"

    # FIXME: This passing of the script files is rather messy
    spoolProject $buildFile $settingsFile $bootstrapFile $projectSettingsFile $projectTypeFile
done

# Ensure all subprocess are done
echo "Done spooling projects."
processSubProcesses wait

echo "Build process complete."
