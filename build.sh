#!/bin/bash
set -xe
shopt -s globstar
cd "$(dirname "$0")"
source util/vars.sh

source "variants/${TARGET}-${VARIANT}.sh"

for addin in ${ADDINS[*]}; do
    source "addins/${addin}.sh"
done

if docker info -f "{{println .SecurityOptions}}" | grep rootless >/dev/null 2>&1; then
    UIDARGS=()
else
    UIDARGS=( -u "$(id -u):$(id -g)" )
fi

rm -rf ffbuild
mkdir ffbuild

FFMPEG_REPO="${FFMPEG_REPO:-https://github.com/FFmpeg/FFmpeg.git}"
FFMPEG_REPO="${FFMPEG_REPO_OVERRIDE:-$FFMPEG_REPO}"
GIT_BRANCH="${GIT_BRANCH:-master}"
GIT_BRANCH="${GIT_BRANCH_OVERRIDE:-$GIT_BRANCH}"

PATCH_REPO="${PATCH_REPO:-}"

if [[ -n "$PATCH_REPO" && -n "$REPO_TOKEN" ]]; then
    PATCH_CLONE_URL="https://x-access-token:${REPO_TOKEN}@github.com/${PATCH_REPO}.git"
else
    PATCH_CLONE_URL=""
fi

BUILD_SCRIPT="$(mktemp)"
trap "rm -f -- '$BUILD_SCRIPT'" EXIT

cat <<EOF >"$BUILD_SCRIPT"
    set -xe
    cd /ffbuild
    rm -rf ffmpeg prefix
    mkdir -p staticlibs

    git clone --filter=blob:none --branch='$GIT_BRANCH' '$FFMPEG_REPO' ffmpeg
    cd ffmpeg

    if [[ -n "$PATCH_CLONE_URL" ]]; then
        echo "Applying patches from private repository..."
        git clone --filter=blob:none --branch="$GIT_BRANCH" "$PATCH_CLONE_URL" /tmp/patches
        
        echo "Checking for patches in /tmp/patches..."
        ls -la /tmp/patches/
        
        # Simple patch application
        echo "Applying patches..."
        patch_count=0
        for patch in /tmp/patches/*.patch; do
            if [[ -f "\$patch" ]]; then
                echo "Applying patch: \$(basename "\$patch")"
                git apply "\$patch" || exit 1
                patch_count=\$((patch_count + 1))
            fi
        done
        
        if [[ \$patch_count -eq 0 ]]; then
            echo "Error: No patch files found in /tmp/patches/*.patch"
            exit 1
        fi
        
        echo "Successfully applied \$patch_count patches"
        
        rm -rf /tmp/patches
    fi

    ./configure --prefix=/ffbuild/prefix --pkg-config-flags="--static" \$FFBUILD_TARGET_FLAGS \$FF_CONFIGURE \
        --extra-cflags="\$FF_CFLAGS" --extra-cxxflags="\$FF_CXXFLAGS" --extra-libs="\$FF_LIBS" \
        --extra-ldflags="\$FF_LDFLAGS" --extra-ldexeflags="\$FF_LDEXEFLAGS" \
        --cc="\$CC" --cxx="\$CXX" --ar="\$AR" --ranlib="\$RANLIB" --nm="\$NM" \
        --extra-version="\$(date +%Y%m%d)"
    make -j\$(nproc) V=1
    
    find . -name "*.a" -exec cp {} /ffbuild/staticlibs/ \;
    
    make install install-doc
EOF

[[ -t 1 ]] && TTY_ARG="-t" || TTY_ARG=""


docker run --rm -i $TTY_ARG "${UIDARGS[@]}" -v "$PWD/ffbuild":/ffbuild -v "$BUILD_SCRIPT":/build.sh \
    -e PATCH_CLONE_URL="$PATCH_CLONE_URL" \
    -e GIT_BRANCH="$GIT_BRANCH" \
    -e FFMPEG_REPO="$FFMPEG_REPO" \
    "$IMAGE" bash /build.sh

if [[ -n "$FFBUILD_OUTPUT_DIR" ]]; then
    mkdir -p "$FFBUILD_OUTPUT_DIR"
    package_variant ffbuild/prefix "$FFBUILD_OUTPUT_DIR"
    rm -rf ffbuild
    exit 0
fi

mkdir -p artifacts
ARTIFACTS_PATH="$PWD/artifacts"
BUILD_NAME="ffmpeg-$(./ffbuild/ffmpeg/ffbuild/version.sh ffbuild/ffmpeg)-${TARGET}-${VARIANT}${ADDINS_STR:+-}${ADDINS_STR}"

mkdir -p "ffbuild/pkgroot/$BUILD_NAME"
package_variant ffbuild/prefix "ffbuild/pkgroot/$BUILD_NAME"

mkdir -p "ffbuild/pkgroot/$BUILD_NAME/lib_static"
find ffbuild/staticlibs -name '*.a' -exec cp -t "ffbuild/pkgroot/$BUILD_NAME/lib_static/" {} +

[[ -n "$LICENSE_FILE" ]] && cp "ffbuild/ffmpeg/$LICENSE_FILE" "ffbuild/pkgroot/$BUILD_NAME/LICENSE.txt"

cd ffbuild/pkgroot
if [[ "${TARGET}" == win* ]]; then
    OUTPUT_FNAME="${BUILD_NAME}.zip"
    docker run --rm -i $TTY_ARG "${UIDARGS[@]}" -v "${ARTIFACTS_PATH}":/out -v "${PWD}/${BUILD_NAME}":"/${BUILD_NAME}" -w / "$IMAGE" zip -9 -r "/out/${OUTPUT_FNAME}" "$BUILD_NAME"
else
    OUTPUT_FNAME="${BUILD_NAME}.tar.xz"
    docker run --rm -i $TTY_ARG "${UIDARGS[@]}" -v "${ARTIFACTS_PATH}":/out -v "${PWD}/${BUILD_NAME}":"/${BUILD_NAME}" -w / "$IMAGE" tar cJf "/out/${OUTPUT_FNAME}" "$BUILD_NAME"
fi
cd -

rm -rf ffbuild

if [[ -n "$GITHUB_ACTIONS" ]]; then
    echo "build_name=${BUILD_NAME}" >> "$GITHUB_OUTPUT"
    echo "${OUTPUT_FNAME}" > "${ARTIFACTS_PATH}/${TARGET}-${VARIANT}${ADDINS_STR:+-}${ADDINS_STR}.txt"
fi
