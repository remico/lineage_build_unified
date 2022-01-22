#!/bin/bash
echo ""
echo "LineageOS 18.x Unified Buildbot"
echo "ATTENTION: this script syncs repo on each run"
echo "Executing in 5 seconds - CTRL-C to exit"
echo ""
sleep 5

usage() {
    echo "Not enough arguments - exiting"
    echo ""
    exit 1
}

if [ $# -lt 2 ]
then
    usage
fi

MODE=${1}
if [ ${MODE} != "device" ] && [ ${MODE} != "treble" ]
then
    echo "Invalid mode - exiting"
    echo ""
    exit 1
fi

PERSONAL=false
SAS=false
LFS=false
FAST=false

until [ -z "$1" ]
do
    case "$1" in
    "personal")
        PERSONAL=true
        OPTS+=("$1")
        shift
        ;;
    "-sas")
        SAS=true
        shift
        ;;
    "-lfs")
        LFS=true
        shift
        ;;
    "-n")
        FAST=true
        shift
        ;;
    "-h")
        usage
        exit 0
        ;;
    *)
        OPTS+=("$1")
        shift
        ;;
    esac
done

# Abort early on error
set -eE
trap '(\
echo;\
echo \!\!\! An error happened during script execution;\
echo \!\!\! Please check console output for bad sync,;\
echo \!\!\! failed patch application, etc.;\
echo\
)' ERR

START=`date +%s`
BUILD_DATE="$(date +%Y%m%d)"
WITHOUT_CHECK_API=true
WITH_SU=true

ROOT_DIR=~/android

echo "Preparing local manifests"
mkdir -p .repo/local_manifests
# git clone https://github.com/phhusson/treble_manifest .repo/local_manifests  -b android-11.0
# rm -f .repo/local_manifests/replace.xml  # required if building any rom except AOSP GSI
cp ./lineage_build_unified/local_manifests_${MODE}/*.xml .repo/local_manifests
echo ""

if [ ! ${FAST} ]; then
    echo "Syncing repos"
    repo sync -c --force-sync --no-clone-bundle --no-tags -j$(nproc --all)
    echo ""
fi

echo "Setting up build environment"
source build/envsetup.sh &> /dev/null
mkdir -p $ROOT_DIR/build-output
echo ""

apply_patches() {
    echo "Applying patch group ${1}"
    bash $ROOT_DIR/treble_experimentations/apply-patches.sh ./lineage_patches_unified/${1}
}

prep_device() {
    :
}

prep_treble() {
    apply_patches patches_treble_prerequisite
    apply_patches patches_treble_phh
}

finalize_device() {
    :
}

finalize_treble() {
    rm -f device/*/sepolicy/common/private/genfs_contexts
    cd device/phh/treble
    git clean -fdx
    bash generate.sh lineage
    cd ../../..
}

build_device() {
    brunch ${1}
    mv $OUT/lineage-*.zip $ROOT_DIR/build-output/lineage-18.1-$BUILD_DATE-UNOFFICIAL-${1}$($PERSONAL && echo "-personal" || echo "").zip
}

build_treble() {
    case "${1}" in
        ("64B") TARGET=treble_arm64_bvS;;
        ("64BG") TARGET=treble_arm64_bgS;;
        (*) echo "Invalid target - exiting"; exit 1;;
    esac
    lunch lineage_${TARGET}-userdebug
    make installclean
    make -j$(nproc --all) systemimage
    make vndk-test-sepolicy
    mv $OUT/system.img $ROOT_DIR/build-output/lineage-18.1-$BUILD_DATE-UNOFFICIAL-${TARGET}$(${PERSONAL} && echo "-personal" || echo "").img
}

if [ ! ${FAST} ]; then
    echo "Applying patches"
    prep_${MODE}
    apply_patches patches_platform
    apply_patches patches_${MODE}
    if ${PERSONAL}
    then
        apply_patches patches_platform_personal
        apply_patches patches_${MODE}_personal
    fi
    finalize_${MODE}
    echo ""

    if ${LFS}; then
        echo "Calling git-lfs..."
        for d in vendor/opengapps/sources/*/ ; do (cd "$d" && git lfs pull); done || true  # if opengapps requested
        echo ""
    fi
fi

for var in "${OPTS[@]:1}"
do
    if [ ${var} == "personal" ]
    then
        continue
    fi
    echo "Starting $(${PERSONAL} && echo "personal " || echo "")build for ${MODE} ${var}"
    build_${MODE} ${var}
done
ls $ROOT_DIR/build-output | grep 'lineage' || true

END=`date +%s`
ELAPSEDM=$(($(($END-$START))/60))
ELAPSEDS=$(($(($END-$START))-$ELAPSEDM*60))
echo "Buildbot completed in $ELAPSEDM minutes and $ELAPSEDS seconds"
echo ""


if ${SAS}; then
    # ensure sas-creator
    [ ! -d ../sas-creator ] && git clone git@github.com:remico/sas-creator.git ..

    # make the image
    systemImage=$ROOT_DIR/build-output/lineage-18.1-$BUILD_DATE-UNOFFICIAL-${TARGET}$(${PERSONAL} && echo "-personal" || echo "").img
    echo "Running sas-creator..."
    [ -f "$systemImage" ] && sudo bash ../sas-creator/run.sh 64 "$systemImage" || echo "'$systemImage' not found"
    echo ""
fi
