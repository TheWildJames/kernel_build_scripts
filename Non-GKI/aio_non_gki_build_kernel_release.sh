#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

#DO NOT GO OVER 4
MAX_CONCURRENT_BUILDS=4

# Check if 'builds' folder exists, create it if not
if [ ! -d "./builds" ]; then
    echo "'builds' folder not found. Creating it..."
    mkdir -p ./builds
else
    echo "'builds' folder already exists removing it."
    rm -rf ./builds
    mkdir -p ./builds
fi

cd ./builds
ROOT_DIR="Non-GKI-AIO-$(date +'%Y-%m-%d-%I-%M-%p')-release"
echo "Creating root folder: $ROOT_DIR..."
mkdir -p "$ROOT_DIR"
cd "$ROOT_DIR"

# Array with configurations (e.g., android-version-kernel-version-date)
BUILD_CONFIGS=(
    "android-4.14-stable"
)

# Arrays to store generated zip files, grouped by androidversion-kernelversion
declare -A RELEASE_ZIPS=()

# Iterate over configurations
build_config() {
    CONFIG=$1
    CONFIG_DETAILS=${CONFIG}

    # Create a directory named after the current configuration
    echo "Creating folder for configuration: $CONFIG..."
    mkdir -p "$CONFIG"
    cd "$CONFIG"
    
    # Split the config details into individual components
    IFS="-" read -r ANDROID_VERSION KERNEL_VERSION STABLE <<< "$CONFIG_DETAILS"
    
    # Formatted branch name for each build (e.g., android14-5.15-2024-01)
    #FORMATTED_BRANCH="${ANDROID_VERSION}-${KERNEL_VERSION}"

    # Log file for this build in case of failure
    LOG_FILE="../${CONFIG}_build.log"

    echo "Starting build for $CONFIG..."
    # Check if AnyKernel3 repo exists, remove it if it does
    if [ -d "./AnyKernel3" ]; then
        echo "Removing existing AnyKernel3 directory..."
        rm -rf ./AnyKernel3
    fi
    echo "Cloning AnyKernel3 repository..."
    #git clone https://github.com/TheWildJames/AnyKernel3.git -b "${ANDROID_VERSION}-${KERNEL_VERSION}"

    # Check if susfs4ksu repo exists, remove it if it does
    if [ -d "./susfs4ksu" ]; then
        echo "Removing existing susfs4ksu directory..."
        rm -rf ./susfs4ksu
    fi
    echo "Cloning susfs4ksu repository..."
    git clone https://gitlab.com/simonpunk/susfs4ksu.git -b "kernel-${KERNEL_VERSION}"

    # Setup directory for each build
    mkdir -p "$CONFIG"
    cd "$CONFIG"

    # Initialize and sync kernel source with updated repo commands
    echo "Initializing and syncing kernel source..."
    repo init --depth=1 --u https://android.googlesource.com/kernel/manifest -b "common-${CONFIG}"
    REMOTE_BRANCH=$(git ls-remote https://android.googlesource.com/kernel/common ${CONFIG})
    DEFAULT_MANIFEST_PATH=.repo/manifests/default.xml
    
    # Check if the branch is deprecated and adjust the manifest
    if grep -q deprecated <<< $REMOTE_BRANCH; then
        echo "Found deprecated branch: $CONFIG"
        sed -i "s/\"${CONFIG}\"/\"deprecated\/${CONFIG}\"/g" $DEFAULT_MANIFEST_PATH
    fi

    # Verify repo version and sync
    repo --version
    repo --trace sync -c -j$(nproc --all) --no-tags

    # Apply KernelSU and SUSFS patches
    echo "Adding KernelSU..."
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s v0.9.5

    echo "Applying SUSFS patches..."
    cp ../susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch ./KernelSU/
    cp ../susfs4ksu/kernel_patches/50_add_susfs_in_kernel-${KERNEL_VERSION}.patch ./common/
    cp ../susfs4ksu/kernel_patches/fs/* ./common/fs/
    cp ../susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/

    # Apply the patches
    cd ./KernelSU
    patch -p1 -F 3 < 10_enable_susfs_for_ksu.patch
    cd ../common
    patch -p1 -F 3 < 50_add_susfs_in_kernel-${KERNEL_VERSION}.patch
    cd ..

    # Add configuration settings for SUSFS
    echo "Adding configuration settings to defconfig..."
    echo "CONFIG_KSU=y" >> ./common/arch/arm64/configs/defconfig
    echo "CONFIG_KSU_SUSFS=y" >> ./common/arch/arm64/configs/defconfig
    echo "CONFIG_KSU_SUSFS_SUS_PATH=y" >> ./common/arch/arm64/configs/defconfig
    echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y" >> ./common/arch/arm64/configs/defconfig
    echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y" >> ./common/arch/arm64/configs/defconfig
    echo "CONFIG_KSU_SUSFS_SUS_OVERLAYFS=y" >> ./common/arch/arm64/configs/defconfig
    echo "CONFIG_KSU_SUSFS_TRY_UMOUNT=y" >> ./common/arch/arm64/configs/defconfig
    echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y" >> ./common/arch/arm64/configs/defconfig
    echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y" >> ./common/arch/arm64/configs/defconfig
    echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y" >> ./common/arch/arm64/configs/defconfig
    echo "CONFIG_KSU_SUSFS_SUS_SU=y" >> ./common/arch/arm64/configs/defconfig

    # Build kernel
    echo "Building kernel for $CONFIG..."

    # Check if build.sh exists, if it does, run the default build script
    if [ -e build/build.sh ]; then
        echo "build.sh found, running default build script..."
        # Modify config files for the default build process
        #sed -i '2s/check_defconfig//' ./common/build.config
        sed -i "s/dirty/'Wild+'/g" ./common/scripts/setlocalversion
        LTO=thin BUILD_CONFIG=common/build.config.aarch64 build/build.sh

        exit

        # Copying to AnyKernel3
        echo "Copying Image.lz4 to $CONFIG/AnyKernel3..."

        # Check if the boot.img file exists
        if [ "$ANDROID_VERSION" = "android12" ]; then
            mkdir bootimgs
            cp ./out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist/Image ./bootimgs
            cp ./out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist/Image.lz4 ./bootimgs
            cp ./out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist/Image ../
            cp ./out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist/Image.lz4 ../
            gzip -n -k -f -9 ./out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist/Image >../Image.gz
            cd ./bootimgs
            
            GKI_URL=https://dl.google.com/android/gki/gki-certified-boot-android12-5.10-"${DATE}"_r1.zip
            FALLBACK_URL=https://dl.google.com/android/gki/gki-certified-boot-android12-5.10-2023-01_r1.zip
            status=$(curl -sL -w "%{http_code}" "$GKI_URL" -o /dev/null)
                
            if [ "$status" = "200" ]; then
                curl -Lo gki-kernel.zip "$GKI_URL"
            else
                echo "[+] $GKI_URL not found, using $FALLBACK_URL"
                curl -Lo gki-kernel.zip "$FALLBACK_URL"
                fi
                
                unzip gki-kernel.zip && rm gki-kernel.zip
                echo 'Unpack prebuilt boot.img'
                unpack_bootimg.py --boot_img="./boot-5.10.img"
                
                echo 'Building Image.gz'
                gzip -n -k -f -9 Image >Image.gz
                
                echo 'Building boot.img'
                mkbootimg.py --header_version 4 --kernel Image --output boot.img --ramdisk out/ramdisk --os_version 12.0.0 --os_patch_level "${DATE}"
                avbtool add_hash_footer --partition_name boot --partition_size $((64 * 1024 * 1024)) --image boot.img --algorithm SHA256_RSA2048 --key /home/james/keys/testkey_rsa2048.pem
                cp ./boot.img ../../../${ANDROID_VERSION}-${KERNEL_VERSION}.${SUB_LEVEL}_${DATE}-boot.img
                
                echo 'Building boot-gz.img'
                mkbootimg.py --header_version 4 --kernel Image.gz --output boot-gz.img --ramdisk out/ramdisk --os_version 12.0.0 --os_patch_level "${DATE}"
            	avbtool add_hash_footer --partition_name boot --partition_size $((64 * 1024 * 1024)) --image boot-gz.img --algorithm SHA256_RSA2048 --key /home/james/keys/testkey_rsa2048.pem
                cp ./boot-gz.img ../../../${ANDROID_VERSION}-${KERNEL_VERSION}.${SUB_LEVEL}_${DATE}-boot-gz.img

                echo 'Building boot-lz4.img'
                mkbootimg.py --header_version 4 --kernel Image.lz4 --output boot-lz4.img --ramdisk out/ramdisk --os_version 12.0.0 --os_patch_level "${DATE}"
                avbtool add_hash_footer --partition_name boot --partition_size $((64 * 1024 * 1024)) --image boot-lz4.img --algorithm SHA256_RSA2048 --key /home/james/keys/testkey_rsa2048.pem
                cp ./boot-lz4.img ../../../${ANDROID_VERSION}-${KERNEL_VERSION}.${SUB_LEVEL}_${DATE}-boot-lz4.img
                cd ..

        elif [ "$ANDROID_VERSION" = "android13" ]; then
            mkdir bootimgs
            cp ./out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist/Image ./bootimgs
            cp ./out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist/Image.lz4 ./bootimgs
            cp ./out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist/Image ../
            cp ./out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist/Image.lz4 ../
            gzip -n -k -f -9 ./out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist/Image >../Image.gz
            cd ./bootimgs

            echo 'Building Image.gz'
            gzip -n -k -f -9 Image >Image.gz

            echo 'Building boot.img'
            mkbootimg.py --header_version 4 --kernel Image --output boot.img
            avbtool add_hash_footer --partition_name boot --partition_size $((64 * 1024 * 1024)) --image boot.img --algorithm SHA256_RSA2048 --key /home/james/keys/testkey_rsa2048.pem
            cp ./boot.img ../../../${ANDROID_VERSION}-${KERNEL_VERSION}.${SUB_LEVEL}_${DATE}-boot.img
            
            echo 'Building boot-gz.img'
            mkbootimg.py --header_version 4 --kernel Image.gz --output boot-gz.img
        	avbtool add_hash_footer --partition_name boot --partition_size $((64 * 1024 * 1024)) --image boot-gz.img --algorithm SHA256_RSA2048 --key /home/james/keys/testkey_rsa2048.pem
            cp ./boot-gz.img ../../../${ANDROID_VERSION}-${KERNEL_VERSION}.${SUB_LEVEL}_${DATE}-boot-gz.img

            echo 'Building boot-lz4.img'
            mkbootimg.py --header_version 4 --kernel Image.lz4 --output boot-lz4.img
            avbtool add_hash_footer --partition_name boot --partition_size $((64 * 1024 * 1024)) --image boot-lz4.img --algorithm SHA256_RSA2048 --key /home/james/keys/testkey_rsa2048.pem
            cp ./boot-lz4.img ../../../${ANDROID_VERSION}-${KERNEL_VERSION}.${SUB_LEVEL}_${DATE}-boot-lz4.img
            cd ..
        fi
    else
        # Use Bazel build if build.sh exists
        echo "Running Bazel build..."
        sed -i "/stable_scmversion_cmd/s/-maybe-dirty/-Wild+/g" ./build/kernel/kleaf/impl/stamp.bzl
        sed -i '2s/check_defconfig//' ./common/build.config.gki
        rm -rf ./common/android/abi_gki_protected_exports_aarch64
        rm -rf ./common/android/abi_gki_protected_exports_x86_64
        tools/bazel build --config=fast //common:kernel_aarch64_dist
        

        # Creating Boot imgs
        echo "Creating boot.imgs..."
        if [ "$ANDROID_VERSION" = "android14" ]; then
            mkdir bootimgs
            cp ./bazel-bin/common/kernel_aarch64/Image ./bootimgs
            cp ./bazel-bin/common/kernel_aarch64/Image.lz4 ./bootimgs
            cp ./bazel-bin/common/kernel_aarch64/Image ../
            cp ./bazel-bin/common/kernel_aarch64/Image.lz4 ../
            gzip -n -k -f -9 ./bazel-bin/common/kernel_aarch64/Image >../Image.gz
            cd ./bootimgs

            echo 'Building Image.gz'
            gzip -n -k -f -9 Image >Image.gz

            echo 'Building boot.img'
            mkbootimg.py --header_version 4 --kernel Image --output boot.img
            avbtool add_hash_footer --partition_name boot --partition_size $((64 * 1024 * 1024)) --image boot.img --algorithm SHA256_RSA2048 --key /home/james/keys/testkey_rsa2048.pem
            cp ./boot.img ../../../${ANDROID_VERSION}-${KERNEL_VERSION}.${SUB_LEVEL}_${DATE}-boot.img
            
            echo 'Building boot-gz.img'
            mkbootimg.py --header_version 4 --kernel Image.gz --output boot-gz.img
        	avbtool add_hash_footer --partition_name boot --partition_size $((64 * 1024 * 1024)) --image boot-gz.img --algorithm SHA256_RSA2048 --key /home/james/keys/testkey_rsa2048.pem
            cp ./boot-gz.img ../../../${ANDROID_VERSION}-${KERNEL_VERSION}.${SUB_LEVEL}_${DATE}-boot-gz.img

            echo 'Building boot-lz4.img'
            mkbootimg.py --header_version 4 --kernel Image.lz4 --output boot-lz4.img
            avbtool add_hash_footer --partition_name boot --partition_size $((64 * 1024 * 1024)) --image boot-lz4.img --algorithm SHA256_RSA2048 --key /home/james/keys/testkey_rsa2048.pem
            cp ./boot-lz4.img ../../../${ANDROID_VERSION}-${KERNEL_VERSION}.${SUB_LEVEL}_${DATE}-boot-lz4.img
            cd ..
        fi
    fi

    # Create zip in the same directory
    cd ../AnyKernel3
    ZIP_NAME="AnyKernel3-${ANDROID_VERSION}-${KERNEL_VERSION}.${SUB_LEVEL}_${DATE}.zip"
    echo "Creating zip file: $ZIP_NAME..."
    mv ../Image ./Image 
    zip -r "../../$ZIP_NAME" ./*
    rm ./Image
    ZIP_NAME="AnyKernel3-lz4-${ANDROID_VERSION}-${KERNEL_VERSION}.${SUB_LEVEL}_${DATE}.zip"
    echo "Creating zip file: $ZIP_NAME..."
    mv ../Image.lz4 ./Image.lz4 
    zip -r "../../$ZIP_NAME" ./*
    rm ./Image.lz4
    ZIP_NAME="AnyKernel3-gz-${ANDROID_VERSION}-${KERNEL_VERSION}.${SUB_LEVEL}_${DATE}.zip"
    echo "Creating zip file: $ZIP_NAME..."
    mv ../Image.gz ./Image.gz 
    zip -r "../../$ZIP_NAME" ./*
    rm ./Image.gz
    cd ../../

    RELEASE_ZIPS["$ANDROID_VERSION-$KERNEL_VERSION.$SUB_LEVEL"]+="./$ZIP_NAME "

    # Delete the $CONFIG folder after building
    echo "Deleting $CONFIG folder..."
    rm -rf "$CONFIG"
}

# Concurrent build management
for CONFIG in "${BUILD_CONFIGS[@]}"; do
    # Start the build process in the background
    build_config "$CONFIG" &

    # Limit concurrent jobs to $MAX_CONCURRENT_BUILDS
    while (( $(jobs -r | wc -l) >= MAX_CONCURRENT_BUILDS )); do
        sleep 1  # Check every second for free slots
    done
done

wait

echo "Build process complete."

exit

# Collect all zip and img files
FILES=($(find ./ -type f \( -name "*.zip" -o -name "*.img" \)))

# GitHub repository details
REPO_OWNER="TheWildJames"
REPO_NAME="GKI-KernelSU-SUSFS"
TAG_NAME="v$(date +'%Y.%m.%d-%H%M%S')"
RELEASE_NAME="GKI Kernels With KernelSU & SUSFS v1.5.2"
RELEASE_NOTES="This release contains KernelSU and SUSFS v1.5.2"

# Create the GitHub release
echo "Creating GitHub release: $RELEASE_NAME..."
gh release create "$TAG_NAME" "${FILES[@]}" \
    --repo "$REPO_OWNER/$REPO_NAME" \
    --title "$RELEASE_NAME" \
    --notes "$RELEASE_NOTES"

echo "GitHub release created with the following files:"
printf '%s\n' "${FILES[@]}"
