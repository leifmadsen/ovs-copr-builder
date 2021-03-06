#!/usr/bin/env bash
CHECK_CHANGE=true
PUBLISH_COPR=false

source buildrpm.conf

read -r -d '' HELPMSG << EOM
Usage:
    ./buildrpm.sh -p <start_path> [-s]
        -s Skip checking for upstream changes
        -c Publish to COPR
        -p Start path
EOM

while getopts ":hscp:" opt; do
    case $opt in
        h)
            echo -e "$HELPMSG" >&2
            exit 0
            ;;
        s)
            CHECK_CHANGE=false
            ;;
        c)
            PUBLISH_COPR=true
            ;;
        p)
            START_PATH=$OPTARG
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument" >&2
            exit 1
            ;;
    esac
done

if [ -z "$START_PATH" ]; then
    echo "Start path is required. See application help."
    exit 1
fi

cd "$START_PATH" || exit

# clean up repository to start fresh
echo "| Cleaning up repository"
{
    rm -rf result/*
    rm -f ovs-specs/openvswitch-kmod.spec
    rm -f ovs-specs/openvswitch.spec
    pushd ovs
    git reset --hard HEAD
    git clean -f -d -X
    popd
} &> /dev/null

# check if we need to update and continue
check_for_update()
{
    pushd ovs
    git remote update &> /dev/null
    LOCAL=$(git rev-parse @)
    REMOTE=$(git rev-parse @{u})

    if [ "$LOCAL" != "$REMOTE" ]; then
        echo "|__ Pulling latest changes..."
        git pull &> /dev/null
        popd
    else
        echo "|__ Nothing changed upstream. Ending."
        popd
        exit 1
    fi
}

mail_failure()
{
    mutt -s "OVS failed to upload to Copr" "$EMAIL_ADDRESS" < /dev/null
}

# check if we should skip update check
if $CHECK_CHANGE; then
    echo "| Checking if we need to continue..."
    check_for_update
fi

pushd ovs

# create new build version
# clever trick taken from http://copr-dist-git.fedorainfracloud.org/cgit/pmatilai/dpdk-snapshot/openvswitch.git/tree/ovs-snapshot.sh?h=epel7
snapgit=$(git log --pretty=oneline -n1|cut -c1-8)
snapser=$(git log --pretty=oneline | wc -l)

basever=$(grep AC_INIT configure.ac | cut -d' ' -f2 | cut -d, -f1)

prefix=openvswitch-${basever}.${snapser}.git${snapgit}

# update configure.ac with new version
echo "| Creating build ${prefix}"
sed -i 's/AC_INIT.*/AC_INIT(openvswitch, '${basever}.${snapser}.git${snapgit}', bugs@openvswitch.org)/' configure.ac &> /dev/null

# prepare environment, build tarball, update spec files
{
    ./boot.sh
    ./configure
    make dist
} &> /dev/null

popd

# move sources around
mv ovs/*.tar.gz ovs-sources/

# setup template for openvswitch-kmod
#cp ovs-specs/openvswitch-kmod-fedora.spec.tmpl ovs-specs/openvswitch-kmod.spec
#sed -i "s/@VERSION@/${basever}.${snapser}.git${snapgit}/" ovs-specs/openvswitch-kmod.spec

cp ovs/rhel/openvswitch-fedora.spec ovs-specs/openvswitch.spec

# build SRPM from spec with tarball
echo "|__ Building SRPM for $prefix"
{
    mock --root epel-7-x86_64 \
         --dnf \
         --spec ovs-specs/openvswitch.spec \
         --sources=ovs-sources/  \
         --resultdir=result \
         --buildsrpm

    SRPM=$(ls result/openvswitch-${basever}*.rpm 2>/dev/null)

    # **NOTE** when building this, an openvswitch-kmod-kernel-version file must be present in ovs-sources/ that contains the proper kernel version
#    mock --root epel-7-x86_64 \
#        --dnf \
#        --spec ovs-specs/openvswitch-kmod.spec \
#        --sources=ovs-sources/ \
#        --resultdir=result \
#        --buildsrpm
#
#    KMOD_SRPM=$(ls result/openvswitch-kmod-${basever}*.rpm 2>/dev/null)
} &> /dev/null

if $PUBLISH_COPR; then
    echo "   |__ Checking if we have an RPM to upload..."
    for build in $SRPM $KMOD_SRPM; do
        if [ ! -z $build ]; then
            echo "      |__ Uploading $build"
            {
                if [ "$build" == "$KMOD_SRPM" ]; then
                    CHROOT="--chroot epel-7-x86_64"
                else
                    CHROOT=""
                fi

                copr build --nowait $CHROOT\
                        ovs-master $build
            } &> /dev/null
            if [ $? != 0 ]; then
                mail_failure
            fi
        else
            echo "      |__ Nothing to upload"
        fi
    done
fi

echo "| All done!"
exit 0
