#!/usr/bin/env bash
SET_SKIP=0
START_PATH=$1

if [ -z "$1" ]; then
    echo "Start path is required."
    exit 1
fi

cd $START_PATH

while getopts ":hs" opt; do
    case $opt in
        h)
            echo -e "Usage: \n\t./buildrpm.sh <start_path> [-s]\n\n\t-s Skip checking for upstream changes" >&2
            exit 0
            ;;
        s)
            SET_SKIP=1
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
    esac
done

# clean up repository to start fresh
echo "| Cleaning up repository"
{
    rm -rf result/*
    cd ovs
    git reset --hard HEAD
    git clean -f -d -X
} &> /dev/null

# check if we need to update and continue
check_for_update()
{
    git remote update &> /dev/null
    LOCAL=$(git rev-parse @)
    REMOTE=$(git rev-parse @{u})

    if [ $LOCAL != $REMOTE ]; then
        echo "|__ Pulling latest changes..."
        git pull --ff-only &> /dev/null
    else
        echo "|__ Nothing changed upstream. Ending."
        exit 1
    fi
}

# check if we should skip update check
if [ $SET_SKIP = "0" ]; then
    echo "| Checking if we need to continue..."
    check_for_update
fi

# create new build version
DATE=`date -u +%Y%m%d%H%M`
GITHASH=`git rev-parse --short HEAD`
VERSION=${DATE}git${GITHASH}

# update configure.ac with new version
echo "| Creating build $VERSION"
sed -i 's/AC_INIT.*/AC_INIT(openvswitch, '$VERSION', bugs@openvswitch.org)/' configure.ac &> /dev/null

# prepare environment, build tarball, update spec files
{
    ./boot.sh
    ./configure
    make dist
    # skip checks
    sed -i '/%bcond_with dpdk/a %bcond_without check' rhel/openvswitch-fedora.spec
    sed -i 's/%bcond_without check//' rhel/openvswitch-fedora.spec
    cd -
} &> /dev/null

# build SRPM from spec with tarball
echo "|__ Building SRPM for $VERSION"
{
    mock --root fedora-23-x86_64 \
         --dnf \
         --spec ovs/rhel/openvswitch-fedora.spec \
         --sources=ovs/  \
         --resultdir=result \
         --buildsrpm

    SRPM=`ls result/*.rpm 2>/dev/null`
} &> /dev/null

echo "   |__ Checking if we have an RPM to upload..."
if [ ! -z $SRPM ]; then
    echo "      |__ Uploading $SRPM"
    {
    copr build --nowait \
                ovs-master $SRPM
    } &> /dev/null
else
    echo "      |__ Nothing to upload"
fi

echo "| All done!"
exit 0
