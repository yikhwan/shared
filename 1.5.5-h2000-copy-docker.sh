#!/bin/bash

# (c) Copyright 2020 Cloudera, Inc. All rights reserved.
# This script copies Docker images for Cloudera on Premises from Cloudera into your
# custom Docker Registry server under the path that you specify.
#
# Prerequisites:
# --------------
# You must run this script from a machine that either has a Docker daemon
# or Podman running, and has fast network access to the Docker Registry server.
# This could be a remote terminal or your laptop.
# You must first authenticate against your custom Docker Registry server using a credential
# that has write access to the registry location.
# $> docker login <your-docker-registry-server/some-path>
# or
# $> podman login <your-docker-registry-server/some-path>

# Basic Usage:
# ------------
# The default Docker destination is the value specified in the variable $DOCKER_REGISTRY_DEST below.
# This script is typically created as a .txt file (for security reasons) by the Cloudera on Premises
# installation wizard.
# $> bash <name-of-this-script>
#

# Performance Tip:
# ----------------
# To speed up the copying process, you can run this script multiple times in parallel on the same machine.
# It uses a common local directory to keep track of which images have been fetched by other scripts for
# the same destination. Once all the images have been fetched and uploaded successfully, this local directory
# will be removed automatically.

# Advanced Usage:
# -----------------------
# If you want to have more than one environment inside Cloudera on Premises, such as in
# a geographically distributed setting (for example, the US and UK), you can setup a second
# docker registry server to improve performance.
#
# You can use this script to copy all the Docker images to this second registry by running this command:
# $> bash <name-of-this-script> <second-docker-registry-server/repository_name>

# The next line sets the following variable to the first command line argument if present.
DOCKER_REGISTRY_DEST=${1:-dsisvr02.ds-inovasi.com:55561}
# The next line sets the following variable to the second command line argument if present.
COPY_DOCKER_MODE=${2:-DOWNLOAD_OR_PULL_AND_PUSH}

# Tip:
# ----
# To speed up the copying process, you can also run this script multiple times in parallel on the same machine.
# It uses a common local directory to keep track which images have been fetched by other scripts for
# the same destination. Once all the images have been fetched and uploaded successfully, this local directory
# will be removed automatically.

echo "This script pushes all Docker images used in Cloudera on Premises to the specified custom Docker Repository."
echo "Start download Docker images to $DOCKER_REGISTRY_DEST."
completedCount=0
errorCount=0

# replace ':' with '-' for compatibility with certain podman versions
# certain versions can't do a podman load on a filename containing a ':'
TOP_LEVEL_DIR="/tmp/cloudera/cdp-private/${DOCKER_REGISTRY_DEST//[:]/-}/1.5.5-h2000-b238"
mkdir -p $TOP_LEVEL_DIR

# determines whether to use Podman or Docker, Docker takes precedence
# the inspect format depends on whether Podman or Docker is used
PODMAN_OR_DOCKER="docker"
INSPECT_ID_FMT="{{index .Id}}"
command -v docker
if [ $? -ne 0 ]; then
  PODMAN_OR_DOCKER="podman"
  INSPECT_ID_FMT="sha256:{{.Id}}"
fi
echo "Using $PODMAN_OR_DOCKER to process the images."

# check if stdout is a terminal...
if test -t 1; then

    # see if it supports colors...
    ncolors=$(tput colors)

    if test -n "$ncolors" && test $ncolors -ge 8; then
        bold="$(tput bold)"
        normal="$(tput sgr0)"
        error="$(tput setaf 1)"
        warning="$(tput setaf 3)"
    fi
fi

onExit() {
  echo ''
  if [ "$COPY_DOCKER_MODE" = "DOWNLOAD_OR_PULL_AND_PUSH" ] || [ "$COPY_DOCKER_MODE" = "DOCKER_PUSH_ONLY" ]; then
    # The total number includes the number of all the independent docker images and
    # the number of all the docker images inside packages.
    # $completedCount should only be incremented after docker push operations.
    echo "Downloaded and pushed $completedCount/391 Docker images to $DOCKER_REGISTRY_DEST."
  fi

  if [ $completedCount -eq 391 ]; then
    rm -rf "$TOP_LEVEL_DIR"
    exit 0
  elif [ $errorCount -eq 0 ]; then
    echo "Remaining images are being processed by another script."
    exit 0
  elif [ "$COPY_DOCKER_MODE" = "DOWNLOAD_OR_PULL_AND_PUSH" ]; then
    echo "${error}Failed to download and push $errorCount images.${normal}"
    echo "${warning}Try running the script again. It will skip any images that have been processed successfully.${normal}"
    exit 1
  elif [ "$COPY_DOCKER_MODE" = "DOWNLOAD_OR_PULL_ONLY" ]; then
    echo "${error}Failed to download or pull $errorCount images.${normal}"
    echo "${warning}Try running the script again. It will skip any images that have been downloaded or pulled successfully.${normal}"
    exit 1
  elif [ "$COPY_DOCKER_MODE" = "DOCKER_PUSH_ONLY" ]; then
    echo "${error}Failed to $PODMAN_OR_DOCKER push $errorCount images.${normal}"
    echo "${warning}Try running the script again. It will skip any images that have been pushed successfully.${normal}"
    exit 1
  fi
}

onInterrupt() {
  if [ "$COPY_DOCKER_MODE" = "DOWNLOAD_OR_PULL_AND_PUSH" ]; then
    rm -f "$CURRENT_PROGRESS_MARKER"
  fi
  exit
}

trap onInterrupt SIGINT
trap onExit EXIT

# The status for each CURRENT_PROGRESS_MARKER file can contain one of the following
# started
# downloaded
# download failed
# pushing
# done

# Used when the script runs on its own and the manifest.json contains container images as tarballs.
# Used by release candidates or production builds.
downloadAndPush() {
  index=$1
  imageLocationPathAndTag=$2
  imagePathTag=$3
  imageSha=$4
  imageSize=$5
  imageTgz=$6
  imageFileName=$(basename "$imageTgz")
  imagePathTagAsFileName=$(echo "$imagePathTag"|tr / -)
  echo ''
  echo "${bold}Processing $index/391 $imagePathTag${normal}"

  export CURRENT_PROGRESS_MARKER="$TOP_LEVEL_DIR/$imagePathTagAsFileName"
  if [ ! -f "$CURRENT_PROGRESS_MARKER" ]; then
    echo 'started' > "$CURRENT_PROGRESS_MARKER"
    curl --insecure --retry 10 -C - -o "$TOP_LEVEL_DIR/$imageFileName" "https://192.168.90.18/repository/1.5.5-h2000-2/$imageTgz"
    if [ $? -ne 0 ]; then
      ((errorCount+=1))
      # This method is invoked manually by the user.
      # When pull failed, we need to make sure this file is not present so user can retry.
      rm -f "$CURRENT_PROGRESS_MARKER"
      echo "${error}Failed to download https://192.168.90.18/repository/1.5.5-h2000-2/$imageTgz${normal}"
    else
      echo 'downloaded' > "$CURRENT_PROGRESS_MARKER"
      imageRegistryAndPathTag=$($PODMAN_OR_DOCKER load -i "$TOP_LEVEL_DIR/$imageFileName"|sed -e 's/^[^:]*: //')
      actualImageSha=$($PODMAN_OR_DOCKER inspect --format="$INSPECT_ID_FMT" "$imageRegistryAndPathTag")
      if [ "$imageSha" = "$actualImageSha" ]; then
        $PODMAN_OR_DOCKER tag "$imageRegistryAndPathTag" "$DOCKER_REGISTRY_DEST/$imagePathTag"
        $PODMAN_OR_DOCKER push "$DOCKER_REGISTRY_DEST/$imagePathTag"
        dockerPushStatus=$(echo $?)

        if [ $dockerPushStatus -eq 0 ]; then
          ((completedCount+=1))
          echo 'done' > "$CURRENT_PROGRESS_MARKER"
        else
          ((errorCount+=1))
          rm -f "$CURRENT_PROGRESS_MARKER"
          echo "${error}Failed to perform $PODMAN_OR_DOCKER push $DOCKER_REGISTRY_DEST/$imagePathTag${normal}"
        fi
        $PODMAN_OR_DOCKER image rm "$DOCKER_REGISTRY_DEST/$imagePathTag"
      else
        ((errorCount+=1))
        rm -f "$CURRENT_PROGRESS_MARKER"
        echo "$imageSha is different from $actualImageSha"
        echo "${error}Image checksum for $imageRegistryAndPathTag does not match.${normal}"
      fi
      $PODMAN_OR_DOCKER image rm "$imageRegistryAndPathTag"
      rm -f "$TOP_LEVEL_DIR/$imageFileName"
    fi
  else
    status=$(cat "$CURRENT_PROGRESS_MARKER")
    if [ "$status" = "done" ]; then
      ((completedCount+=1))
      echo 'Already downloaded.'
    else
      echo 'Downloading in another script, skipping.'
    fi
  fi
}

# Used when the script runs on its own and the manifest.json DOES not contain container images as tarballs.
# Used by dev builds.
dockerPullAndPush() {
  index=$1
  imageLocationPathAndTag=$2
  imagePathTag=$3
  imageSha=$4
  imageSize=$5
  imagePathTagAsFileName=$(echo "$imagePathTag"|tr / -)
  echo ''
  echo "${bold}Processing $index/391 $imagePathTag${normal}"

  export CURRENT_PROGRESS_MARKER="$TOP_LEVEL_DIR/$imagePathTagAsFileName"
  if [ ! -f "$CURRENT_PROGRESS_MARKER" ]; then
    echo 'started' > "$CURRENT_PROGRESS_MARKER"
    $PODMAN_OR_DOCKER pull "$imageLocationPathAndTag"
    if [ $? -ne 0 ]; then
      echo "${error}Failed to $PODMAN_OR_DOCKER pull $imageLocationPathAndTag${normal}"
      ((errorCount+=1))
      # This method is invoked manually by the user.
      # When pull failed, we need to make sure this file is not present so user can retry.
      rm -f "$CURRENT_PROGRESS_MARKER"
    else
      echo 'downloaded' > "$CURRENT_PROGRESS_MARKER"
      actualImageSha=$($PODMAN_OR_DOCKER inspect --format="$INSPECT_ID_FMT" "$imageLocationPathAndTag")
      # TODO: OPSX-789 Remove || "$imageSha" != "$actualImageSha" once the image sha matches.
      if [[ "$imageSha" = "$actualImageSha" || -z "$imageSha" || "$imageSha" != "$actualImageSha" ]]; then
        $PODMAN_OR_DOCKER tag "$imageLocationPathAndTag" "$DOCKER_REGISTRY_DEST/$imagePathTag"
        $PODMAN_OR_DOCKER push "$DOCKER_REGISTRY_DEST/$imagePathTag"
        dockerPushStatus=$(echo $?)
        if [ $dockerPushStatus -eq 0 ]; then
          ((completedCount+=1))
          echo 'done' > "$CURRENT_PROGRESS_MARKER"
          echo "Pushed  $index/391 $imagePathTag"
        else
          ((errorCount+=1))
          rm -f "$CURRENT_PROGRESS_MARKER"
          echo "${error}Failed to perform $PODMAN_OR_DOCKER push $DOCKER_REGISTRY_DEST/$imagePathTag${normal}"
        fi
        $PODMAN_OR_DOCKER image rm "$DOCKER_REGISTRY_DEST/$imagePathTag"
      else
        ((errorCount+=1))
        rm -f "$CURRENT_PROGRESS_MARKER"
        echo "$imageSha is different from $actualImageSha"
        echo "${error}Image checksum for $imageLocationPathAndTag does not match.${normal}"
      fi
      $PODMAN_OR_DOCKER image rm "$imageLocationPathAndTag"
    fi
  else
    status=$(cat "$CURRENT_PROGRESS_MARKER")
    if [ "$status" = "done" ]; then
      ((completedCount+=1))
      echo 'Already downloaded.'
    else
      echo 'Downloading in another script, skipping.'
    fi
  fi
}

# Some docker images are put together in a single package.
# The status of a package can be
# 'started', 'downloaded', 'download failed', 'load failed', or 'done'.
downloadPackageOnly() {
  imageSha=$1
  imageSize=$2
  imageTgz=$3
  imageFileName=$(basename "$imageTgz")

  export CURRENT_PROGRESS_MARKER="$TOP_LEVEL_DIR/$imageFileName-status"
  status=""
  if [ -f "$CURRENT_PROGRESS_MARKER" ]; then
    status=$(cat "$CURRENT_PROGRESS_MARKER")
  fi

  # The status of a packge is different from a docker image.
  # So when it is not in a good state, we can move it to 'started'
  if [ "$status" != "started" ] && [ "$status" != "downloaded" ] && [ "$status" != "done" ]; then
    echo ''
    echo "${bold}Downloading $imageTgz${normal}"
    echo 'started' > "$CURRENT_PROGRESS_MARKER"
    curl --insecure --retry 10 -C - -o "$TOP_LEVEL_DIR/$imageFileName" "https://192.168.90.18/repository/1.5.5-h2000-2/$imageTgz"
    if [ $? -ne 0 ]; then
      ((errorCount+=1))
      # This method does only the download portion, so it needs to let
      # the corresponding push method know that the download failed.
      echo "download failed" > "$CURRENT_PROGRESS_MARKER"
      echo "${error}Failed to download https://192.168.90.18/repository/1.5.5-h2000-2/$imageTgz${normal}"
    else
      $PODMAN_OR_DOCKER load -i "$TOP_LEVEL_DIR/$imageFileName"
      if [ $? -ne 0 ]; then
        echo "load failed" > "$CURRENT_PROGRESS_MARKER"
        echo "${error}Failed to load $imageFileName"
        ((errorCount+=1))
      else
        echo "downloaded" > "$CURRENT_PROGRESS_MARKER"
      fi
    fi
  fi
}

# During production mode, some images are downloaded as part of a package.
# We need to mark those images as downloaded to unblock the docker push procedure.
markAsDownloaded() {
  imagePathTag=$1
  imageTgz=$2
  imageFileName=$(basename "$imageTgz")

  export CURRENT_PACKAGE_PROGRESS_MARKER="$TOP_LEVEL_DIR/$imageFileName-status"
  package_status=""
  if [ -f "$CURRENT_PACKAGE_PROGRESS_MARKER" ]; then
    package_status=$(cat "$CURRENT_PACKAGE_PROGRESS_MARKER")
  fi

  imagePathTagAsFileName=$(echo "$imagePathTag"|tr / -)
  export CURRENT_PROGRESS_MARKER="$TOP_LEVEL_DIR/$imagePathTagAsFileName"

  package_status=$(cat "$CURRENT_PACKAGE_PROGRESS_MARKER")
  if [ "$package_status" = "downloaded" ]; then
    status=""
    if [ -f "$CURRENT_PROGRESS_MARKER" ]; then
      status=$(cat "$CURRENT_PROGRESS_MARKER")
    fi

    # The status of an image inside a package could be either
    # nothing, 'downloaded', 'pushing', or 'done'.
    # When it is none of the above, put it in the initial state 'downloaded'.
    if [ "$status" != "downloaded" ] && [ "$status" != "pushing" ] && [ "$status" != "done" ]; then
      echo "downloaded" > "$CURRENT_PROGRESS_MARKER"
    fi
  fi
}

# Downloads the image and tag it locally.
# Used when the scripts run in pairs. One does the download and one does the push.
# Used by release candidates or production builds.
downloadOnly() {
  index=$1
  imageLocationPathAndTag=$2
  imagePathTag=$3
  imageSha=$4
  imageSize=$5
  imageTgz=$6
  imageFileName=$(basename "$imageTgz")
  imagePathTagAsFileName=$(echo "$imagePathTag"|tr / -)

  export CURRENT_PROGRESS_MARKER="$TOP_LEVEL_DIR/$imagePathTagAsFileName"
  status=""
  if [ -f "$CURRENT_PROGRESS_MARKER" ]; then
    status=$(cat "$CURRENT_PROGRESS_MARKER")
  fi

  # There could be multiple scripts processing an image.
  # So we must not try to do anything if it is already getting processed by another script.
  if [ "$status" != "downloaded" ] && [ "$status" != "pushing" ] && [ "$status" != "done" ]; then
    echo ''
    echo "${bold}Downloading $index/391 $imageTgz for $imagePathTag${normal}"
    echo 'started' > "$CURRENT_PROGRESS_MARKER"
    curl --insecure --retry 10 -C - -o "$TOP_LEVEL_DIR/$imageFileName" "https://192.168.90.18/repository/1.5.5-h2000-2/$imageTgz"
    if [ $? -ne 0 ]; then
      ((errorCount+=1))
      # This method does only the download portion, so it needs to let
      # the corresponding push method know that the download failed.
      echo "download failed" > "$CURRENT_PROGRESS_MARKER"
      echo "${error}Failed to download https://192.168.90.18/repository/1.5.5-h2000-2/$imageTgz${normal}"
    else
      imageRegistryAndPathTag=$($PODMAN_OR_DOCKER load -i "$TOP_LEVEL_DIR/$imageFileName"|sed -e 's/^[^:]*: //')
      actualImageSha=$($PODMAN_OR_DOCKER inspect --format="$INSPECT_ID_FMT" "$imageRegistryAndPathTag")
      if [ "$imageSha" = "$actualImageSha" ]; then
        $PODMAN_OR_DOCKER tag "$imageRegistryAndPathTag" "$DOCKER_REGISTRY_DEST/$imagePathTag"
        echo "downloaded" > "$CURRENT_PROGRESS_MARKER"
        echo "Downloaded  $index/391 $imageTgz"
      elif [ "$actualImageSha" = "" ]; then
        ((errorCount+=1))
        # This method does only the download portion, so it needs to let
        # the corresponding push method know that the download failed, or more specifically, the load failed.
        # However, we don't treat load failed differently, so using the same marker for both cases.
        echo "download failed" > "$CURRENT_PROGRESS_MARKER"
        echo "Could not retrieve the image information. The file $imageTgz might be invalid or inaccessible."
      else
        ((errorCount+=1))
        echo "download failed" > "$CURRENT_PROGRESS_MARKER"
        echo "$imageSha is different from $actualImageSha"
        echo "${error}Image checksum for $imageRegistryAndPathTag does not match.${normal}"
      fi
      $PODMAN_OR_DOCKER image rm "$imageRegistryAndPathTag"
    fi
  fi
}

# Pulls down the image and tag it locally.
# Used when the scripts run in pairs. One does the pull and one does the push.
# Used by dev builds.
dockerPullOnly() {
  index=$1
  imageLocationPathAndTag=$2
  imagePathTag=$3
  imageSha=$4
  imageSize=$5
  imagePathTagAsFileName=$(echo "$imagePathTag"|tr / -)

  export CURRENT_PROGRESS_MARKER="$TOP_LEVEL_DIR/$imagePathTagAsFileName"
  status=""
  if [ -f "$CURRENT_PROGRESS_MARKER" ]; then
    status=$(cat "$CURRENT_PROGRESS_MARKER")
  fi

  # There could be multiple scripts processing an image.
  # So we must not try to do anything if it is already getting processed by another script.
  if [ "$status" != "downloaded" ] && [ "$status" != "pushing" ] && [ "$status" != "done" ]; then
    echo ''
    echo "${bold}Pulling $index/391 $imagePathTag${normal}"
    echo 'started' > "$CURRENT_PROGRESS_MARKER"
    $PODMAN_OR_DOCKER pull "$imageLocationPathAndTag"
    if [ $? -ne 0 ]; then
      ((errorCount+=1))
      echo "download failed" > "$CURRENT_PROGRESS_MARKER"
      echo "${error}Failed to $PODMAN_OR_DOCKER pull $imageLocationPathAndTag${normal}"
    else
      $PODMAN_OR_DOCKER tag "$imageLocationPathAndTag" "$DOCKER_REGISTRY_DEST/$imagePathTag"
      echo "Pulled  $index/391 $imageLocationPathAndTag"
      echo "downloaded" > "$CURRENT_PROGRESS_MARKER"
    fi
    $PODMAN_OR_DOCKER image rm "$imageLocationPathAndTag"
  fi
}

# Used when the scripts run in pairs. One does the download/pull and one does the push.
# Used by either release candidates, production builds, or dev builds.
dockerPushOnly() {
  index=$1
  imageLocationPathAndTag=$2
  imagePathTag=$3
  imageSha=$4
  imageSize=$5
  performTag=$6
  imagePathTagAsFileName=$(echo "$imagePathTag"|tr / -)

  export CURRENT_PROGRESS_MARKER="$TOP_LEVEL_DIR/$imagePathTagAsFileName"
  status=""
  if [ -f "$CURRENT_PROGRESS_MARKER" ]; then
    status=$(cat "$CURRENT_PROGRESS_MARKER")
  fi

  echo ''
  echo "${bold}Processing $index/391 $imagePathTag${normal}"

  # max time out is 30 minutes
  timeout=1800
  timeElapsed=0

  # Waiting for the status to become one of the known states, so we can continue.
  until [ "$status" = "downloaded" ] || [ "$status" = "pushing" ] || [ "$status" = "download failed" ] || [ "$status" = "done" ]
  do
    if [ $timeElapsed -gt $timeout ]; then
      break
    fi
    sleep 10
    echo -n '.'
    status=$(cat "$CURRENT_PROGRESS_MARKER")
    timeElapsed=$(($timeElapsed+10))
  done
  echo ''

  if [ "$status" = "downloaded" ]; then
    # which ever script reaches here will need to change
    # the marker to something other than 'downloaded' to prevent
    # multiple push operations.
    echo "pushing" > "$CURRENT_PROGRESS_MARKER"
    echo "Pushing ..."

    if [ "$performTag" == "true" ]; then
      $PODMAN_OR_DOCKER tag "$imageLocationPathAndTag" "$DOCKER_REGISTRY_DEST/$imagePathTag"
    fi

    $PODMAN_OR_DOCKER push "$DOCKER_REGISTRY_DEST/$imagePathTag"
    dockerPushStatus=$(echo $?)
    if [ $dockerPushStatus -eq 0 ]; then
      ((completedCount+=1))
      echo "Pushed  $index/391 $imagePathTag"
      echo 'done' > "$CURRENT_PROGRESS_MARKER"
      $PODMAN_OR_DOCKER image rm "$DOCKER_REGISTRY_DEST/$imagePathTag"

      if [ "$performTag" == "true" ]; then
        $PODMAN_OR_DOCKER image rm "$imageLocationPathAndTag"
      fi
    else
      ((errorCount+=1))
      # Move the status back to downloaded sice push failed.
      echo 'downloaded' > "$CURRENT_PROGRESS_MARKER"
      echo "docker push exit code = $dockerPushStatus"
      echo "${error}Failed to perform $PODMAN_OR_DOCKER push $DOCKER_REGISTRY_DEST/$imagePathTag${normal}"
    fi
  elif [ "$status" = "done" ]; then
    # If the push script had to run for the second time, we still want to track all the done items.
    ((completedCount+=1))
    echo 'The image was already processed.'
  elif [ "$status" = "pushing" ]; then
    echo 'Pushing in another script, skipping.'
  else
    ((errorCount+=1))
    echo "${error}The image was not downloaded or pulled successfully.${normal}"
  fi
}

downloadAndPush 1 container.repository.cloudera.com/cdp-private/cloudera/admissiond:2025.0.20.2-26 cloudera/admissiond:2025.0.20.2-26 sha256:f00bf99612282eb636d3b1e3210e14fcb7f7842655bf328b252465cbaea27650 1Gi images/admissiond-2025.0.20.2-26.tar.gz false
downloadAndPush 2 container.repository.cloudera.com/cdp-private/cloudera/cml-serving/api:1.9.0-b45 cloudera/cml-serving/api:1.9.0-b45 sha256:a107f7c16cbecb6dea4ffe4eaa4a80253361fbdfc1127f112a630fa48a122c19 342Mi images/api-1.9.0-b45.tar.gz false
downloadAndPush 3 container.repository.cloudera.com/cdp-private/cloudera/cml-serving/archiver:1.9.0-b45 cloudera/cml-serving/archiver:1.9.0-b45 sha256:dc4e2c342cb25a22b72b314030b3158d314e7063b57dd03c8f532ef00fa254a9 104Mi images/archiver-1.9.0-b45.tar.gz false
downloadAndPush 4 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/longhornio/backing-image-manager:v1.8.2 cloudera_thirdparty/hardened/longhornio/backing-image-manager:v1.8.2 sha256:9262793a5aa4f00b2b193a490523f7bb7f96a235f75acac586dd6960ec4db64f 368Mi images/backing-image-manager-v1.8.2.tar.gz false
downloadAndPush 5 container.repository.cloudera.com/cdp-private/cloudera/cml-serving/base:1.9.0-b45 cloudera/cml-serving/base:1.9.0-b45 sha256:40f8b106774af68806369099f9f9d63d4e7e73cda9d94055c69c702a8b6d4a3a 75Mi images/base-1.9.0-b45.tar.gz false
downloadAndPush 6 container.repository.cloudera.com/cdp-private/cloudera/cadence-kubectl:1.2.11-b41 cloudera/cadence-kubectl:1.2.11-b41 sha256:5c94f1d5078add10a37fc16a15eaa107d25a87a8d1140aa7554f74c5ff3549b4 126Mi images/cadence-kubectl-1.2.11-b41.tar.gz false
downloadAndPush 7 container.repository.cloudera.com/cdp-private/cloudera/cadence-server:1.2.11-b41 cloudera/cadence-server:1.2.11-b41 sha256:c515bab94343caf6667708388ce92ac2717b6434323ba80af19b67f1bab53f9a 336Mi images/cadence-server-1.2.11-b41.tar.gz false
downloadAndPush 8 container.repository.cloudera.com/cdp-private/cloudera/catalogd:2025.0.20.2-26 cloudera/catalogd:2025.0.20.2-26 sha256:2d48d4f2c874856d49afd54545158026ec1d198ee6eb7f042fe7c50e2201e9ed 1Gi images/catalogd-2025.0.20.2-26.tar.gz false
downloadAndPush 9 container.repository.cloudera.com/cdp-private/cloudera/cloud/cdc-api:1.5.5-h2-b25 cloudera/cloud/cdc-api:1.5.5-h2-b25 sha256:ccbd23eb06a3b0d6e1c4aef4b6a47b2982ff096e9a20520e95b22e7dd7b0a5b0 119Mi images/cdc-api-1.5.5-h2-b25.tar.gz false
downloadAndPush 10 container.repository.cloudera.com/cdp-private/cloudera/cloud/cdc-profiler-launcher:1.5.5-h2-b28 cloudera/cloud/cdc-profiler-launcher:1.5.5-h2-b28 sha256:33e846fe1dd7c81ca8a73be6e89609557d740fb639f2f8983f2b82d561c9f707 190Mi images/cdc-profiler-launcher-1.5.5-h2-b28.tar.gz false
downloadAndPush 11 container.repository.cloudera.com/cdp-private/cloudera/cloud/cdc_profilers:1.5.5-h2-b16 cloudera/cloud/cdc_profilers:1.5.5-h2-b16 sha256:ccfb9a22e06547efb245bd1dfaab65961375c9877aa1e293d628319855303d06 4Gi images/cdc_profilers-1.5.5-h2-b16.tar.gz false
downloadAndPush 12 container.repository.cloudera.com/cdp-private/cloudera/cloud/cdc_profilers:1.5.5-h2-b16 cloudera/cloud/cdc_profilers:1.5.5-h2-b16 sha256:ccfb9a22e06547efb245bd1dfaab65961375c9877aa1e293d628319855303d06 4Gi images/cdc_profilers-1.5.5-h2-b16.tar.gz false
downloadAndPush 13 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/postgres:17.5-r2-openshift-202506162119 cloudera_thirdparty/hardened/postgres:17.5-r2-openshift-202506162119 sha256:0d81a7314dfa6740c30a83781de65a8afa99d955db8c2d2c2528fdd9d19cb22b 345Mi images/postgres-17.5-r2-openshift-202506162119.tar.gz false
downloadAndPush 14 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/cdp-embedded-db-migrate:v1.0.4 cloudera_thirdparty/cdp-embedded-db-migrate:v1.0.4 sha256:35608a8d51d11fba63b3ca36b0ae760153c965e595edc6ef27097d7d1f5a49d8 370Mi images/cdp-embedded-db-migrate-v1.0.4.tar.gz false
downloadAndPush 15 container.repository.cloudera.com/cdp-private/cloudera/cdp-request-signer:0.1.0_b286 cloudera/cdp-request-signer:0.1.0_b286 sha256:20d4478127a50f90088574958c7e9edb2755d0ff371af86fff3251457e74663f 94Mi images/cdp-request-signer-0.1.0_b286.tar.gz false
downloadAndPush 16 container.repository.cloudera.com/cdp-private/cloudera/cdpcli:1.5.5-h2000-b49 cloudera/cdpcli:1.5.5-h2000-b49 sha256:55fc900200752bd15ebd0a3b41f05759fac2bb1b5d0c6b32c5a284e23b09208d 662Mi images/cdpcli-1.5.5-h2000-b49.tar.gz false
downloadAndPush 17 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/stakater-reloader:1.3.0-r2-202503181713 cloudera_thirdparty/hardened/stakater-reloader:1.3.0-r2-202503181713 sha256:e2c8c63b5cbc26e3cb5750d31c7ed377ad8aae491e06eb78520f50aa91e1dbd7 69Mi images/stakater-reloader-1.3.0-r2-202503181713.tar.gz false
downloadAndPush 18 container.repository.cloudera.com/cdp-private/cloudera/cdsw/api:2.0.51-h2000-b100 cloudera/cdsw/api:2.0.51-h2000-b100 sha256:97f98542751579bae5c64b16878bb24b96b5cd05f81f5964217512f1f8889e30 264Mi images/api-2.0.51-h2000-b100.tar.gz false
downloadAndPush 19 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/cldr-sidecar:v1.0.0.cldr.2 cloudera_thirdparty/cldr-sidecar:v1.0.0.cldr.2 sha256:d0e753a357dee709a34f14dcbbef86ee2ad6a0451f75c3a6ebbbcd13c011f621 121Mi images/cldr-sidecar-v1.0.0.cldr.2.tar.gz false
downloadAndPush 20 container.repository.cloudera.com/cdp-private/cloudera/cdsw/buildkitd-registry-certs:2.0.51-h2000-b100 cloudera/cdsw/buildkitd-registry-certs:2.0.51-h2000-b100 sha256:7222446352a24198194b2591fd40048c91dbc39e6f549fea3f978f49c2d7406d 136Mi images/buildkitd-registry-certs-2.0.51-h2000-b100.tar.gz false
downloadAndPush 21 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/buildkit:0.20.2-r0-202503312240 cloudera_thirdparty/hardened/buildkit:0.20.2-r0-202503312240 sha256:7294958de393cfdcb49e71aed1949e29c8b09474c94cd9d5a074eb14347254bd 89Mi images/buildkit-0.20.2-r0-202503312240.tar.gz false
downloadAndPush 22 container.repository.cloudera.com/cdp-private/cloudera/cdsw/cdh-client:2.0.51-h2000-b100 cloudera/cdsw/cdh-client:2.0.51-h2000-b100 sha256:a0176ee6f6e3a074eae6c923b3861c6c10de3762a33f430227255dfb37834450 118Mi images/cdh-client-2.0.51-h2000-b100.tar.gz false
downloadAndPush 23 container.repository.cloudera.com/cdp-private/cloudera/cdsw/cdsw-ubi-minimal:2.0.51-h2000-b100 cloudera/cdsw/cdsw-ubi-minimal:2.0.51-h2000-b100 sha256:2a93cf4372e9a885673279d2cd5e3773b385e5305465c6d4f050ec348bf7c2e0 99Mi images/cdsw-ubi-minimal-2.0.51-h2000-b100.tar.gz false
downloadAndPush 24 container.repository.cloudera.com/cdp-private/cloudera/cdsw/cron:2.0.51-h2000-b100 cloudera/cdsw/cron:2.0.51-h2000-b100 sha256:5c3a7066799f0a4e94d67518727480301b1aa2ae86c5f485840ca121b9a4b935 109Mi images/cron-2.0.51-h2000-b100.tar.gz false
downloadAndPush 25 container.repository.cloudera.com/cdp-private/cloudera/cdsw/db-refresh:2.0.51-h2000-b100 cloudera/cdsw/db-refresh:2.0.51-h2000-b100 sha256:1d111f0383dbb8602e88696d4e480011efd30793a5678ebf12199fd04ab33849 104Mi images/db-refresh-2.0.51-h2000-b100.tar.gz false
downloadAndPush 26 container.repository.cloudera.com/cdp-private/cloudera/cdsw/engine-deps:2.0.51-h2000-b100 cloudera/cdsw/engine-deps:2.0.51-h2000-b100 sha256:4ba4d27c3ca3750a8ac328585c5c766ba66904c0905ffda53ca9046b4bfd5462 210Mi images/engine-deps-2.0.51-h2000-b100.tar.gz false
downloadAndPush 27 container.repository.cloudera.com/cdp-private/cloudera/cdsw/eventlog-reader:2.0.51-h2000-b100 cloudera/cdsw/eventlog-reader:2.0.51-h2000-b100 sha256:4e53253ca1ee9d3783a33afeec1712adf08dac49df8b6db7b438ce16f8ffcaf2 270Mi images/eventlog-reader-2.0.51-h2000-b100.tar.gz false
downloadAndPush 28 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/fluent-bit:4.1.1-r0-202511101924 cloudera_thirdparty/hardened/fluent-bit:4.1.1-r0-202511101924 sha256:4a05311304ddefd7ca410a35ccd5892873956c74f11e8b63e4dac549b9a0c82b 65Mi images/fluent-bit-4.1.1-r0-202511101924.tar.gz false
downloadAndPush 29 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/fluentd:1.17.1-r2-202411041725 cloudera_thirdparty/hardened/fluentd:1.17.1-r2-202411041725 sha256:0dc7e6e88ccc3e9ff12d5b5e48dbc324bc6062a228d1342bb5eed58f50507876 103Mi images/fluentd-1.17.1-r2-202411041725.tar.gz false
downloadAndPush 30 container.repository.cloudera.com/cdp-private/cloudera/cdsw/gatewayapi-to-ingress-converter:2.0.51-h2000-b100 cloudera/cdsw/gatewayapi-to-ingress-converter:2.0.51-h2000-b100 sha256:b093537e956e7acbdee442af13a1a62fd6b3d23a64610fa48737e07698a8a0fe 126Mi images/gatewayapi-to-ingress-converter-2.0.51-h2000-b100.tar.gz false
downloadAndPush 31 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/postgres:17.5-r3-openshift-202507080300 cloudera_thirdparty/hardened/postgres:17.5-r3-openshift-202507080300 sha256:68e4a3a7a51728106a450f990bcba28764ca874510fb0ff70fb753a1b27adb62 345Mi images/postgres-17.5-r3-openshift-202507080300.tar.gz false
downloadAndPush 32 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ingress-to-gatewayapi-converter:2.0.51-h2000-b100 cloudera/cdsw/ingress-to-gatewayapi-converter:2.0.51-h2000-b100 sha256:8ddf9b6d7341cd04c2e6cb6c7e4d5b889a61bbb316f5828ddd9e08e6ff4eb04e 126Mi images/ingress-to-gatewayapi-converter-2.0.51-h2000-b100.tar.gz false
downloadAndPush 33 container.repository.cloudera.com/cdp-private/cloudera/cdsw/kinit:2.0.51-h2000-b100 cloudera/cdsw/kinit:2.0.51-h2000-b100 sha256:9ed85941f84fa5e0393bf7f1c2c27c4e1974ea91a2ee73759c015086d7905e53 105Mi images/kinit-2.0.51-h2000-b100.tar.gz false
downloadAndPush 34 container.repository.cloudera.com/cdp-private/cloudera/cdsw/livelog:2.0.51-h2000-b100 cloudera/cdsw/livelog:2.0.51-h2000-b100 sha256:8065e4406ca18558b865c480552a3399b488a1bcaf1aa10c020044ef09c4e001 453Mi images/livelog-2.0.51-h2000-b100.tar.gz false
downloadAndPush 35 container.repository.cloudera.com/cdp-private/cloudera/cdsw/livelog-cleaner:2.0.51-h2000-b100 cloudera/cdsw/livelog-cleaner:2.0.51-h2000-b100 sha256:bdda3f90f3c7a83ebb28235282bd4481cc759013908d960414037043c169ae8d 112Mi images/livelog-cleaner-2.0.51-h2000-b100.tar.gz false
downloadAndPush 36 container.repository.cloudera.com/cdp-private/cloudera/cdsw/livelog-publisher:2.0.51-h2000-b100 cloudera/cdsw/livelog-publisher:2.0.51-h2000-b100 sha256:23dab6a75cfdc87178fb2a6e51c80322ff14e1ff048dea393502ade64c57262b 129Mi images/livelog-publisher-2.0.51-h2000-b100.tar.gz false
downloadAndPush 37 container.repository.cloudera.com/cdp-private/cloudera/cdsw/metrics-collector:2.0.51-h2000-b100 cloudera/cdsw/metrics-collector:2.0.51-h2000-b100 sha256:654fafb2847a7629871980562e0e11701fa3ec034a0edcb7666332b6e0e85dbf 137Mi images/metrics-collector-2.0.51-h2000-b100.tar.gz false
downloadAndPush 38 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-mlopsgovernance:1.0.3-b1798 cloudera/thunderhead-mlopsgovernance:1.0.3-b1798 sha256:03c7d1b46b59de0b5e06c91d86cf22d7cda013fd614c79f032e3584ee6cfc7ac 677Mi images/thunderhead-mlopsgovernance-1.0.3-b1798.tar.gz false
downloadAndPush 39 container.repository.cloudera.com/cdp-private/cloudera/cdsw/model-metrics:2.0.51-h2000-b100 cloudera/cdsw/model-metrics:2.0.51-h2000-b100 sha256:e2999001920a0fe6dbd1752b114d3ca2478c8c36fc785da08e2c72d52e7e408a 116Mi images/model-metrics-2.0.51-h2000-b100.tar.gz false
downloadAndPush 40 container.repository.cloudera.com/cdp-private/cloudera/cdsw/modelproxy:2.0.51-h2000-b100 cloudera/cdsw/modelproxy:2.0.51-h2000-b100 sha256:a8b9f0e942c1baf823d1de3c92b5a82478c2799e3759a871c2601ca5911573ff 114Mi images/modelproxy-2.0.51-h2000-b100.tar.gz false
downloadAndPush 41 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ntp-update:2.0.51-h2000-b100 cloudera/cdsw/ntp-update:2.0.51-h2000-b100 sha256:36e6b2f0cfcf90b3df107f3d8824913745e1c7390d759101311baafb508dc834 126Mi images/ntp-update-2.0.51-h2000-b100.tar.gz false
downloadAndPush 42 container.repository.cloudera.com/cdp-private/cloudera/cdsw/operator:2.0.51-h2000-b100 cloudera/cdsw/operator:2.0.51-h2000-b100 sha256:7778dd64c328a0929b8bbe82c870cffaf83514e3d13211aea8b9277e9d39b6be 177Mi images/operator-2.0.51-h2000-b100.tar.gz false
downloadAndPush 43 container.repository.cloudera.com/cdp-private/cloudera/cdsw/pod-security:2.0.51-h2000-b100 cloudera/cdsw/pod-security:2.0.51-h2000-b100 sha256:74e726ec84854f08d3cf2ef80ab66d5e83e46fef8c2547f9e75e3ff4b1fea0a8 309Mi images/pod-security-2.0.51-h2000-b100.tar.gz false
downloadAndPush 44 container.repository.cloudera.com/cdp-private/cloudera/cdsw/postgres:2.0.51-h2000-b100 cloudera/cdsw/postgres:2.0.51-h2000-b100 sha256:1f28e76fe935fced300a192c60e18dc437b7ba546ff75a44e3c32f58acc1a2cb 297Mi images/postgres-2.0.51-h2000-b100.tar.gz false
downloadAndPush 45 container.repository.cloudera.com/cdp-private/cloudera/cdsw/postgres-exporter:2.0.51-h2000-b100 cloudera/cdsw/postgres-exporter:2.0.51-h2000-b100 sha256:6828ba92d9915ef066d87f30944cda4aed1ba29550da76e2e6a28ccc1005a93e 119Mi images/postgres-exporter-2.0.51-h2000-b100.tar.gz false
downloadAndPush 46 container.repository.cloudera.com/cdp-private/cloudera/cdsw/reconciler:2.0.51-h2000-b100 cloudera/cdsw/reconciler:2.0.51-h2000-b100 sha256:263995b9aaf0ed349061141318575cf660f43599f05235fcb5b39eac2df69d1d 155Mi images/reconciler-2.0.51-h2000-b100.tar.gz false
downloadAndPush 47 container.repository.cloudera.com/cdp-private/cloudera/cdsw/runtime-addon-loader:2.0.51-h2000-b100 cloudera/cdsw/runtime-addon-loader:2.0.51-h2000-b100 sha256:95f84ca0dc85f3dbf4c867a7031b441664fd89408acee5c82d0c08f740e95b5b 112Mi images/runtime-addon-loader-2.0.51-h2000-b100.tar.gz false
downloadAndPush 48 container.repository.cloudera.com/cdp-private/cloudera/cdsw/runtime-manager:2.0.51-h2000-b100 cloudera/cdsw/runtime-manager:2.0.51-h2000-b100 sha256:cc2fa1b8831bf6110cc99cfd0be4b86ed598e94994dc53bdee0b8d99030aa5b6 161Mi images/runtime-manager-2.0.51-h2000-b100.tar.gz false
downloadAndPush 49 container.repository.cloudera.com/cdp-private/cloudera/cdsw/s2i-builder-buildah:2.0.51-h2000-b100 cloudera/cdsw/s2i-builder-buildah:2.0.51-h2000-b100 sha256:41705a8365fa9c53640e4dfe1dbf0c5326b451c00c90e3ffe638a766deb93371 684Mi images/s2i-builder-buildah-2.0.51-h2000-b100.tar.gz false
downloadAndPush 50 container.repository.cloudera.com/cdp-private/cloudera/cdsw/s2i-builder-buildkit:2.0.51-h2000-b100 cloudera/cdsw/s2i-builder-buildkit:2.0.51-h2000-b100 sha256:d4635b1f61a12486c94b444f35d4d42d8d3aceef97c07e1b7bcc7bdd42451fd6 500Mi images/s2i-builder-buildkit-2.0.51-h2000-b100.tar.gz false
downloadAndPush 51 container.repository.cloudera.com/cdp-private/cloudera/cdsw/s2i-client:2.0.51-h2000-b100 cloudera/cdsw/s2i-client:2.0.51-h2000-b100 sha256:7ba520c90fbc2203195fe168298cbdf6cc29b5aa34e4cf92108c627350000f0e 331Mi images/s2i-client-2.0.51-h2000-b100.tar.gz false
downloadAndPush 52 container.repository.cloudera.com/cdp-private/cloudera/cdsw/s2i-git-server:2.0.51-h2000-b100 cloudera/cdsw/s2i-git-server:2.0.51-h2000-b100 sha256:b7fade15c396090f7e6a6b5dd66bc9cccf1f0227f4f8a19d64119e6c4a21ec74 137Mi images/s2i-git-server-2.0.51-h2000-b100.tar.gz false
downloadAndPush 53 container.repository.cloudera.com/cdp-private/cloudera/cdsw/s2i-queue:2.0.51-h2000-b100 cloudera/cdsw/s2i-queue:2.0.51-h2000-b100 sha256:480e4ff07e359721f3f2d2dbaecb9a3c03397baba6b37d6d030b63bf2548d627 512Mi images/s2i-queue-2.0.51-h2000-b100.tar.gz false
downloadAndPush 54 container.repository.cloudera.com/cdp-private/cloudera/cdsw/s2i-registry:2.0.51-h2000-b100 cloudera/cdsw/s2i-registry:2.0.51-h2000-b100 sha256:d9032a3d7c723d67114d64558127e64c413149001b42ed78e810a7c136aae0bb 337Mi images/s2i-registry-2.0.51-h2000-b100.tar.gz false
downloadAndPush 55 container.repository.cloudera.com/cdp-private/cloudera/cdsw/s2i-server:2.0.51-h2000-b100 cloudera/cdsw/s2i-server:2.0.51-h2000-b100 sha256:2230e60b9cb4c6935b56eb9fe08b1f1c1ea80e9ddc1db482252e2ffbf39ef6c5 152Mi images/s2i-server-2.0.51-h2000-b100.tar.gz false
downloadAndPush 56 container.repository.cloudera.com/cdp-private/cloudera/cdsw/sdx-templates:2.0.51-h2000-b100 cloudera/cdsw/sdx-templates:2.0.51-h2000-b100 sha256:4f18c1032b154936366be1e4008d190e1d599476573c71549537dc7c6319f241 99Mi images/sdx-templates-2.0.51-h2000-b100.tar.gz false
downloadAndPush 57 container.repository.cloudera.com/cdp-private/cloudera/cdsw/secret-generator:2.0.51-h2000-b100 cloudera/cdsw/secret-generator:2.0.51-h2000-b100 sha256:1ad65e868046142315dd28e8c0136851aecaf42926586da612edf52cfa4e58f5 130Mi images/secret-generator-2.0.51-h2000-b100.tar.gz false
downloadAndPush 58 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ssh:2.0.51-h2000-b100 cloudera/cdsw/ssh:2.0.51-h2000-b100 sha256:2935c1c0b9aa6c85788a4ec193496672a7bad8a34db2da6bc0317f57b77247da 106Mi images/ssh-2.0.51-h2000-b100.tar.gz false
downloadAndPush 59 container.repository.cloudera.com/cdp-private/cloudera/cdsw/tcp-ingress-controller:2.0.51-h2000-b100 cloudera/cdsw/tcp-ingress-controller:2.0.51-h2000-b100 sha256:9bc20cd36e14f2d4c3c4a0cba19ba83b59187373f5a98cb5573753524fff21d1 115Mi images/tcp-ingress-controller-2.0.51-h2000-b100.tar.gz false
downloadAndPush 60 container.repository.cloudera.com/cdp-private/cloudera/cdsw/upgrade-db:2.0.51-h2000-b100 cloudera/cdsw/upgrade-db:2.0.51-h2000-b100 sha256:90f9f6465012f055ebf55ef32ff98e64f3ecb9ca72f1b1194f3093c1a862a81c 393Mi images/upgrade-db-2.0.51-h2000-b100.tar.gz false
downloadAndPush 61 container.repository.cloudera.com/cdp-private/cloudera/cdsw/usage-reporter:2.0.51-h2000-b100 cloudera/cdsw/usage-reporter:2.0.51-h2000-b100 sha256:29bb9f2a9b57f10c4030003701021b582f0e9e3a1c8c80f42ed73a8d77b71707 113Mi images/usage-reporter-2.0.51-h2000-b100.tar.gz false
downloadAndPush 62 container.repository.cloudera.com/cdp-private/cloudera/cdsw/user-management:2.0.51-h2000-b100 cloudera/cdsw/user-management:2.0.51-h2000-b100 sha256:017a6c1e80ed0eeb3c5807fff2d2bdca4472e21a8b7de7720a9840596f91ad7b 119Mi images/user-management-2.0.51-h2000-b100.tar.gz false
downloadAndPush 63 container.repository.cloudera.com/cdp-private/cloudera/cdsw/vfs:2.0.51-h2000-b100 cloudera/cdsw/vfs:2.0.51-h2000-b100 sha256:0129d1e479d21590e250dad9d0a9532cf627002ecf28925b8cdecf12588693e7 161Mi images/vfs-2.0.51-h2000-b100.tar.gz false
downloadAndPush 64 container.repository.cloudera.com/cdp-private/cloudera/cdsw/web:2.0.51-h2000-b100 cloudera/cdsw/web:2.0.51-h2000-b100 sha256:6d39325e803c00352075673ca0c386cdb9184b8938de562bd2b4c0f9257efff1 2Gi images/web-2.0.51-h2000-b100.tar.gz false
downloadAndPush 65 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/cdw-diagnostic-tools:v1.4 cloudera_thirdparty/cdw-diagnostic-tools:v1.4 sha256:4fac80ceb9ce49d9fa55123a5945d04fdda0d506eef607a07cc3440bf35831b2 645Mi images/cdw-diagnostic-tools-v1.4.tar.gz false
downloadAndPush 66 container.repository.cloudera.com/cdp-private/cloudera/cdw-jceks-tool:1.12.0-b92 cloudera/cdw-jceks-tool:1.12.0-b92 sha256:9f055b83ac204e22933b5a79f7898abd34eb1bc7f2e6ed4d01a029a40acd9942 86Mi images/cdw-jceks-tool-1.12.0-b92.tar.gz false
downloadAndPush 67 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/cdw-kube-fluentd-operator:v1.17.2-15 cloudera_thirdparty/cdw-kube-fluentd-operator:v1.17.2-15 sha256:eb1b34f7a643ceee1caa925ab7c7d3149f257d4ebaa6ead3043b6d0a71940edc 1Gi images/cdw-kube-fluentd-operator-v1.17.2-15.tar.gz false
downloadAndPush 68 container.repository.cloudera.com/cdp-private/cloudera/cdv/cdwdataviz:8.0.8-b39 cloudera/cdv/cdwdataviz:8.0.8-b39 sha256:29cf1c5a1fa74cde529a6936b46f679b1bc73eb41d0ee18cdbd77fdf46573c4c 3Gi images/cdwdataviz-8.0.8-b39.tar.gz false
downloadAndPush 69 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/cert-manager-cainjector:1.16.1-r0-202410251648 cloudera_thirdparty/hardened/cert-manager-cainjector:1.16.1-r0-202410251648 sha256:be9d5982be1cd169f42124dbf3430be394bf58f16e4bc1e681852081ac8a4791 49Mi images/cert-manager-cainjector-1.16.1-r0-202410251648.tar.gz false
downloadAndPush 70 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/cert-manager-controller:1.16.1-r0-202410251648 cloudera_thirdparty/hardened/cert-manager-controller:1.16.1-r0-202410251648 sha256:097cab2b9783ba42cb18e265aebda3e0548f3a5874bc40a9c786b9d71e136dbc 67Mi images/cert-manager-controller-1.16.1-r0-202410251648.tar.gz false
downloadAndPush 71 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/jetstack/cert-manager-startupapicheck:v1.16.1 cloudera_thirdparty/jetstack/cert-manager-startupapicheck:v1.16.1 sha256:c2d4b358f188d26ecff74a0e4a5ca20f391b5c526ecbd42534495e9efd940477 40Mi images/cert-manager-startupapicheck-v1.16.1.tar.gz false
downloadAndPush 72 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/cert-manager-webhook:1.16.1-r0-202410251648 cloudera_thirdparty/hardened/cert-manager-webhook:1.16.1-r0-202410251648 sha256:2b313731a62fbbc18901dfa08c0662f9674211d25ad1ee2a7d42401d9d2d5c5e 57Mi images/cert-manager-webhook-1.16.1-r0-202410251648.tar.gz false
downloadAndPush 73 container.repository.cloudera.com/cdp-private/cloudera/cdp-opentelemetry-collector:1.4.0-b9 cloudera/cdp-opentelemetry-collector:1.4.0-b9 sha256:4c3af188bd575709f1ea34fea240e2e45ed358e01d36036352ea15c9c991fc0f 331Mi images/cdp-opentelemetry-collector-1.4.0-b9.tar.gz false
downloadAndPush 74 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/cldr-sidecar:v1.0.0.cldr.1 cloudera_thirdparty/cldr-sidecar:v1.0.0.cldr.1 sha256:aa665665486cdd5cd22bffafd9dd171de310d4387f8e1c039345535cb8910061 117Mi images/cldr-sidecar-v1.0.0.cldr.1.tar.gz false
downloadAndPush 75 container.repository.cloudera.com/cdp-private/cloudera/cluster-access-manager:0.18.0-b11 cloudera/cluster-access-manager:0.18.0-b11 sha256:59f4cceea2c5e648393c092ea418c5bcc6a57418f39b90a5b18cafe3d130996c 80Mi images/cluster-access-manager-0.18.0-b11.tar.gz false
downloadAndPush 76 container.repository.cloudera.com/cdp-private/cloudera/cm-health-exporter:1.5.5-h2000-b13 cloudera/cm-health-exporter:1.5.5-h2000-b13 sha256:d41d2476fd5e3604a56aa33a7daa7c1ccba1d741fa4dc522b98070ffa168381d 136Mi images/cm-health-exporter-1.5.5-h2000-b13.tar.gz false
downloadAndPush 77 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-addon-pvc-hadoop-cli-71379092-7.1.9.1064-1:1.1.10-b2 cloudera/cdsw/ml-runtime-addon-pvc-hadoop-cli-71379092-7.1.9.1064-1:1.1.10-b2 sha256:1f7072445797cdae36be1a36c4d3c15f90df48f9eb164c3050fb6e4fc28ea0cc 922Mi images/ml-runtime-addon-pvc-hadoop-cli-71379092-7.1.9.1064-1-1.1.10-b2.tar.gz false
downloadAndPush 78 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-addon-pvc-hadoop-cli-73534044-7.3.1.600-337:1.1.12-b5 cloudera/cdsw/ml-runtime-addon-pvc-hadoop-cli-73534044-7.3.1.600-337:1.1.12-b5 sha256:e30a27494858fee50b1869e92ecdf6bea304e5eb59aff2c26a1bb5546d32ef15 1Gi images/ml-runtime-addon-pvc-hadoop-cli-73534044-7.3.1.600-337-1.1.12-b5.tar.gz false
downloadAndPush 79 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/fluent-bit:4.1.1-r0-202511101924 cloudera_thirdparty/hardened/fluent-bit:4.1.1-r0-202511101924 sha256:4a05311304ddefd7ca410a35ccd5892873956c74f11e8b63e4dac549b9a0c82b 65Mi images/fluent-bit-4.1.1-r0-202511101924.tar.gz false
downloadAndPush 80 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/fluentd:1.17.1-r2-202411041725 cloudera_thirdparty/hardened/fluentd:1.17.1-r2-202411041725 sha256:0dc7e6e88ccc3e9ff12d5b5e48dbc324bc6062a228d1342bb5eed58f50507876 103Mi images/fluentd-1.17.1-r2-202411041725.tar.gz false
downloadAndPush 81 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/kserve/huggingfaceserver:v0.15.2-gpu cloudera_thirdparty/kserve/huggingfaceserver:v0.15.2-gpu sha256:7b441f19138602057e92b015372ab2781b9bf1da02fba4d0163151c7dc123f1e 11Gi images/huggingfaceserver-v0.15.2-gpu.tar.gz false
downloadAndPush 82 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nvidia/tritonserver-pb25h2:25.08.02-py3-stig-fips-x86 cloudera_thirdparty/nvidia/tritonserver-pb25h2:25.08.02-py3-stig-fips-x86 sha256:4b4bad53a5d7fbaf5c077c513546108e18792010979d7315422b565cd8d36fe3 12Gi images/tritonserver-pb25h2-25.08.02-py3-stig-fips-x86.tar.gz false
downloadAndPush 83 container.repository.cloudera.com/cdp-private/cloudera/compute-operator:1.12.0-b92 cloudera/compute-operator:1.12.0-b92 sha256:55ab8cd18233eea21c4e82a65ff72fa687097ea516160e74b798ba93f028ae87 198Mi images/compute-operator-1.12.0-b92.tar.gz false
downloadAndPush 84 container.repository.cloudera.com/cdp-private/cloudera/compute-usage-monitor:1.12.0-b92 cloudera/compute-usage-monitor:1.12.0-b92 sha256:926f4ba09e93c37827bc4862ed87d9be0c63b98350b55e09377773c458348bf9 222Mi images/compute-usage-monitor-1.12.0-b92.tar.gz false
downloadAndPush 85 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/busybox:glibc-1.37.0-r0-202410311742 cloudera_thirdparty/hardened/busybox:glibc-1.37.0-r0-202410311742 sha256:1db4759f45b6c5a7a42d663658b241ab74ed4c6bb77ea4813d04b9fcae4eb870 7Mi images/busybox-glibc-1.37.0-r0-202410311742.tar.gz false
downloadAndPush 86 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-configtemplate:1.0.0-b13112 cloudera/thunderhead-configtemplate:1.0.0-b13112 sha256:7a4570eb2c7691237dc6c4f3cfd877909bac550baa10a76ff305c6c338281ada 550Mi images/thunderhead-configtemplate-1.0.0-b13112.tar.gz false
downloadAndPush 87 container.repository.cloudera.com/cdp-private/cloudera/configuration-sidecar:1.12.0-b92 cloudera/configuration-sidecar:1.12.0-b92 sha256:8c2976ed18116aa1152c042e76038d46b0b481bcde1e0608960327f133f3d4c6 124Mi images/configuration-sidecar-1.12.0-b92.tar.gz false
downloadAndPush 88 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/longhornio/csi-attacher:v4.9.0 cloudera_thirdparty/hardened/longhornio/csi-attacher:v4.9.0 sha256:db75e0f40b422cab72e3b0f45e64541ff660c947e19503a1accabc904df4f40d 78Mi images/csi-attacher-v4.9.0.tar.gz false
downloadAndPush 89 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/longhornio/csi-node-driver-registrar:v2.14.0 cloudera_thirdparty/hardened/longhornio/csi-node-driver-registrar:v2.14.0 sha256:b982acdbc9aef97aed274d8c9c6f42cf7de2347cbb6589f612c94b8c96fdced4 30Mi images/csi-node-driver-registrar-v2.14.0.tar.gz false
downloadAndPush 90 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/longhornio/csi-provisioner:v5.3.0 cloudera_thirdparty/hardened/longhornio/csi-provisioner:v5.3.0 sha256:656e8e61e9219130a42109638faec39251f8e9d048107bce4d019ee3ce85b215 83Mi images/csi-provisioner-v5.3.0.tar.gz false
downloadAndPush 91 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/longhornio/csi-resizer:v1.13.2 cloudera_thirdparty/hardened/longhornio/csi-resizer:v1.13.2 sha256:7a3f1c5bd33fe3c493fd66b5a19c8c58219febeb671090af11dc819f103d974d 74Mi images/csi-resizer-v1.13.2.tar.gz false
downloadAndPush 92 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/longhornio/csi-snapshotter:v8.2.0 cloudera_thirdparty/hardened/longhornio/csi-snapshotter:v8.2.0 sha256:28b683a30a82ac7bf25feac6656ba197545fe6f2fa0b291f39248ef931d6dd98 71Mi images/csi-snapshotter-v8.2.0.tar.gz false
downloadAndPush 93 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-admission-controller:1.25.1-b245 cloudera/dex/dex-admission-controller:1.25.1-b245 sha256:51d59544ee749adf416804a2a155399ff7f30dc88c909a77107debb1cbe0ddfb 115Mi images/dex-admission-controller-1.25.1-b245.tar.gz false
downloadAndPush 94 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-airflow-7.1.9.1064:1.25.1-b245 cloudera/dex/dex-airflow-7.1.9.1064:1.25.1-b245 sha256:ad5c2c524c1260cb848fb162b1bb9e4ab256019ba4a5998c64e043d262882e4a 5Gi images/dex-airflow-7.1.9.1064-1.25.1-b245.tar.gz false
downloadAndPush 95 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-airflow-7.3.1.600:1.25.1-b245 cloudera/dex/dex-airflow-7.3.1.600:1.25.1-b245 sha256:b5dbfef821f208aebac7b673ba30e609dbb935a4aacbe64959c697538760107c 5Gi images/dex-airflow-7.3.1.600-1.25.1-b245.tar.gz false
downloadAndPush 96 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-airflow-api-server-7.1.9.1064:1.25.1-b245 cloudera/dex/dex-airflow-api-server-7.1.9.1064:1.25.1-b245 sha256:c7019203a05bf509a7a74adab1dd4f8128f2def6d6e851a1708d12e3ded9f113 5Gi images/dex-airflow-api-server-7.1.9.1064-1.25.1-b245.tar.gz false
downloadAndPush 97 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-airflow-api-server-7.3.1.600:1.25.1-b245 cloudera/dex/dex-airflow-api-server-7.3.1.600:1.25.1-b245 sha256:577be9fa13ddaebd927adcadd617f029b387b62f02dff1f13edab6a7956d04ef 5Gi images/dex-airflow-api-server-7.3.1.600-1.25.1-b245.tar.gz false
downloadAndPush 98 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-airflow-connections-7.1.9.1064:1.25.1-b245 cloudera/dex/dex-airflow-connections-7.1.9.1064:1.25.1-b245 sha256:140b07384b4ecf3d338f2b0c8f457d43c6e496ac841749edbc6c81d311286b64 2Gi images/dex-airflow-connections-7.1.9.1064-1.25.1-b245.tar.gz false
downloadAndPush 99 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-airflow-connections-7.3.1.600:1.25.1-b245 cloudera/dex/dex-airflow-connections-7.3.1.600:1.25.1-b245 sha256:975b5462550e9cc36fb543bd7c77aa0edb4e89f024f04a5c97d34de288d9d11f 2Gi images/dex-airflow-connections-7.3.1.600-1.25.1-b245.tar.gz false
downloadAndPush 100 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-configs-manager:1.25.1-b245 cloudera/dex/dex-configs-manager:1.25.1-b245 sha256:6b985d3780542cd4bcd9d5bb8f4ab74231165436da812b2ac928c5e735034d12 181Mi images/dex-configs-manager-1.25.1-b245.tar.gz false
downloadAndPush 101 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-configs-templates-init-pc:1.25.1-b245 cloudera/dex/dex-configs-templates-init-pc:1.25.1-b245 sha256:e674b4a6bb645678b2d3f2b2e9799ddb047e72f428f7c7e0b4f084a260aa6e0e 75Mi images/dex-configs-templates-init-pc-1.25.1-b245.tar.gz false
downloadAndPush 102 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-configs-templates-init-pvc:1.25.1-b245 cloudera/dex/dex-configs-templates-init-pvc:1.25.1-b245 sha256:c04ebd98bf966b1cd751d07c4b5941d378869ddd7445e9ee259c9771e803f961 75Mi images/dex-configs-templates-init-pvc-1.25.1-b245.tar.gz false
downloadAndPush 103 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-cp:1.25.1-b245 cloudera/dex/dex-cp:1.25.1-b245 sha256:52a3c452e29437287f062808249ce6b2d5f0df7ce3c15746aa3adaff45a3841f 512Mi images/dex-cp-1.25.1-b245.tar.gz false
downloadAndPush 104 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-cp-cadence-worker:1.25.1-b245 cloudera/dex/dex-cp-cadence-worker:1.25.1-b245 sha256:94547f53a6f8d40f2ba876683dc92d76326ab7bada5a7008b1e5a68035c6e22c 229Mi images/dex-cp-cadence-worker-1.25.1-b245.tar.gz false
downloadAndPush 105 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-diagnostics:1.25.1-b245 cloudera/dex/dex-diagnostics:1.25.1-b245 sha256:ce5d3e642414b70f5a1e4ca2041afba93eb676fddf8937cff67583cf0c61a4f2 295Mi images/dex-diagnostics-1.25.1-b245.tar.gz false
downloadAndPush 106 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-downloads:1.25.1-b245 cloudera/dex/dex-downloads:1.25.1-b245 sha256:fd241974729b98ec802358ca9e8eb0cc5f5fb1a01fd816b6d56b9a5d02fb43dc 4Gi images/dex-downloads-1.25.1-b245.tar.gz false
downloadAndPush 107 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-efs-init:1.25.1-b245 cloudera/dex/dex-efs-init:1.25.1-b245 sha256:e5106a715927cf945e857201044dc65ae7696b54bc4a876b59bd3b7f84d8eeaf 75Mi images/dex-efs-init-1.25.1-b245.tar.gz false
downloadAndPush 108 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-eventlog-reader:1.25.1-b245 cloudera/dex/dex-eventlog-reader:1.25.1-b245 sha256:b3038572f22326b16a80447e062d6a9e5f41dbab08876e28f4ffda110ba2971f 76Mi images/dex-eventlog-reader-1.25.1-b245.tar.gz false
downloadAndPush 109 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-grafana:1.25.1-b245 cloudera/dex/dex-grafana:1.25.1-b245 sha256:94c8cf882f13f53f6fe4dc911fcfb07e71347d63b80d1296e66cc1facf6f0d58 430Mi images/dex-grafana-1.25.1-b245.tar.gz false
downloadAndPush 110 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-k8s-events-logger:1.25.1-b245 cloudera/dex/dex-k8s-events-logger:1.25.1-b245 sha256:9ad37a5234bf2ea88f454c8263e00748e1f2a07795b2d959ff7d3ebac159c950 830Mi images/dex-k8s-events-logger-1.25.1-b245.tar.gz false
downloadAndPush 111 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-keytab-management-server:1.25.1-b245 cloudera/dex/dex-keytab-management-server:1.25.1-b245 sha256:93d8299be16a02e5794334ada2c2d1e59ee7f9b33eb5b3a63a93fc1ff3d1a11f 251Mi images/dex-keytab-management-server-1.25.1-b245.tar.gz false
downloadAndPush 112 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-knox:1.25.1-b245 cloudera/dex/dex-knox:1.25.1-b245 sha256:0b287aa1b8ec12c8e8651862a16c28c03efd36421a8771799414ac7dd3670b63 903Mi images/dex-knox-1.25.1-b245.tar.gz false
downloadAndPush 113 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-livy-runtime-2.4.8-7.1.9.1064:1.25.1-b245 cloudera/dex/dex-livy-runtime-2.4.8-7.1.9.1064:1.25.1-b245 sha256:4558207d6d2f5b6f5b04c2b7684ebb7b2d69fdbbe5be425fe6b56c0e47d3c812 3Gi images/dex-livy-runtime-2.4.8-7.1.9.1064-1.25.1-b245.tar.gz false
downloadAndPush 114 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-livy-runtime-3.3.2-7.1.9.1064:1.25.1-b245 cloudera/dex/dex-livy-runtime-3.3.2-7.1.9.1064:1.25.1-b245 sha256:bbcb727737b49825aa40679b4cde3a9a499e3c26cbd4616a9276c5ebf24d3262 3Gi images/dex-livy-runtime-3.3.2-7.1.9.1064-1.25.1-b245.tar.gz false
downloadAndPush 115 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-livy-runtime-3.3.2-7.1.9.1064-compat:1.25.1-b245 cloudera/dex/dex-livy-runtime-3.3.2-7.1.9.1064-compat:1.25.1-b245 sha256:6cd13620aff90945e6380a574f67c0214e94da8073c382d2aba7c7e28a56b1e8 3Gi images/dex-livy-runtime-3.3.2-7.1.9.1064-compat-1.25.1-b245.tar.gz false
downloadAndPush 116 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-livy-runtime-3.5.4-7.1.9.1064:1.25.1-b245 cloudera/dex/dex-livy-runtime-3.5.4-7.1.9.1064:1.25.1-b245 sha256:1778a1a97ef2609b63e688a8adeffcc101a9b05ecd6f9d3a00bbf30bcabb54df 4Gi images/dex-livy-runtime-3.5.4-7.1.9.1064-1.25.1-b245.tar.gz false
downloadAndPush 117 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-livy-runtime-3.5.4-7.3.1.600:1.25.1-b245 cloudera/dex/dex-livy-runtime-3.5.4-7.3.1.600:1.25.1-b245 sha256:c9781f944a85d569e16cbe65211b082f9f814e7f85bb5033fe06d06e9a6034be 6Gi images/dex-livy-runtime-3.5.4-7.3.1.600-1.25.1-b245.tar.gz false
downloadAndPush 118 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-livy-server-2.4.8-7.1.9.1064:1.25.1-b245 cloudera/dex/dex-livy-server-2.4.8-7.1.9.1064:1.25.1-b245 sha256:f31c82dade4838e79b8fe6cd36dcd6c4e61efa3b7cd1cdb9fa9f00d8d2d9b8b4 3Gi images/dex-livy-server-2.4.8-7.1.9.1064-1.25.1-b245.tar.gz false
downloadAndPush 119 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-livy-server-3.3.2-7.1.9.1064:1.25.1-b245 cloudera/dex/dex-livy-server-3.3.2-7.1.9.1064:1.25.1-b245 sha256:361ba1e88ca66d54708a26b12b48ead5ce253fadf11c623179cc9fe9808f70e2 3Gi images/dex-livy-server-3.3.2-7.1.9.1064-1.25.1-b245.tar.gz false
downloadAndPush 120 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-livy-server-3.5.4-7.1.9.1064:1.25.1-b245 cloudera/dex/dex-livy-server-3.5.4-7.1.9.1064:1.25.1-b245 sha256:1fc28ea4c4103014a8d28910a4d9234840e039c6267f5c011562c76dc0e63953 4Gi images/dex-livy-server-3.5.4-7.1.9.1064-1.25.1-b245.tar.gz false
downloadAndPush 121 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-livy-server-3.5.4-7.3.1.600:1.25.1-b245 cloudera/dex/dex-livy-server-3.5.4-7.3.1.600:1.25.1-b245 sha256:cfcb5c984073a63e6ba940e07074ee2e4a69328d278b08f114ff09395e7c451a 6Gi images/dex-livy-server-3.5.4-7.3.1.600-1.25.1-b245.tar.gz false
downloadAndPush 122 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-migration-tool:1.25.1-b245 cloudera/dex/dex-migration-tool:1.25.1-b245 sha256:0a347e4801667234b5a7f09c0bdeee6ad839c2d5157087d980385c743230976b 174Mi images/dex-migration-tool-1.25.1-b245.tar.gz false
downloadAndPush 123 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kubernetes-dns-node-cache:1.23.1-r3-202410102224 cloudera_thirdparty/hardened/kubernetes-dns-node-cache:1.23.1-r3-202410102224 sha256:10e042acc8353dc56fae7ddb25f124c7fcddcd785063a5f15e993703ee073d97 58Mi images/kubernetes-dns-node-cache-1.23.1-r3-202410102224.tar.gz false
downloadAndPush 124 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-pipelines-api-server:1.25.1-b245 cloudera/dex/dex-pipelines-api-server:1.25.1-b245 sha256:ac1d7f68c52853eeb5ad3a6bfe9c7448cbb22b1f8207546e119174baf3a7b69e 421Mi images/dex-pipelines-api-server-1.25.1-b245.tar.gz false
downloadAndPush 125 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-runtime-airflow-python-builder-7.1.9.1064:1.25.1-b245 cloudera/dex/dex-runtime-airflow-python-builder-7.1.9.1064:1.25.1-b245 sha256:b9eb846675f78451a29bda30a721cd7adb9180051defcd052636636e9844bd68 5Gi images/dex-runtime-airflow-python-builder-7.1.9.1064-1.25.1-b245.tar.gz false
downloadAndPush 126 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-runtime-airflow-python-builder-7.3.1.600:1.25.1-b245 cloudera/dex/dex-runtime-airflow-python-builder-7.3.1.600:1.25.1-b245 sha256:894d61d269e82ab1ef48c4eff2c8cb3dd887381c17a76bf545bf033218e0ead8 6Gi images/dex-runtime-airflow-python-builder-7.3.1.600-1.25.1-b245.tar.gz false
downloadAndPush 127 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-runtime-api-kinit:1.25.1-b245 cloudera/dex/dex-runtime-api-kinit:1.25.1-b245 sha256:5eca2e212f6f91d8cae799739940d996ab71bfbf519be4170ded8231d5bac510 82Mi images/dex-runtime-api-kinit-1.25.1-b245.tar.gz false
downloadAndPush 128 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-runtime-api-server:1.25.1-b245 cloudera/dex/dex-runtime-api-server:1.25.1-b245 sha256:c669ba72343383b700966c3311467a8b26f40ae6c4402a3a94de45d444100a20 1010Mi images/dex-runtime-api-server-1.25.1-b245.tar.gz false
downloadAndPush 129 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-runtime-db-hook:1.25.1-b245 cloudera/dex/dex-runtime-db-hook:1.25.1-b245 sha256:8d9a7fce8f5b81d8c00b6fd1b83ac199e9fe50db2da8fb86f0bfda8644587bdd 608Mi images/dex-runtime-db-hook-1.25.1-b245.tar.gz false
downloadAndPush 130 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-runtime-management-authz:1.25.1-b245 cloudera/dex/dex-runtime-management-authz:1.25.1-b245 sha256:9cb384b7fcd974091bbe5af19b72431cdac3787c681022cce07f92b9f2f34e0a 261Mi images/dex-runtime-management-authz-1.25.1-b245.tar.gz false
downloadAndPush 131 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-runtime-management-cadence-worker:1.25.1-b245 cloudera/dex/dex-runtime-management-cadence-worker:1.25.1-b245 sha256:a07fda3e1ddf7bbb3bfef7f9c7298e063f2d66f2614b53b2aa3cebb8dea43553 194Mi images/dex-runtime-management-cadence-worker-1.25.1-b245.tar.gz false
downloadAndPush 132 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-runtime-management-metadata-proxy:1.25.1-b245 cloudera/dex/dex-runtime-management-metadata-proxy:1.25.1-b245 sha256:045d520ff5725ecd4d91d9852ab7bc84c394bbc43a5fc917fa11e2feadaeeb47 256Mi images/dex-runtime-management-metadata-proxy-1.25.1-b245.tar.gz false
downloadAndPush 133 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-runtime-management-metadata-proxy-templates-init:1.25.1-b245 cloudera/dex/dex-runtime-management-metadata-proxy-templates-init:1.25.1-b245 sha256:13594b394e9d1433328001d8e4d4e78c8a69ff38c79cf1c7d2913d6ec515e985 75Mi images/dex-runtime-management-metadata-proxy-templates-init-1.25.1-b245.tar.gz false
downloadAndPush 134 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-runtime-management-server:1.25.1-b245 cloudera/dex/dex-runtime-management-server:1.25.1-b245 sha256:09038d72f78bc6993412e11543c8ff27eff0871328ef4364868e286b73e47885 218Mi images/dex-runtime-management-server-1.25.1-b245.tar.gz false
downloadAndPush 135 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-runtime-python-builder-7.1.9.1064:1.25.1-b245 cloudera/dex/dex-runtime-python-builder-7.1.9.1064:1.25.1-b245 sha256:da183cfb9350255405665bbeb025b4e96abcddeac217ca02d67b4f5da23e8c3f 776Mi images/dex-runtime-python-builder-7.1.9.1064-1.25.1-b245.tar.gz false
downloadAndPush 136 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-runtime-python-builder-7.1.9.1064-compat:1.25.1-b245 cloudera/dex/dex-runtime-python-builder-7.1.9.1064-compat:1.25.1-b245 sha256:5e72270e29fbeea87426b305d5af77ba59c253815e38b3b460cbca987a4a3834 680Mi images/dex-runtime-python-builder-7.1.9.1064-compat-1.25.1-b245.tar.gz false
downloadAndPush 137 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-runtime-python-builder-7.3.1.600:1.25.1-b245 cloudera/dex/dex-runtime-python-builder-7.3.1.600:1.25.1-b245 sha256:7d60403b8a4c522483a13eddaf49672fe527890a696594bb3b930fc1153c3fb8 789Mi images/dex-runtime-python-builder-7.3.1.600-1.25.1-b245.tar.gz false
downloadAndPush 138 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-runtime-python-builder-python36-compat:1.25.1-b245 cloudera/dex/dex-runtime-python-builder-python36-compat:1.25.1-b245 sha256:f8a666177fd54fdf7b63855376655e3641ca446a1743aa5bf4bbb59a400c0bb6 653Mi images/dex-runtime-python-builder-python36-compat-1.25.1-b245.tar.gz false
downloadAndPush 139 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-safari-7.1.9.1064:1.25.1-b245 cloudera/dex/dex-safari-7.1.9.1064:1.25.1-b245 sha256:c70548abe48b60fc00f75791e68dd810398d3547aa5767d5a90e70d4786ff629 3Gi images/dex-safari-7.1.9.1064-1.25.1-b245.tar.gz false
downloadAndPush 140 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-shs-init:1.25.1-b245 cloudera/dex/dex-shs-init:1.25.1-b245 sha256:e336c75892ae74a574ee09a07b752128290410f66bc82c4cf77816d62c23f4eb 145Mi images/dex-shs-init-1.25.1-b245.tar.gz false
downloadAndPush 141 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-spark-history-server-2.4.8-7.1.9.1064:1.25.1-b245 cloudera/dex/dex-spark-history-server-2.4.8-7.1.9.1064:1.25.1-b245 sha256:5862d333fcc0d9dc9ce780d44f034a648c315d43e46f766a35fa809ea143fec0 2Gi images/dex-spark-history-server-2.4.8-7.1.9.1064-1.25.1-b245.tar.gz false
downloadAndPush 142 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-spark-history-server-3.3.2-7.1.9.1064:1.25.1-b245 cloudera/dex/dex-spark-history-server-3.3.2-7.1.9.1064:1.25.1-b245 sha256:82713f9a2b6d5d3a2e79434fa734df8525b8efc75949db0e1a4fdfee6b4cf1ce 2Gi images/dex-spark-history-server-3.3.2-7.1.9.1064-1.25.1-b245.tar.gz false
downloadAndPush 143 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-spark-history-server-3.5.4-7.1.9.1064:1.25.1-b245 cloudera/dex/dex-spark-history-server-3.5.4-7.1.9.1064:1.25.1-b245 sha256:7c8b98d304b93ee16b17ab4737d1b9f3fe4da246ae19950f6c9c671b49a36687 4Gi images/dex-spark-history-server-3.5.4-7.1.9.1064-1.25.1-b245.tar.gz false
downloadAndPush 144 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-spark-history-server-3.5.4-7.3.1.600:1.25.1-b245 cloudera/dex/dex-spark-history-server-3.5.4-7.3.1.600:1.25.1-b245 sha256:30e1c00205af199867e4596397d3de40d1d298454e6a9c68f23d02e46c8de37e 5Gi images/dex-spark-history-server-3.5.4-7.3.1.600-1.25.1-b245.tar.gz false
downloadAndPush 145 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-spark-runtime-2.4.8-7.1.9.1064:1.25.1-b245 cloudera/dex/dex-spark-runtime-2.4.8-7.1.9.1064:1.25.1-b245 sha256:4a40a6533ed07d1cda9085d14e1d91f498f4b665429a8a74a6b4da8b466f330b 3Gi images/dex-spark-runtime-2.4.8-7.1.9.1064-1.25.1-b245.tar.gz false
downloadAndPush 146 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-spark-runtime-3.3.2-7.1.9.1064:1.25.1-b245 cloudera/dex/dex-spark-runtime-3.3.2-7.1.9.1064:1.25.1-b245 sha256:0a2344d01d3e27791b7753886fa67ab0d36913d363e5498d6db1c51178f86e5c 2Gi images/dex-spark-runtime-3.3.2-7.1.9.1064-1.25.1-b245.tar.gz false
downloadAndPush 147 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-spark-runtime-3.3.2-7.1.9.1064-compat:1.25.1-b245 cloudera/dex/dex-spark-runtime-3.3.2-7.1.9.1064-compat:1.25.1-b245 sha256:b5cf3d3e2f056c4aae5e019b9097eb98bf458aa889c24be27e828b6d8118b85b 3Gi images/dex-spark-runtime-3.3.2-7.1.9.1064-compat-1.25.1-b245.tar.gz false
downloadAndPush 148 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-spark-runtime-3.5.4-7.1.9.1064:1.25.1-b245 cloudera/dex/dex-spark-runtime-3.5.4-7.1.9.1064:1.25.1-b245 sha256:63533905b4095a8fd1bf455037a79a67aadcd368c11d7c629d00b9c576cd4e0f 4Gi images/dex-spark-runtime-3.5.4-7.1.9.1064-1.25.1-b245.tar.gz false
downloadAndPush 149 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-spark-runtime-3.5.4-7.3.1.600:1.25.1-b245 cloudera/dex/dex-spark-runtime-3.5.4-7.3.1.600:1.25.1-b245 sha256:d18517ee0dd73bfef0f328f8aa5ab49161785f5d3eb896a7b972e5eb0ba1b94e 5Gi images/dex-spark-runtime-3.5.4-7.3.1.600-1.25.1-b245.tar.gz false
downloadAndPush 150 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-tgtgen-reconciler:1.25.1-b245 cloudera/dex/dex-tgtgen-reconciler:1.25.1-b245 sha256:8c5b3ed35aaf29880b2d18940b3addc1a664c76dedbad20170a7989a3955a980 162Mi images/dex-tgtgen-reconciler-1.25.1-b245.tar.gz false
downloadAndPush 151 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-tgtgen-templates-init:1.25.1-b245 cloudera/dex/dex-tgtgen-templates-init:1.25.1-b245 sha256:447e7ce1bfd21bf793aba6a69ecb7fec2976129f965acd48795dd02977ffde7c 75Mi images/dex-tgtgen-templates-init-1.25.1-b245.tar.gz false
downloadAndPush 152 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-upgrade-utils:1.25.1-b245 cloudera/dex/dex-upgrade-utils:1.25.1-b245 sha256:3e05e19eb4f3b69878bb85f0aa4de2101449e3593e649263a35117dcd83e52f1 1Gi images/dex-upgrade-utils-1.25.1-b245.tar.gz false
downloadAndPush 153 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-workload-acl-server:1.25.1-b245 cloudera/dex/dex-workload-acl-server:1.25.1-b245 sha256:5b67d98db2b9115ad866281e5184dc9f482b592d1eb677b925cf7355e399aa08 252Mi images/dex-workload-acl-server-1.25.1-b245.tar.gz false
downloadAndPush 154 container.repository.cloudera.com/cdp-private/cloudera/dex/dex-workspace-init:1.25.1-b245 cloudera/dex/dex-workspace-init:1.25.1-b245 sha256:1c5fadf7d1c62ba124351cfc846927d5ee55aa6417fd20678453d4c0ff9ac2d2 92Mi images/dex-workspace-init-1.25.1-b245.tar.gz false
downloadAndPush 155 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/busybox:glibc-1.36.1-r10-202408191623 cloudera_thirdparty/busybox:glibc-1.36.1-r10-202408191623 sha256:156dbf89f914de77e2469984edeb0823444f32273ab436da0b1cf96d80b610c9 7Mi images/busybox-glibc-1.36.1-r10-202408191623.tar.gz false
downloadAndPush 156 container.repository.cloudera.com/cdp-private/cloudera/data-connectors:0.1.0-b37 cloudera/data-connectors:0.1.0-b37 sha256:791c53950ac11795681b85a0b3bde2b74840fc8596bfdb03351ad07ae6a08a3d 140Mi images/data-connectors-0.1.0-b37.tar.gz false
downloadAndPush 157 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/mysql:8.4.3-r0-202410251846 cloudera_thirdparty/hardened/mysql:8.4.3-r0-202410251846 sha256:1efe03e36bd775bb6fc9a5b0d95f85fa07d52475d72e7d4455627d8df77ebb1d 443Mi images/mysql-8.4.3-r0-202410251846.tar.gz false
downloadAndPush 158 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/ingress-nginx-controller:1.11.5-r0-202503251929 cloudera_thirdparty/hardened/ingress-nginx-controller:1.11.5-r0-202503251929 sha256:00cb1dca6a3400f3913f206edd6f589fab998c4fb1a2bd2ee2af3a8a5023920e 403Mi images/ingress-nginx-controller-1.11.5-r0-202503251929.tar.gz false
downloadAndPush 159 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/obs/configmap-reload:v0.13.0 cloudera_thirdparty/obs/configmap-reload:v0.13.0 sha256:04a2fe5f97e7ff9492b5ea0f607a5ea02271ef78c53f3b5873a8b22137b70735 33Mi images/configmap-reload-v0.13.0.tar.gz false
downloadAndPush 160 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/pause:3.7 cloudera_thirdparty/pause:3.7 sha256:221177c6082a88ea4f6240ab2450d540955ac6f4d5454f0e15751b653ebda165 694Ki images/pause-3.7.tar.gz false
downloadAndPush 161 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/fluent-bit:4.0.4-r1-202507181342 cloudera_thirdparty/hardened/fluent-bit:4.0.4-r1-202507181342 sha256:9ec1c2fa382fbbf73e9184292217ca723e9959436df83af11d17eb2599807f92 64Mi images/fluent-bit-4.0.4-r1-202507181342.tar.gz false
downloadAndPush 162 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/fluentd:1.17.1-r2-202411041725 cloudera_thirdparty/hardened/fluentd:1.17.1-r2-202411041725 sha256:0dc7e6e88ccc3e9ff12d5b5e48dbc324bc6062a228d1342bb5eed58f50507876 103Mi images/fluentd-1.17.1-r2-202411041725.tar.gz false
downloadAndPush 163 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-configtemplate:1.0.3-b1798 cloudera/thunderhead-configtemplate:1.0.3-b1798 sha256:a4f4bdc27310853802deeba3825a257e06a58128e85dec91494d8f74306d6f55 604Mi images/thunderhead-configtemplate-1.0.3-b1798.tar.gz false
downloadAndPush 164 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-dbuswxmclient:1.10.0-b5 cloudera/thunderhead-dbuswxmclient:1.10.0-b5 sha256:9a423b76efb9946c0fbe3a046c4f2a6748865406cb5d25d67f1b48824302e3db 757Mi images/thunderhead-dbuswxmclient-1.10.0-b5.tar.gz false
downloadAndPush 165 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-tgtgenerator:1.0.3-b1798 cloudera/thunderhead-tgtgenerator:1.0.3-b1798 sha256:df311dfc539a16b9871c0db83e988ab86d02b91d4e968285de3ab42a3c7e549c 633Mi images/thunderhead-tgtgenerator-1.0.3-b1798.tar.gz false
downloadAndPush 166 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-tgtloader:1.0.3-b1798 cloudera/thunderhead-tgtloader:1.0.3-b1798 sha256:009a9661fdd079f467cf723ac76cc28e6bc92182641edbf43e8d05e0c96e0064 1Gi images/thunderhead-tgtloader-1.0.3-b1798.tar.gz false
downloadAndPush 167 container.repository.cloudera.com/cdp-private/cloudera/diagnostic-data-generator:1.12.0-b92 cloudera/diagnostic-data-generator:1.12.0-b92 sha256:97031237cb6a7ee7c87eb8ec159042a76766096c604beb09c8f96db3a0c04c28 166Mi images/diagnostic-data-generator-1.12.0-b92.tar.gz false
downloadAndPush 168 container.repository.cloudera.com/cdp-private/cloudera/dmx-app:1.5.5-h100-b5 cloudera/dmx-app:1.5.5-h100-b5 sha256:ce4aae074d23fa685a60a976d78b68269299def378cfa52f35fa15ee4a3b0527 2Gi images/dmx-app-1.5.5-h100-b5.tar.gz false
downloadAndPush 169 container.repository.cloudera.com/cdp-private/cloudera/cloud/dp-web-private:1.0.5-b117 cloudera/cloud/dp-web-private:1.0.5-b117 sha256:8ce3cae7cf12f2b296015417ea53e1a45758978569dac37e2e738c993666fc32 194Mi images/dp-web-private-1.0.5-b117.tar.gz false
downloadAndPush 170 container.repository.cloudera.com/cdp-private/cloudera/cdp-gateway:2.1.0-b288 cloudera/cdp-gateway:2.1.0-b288 sha256:fcfd992c0b120def595f635c7d2bb63ee81d152060b51fbdc5401a3516179ca3 170Mi images/cdp-gateway-2.1.0-b288.tar.gz false
downloadAndPush 171 container.repository.cloudera.com/cdp-private/cloudera/dss-app:1.5.5-h2-b25 cloudera/dss-app:1.5.5-h2-b25 sha256:c4f50e56d029806307f086d2a479a6305536745e180a7d7d30762e77d7f2fa86 1Gi images/dss-app-1.5.5-h2-b25.tar.gz false
downloadAndPush 172 container.repository.cloudera.com/cdp-private/cloudera/dwx:1.12.0-b92 cloudera/dwx:1.12.0-b92 sha256:0886fb598d6cece41259e005abe711d32970205dc095c49baa60ba072844ee9a 1Gi images/dwx-1.12.0-b92.tar.gz false
downloadAndPush 173 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/busybox:glibc-1.37.0-r0-202410311742 cloudera_thirdparty/hardened/busybox:glibc-1.37.0-r0-202410311742 sha256:1db4759f45b6c5a7a42d663658b241ab74ed4c6bb77ea4813d04b9fcae4eb870 7Mi images/busybox-glibc-1.37.0-r0-202410311742.tar.gz false
downloadAndPush 174 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kubernetes-dashboard:7.10.0-r0-202411012128 cloudera_thirdparty/hardened/kubernetes-dashboard:7.10.0-r0-202411012128 sha256:77cf8c6695eea54b5e9be7874f425d2ebf9f74b6fb7de0cfbd2527f642688b51 201Mi images/kubernetes-dashboard-7.10.0-r0-202411012128.tar.gz false
downloadAndPush 175 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kubernetes-dashboard-api:1.10.3-r0-202502251954 cloudera_thirdparty/hardened/kubernetes-dashboard-api:1.10.3-r0-202502251954 sha256:900ec6432d16b7bcfea89c48dccb720653d511401a57ecbdb1361973274a1f7b 101Mi images/kubernetes-dashboard-api-1.10.3-r0-202502251954.tar.gz false
downloadAndPush 176 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kubernetes-dashboard-auth:1.2.3-r2-202502262150 cloudera_thirdparty/hardened/kubernetes-dashboard-auth:1.2.3-r2-202502262150 sha256:731338f5c178b2fa34af04bd2a49837e07b1e97d1b7eede23adcf0b9672f2c8f 69Mi images/kubernetes-dashboard-auth-1.2.3-r2-202502262150.tar.gz false
downloadAndPush 177 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kong:3.9.0-r3-202502270232 cloudera_thirdparty/hardened/kong:3.9.0-r3-202502270232 sha256:9b6f2ec6cdac6e73b890e108e4b6e9775b105b17e33da2dc02b47951378b48d9 248Mi images/kong-3.9.0-r3-202502270232.tar.gz false
downloadAndPush 178 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kubernetes-dashboard-metrics-scraper:1.2.2-r2-202502242204 cloudera_thirdparty/hardened/kubernetes-dashboard-metrics-scraper:1.2.2-r2-202502242204 sha256:55f11fd48b57d5e92cfa9db9b5a04a364592c37f10bb648bea328cb0db74e273 57Mi images/kubernetes-dashboard-metrics-scraper-1.2.2-r2-202502242204.tar.gz false
downloadAndPush 179 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kubernetes-dashboard-web:1.6.2-r0-202502251953 cloudera_thirdparty/hardened/kubernetes-dashboard-web:1.6.2-r0-202502251953 sha256:f22089733d2340217f43032875dbf9a2b9999d54ba6c44378da0cfa6d4a7684a 203Mi images/kubernetes-dashboard-web-1.6.2-r0-202502251953.tar.gz false
downloadAndPush 180 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kube-state-metrics:2.16.0-r3-202508152121 cloudera_thirdparty/hardened/kube-state-metrics:2.16.0-r3-202508152121 sha256:9aee2cd87dca83aead0ec905a0e5904f1cc05f780e2b43abafcd29896e8a8a5b 83Mi images/kube-state-metrics-2.16.0-r3-202508152121.tar.gz false
downloadAndPush 181 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/prometheus-node-exporter:1.9.1-r6-202508162146 cloudera_thirdparty/hardened/prometheus-node-exporter:1.9.1-r6-202508162146 sha256:c11cd29a37e04bb0c46865fff36db04764dc2bda7bd4375ff13b83b9e07aedb5 33Mi images/prometheus-node-exporter-1.9.1-r6-202508162146.tar.gz false
downloadAndPush 182 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/ecs/ecs-pod-dependency-init-container:v7.0.0 cloudera_thirdparty/ecs/ecs-pod-dependency-init-container:v7.0.0 sha256:d6817e3135c23c297f5505827b3089751cf770292e4bb612c48170103955c7a0 43Mi images/ecs-pod-dependency-init-container-v7.0.0.tar.gz false
downloadAndPush 183 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/prometheus-alertmanager:0.28.1-r10-202508162146 cloudera_thirdparty/hardened/prometheus-alertmanager:0.28.1-r10-202508162146 sha256:f2482a9119288a8af92b0dd42d19cb244f7a214e4aa3100889ca9794f92a4eee 71Mi images/prometheus-alertmanager-0.28.1-r10-202508162146.tar.gz false
downloadAndPush 184 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/prometheus-config-reloader:0.84.1-r2-202508162146 cloudera_thirdparty/hardened/prometheus-config-reloader:0.84.1-r2-202508162146 sha256:36518be54d8aca7522a52be441c419ab98d8ed3dcfdbff7ac265a1aa02e7fb83 63Mi images/prometheus-config-reloader-0.84.1-r2-202508162146.tar.gz false
downloadAndPush 185 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/configmap-reload:0.15.0-r3-202508162146 cloudera_thirdparty/hardened/configmap-reload:0.15.0-r3-202508162146 sha256:af832e9bdbcd32d1fe0754f1be120eee46aff6bfd539676d0eba190670ae6c66 25Mi images/configmap-reload-0.15.0-r3-202508162146.tar.gz false
downloadAndPush 186 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/prometheus-operator:0.84.1-r2-202508162146 cloudera_thirdparty/hardened/prometheus-operator:0.84.1-r2-202508162146 sha256:24fcdc70a73a99e560965954adfc47549e8cbbf1271d40f426608e07c21c5c14 88Mi images/prometheus-operator-0.84.1-r2-202508162146.tar.gz false
downloadAndPush 187 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/prometheus:3.4.2-r5-202508162146 cloudera_thirdparty/hardened/prometheus:3.4.2-r5-202508162146 sha256:1186961699c5277c6ea4ade3793b437fd60505d115a37a3090b1333e5a1e1bb0 269Mi images/prometheus-3.4.2-r5-202508162146.tar.gz false
downloadAndPush 188 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/ecs/ecs-tolerations-webhook:v15 cloudera_thirdparty/ecs/ecs-tolerations-webhook:v15 sha256:188db7749a7c128d51be8ffaf65fb0c248c00a6d90dcd7d20ab07371cafc2256 270Mi images/ecs-tolerations-webhook-v15.tar.gz false
downloadAndPush 189 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/vault:1.20.1-r2-202508012305 cloudera_thirdparty/hardened/vault:1.20.1-r2-202508012305 sha256:6fee85173471a5ddc736c2e059f06b57b9f259dd1ff39777d7cfa19fe639e741 430Mi images/vault-1.20.1-r2-202508012305.tar.gz false
downloadAndPush 190 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/obs/vault-exporter:v2.5.1 cloudera_thirdparty/obs/vault-exporter:v2.5.1 sha256:d3f33dc22c088f01336f9d6f83bc115103e8179f32b0d78803961067121f6a28 70Mi images/vault-exporter-v2.5.1.tar.gz false
downloadAndPush 191 container.repository.cloudera.com/cdp-private/cloudera/feng:2025.0.20.2-26 cloudera/feng:2025.0.20.2-26 sha256:f37ffc89d1c8583636900866f4e3b92ee830def46212edee301a7ef24073ea33 4Gi images/feng-2025.0.20.2-26.tar.gz false
downloadAndPush 192 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/fluentd:1.17.1-r2-202411041725 cloudera_thirdparty/hardened/fluentd:1.17.1-r2-202411041725 sha256:0dc7e6e88ccc3e9ff12d5b5e48dbc324bc6062a228d1342bb5eed58f50507876 103Mi images/fluentd-1.17.1-r2-202411041725.tar.gz false
downloadAndPush 193 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/fluent-bit:3.1.9-r1-202411041952 cloudera_thirdparty/hardened/fluent-bit:3.1.9-r1-202411041952 sha256:35d638cf439e09df3127247aa26dad60967b8bd1cf4ad05212a8f9b8af32ed5c 42Mi images/fluent-bit-3.1.9-r1-202411041952.tar.gz false
downloadAndPush 194 container.repository.cloudera.com/cdp-private/cloudera/jumpgate-flyway:3.13.0-b46 cloudera/jumpgate-flyway:3.13.0-b46 sha256:7d33adf6eb7667a58cb43e3956138f4663bbb1a2637defd64f0868d70ea52cc7 1Gi images/jumpgate-flyway-3.13.0-b46.tar.gz false
downloadAndPush 195 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nvidia/gpu-feature-discovery:v0.8.2 cloudera_thirdparty/nvidia/gpu-feature-discovery:v0.8.2 sha256:3d149d6e943446056401ddec07d17710c34f67b9f62a095ed4bc4ca57c9e6bb5 416Mi images/gpu-feature-discovery-v0.8.2.tar.gz false
downloadAndPush 196 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/grafana:11.6.4-r2-202508152121 cloudera_thirdparty/hardened/grafana:11.6.4-r2-202508152121 sha256:bbeb268d00b7e1f860958e381f2327b99d75ac04bab1a7f7908a9b7d4e786ff3 610Mi images/grafana-11.6.4-r2-202508152121.tar.gz false
downloadAndPush 197 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/haproxy:3.0.5-r1-202410260041 cloudera_thirdparty/hardened/haproxy:3.0.5-r1-202410260041 sha256:3aec0f70ec0959259b4cf993848c2ba1058ad50a082486b6397fe25a1bb077dd 23Mi images/haproxy-3.0.5-r1-202410260041.tar.gz false
downloadAndPush 198 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kubectl:1.34.2-r0-202511182150 cloudera_thirdparty/hardened/kubectl:1.34.2-r0-202511182150 sha256:603caa44ee93cd5c5448285d6c12b9b7ff45e1a2a2c63a75dc4a034d51f24ac2 125Mi images/kubectl-1.34.2-r0-202511182150.tar.gz false
downloadAndPush 199 container.repository.cloudera.com/cdp-private/cloudera/hive:2025.0.20.2-26 cloudera/hive:2025.0.20.2-26 sha256:71cb75c344824dc6f5f7b051208be0abf5f15e008db037184742349414db73d2 4Gi images/hive-2025.0.20.2-26.tar.gz false
downloadAndPush 200 container.repository.cloudera.com/cdp-private/cloudera/hive-autoscaler:1.12.0-b92 cloudera/hive-autoscaler:1.12.0-b92 sha256:ff2450345cc82771e920ac95a88370a2b70469f7c33fab82f6a68c26f0fd860c 108Mi images/hive-autoscaler-1.12.0-b92.tar.gz false
downloadAndPush 201 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/http-echo:1.0.0-r9-202409162237 cloudera_thirdparty/hardened/http-echo:1.0.0-r9-202409162237 sha256:b30f5e794cb8c0352fb9f3e84b2baa8c32ab740735261de24ad3a4535e0c28c7 5Mi images/http-echo-1.0.0-r9-202409162237.tar.gz false
downloadAndPush 202 container.repository.cloudera.com/cdp-private/cloudera/hue:2025.0.20.2-26 cloudera/hue:2025.0.20.2-26 sha256:2d33182473538b93c90c399d4dfbb1f0e35236af8a9a054818fc04201433852f 4Gi images/hue-2025.0.20.2-26.tar.gz false
downloadAndPush 203 container.repository.cloudera.com/cdp-private/cloudera/huelb:2025.0.20.2-26 cloudera/huelb:2025.0.20.2-26 sha256:fc15bcc11fda32d20f7fc9e7bca97c2cfe858680fc9c6aa3139fda34abe1d7e3 653Mi images/huelb-2025.0.20.2-26.tar.gz false
downloadAndPush 204 container.repository.cloudera.com/cdp-private/cloudera/hueqp:2025.0.20.2-26 cloudera/hueqp:2025.0.20.2-26 sha256:6773b003326170b33683f1f2af2af6084f1f1cd8e8b26a072be67e55b4cef9a1 2Gi images/hueqp-2025.0.20.2-26.tar.gz false
downloadAndPush 205 container.repository.cloudera.com/cdp-private/cloudera/impala-autoscaler:1.12.0-b92 cloudera/impala-autoscaler:1.12.0-b92 sha256:c59104b7d8f2d9ec32152949252c673796f582bf5cbb3fd125e247337da497a6 198Mi images/impala-autoscaler-1.12.0-b92.tar.gz false
downloadAndPush 206 container.repository.cloudera.com/cdp-private/cloudera/impala-autoscaler-webui-metrics:1.12.0-b92 cloudera/impala-autoscaler-webui-metrics:1.12.0-b92 sha256:54d4160f4e7e2549afdb3a55a96139edf03c36426574c86274ee4c7e1de6948a 666Mi images/impala-autoscaler-webui-metrics-1.12.0-b92.tar.gz false
downloadAndPush 207 container.repository.cloudera.com/cdp-private/cloudera/impala-proxy:1.12.0-b92 cloudera/impala-proxy:1.12.0-b92 sha256:7b25c77da4bf8cf4f51ee66a493479783413ec7c64a3b3e2bcf38ceff8a945c7 196Mi images/impala-proxy-1.12.0-b92.tar.gz false
downloadAndPush 208 container.repository.cloudera.com/cdp-private/cloudera/impalad_coord_exec:2025.0.20.2-26 cloudera/impalad_coord_exec:2025.0.20.2-26 sha256:09c03986fb4a5792a9d05fd9602ee74adef8145867d8eb311272d65764afbbeb 1Gi images/impalad_coord_exec-2025.0.20.2-26.tar.gz false
downloadAndPush 209 container.repository.cloudera.com/cdp-private/cloudera/impalad_coordinator:2025.0.20.2-26 cloudera/impalad_coordinator:2025.0.20.2-26 sha256:9c3ffcfeb9afd7de0c081e307221a1becd13186b39376aa798f3e4d0e293604c 1Gi images/impalad_coordinator-2025.0.20.2-26.tar.gz false
downloadAndPush 210 container.repository.cloudera.com/cdp-private/cloudera/impalad_executor:2025.0.20.2-26 cloudera/impalad_executor:2025.0.20.2-26 sha256:5b52deb90efdf39cdf7cd4a4bec3f53c9098af6de8641383ac3b1e45b53cb217 1Gi images/impalad_executor-2025.0.20.2-26.tar.gz false
downloadAndPush 211 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/gloo-mesh/istio-d11c80c0c3fc/install-cni:1.27.3-patch0-solo-fips-distroless cloudera_thirdparty/hardened/gloo-mesh/istio-d11c80c0c3fc/install-cni:1.27.3-patch0-solo-fips-distroless sha256:7cf5cc53421339d4b11826e7a981473690cb6f0bf40b92abe86a2c3e8e6045f6 139Mi images/install-cni-1.27.3-patch0-solo-fips-distroless.tar.gz false
downloadAndPush 212 container.repository.cloudera.com/cdp-private/cloudera/jumpgate-admin:3.13.0-b46 cloudera/jumpgate-admin:3.13.0-b46 sha256:52111d222f8951422eca5a431e1e7d31118e0dc53e51ebfefc2f42b26ee535e4 101Mi images/jumpgate-admin-3.13.0-b46.tar.gz false
downloadAndPush 213 container.repository.cloudera.com/cdp-private/cloudera/jumpgate-agent:3.13.0-b46 cloudera/jumpgate-agent:3.13.0-b46 sha256:5118483922c90a9b89e95c212d185e5c85b1249fb5b494bd24c5c715106876cc 90Mi images/jumpgate-agent-3.13.0-b46.tar.gz false
downloadAndPush 214 container.repository.cloudera.com/cdp-private/cloudera/jumpgate-interop:3.13.0-b46 cloudera/jumpgate-interop:3.13.0-b46 sha256:b376bf85c62af31ff71dc4ef7f1604cedb0d63241c381cb13dcb80cdfe515336 88Mi images/jumpgate-interop-3.13.0-b46.tar.gz false
downloadAndPush 215 container.repository.cloudera.com/cdp-private/cloudera/jumpgate-proxy:3.13.0-b46 cloudera/jumpgate-proxy:3.13.0-b46 sha256:8db6ff1a4d8a694eb2e4eeeb6c0ff8a99634f46474511c07d4e1ca51e6d74e79 96Mi images/jumpgate-proxy-3.13.0-b46.tar.gz false
downloadAndPush 216 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/k8s-sidecar:1.30.9-r0-202508150721 cloudera_thirdparty/hardened/k8s-sidecar:1.30.9-r0-202508150721 sha256:ea4b69a374ba2d7a263435187d93af1fa1607edb106bf231219df0c5a0a506fe 98Mi images/k8s-sidecar-1.30.9-r0-202508150721.tar.gz false
downloadAndPush 217 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/k8tz:0.17.1-cldr cloudera_thirdparty/k8tz:0.17.1-cldr sha256:0316f389a712858b95ee63165f01806a08e45f7df65a7ebf36aa2effca05b561 35Mi images/k8tz-0.17.1-cldr.tar.gz false
downloadAndPush 218 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/keda-admission-webhooks:2.17.2-r1-202508110823 cloudera_thirdparty/hardened/keda-admission-webhooks:2.17.2-r1-202508110823 sha256:17faebce8212534e85ef84d9b82d6b2b0af8282aee04fd3ea5fabd71d7031577 65Mi images/keda-admission-webhooks-2.17.2-r1-202508110823.tar.gz false
downloadAndPush 219 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/keda-metrics-apiserver:2.17.2-r1-202508110823 cloudera_thirdparty/hardened/keda-metrics-apiserver:2.17.2-r1-202508110823 sha256:14e1411ec492081ae7337a62ad1a76c3e93f0421e5b1fee4e99fcc842e59fc5e 132Mi images/keda-metrics-apiserver-2.17.2-r1-202508110823.tar.gz false
downloadAndPush 220 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/keda:2.17.2-r1-202508110823 cloudera_thirdparty/hardened/keda:2.17.2-r1-202508110823 sha256:b0f8a7a649df22180ec1683ac1bc11a4fdda2f1a705b287742d0db3058d5595a 182Mi images/keda-2.17.2-r1-202508110823.tar.gz false
downloadAndPush 221 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/knative-serving-activator:v1.17.2-r6-202511241738 cloudera_thirdparty/hardened/knative-serving-activator:v1.17.2-r6-202511241738 sha256:7b9e7116e62dbba40cae1d72bc36570cfc07d69ad364156692015142526b684f 62Mi images/knative-serving-activator-v1.17.2-r6-202511241738.tar.gz false
downloadAndPush 222 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/knative-serving-autoscaler:v1.17.2-r6-202511241908 cloudera_thirdparty/hardened/knative-serving-autoscaler:v1.17.2-r6-202511241908 sha256:2757f4d10f43a24c6671b90bf5b85726469bad4eb095df6f95fee10d213ad56a 62Mi images/knative-serving-autoscaler-v1.17.2-r6-202511241908.tar.gz false
downloadAndPush 223 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/knative-serving-controller:v1.17.2-r6-202511241854 cloudera_thirdparty/hardened/knative-serving-controller:v1.17.2-r6-202511241854 sha256:38afc8b31822ede6da46f24937c8ac2d8b9284a968519dbeba78b46bb7d511b3 71Mi images/knative-serving-controller-v1.17.2-r6-202511241854.tar.gz false
downloadAndPush 224 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/knative-releases/knative.dev/pkg/apiextensions/storageversion/cmd/migrate:v1.17.6 cloudera_thirdparty/hardened/knative-releases/knative.dev/pkg/apiextensions/storageversion/cmd/migrate:v1.17.6 sha256:609db2a0ab2d3b6e9f31c6fee595334d5068e9a6a729f48634f379631ac35505 41Mi images/migrate-v1.17.6.tar.gz false
downloadAndPush 225 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/knative-serving-queue:v1.17.2-r6-202511241854 cloudera_thirdparty/hardened/knative-serving-queue:v1.17.2-r6-202511241854 sha256:bc0af0ac5498280fd5d2821e3290b39f9411ff980e1e8aba9c217cee4bd1b0b3 30Mi images/knative-serving-queue-v1.17.2-r6-202511241854.tar.gz false
downloadAndPush 226 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/knative-serving-webhook:v1.17.2-r6-202511241746 cloudera_thirdparty/hardened/knative-serving-webhook:v1.17.2-r6-202511241746 sha256:a63af77ddcc6731e960eacd9a9af7706c2c175f269070d67652b7ffe02cbde6e 61Mi images/knative-serving-webhook-v1.17.2-r6-202511241746.tar.gz false
downloadAndPush 227 container.repository.cloudera.com/cdp-private/cloudera/cml-serving/knox-gateway:1.9.0-b45 cloudera/cml-serving/knox-gateway:1.9.0-b45 sha256:f37e53a5b89c95446389806760ccfdd7ac25298ab611a7aba1da9fc5816ec746 2Gi images/knox-gateway-1.9.0-b45.tar.gz false
downloadAndPush 228 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kserve-agent:0.15.2-r5 cloudera_thirdparty/hardened/kserve-agent:0.15.2-r5 sha256:46563d8646686a22a4ca86589234313aba27edddf6569d8ec3a3f0ebf6264ab1 75Mi images/kserve-agent-0.15.2-r5.tar.gz false
downloadAndPush 229 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kserve-controller:0.15.2-r5 cloudera_thirdparty/hardened/kserve-controller:0.15.2-r5 sha256:caee9734f5845b58778c254746c0f610393bea40f016f5088531596f1312e9db 85Mi images/kserve-controller-0.15.2-r5.tar.gz false
downloadAndPush 230 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kserve/kserve-localmodel-controller:v0.15.1 cloudera_thirdparty/hardened/kserve/kserve-localmodel-controller:v0.15.1 sha256:0b074c638d9b1ca777cf1ebc747c2c85bb515d3fe2ed5829c737307cbd745151 101Mi images/kserve-localmodel-controller-v0.15.1.tar.gz false
downloadAndPush 231 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/kserve/qpext:v0.12.0-rc1 cloudera_thirdparty/kserve/qpext:v0.12.0-rc1 sha256:49992422fa1001581d2774dc3b122fbc87b334247822f2328103060290c5fb1f 34Mi images/qpext-v0.12.0-rc1.tar.gz false
downloadAndPush 232 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kserve-rest-proxy:0.12.0-r11-202511202151 cloudera_thirdparty/hardened/kserve-rest-proxy:0.12.0-r11-202511202151 sha256:b16b5dc237250236463ccab33793fd483b98a943a8115345bedef7f3a08c363c 17Mi images/kserve-rest-proxy-0.12.0-r11-202511202151.tar.gz false
downloadAndPush 233 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kserve-router:0.15.2-r5 cloudera_thirdparty/hardened/kserve-router:0.15.2-r5 sha256:c7a7a237fe9655c84cc0a9ccd6ed4c5f044ee10c4ef9421f6e144a2c9670eea1 64Mi images/kserve-router-0.15.2-r5.tar.gz false
downloadAndPush 234 container.repository.cloudera.com/cdp-private/cloudera/cml-serving/kserve_storage_initializer:1.9.0-b45 cloudera/cml-serving/kserve_storage_initializer:1.9.0-b45 sha256:42aa7385943b13462aa7076543ae87226bc1b4aa5bfe617a0cbb2e7e6021e3c0 1Gi images/kserve_storage_initializer-1.9.0-b45.tar.gz false
downloadAndPush 235 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kube-rbac-proxy:0.20.0-r1-202511202338 cloudera_thirdparty/hardened/kube-rbac-proxy:0.20.0-r1-202511202338 sha256:bb7fa9c41e500fc725ab6a90d28c2e77fdddf532e5466f0ce5cf9b28838144da 74Mi images/kube-rbac-proxy-0.20.0-r1-202511202338.tar.gz false
downloadAndPush 236 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/leader-elector:v1.4 cloudera_thirdparty/leader-elector:v1.4 sha256:2696f0c2c8f33feaba2f73355b22753a554878534b5a18dff38e16f3e36432e6 108Mi images/leader-elector-v1.4.tar.gz false
downloadAndPush 237 container.repository.cloudera.com/cdp-private/cloudera/liftie:1.29.10-b16 cloudera/liftie:1.29.10-b16 sha256:5919c7b3fa6450d6f8dd4d1493c1b8f6328d4b5e21c651f2ae4ec5802f2b5347 2Gi images/liftie-1.29.10-b16.tar.gz false
downloadAndPush 238 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/longhornio/livenessprobe:v2.16.0 cloudera_thirdparty/hardened/longhornio/livenessprobe:v2.16.0 sha256:9ec90e5cbd3b9790ce7962d514ad7fd0db5030959f02e595623ade2ebb447a08 30Mi images/livenessprobe-v2.16.0.tar.gz false
downloadAndPush 239 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/rancher/local-path-provisioner:v0.0.31 cloudera_thirdparty/rancher/local-path-provisioner:v0.0.31 sha256:8309ed19e06b99d27ea8ade9635fc3aaec0dfaf906fcf71706a679ea444df01f 57Mi images/local-path-provisioner-v0.0.31.tar.gz false
downloadAndPush 240 container.repository.cloudera.com/cdp-private/cloudera/logger-alert-receiver:1.5.5-h2000-b13 cloudera/logger-alert-receiver:1.5.5-h2000-b13 sha256:b41b56b0e02402267aa050df7e31d2079ab1c5697acbb9a8df2b2b10e0d39cc0 251Mi images/logger-alert-receiver-1.5.5-h2000-b13.tar.gz false
downloadAndPush 241 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/longhornio/longhorn-engine:v1.8.2 cloudera_thirdparty/hardened/longhornio/longhorn-engine:v1.8.2 sha256:bd1805499c1ae61aa0fecf0d25db2820bdf9ae483fbb1605a3e1141c659840f0 390Mi images/longhorn-engine-v1.8.2.tar.gz false
downloadAndPush 242 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/longhornio/longhorn-instance-manager:v1.8.2 cloudera_thirdparty/hardened/longhornio/longhorn-instance-manager:v1.8.2 sha256:36043bd21ffde8257e251e8329078c01f3418f64ff5edb61ecbca54ceb9502f1 1007Mi images/longhorn-instance-manager-v1.8.2.tar.gz false
downloadAndPush 243 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/longhornio/longhorn-manager:v1.8.2 cloudera_thirdparty/hardened/longhornio/longhorn-manager:v1.8.2 sha256:ccecd2ff11e618c6e25160f0905a50e4fa582287531e5fe8599658b90b91eacc 325Mi images/longhorn-manager-v1.8.2.tar.gz false
downloadAndPush 244 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/longhornio/longhorn-share-manager:v1.8.2 cloudera_thirdparty/hardened/longhornio/longhorn-share-manager:v1.8.2 sha256:c133262b4c2ee06263f36c8e48aad4fe56ee0af49430d305980fbeadfbccba4d 238Mi images/longhorn-share-manager-v1.8.2.tar.gz false
downloadAndPush 245 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/longhornio/longhorn-ui:v1.8.2 cloudera_thirdparty/hardened/longhornio/longhorn-ui:v1.8.2 sha256:b33f5bd5dcb4fdf879c339350645b02a316a95add84de602431253d0fec01aa7 211Mi images/longhorn-ui-v1.8.2.tar.gz false
downloadAndPush 246 container.repository.cloudera.com/cdp-private/cloudera/metrics-server-exporter:1.5.5-h2000-b13 cloudera/metrics-server-exporter:1.5.5-h2000-b13 sha256:2829447c6669df02381c49e87a22f1b91730e1a64afdf221a2f3a6e8132cd709 250Mi images/metrics-server-exporter-1.5.5-h2000-b13.tar.gz false
downloadAndPush 247 container.repository.cloudera.com/cdp-private/cloudera/mlx-control-plane-app:1.51.0-h2000-b148 cloudera/mlx-control-plane-app:1.51.0-h2000-b148 sha256:5e654885f29b6f6ea7654a1d159e1b20ff1d23615cb1960baec6342dacb7f06d 506Mi images/mlx-control-plane-app-1.51.0-h2000-b148.tar.gz false
downloadAndPush 248 container.repository.cloudera.com/cdp-private/cloudera/mlx-control-plane-app-cadence-worker:1.51.0-h2000-b148 cloudera/mlx-control-plane-app-cadence-worker:1.51.0-h2000-b148 sha256:7a4a4f82d188e1e1fb57cfbe3856ea097933c71bb775f351f98d0497fbe39052 2Gi images/mlx-control-plane-app-cadence-worker-1.51.0-h2000-b148.tar.gz false
downloadAndPush 249 container.repository.cloudera.com/cdp-private/cloudera/mlx-control-plane-app-cdsw-migrator:1.51.0-h2000-b148 cloudera/mlx-control-plane-app-cdsw-migrator:1.51.0-h2000-b148 sha256:04905e79009def69cf8f53c01e6cce443d359871a730aea04df70c3d99a07475 298Mi images/mlx-control-plane-app-cdsw-migrator-1.51.0-h2000-b148.tar.gz false
downloadAndPush 250 container.repository.cloudera.com/cdp-private/cloudera/mlx-control-plane-app-health-poller:1.51.0-h2000-b148 cloudera/mlx-control-plane-app-health-poller:1.51.0-h2000-b148 sha256:d02ce8eaede09a472da8c1492d8911dba6e3342ca0f040d69f9f145b88ecae1c 206Mi images/mlx-control-plane-app-health-poller-1.51.0-h2000-b148.tar.gz false
downloadAndPush 251 container.repository.cloudera.com/cdp-private/cloudera/cdsw/third-party/model-registry:1.12.0-b31 cloudera/cdsw/third-party/model-registry:1.12.0-b31 sha256:dc0b791fc3d9b6da8a95ba15daf653ec1b2241099d1ab286fae7137ff270d3e6 2Gi images/model-registry-1.12.0-b31.tar.gz false
downloadAndPush 252 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/fluent-bit:4.1.1-r0-202511101924 cloudera_thirdparty/hardened/fluent-bit:4.1.1-r0-202511101924 sha256:4a05311304ddefd7ca410a35ccd5892873956c74f11e8b63e4dac549b9a0c82b 65Mi images/fluent-bit-4.1.1-r0-202511101924.tar.gz false
downloadAndPush 253 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/fluentd:1.17.1-r2-202411041725 cloudera_thirdparty/hardened/fluentd:1.17.1-r2-202411041725 sha256:0dc7e6e88ccc3e9ff12d5b5e48dbc324bc6062a228d1342bb5eed58f50507876 103Mi images/fluentd-1.17.1-r2-202411041725.tar.gz false
downloadAndPush 254 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/prometheus-alertmanager:0.28.1-r10-202509051806 cloudera_thirdparty/hardened/prometheus-alertmanager:0.28.1-r10-202509051806 sha256:181e768e8bd4a15ddc9468b5aae794e8105775abdc53e668d454a55a01f0d637 71Mi images/prometheus-alertmanager-0.28.1-r10-202509051806.tar.gz false
downloadAndPush 255 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/fluentd:1.19.0-r1-202509071523 cloudera_thirdparty/hardened/fluentd:1.19.0-r1-202509071523 sha256:1fdfcd4e6b1bdadd0ab31f23de16f4ad087701a169094683fe3eaa78bd9fb681 192Mi images/fluentd-1.19.0-r1-202509071523.tar.gz false
downloadAndPush 256 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/grafana:12.1.2-r0-202509240036 cloudera_thirdparty/hardened/grafana:12.1.2-r0-202509240036 sha256:1362908fc1042bd6eb5accb4cb98715a8891ce87c1d7e97ffcac094a71d1b928 691Mi images/grafana-12.1.2-r0-202509240036.tar.gz false
downloadAndPush 257 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/k8s-sidecar:1.30.10-r0-202509051806 cloudera_thirdparty/hardened/k8s-sidecar:1.30.10-r0-202509051806 sha256:f95bcd1308311b11504cc43c93f81e83ef6ae449c9091d9abd1a48a8b90b8870 99Mi images/k8s-sidecar-1.30.10-r0-202509051806.tar.gz false
downloadAndPush 258 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kube-state-metrics:2.17.0-r0-202509051806 cloudera_thirdparty/hardened/kube-state-metrics:2.17.0-r0-202509051806 sha256:f131ec87caba08b1511f22a0bf93806c284fc449896732d2cb7e8b1844cc4817 85Mi images/kube-state-metrics-2.17.0-r0-202509051806.tar.gz false
downloadAndPush 259 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/prometheus-node-exporter:1.9.1-r6-202509051806 cloudera_thirdparty/hardened/prometheus-node-exporter:1.9.1-r6-202509051806 sha256:28090737935b228845ca6b27d632b709fcb743ce689d9ae45c49162faea3698f 33Mi images/prometheus-node-exporter-1.9.1-r6-202509051806.tar.gz false
downloadAndPush 260 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/prometheus:3.5.0-r6-202509051806 cloudera_thirdparty/hardened/prometheus:3.5.0-r6-202509051806 sha256:2c95d8c073985a83eb620a04953b25914244fbb6fdb2339db51ce0d96b2f5ea9 276Mi images/prometheus-3.5.0-r6-202509051806.tar.gz false
downloadAndPush 261 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/configmap-reload:0.15.0-r3-202509051806 cloudera_thirdparty/hardened/configmap-reload:0.15.0-r3-202509051806 sha256:3937e59887e341d30586395d1cfcb5e769f26613d5412f70c5a1a626a63d3b77 25Mi images/configmap-reload-0.15.0-r3-202509051806.tar.gz false
downloadAndPush 262 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/prometheus-pushgateway:1.11.1-r5-202509051806 cloudera_thirdparty/hardened/prometheus-pushgateway:1.11.1-r5-202509051806 sha256:e2276a8641d3fea8437adf5c4cdc4ddb9c10bb534704a7316c24617db393c349 32Mi images/prometheus-pushgateway-1.11.1-r5-202509051806.tar.gz false
downloadAndPush 263 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/obs/snmp_notifier:v2.1.0.cldr.1 cloudera_thirdparty/obs/snmp_notifier:v2.1.0.cldr.1 sha256:2d3ef399c947bce1e7a4ae9cc9005eec146600f021ee75b52a851e46d697706f 86Mi images/snmp_notifier-v2.1.0.cldr.1.tar.gz false
downloadAndPush 264 container.repository.cloudera.com/cdp-private/cloudera/monitoring-app:1.5.5-h2000-b13 cloudera/monitoring-app:1.5.5-h2000-b13 sha256:576367b5fe3a7c95462c64696bf2ed36e88c1605de9d4aff52213c2453fa38d0 759Mi images/monitoring-app-1.5.5-h2000-b13.tar.gz false
downloadAndPush 265 container.repository.cloudera.com/cdp-private/cloudera/monitoring-controller-manager:1.5.5-h2000-b13 cloudera/monitoring-controller-manager:1.5.5-h2000-b13 sha256:e0f3db092c3ba7d297c4f36c1728ff7e5f352fe02f9b9302e4fd0f2b89bbe79d 216Mi images/monitoring-controller-manager-1.5.5-h2000-b13.tar.gz false
downloadAndPush 266 container.repository.cloudera.com/cdp-private/cloudera/multilog-init:1.5.5-h2000-b13 cloudera/multilog-init:1.5.5-h2000-b13 sha256:d6293dad4d8979b3990755873bb3010139c8389d64fbbfc493770f07a67ee447 112Mi images/multilog-init-1.5.5-h2000-b13.tar.gz false
downloadAndPush 267 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/nvidia/nemotron-nano-12b-v2-vl:1.5.0 cloudera_thirdparty/nim/nvidia/nemotron-nano-12b-v2-vl:1.5.0 sha256:c480d963a4eec9e34ec9c6abc7a6e3ca0fcc9d2a8e54fb13fb4a854f18170bdf 24Gi images/nemotron-nano-12b-v2-vl-1.5.0.tar.gz false
downloadAndPush 268 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/knative-releases/knative.dev/net-istio/cmd/controller:v1.20.1 cloudera_thirdparty/hardened/knative-releases/knative.dev/net-istio/cmd/controller:v1.20.1 sha256:aa1ea5d272d845b79598119ebf3dd2fb958f8ef238afe6fa9c8aff3dc759e965 69Mi images/controller-v1.20.1.tar.gz false
downloadAndPush 269 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/knative-releases/knative.dev/net-istio/cmd/webhook:v1.20.1 cloudera_thirdparty/hardened/knative-releases/knative.dev/net-istio/cmd/webhook:v1.20.1 sha256:f4901094d958b32c23185050a9db0cca99b87bf767f5411e28c8df4af98cb073 64Mi images/webhook-v1.20.1.tar.gz false
downloadAndPush 270 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/baidu/paddleocr:1.5.0 cloudera_thirdparty/nim/baidu/paddleocr:1.5.0 sha256:ead9d9b7db171e24cff22d6614b13b4af918bf77079aac1d72abcddb4a077d40 10Gi images/paddleocr-1.5.0.tar.gz false
downloadAndPush 271 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/bigcode/starcoder2-7b:1.14.1 cloudera_thirdparty/nim/bigcode/starcoder2-7b:1.14.1 sha256:e9f52bea8f6e8dd57512709246884c866b9780aa60215afe5d6749f546a216c7 25Gi images/starcoder2-7b-1.14.1.tar.gz false
downloadAndPush 272 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/deepseek-ai/deepseek-r1-distill-llama-70b:1.5.2 cloudera_thirdparty/nim/deepseek-ai/deepseek-r1-distill-llama-70b:1.5.2 sha256:cc0b90ac5a685e386b797d8f01a8d5040b68f3afa7f8a6cf92abbd49a8fc99f0 13Gi images/deepseek-r1-distill-llama-70b-1.5.2.tar.gz false
downloadAndPush 273 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/deepseek-ai/deepseek-r1-distill-llama-8b:1.5.2 cloudera_thirdparty/nim/deepseek-ai/deepseek-r1-distill-llama-8b:1.5.2 sha256:cc0012a89643ca6a8ebedb732de287b73501582f53d4fe40a8a55d06a1ec36e3 13Gi images/deepseek-r1-distill-llama-8b-1.5.2.tar.gz false
downloadAndPush 274 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/deepseek-ai/deepseek-r1:1.7.3 cloudera_thirdparty/nim/deepseek-ai/deepseek-r1:1.7.3 sha256:ffe792c87ed354cf0a9bb1f676984596fc0cb97a6ab5706893bd5bf1db04aee6 21Gi images/deepseek-r1-1.7.3.tar.gz false
downloadAndPush 275 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/nvidia/llama-3.1-nemotron-nano-8b-v1:1.8.4 cloudera_thirdparty/nim/nvidia/llama-3.1-nemotron-nano-8b-v1:1.8.4 sha256:3ff6aa82f4c8246ccdb083497522b368ae65213dbeb7b91b72770c6878d47f21 15Gi images/llama-3.1-nemotron-nano-8b-v1-1.8.4.tar.gz false
downloadAndPush 276 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/meta/llama-3.1-70b-instruct:1.14.0 cloudera_thirdparty/nim/meta/llama-3.1-70b-instruct:1.14.0 sha256:8626425ffa9e3068aaca9bac430810e4b48103710a83cf784fa86d63b3a6a128 25Gi images/llama-3.1-70b-instruct-1.14.0.tar.gz false
downloadAndPush 277 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/meta/llama-3.1-8b-instruct:1.13.1 cloudera_thirdparty/nim/meta/llama-3.1-8b-instruct:1.13.1 sha256:b3412f793b881b51e234066eddeb21c42cac17a870ff6cab1d1a6038e15fe013 23Gi images/llama-3.1-8b-instruct-1.13.1.tar.gz false
downloadAndPush 278 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/meta/llama-3.2-1b-instruct:1.12.0 cloudera_thirdparty/nim/meta/llama-3.2-1b-instruct:1.12.0 sha256:6376cef196a20687d9ecde76ca28e0f378bffaa4956403001cbcb13097aeba58 22Gi images/llama-3.2-1b-instruct-1.12.0.tar.gz false
downloadAndPush 279 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/meta/llama-3.2-3b-instruct:1.10.1 cloudera_thirdparty/nim/meta/llama-3.2-3b-instruct:1.10.1 sha256:ab76d491519a6818d1cdb7735b7e499d7915a3266e1bea3ed7afd3b88bdee8eb 18Gi images/llama-3.2-3b-instruct-1.10.1.tar.gz false
downloadAndPush 280 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/meta/llama-3.3-70b-instruct:1.14.0 cloudera_thirdparty/nim/meta/llama-3.3-70b-instruct:1.14.0 sha256:184f0063a11d52f5025f9c96bb630e2057063693ceb0a11aad17a8ff1a9d286c 25Gi images/llama-3.3-70b-instruct-1.14.0.tar.gz false
downloadAndPush 281 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/mistralai/mistral-7b-instruct-v0.3:1.12.0 cloudera_thirdparty/nim/mistralai/mistral-7b-instruct-v0.3:1.12.0 sha256:7aa228487ff6f02746e699b22a12200b66383fdc74d897652c0d3b4538286745 22Gi images/mistral-7b-instruct-v0.3-1.12.0.tar.gz false
downloadAndPush 282 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/mistralai/mixtral-8x7b-instruct-v01:1.8.4 cloudera_thirdparty/nim/mistralai/mixtral-8x7b-instruct-v01:1.8.4 sha256:6ef1f468a067b98ae0bfa6c3567ebc6cef554366fbb8aa873b72af9a0d39c551 15Gi images/mixtral-8x7b-instruct-v01-1.8.4.tar.gz false
downloadAndPush 283 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/mit/boltz2:1.3.0 cloudera_thirdparty/nim/mit/boltz2:1.3.0 sha256:b4f76d6a548efa79657b0ebba798fe90e13461fc9a8846da2066bd4ae98ec0d9 38Gi images/boltz2-1.3.0.tar.gz false
downloadAndPush 284 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/nvidia/llama3.1-nemotron-nano-4b-v1.1:1.8.5 cloudera_thirdparty/nim/nvidia/llama3.1-nemotron-nano-4b-v1.1:1.8.5 sha256:5c7b4da7602484e4e9b99aaf3b4ab47fad2952f0facec65494ab8c0780a12bd4 15Gi images/llama3.1-nemotron-nano-4b-v1.1-1.8.5.tar.gz false
downloadAndPush 285 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/nvidia/llama-3.2-nv-rerankqa-1b-v2:1.8.0 cloudera_thirdparty/nim/nvidia/llama-3.2-nv-rerankqa-1b-v2:1.8.0 sha256:015429eb016edc4b3ec67a09fe559e181268b71138967e4cde1ac16755f3488f 3Gi images/llama-3.2-nv-rerankqa-1b-v2-1.8.0.tar.gz false
downloadAndPush 286 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/nvidia/llama-3.3-nemotron-super-49b-v1:1.10.1 cloudera_thirdparty/nim/nvidia/llama-3.3-nemotron-super-49b-v1:1.10.1 sha256:2e2f6d1512bcd998f1445df76462cf9083887f962ccf76a6a6b9b504c68a82f0 18Gi images/llama-3.3-nemotron-super-49b-v1-1.10.1.tar.gz false
downloadAndPush 287 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/nvidia/llama-3.3-nemotron-super-49b-v1.5:1.14.0 cloudera_thirdparty/nim/nvidia/llama-3.3-nemotron-super-49b-v1.5:1.14.0 sha256:077999054bbf2523ddd55ef81caedd432ccd390fe0b3d9f8cb80ff4f15bef736 25Gi images/llama-3.3-nemotron-super-49b-v1.5-1.14.0.tar.gz false
downloadAndPush 288 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/nvidia/llama-3.2-nv-embedqa-1b-v2:1.10.0 cloudera_thirdparty/nim/nvidia/llama-3.2-nv-embedqa-1b-v2:1.10.0 sha256:19cc5549b472b71488b5978f4271a8ccab34a012932cef8058b2981fbf3803d8 3Gi images/llama-3.2-nv-embedqa-1b-v2-1.10.0.tar.gz false
downloadAndPush 289 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/nvidia/nemoretriever-graphic-elements-v1:1.6.0 cloudera_thirdparty/nim/nvidia/nemoretriever-graphic-elements-v1:1.6.0 sha256:9dbb73c8784f9bd85bedd06ab5433fb20bf10626e75280e2c9854755989e6528 10Gi images/nemoretriever-graphic-elements-v1-1.6.0.tar.gz false
downloadAndPush 290 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/nvidia/nemoretriever-page-elements-v2:1.6.0 cloudera_thirdparty/nim/nvidia/nemoretriever-page-elements-v2:1.6.0 sha256:ffc2237d7002f0b5cd2e851b68540834a97b5166cdf67613d65c95d8743c9f5d 10Gi images/nemoretriever-page-elements-v2-1.6.0.tar.gz false
downloadAndPush 291 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/nvidia/nemoretriever-parse:1.2.0 cloudera_thirdparty/nim/nvidia/nemoretriever-parse:1.2.0 sha256:5a95aea5fbb8a1b946f5dd440bd6dd327ad21884440b1ccdfa99362c0513ed9a 14Gi images/nemoretriever-parse-1.2.0.tar.gz false
downloadAndPush 292 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/nvidia/nemoretriever-table-structure-v1:1.6.0 cloudera_thirdparty/nim/nvidia/nemoretriever-table-structure-v1:1.6.0 sha256:b42b81af8522ef1b9c4da8104baec82f7f8ed5b5e2c87aeae9f0833c225f71e6 10Gi images/nemoretriever-table-structure-v1-1.6.0.tar.gz false
downloadAndPush 293 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/nvidia/whisper-large-v3:1.3.0 cloudera_thirdparty/nim/nvidia/whisper-large-v3:1.3.0 sha256:d28ac852a05247f5800baf1b8e4f87e96f054b389dd59d4395d6bb20ac234a04 31Gi images/whisper-large-v3-1.3.0.tar.gz false
downloadAndPush 294 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/openai/gpt-oss-120b:1.12.4 cloudera_thirdparty/nim/openai/gpt-oss-120b:1.12.4 sha256:73418c6621419910a4e7730a2bca184152cf48a37bc6490ee268d6637a3595c8 13Gi images/gpt-oss-120b-1.12.4.tar.gz false
downloadAndPush 295 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nim/openai/gpt-oss-20b:1.12.4 cloudera_thirdparty/nim/openai/gpt-oss-20b:1.12.4 sha256:dc839145b8e8e5a8c59ac97f733e97693edaa6a1144cecaf8361553c31c69825 13Gi images/gpt-oss-20b-1.12.4.tar.gz false
downloadAndPush 296 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nfd/node-feature-discovery:v0.13.2 cloudera_thirdparty/nfd/node-feature-discovery:v0.13.2 sha256:ab4a5a514f1bd976ae7c73c6d2b8f851424741b0899f32d4708932310af84168 179Mi images/node-feature-discovery-v0.13.2.tar.gz false
downloadAndPush 297 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/nvidia/k8s-device-plugin:v0.15.0 cloudera_thirdparty/nvidia/k8s-device-plugin:v0.15.0 sha256:fa3ba2723b8864aa319016e2ae3469e5c63a1c991d36cc8938657a59ec0ada22 332Mi images/k8s-device-plugin-v0.15.0.tar.gz false
downloadAndPush 298 container.repository.cloudera.com/cdp-private/cloudera/observability-agent:1.8.0-b7 cloudera/observability-agent:1.8.0-b7 sha256:4ce701d4ba93e00444174dece16377ff435b3d3a71ecfd1181d08375a2d253e8 796Mi images/observability-agent-1.8.0-b7.tar.gz false
downloadAndPush 299 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kube-state-metrics:2.17.0-r2-202511241937 cloudera_thirdparty/hardened/kube-state-metrics:2.17.0-r2-202511241937 sha256:7a220dde786da89ca9807f3ba17ec1102f76258463310c6533fee49a6509bd95 85Mi images/kube-state-metrics-2.17.0-r2-202511241937.tar.gz false
downloadAndPush 300 container.repository.cloudera.com/cdp-private/cloudera/cdp-opentelemetry-collector:1.4.0-b14 cloudera/cdp-opentelemetry-collector:1.4.0-b14 sha256:236fe0f2bbc5031e21ce6b8a2f624a966e64682e179d909a4f6f47809e359a9c 368Mi images/cdp-opentelemetry-collector-1.4.0-b14.tar.gz false
downloadAndPush 301 container.repository.cloudera.com/cdp-private/cloudera/observability-operator:1.0.0-b146 cloudera/observability-operator:1.0.0-b146 sha256:d1af2dad750882451aa48f23f58fd09c06fd2ac511231236215751a281e83366 174Mi images/observability-operator-1.0.0-b146.tar.gz false
downloadAndPush 302 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/cert-manager/cert-manager-openshift-routes:v0.8.3 cloudera_thirdparty/cert-manager/cert-manager-openshift-routes:v0.8.3 sha256:2c78d2e55f406f8c2a1a5a3175d7e3e6c36fd09cc31701d8281e61ffff80c6ad 34Mi images/cert-manager-openshift-routes-v0.8.3.tar.gz false
downloadAndPush 303 container.repository.cloudera.com/cdp-private/cloudera/ozone-parcel-image:731.1.0-b2 cloudera/ozone-parcel-image:731.1.0-b2 sha256:0b56f896f4b6f2c27cbc767fed3ad457e81b5d8e74701006bca9331d270b66c7 710Mi images/ozone-parcel-image-731.1.0-b2.tar.gz false
downloadAndPush 304 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/pause:3.7 cloudera_thirdparty/pause:3.7 sha256:221177c6082a88ea4f6240ab2450d540955ac6f4d5454f0e15751b653ebda165 694Ki images/pause-3.7.tar.gz false
downloadAndPush 305 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/gloo-mesh/istio-d11c80c0c3fc/pilot:1.27.3-patch0-solo-fips-distroless cloudera_thirdparty/hardened/gloo-mesh/istio-d11c80c0c3fc/pilot:1.27.3-patch0-solo-fips-distroless sha256:34a6026ab2c5e03546ec6187b19784670cdd92c548f4f63d216fdb0974462c99 118Mi images/pilot-1.27.3-patch0-solo-fips-distroless.tar.gz false
downloadAndPush 306 container.repository.cloudera.com/cdp-private/cloudera/platform-agent-proxy:1.5.5-h2000-b1 cloudera/platform-agent-proxy:1.5.5-h2000-b1 sha256:c3e65343d784512dcabab2beff220597793696b003dba57f15485d07e2458bff 99Mi images/platform-agent-proxy-1.5.5-h2000-b1.tar.gz false
downloadAndPush 307 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/postgres:17.5-r2-openshift-202506162119 cloudera_thirdparty/hardened/postgres:17.5-r2-openshift-202506162119 sha256:0d81a7314dfa6740c30a83781de65a8afa99d955db8c2d2c2528fdd9d19cb22b 345Mi images/postgres-17.5-r2-openshift-202506162119.tar.gz false
downloadAndPush 308 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/pre-upgrade-hook:0.0.6 cloudera_thirdparty/pre-upgrade-hook:0.0.6 sha256:8a332a3bc07b47673afb494f0517334631a5c086c958735ec8077159b8a7f0ca 599Mi images/pre-upgrade-hook-0.0.6.tar.gz false
downloadAndPush 309 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/gloo-mesh/istio-d11c80c0c3fc/proxyv2:1.27.3-patch0-solo-fips-distroless cloudera_thirdparty/hardened/gloo-mesh/istio-d11c80c0c3fc/proxyv2:1.27.3-patch0-solo-fips-distroless sha256:ac213b8d0894a68a8c39b8563b5450a4810ec666c043cce382a6cb076042eb69 188Mi images/proxyv2-1.27.3-patch0-solo-fips-distroless.tar.gz false
downloadAndPush 310 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kubernetes-reflector:9.1.38-r0-202511061454 cloudera_thirdparty/hardened/kubernetes-reflector:9.1.38-r0-202511061454 sha256:a62bfd6e267e07d5119fe23fff2b88246c99637ccafe364c4a5f195ec1115fa6 591Mi images/kubernetes-reflector-9.1.38-r0-202511061454.tar.gz false
downloadAndPush 311 container.repository.cloudera.com/cdp-private/cloudera/resource-pool-manager:0.18.0-b16 cloudera/resource-pool-manager:0.18.0-b16 sha256:b4ac2e344b5bcced77183b47b2d4e6546ac7ea0d2e76b7c40c7adb4d274e43f8 34Mi images/resource-pool-manager-0.18.0-b16.tar.gz false
downloadAndPush 312 container.repository.cloudera.com/cdp-private/cloudera/service-discovery:1.12.0-b92 cloudera/service-discovery:1.12.0-b92 sha256:f10ad6fe9cd975b646ac372d31a6b5a5ae22eb531a442a5cbbea5d58bb8d7124 190Mi images/service-discovery-1.12.0-b92.tar.gz false
downloadAndPush 313 container.repository.cloudera.com/cdp-private/cloudera/statestored:2025.0.20.2-26 cloudera/statestored:2025.0.20.2-26 sha256:2b98dac2eabfce848b2bc1f374e0e86a4759717294df89014058e78aff438fdc 557Mi images/statestored-2025.0.20.2-26.tar.gz false
downloadAndPush 314 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/longhornio/support-bundle-kit:v0.0.56 cloudera_thirdparty/hardened/longhornio/support-bundle-kit:v0.0.56 sha256:89e59a86b2473dc252fd4639ea03f98d804440d32765b8afad6d95bd1b176a1f 266Mi images/support-bundle-kit-v0.0.56.tar.gz false
downloadAndPush 315 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-audit-private:1.5.5-h2000-b49 cloudera/thunderhead-audit-private:1.5.5-h2000-b49 sha256:6a4d48dc33517d25d77bfd1824afea6f2d0af1802a135c9fe628f0a74493f537 126Mi images/thunderhead-audit-private-1.5.5-h2000-b49.tar.gz false
downloadAndPush 316 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-backupjob:1.5.5-h2000-b49 cloudera/thunderhead-backupjob:1.5.5-h2000-b49 sha256:7ae0b8dcbe0eb716e5e722b1d8ad5dad496281d270a90de682c0cb81ddeb432e 597Mi images/thunderhead-backupjob-1.5.5-h2000-b49.tar.gz false
downloadAndPush 317 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-cdp-private-authentication-console:1.5.5-h2000-b49 cloudera/thunderhead-cdp-private-authentication-console:1.5.5-h2000-b49 sha256:dab4fe2499ad0e0f0f765cd0a388bc98fb424e4c926ed8a66b14febe75f4d0bd 79Mi images/thunderhead-cdp-private-authentication-console-1.5.5-h2000-b49.tar.gz false
downloadAndPush 318 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-cdp-private-commonconsole:1.5.5-h2000-b49 cloudera/thunderhead-cdp-private-commonconsole:1.5.5-h2000-b49 sha256:8d4825c9bab2b52f9b11c350871d71abe9b1f2229b7971672bd2205492a284c9 81Mi images/thunderhead-cdp-private-commonconsole-1.5.5-h2000-b49.tar.gz false
downloadAndPush 319 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-cdp-private-environments-console:1.5.5-h2000-b49 cloudera/thunderhead-cdp-private-environments-console:1.5.5-h2000-b49 sha256:65dd5d9df3c0ce6791962f74d4eca52eb116fb4a0c13e03ab974fb78bcf281f2 85Mi images/thunderhead-cdp-private-environments-console-1.5.5-h2000-b49.tar.gz false
downloadAndPush 320 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-certrevoke:1.5.5-h2000-b49 cloudera/thunderhead-certrevoke:1.5.5-h2000-b49 sha256:a8ba6612ec6d1c35db556e63158e4007f2b0044c0b7398704676380f26714a2b 129Mi images/thunderhead-certrevoke-1.5.5-h2000-b49.tar.gz false
downloadAndPush 321 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-certwebhook:1.5.5-h2000-b49 cloudera/thunderhead-certwebhook:1.5.5-h2000-b49 sha256:9f0071e149463794d1ffcb12685c5c420f5d95be0d9f6c09fd6bc7d3832ef1c2 164Mi images/thunderhead-certwebhook-1.5.5-h2000-b49.tar.gz false
downloadAndPush 322 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-compute-api:1.5.5-h2000-b49 cloudera/thunderhead-compute-api:1.5.5-h2000-b49 sha256:7feae9921d9da39eac9277664f91261f5023a2d8555298a3f2035da36f997d93 583Mi images/thunderhead-compute-api-1.5.5-h2000-b49.tar.gz false
downloadAndPush 323 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-configmap-autoupdater:1.5.5-h2000-b49 cloudera/thunderhead-configmap-autoupdater:1.5.5-h2000-b49 sha256:edfdc7e9c4d5e6153b5a93bc8e7b44799fda732f462917e5c5b6568109fb193d 71Mi images/thunderhead-configmap-autoupdater-1.5.5-h2000-b49.tar.gz false
downloadAndPush 324 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-configtemplate:1.5.5-h2000-b49 cloudera/thunderhead-configtemplate:1.5.5-h2000-b49 sha256:5f676aa91d1ef6d021c363153dafc3518275191d8ec789e6bda200a259dd38b9 599Mi images/thunderhead-configtemplate-1.5.5-h2000-b49.tar.gz false
downloadAndPush 325 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-consoleauthenticationcdp:1.5.5-h2000-b49 cloudera/thunderhead-consoleauthenticationcdp:1.5.5-h2000-b49 sha256:aca8aa2cbb1edd26eeb533c5d91890326930af4cc1052be9ef88c6b2c01322aa 584Mi images/thunderhead-consoleauthenticationcdp-1.5.5-h2000-b49.tar.gz false
downloadAndPush 326 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-de-api:1.5.5-h2000-b49 cloudera/thunderhead-de-api:1.5.5-h2000-b49 sha256:6044cc54b077683b0bd6686b506ac2b6d44418b088315228869763930f69a80f 575Mi images/thunderhead-de-api-1.5.5-h2000-b49.tar.gz false
downloadAndPush 327 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-deletebackupjob:1.5.5-h2000-b49 cloudera/thunderhead-deletebackupjob:1.5.5-h2000-b49 sha256:7e5ae830880af68670d67b9eb239e9dd116a598cc440ffa106b6693ab7d8339d 597Mi images/thunderhead-deletebackupjob-1.5.5-h2000-b49.tar.gz false
downloadAndPush 328 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-deleteexternalbackupjob:1.5.5-h2000-b49 cloudera/thunderhead-deleteexternalbackupjob:1.5.5-h2000-b49 sha256:af15e67a32548e2f62281c7ac9665b67608b2cd786d842d6049ad97e92213e4d 228Mi images/thunderhead-deleteexternalbackupjob-1.5.5-h2000-b49.tar.gz false
downloadAndPush 329 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-diagnostics-api:1.5.5-h2000-b49 cloudera/thunderhead-diagnostics-api:1.5.5-h2000-b49 sha256:3be64aba35e3882a478e9bf7b2d51bac51f11775923c5b020be861d470c261ba 605Mi images/thunderhead-diagnostics-api-1.5.5-h2000-b49.tar.gz false
downloadAndPush 330 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-drscp-api:1.5.5-h2000-b49 cloudera/thunderhead-drscp-api:1.5.5-h2000-b49 sha256:4ce7be18450f618f9da18640a91547024e2c3e9e1e40401eda586f7c5fa9a390 596Mi images/thunderhead-drscp-api-1.5.5-h2000-b49.tar.gz false
downloadAndPush 331 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-drsprovider:1.5.5-h2000-b49 cloudera/thunderhead-drsprovider:1.5.5-h2000-b49 sha256:51d227cbc7df91b093e80eacae5c9a657243fee4cb4823d2a3b6041449e7d92e 197Mi images/thunderhead-drsprovider-1.5.5-h2000-b49.tar.gz false
downloadAndPush 332 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-drsprovider-kopiaui-controller:1.5.5-h2000-b49 cloudera/thunderhead-drsprovider-kopiaui-controller:1.5.5-h2000-b49 sha256:de210286ee4b06dc56719ca046c6d6c0130dd4a57e13b734b5370302c8cb7b8b 177Mi images/thunderhead-drsprovider-kopiaui-controller-1.5.5-h2000-b49.tar.gz false
downloadAndPush 333 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-dw-api:1.5.5-h2000-b49 cloudera/thunderhead-dw-api:1.5.5-h2000-b49 sha256:c29e2ec3ba24f21a968a0ad61fe70be387b7b05c28f1f981ad4724db90b27d0e 577Mi images/thunderhead-dw-api-1.5.5-h2000-b49.tar.gz false
downloadAndPush 334 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-environment:1.5.5-h2000-b49 cloudera/thunderhead-environment:1.5.5-h2000-b49 sha256:61aa3f106c3935fa500683143261e59b54417773fef1b8dc3ec77c453327f337 678Mi images/thunderhead-environment-1.5.5-h2000-b49.tar.gz false
downloadAndPush 335 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-environments2-api:1.5.5-h2000-b49 cloudera/thunderhead-environments2-api:1.5.5-h2000-b49 sha256:a515775b7900a48285add5968a26412551f936c59e2d3665cc3b9c4c80321cb9 606Mi images/thunderhead-environments2-api-1.5.5-h2000-b49.tar.gz false
downloadAndPush 336 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-externalbackupjob:1.5.5-h2000-b49 cloudera/thunderhead-externalbackupjob:1.5.5-h2000-b49 sha256:db03f71cfdcdad03a3fd13ab602da653364db78a591aed395978d9564fb40eea 232Mi images/thunderhead-externalbackupjob-1.5.5-h2000-b49.tar.gz false
downloadAndPush 337 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-externalrestorejob:1.5.5-h2000-b49 cloudera/thunderhead-externalrestorejob:1.5.5-h2000-b49 sha256:a43222f7ac01778eefb51e40088c4f95ffc81688be4de5d1bd5f4d9ccd641fca 277Mi images/thunderhead-externalrestorejob-1.5.5-h2000-b49.tar.gz false
downloadAndPush 338 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-gatewayapimigration:1.5.5-h2000-b49 cloudera/thunderhead-gatewayapimigration:1.5.5-h2000-b49 sha256:87b7c7c50ed4147bfab8e9ecf0912fcdebfee3e105d669894a818258a7b697f3 207Mi images/thunderhead-gatewayapimigration-1.5.5-h2000-b49.tar.gz false
downloadAndPush 339 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-iam-api:1.5.5-h2000-b49 cloudera/thunderhead-iam-api:1.5.5-h2000-b49 sha256:63f1586727561effa84028e46d65abd6790d6765dbf5cae4bd0996dbbe4717c5 582Mi images/thunderhead-iam-api-1.5.5-h2000-b49.tar.gz false
downloadAndPush 340 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-iam-console:1.5.5-h2000-b49 cloudera/thunderhead-iam-console:1.5.5-h2000-b49 sha256:d1c78c30821c18013456e21c1c043e47d03ac3f9d15a1ddf9d101107c5fb4dd7 82Mi images/thunderhead-iam-console-1.5.5-h2000-b49.tar.gz false
downloadAndPush 341 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-java-init-container-21:1.5.5-h2000-b49 cloudera/thunderhead-java-init-container-21:1.5.5-h2000-b49 sha256:7db3b8390eb151c093f83c41f12f7416247f80e0d92337a59c083f68eb9bbcb9 520Mi images/thunderhead-java-init-container-21-1.5.5-h2000-b49.tar.gz false
downloadAndPush 342 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-kerberosmgmt-api:1.5.5-h2000-b49 cloudera/thunderhead-kerberosmgmt-api:1.5.5-h2000-b49 sha256:3a3055448f2dce76ff0869a5c58a68a44d3e4086e8bb0c588e9230e165cef9ed 578Mi images/thunderhead-kerberosmgmt-api-1.5.5-h2000-b49.tar.gz false
downloadAndPush 343 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-ml-api:1.5.5-h2000-b49 cloudera/thunderhead-ml-api:1.5.5-h2000-b49 sha256:0b56c1013740cfcd815546718c527aa0da2d2070c0caa62958dab9033527c116 572Mi images/thunderhead-ml-api-1.5.5-h2000-b49.tar.gz false
downloadAndPush 344 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-mlopsgovernance:1.5.5-h2000-b49 cloudera/thunderhead-mlopsgovernance:1.5.5-h2000-b49 sha256:c1cdfa1b7d3f10c4ffebda41a5ce49a0359e34b0ef4116210870a5280f82d6ca 663Mi images/thunderhead-mlopsgovernance-1.5.5-h2000-b49.tar.gz false
downloadAndPush 345 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-onpremises-api:1.5.5-h2000-b49 cloudera/thunderhead-onpremises-api:1.5.5-h2000-b49 sha256:254eec16d54d9ffc11b838b079f90978bf1897c6d1f8e060bc0ad57741679c57 571Mi images/thunderhead-onpremises-api-1.5.5-h2000-b49.tar.gz false
downloadAndPush 346 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-pre-install-validation:1.5.5-h2000-b49 cloudera/thunderhead-pre-install-validation:1.5.5-h2000-b49 sha256:89173d03cbc5b81da25e08a39d6a778a9013931adf6086dd25cd1aa7eac61df1 218Mi images/thunderhead-pre-install-validation-1.5.5-h2000-b49.tar.gz false
downloadAndPush 347 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-remotecluster:1.5.5-h2000-b49 cloudera/thunderhead-remotecluster:1.5.5-h2000-b49 sha256:dae6d8a459bde7b1527ae1a4de3a8406d6a1d68f894ea5940b011cdff2db0e83 602Mi images/thunderhead-remotecluster-1.5.5-h2000-b49.tar.gz false
downloadAndPush 348 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-resource-management-console:1.5.5-h2000-b49 cloudera/thunderhead-resource-management-console:1.5.5-h2000-b49 sha256:9a5c6ee5ee0ab21bd3c99ca5dad22b3ffbb0ff1de74a0f5e2d41861bc47e2386 80Mi images/thunderhead-resource-management-console-1.5.5-h2000-b49.tar.gz false
downloadAndPush 349 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-restorejob:1.5.5-h2000-b49 cloudera/thunderhead-restorejob:1.5.5-h2000-b49 sha256:a9c501c8aa0b978541c4dad019077d98bf52965f4d570cb860faa60f7bdc6373 597Mi images/thunderhead-restorejob-1.5.5-h2000-b49.tar.gz false
downloadAndPush 350 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-sdx2-api:1.5.5-h2000-b49 cloudera/thunderhead-sdx2-api:1.5.5-h2000-b49 sha256:43ad85d8fa3df199ffb09396f4524314a960ea322316980293f3fbe00187cc33 571Mi images/thunderhead-sdx2-api-1.5.5-h2000-b49.tar.gz false
downloadAndPush 351 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-servicediscovery-api:1.5.5-h2000-b49 cloudera/thunderhead-servicediscovery-api:1.5.5-h2000-b49 sha256:91d415fc50056407c331a454eb870a2726545b4e66ea7c4b621eac032eb48601 571Mi images/thunderhead-servicediscovery-api-1.5.5-h2000-b49.tar.gz false
downloadAndPush 352 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-servicediscoverysimple:1.5.5-h2000-b49 cloudera/thunderhead-servicediscoverysimple:1.5.5-h2000-b49 sha256:7505e9281469e56e9f8c60e26ad2f7ff33eaa2704a3b0eae61246243d18dd925 579Mi images/thunderhead-servicediscoverysimple-1.5.5-h2000-b49.tar.gz false
downloadAndPush 353 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-usermanagement-private:1.5.5-h2000-b49 cloudera/thunderhead-usermanagement-private:1.5.5-h2000-b49 sha256:8db9d7e62182392eb6a0751cd6b197e617e96d74e69aa92d7a8a4aa6add6b7f5 587Mi images/thunderhead-usermanagement-private-1.5.5-h2000-b49.tar.gz false
downloadAndPush 354 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-userpreference:1.5.5-h2000-b49 cloudera/thunderhead-userpreference:1.5.5-h2000-b49 sha256:c4594bfa06a8eb6b69d8bc3e199d556a7c09493a24bb15b0cbd1dfe776866d81 612Mi images/thunderhead-userpreference-1.5.5-h2000-b49.tar.gz false
downloadAndPush 355 container.repository.cloudera.com/cdp-private/cloudera/thunderhead-userpreference-api:1.5.5-h2000-b49 cloudera/thunderhead-userpreference-api:1.5.5-h2000-b49 sha256:70f17958bcc8d42b9b049749e719f6f8d53735140e8e0cc181331492a3eabe3f 571Mi images/thunderhead-userpreference-api-1.5.5-h2000-b49.tar.gz false
downloadAndPush 356 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/traefik:2.11.13-r0-202410281525 cloudera_thirdparty/hardened/traefik:2.11.13-r0-202410281525 sha256:5408ed082cd30c816b8c243865f333f53c84816c83224dd8b7deebb1a06a08ab 181Mi images/traefik-2.11.13-r0-202410281525.tar.gz false
downloadAndPush 357 container.repository.cloudera.com/cdp-private/cloudera/trino:2025.0.20.2-26 cloudera/trino:2025.0.20.2-26 sha256:9a0f7e24ea438f76d70abc042365c4e5a09963377b5dee90747f9e8aa3f87133 3Gi images/trino-2025.0.20.2-26.tar.gz false
downloadAndPush 358 container.repository.cloudera.com/cdp-private/cloudera/cml-serving/usage_reporter:1.9.0-b45 cloudera/cml-serving/usage_reporter:1.9.0-b45 sha256:ccd09d45afa1d6e011078ffb004ea52a68a6b242b0173c414b880b30fff9a9b7 91Mi images/usage_reporter-1.9.0-b45.tar.gz false
downloadAndPush 359 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/vault:1.20.1-r2-202508012305 cloudera_thirdparty/hardened/vault:1.20.1-r2-202508012305 sha256:6fee85173471a5ddc736c2e059f06b57b9f259dd1ff39777d7cfa19fe639e741 430Mi images/vault-1.20.1-r2-202508012305.tar.gz false
downloadAndPush 360 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/kube-webhook-certgen:1.13.0-r6-202508121042 cloudera_thirdparty/hardened/kube-webhook-certgen:1.13.0-r6-202508121042 sha256:c21ce725086ee720273071b61ea3bf5cdc60f1d92ed5858ca6f7356ce7679f3d 52Mi images/kube-webhook-certgen-1.13.0-r6-202508121042.tar.gz false
downloadAndPush 361 container.repository.cloudera.com/cdp-private/cloudera/yunikorn-admission:1.7.0-b18 cloudera/yunikorn-admission:1.7.0-b18 sha256:9ef300d1f62d20c0bdb28cefce65d578afc33253cfc86245f0c71d6266819df3 81Mi images/yunikorn-admission-1.7.0-b18.tar.gz false
downloadAndPush 362 container.repository.cloudera.com/cdp-private/cloudera/yunikorn-scheduler-plugin:1.7.0-b18 cloudera/yunikorn-scheduler-plugin:1.7.0-b18 sha256:1c64dd35ffd43d62a50ad90c3e30795cd93ac0ff6dbe1608c745c42cae7c84ea 98Mi images/yunikorn-scheduler-plugin-1.7.0-b18.tar.gz false
downloadAndPush 363 container.repository.cloudera.com/cdp-private/cloudera/yunikorn-web:1.7.0-b18 cloudera/yunikorn-web:1.7.0-b18 sha256:3a2be2c9ab38bf544fe656797e8f08409a192b18c71565b7ce21629f72533f25 14Mi images/yunikorn-web-1.7.0-b18.tar.gz false
downloadAndPush 364 container.repository.cloudera.com/cdp-private/cloudera_thirdparty/hardened/gloo-mesh/istio-d11c80c0c3fc/ztunnel:1.27.3-patch0-solo-fips-distroless cloudera_thirdparty/hardened/gloo-mesh/istio-d11c80c0c3fc/ztunnel:1.27.3-patch0-solo-fips-distroless sha256:31379d0b32ba6ea98ebf556f228ffd428fa826359de9f0c7174676a01f1a4495 30Mi images/ztunnel-1.27.3-patch0-solo-fips-distroless.tar.gz false
downloadPackageOnly 339511b15bd0cd385526ef28ce5a5ab0 1GB images/agent-studio-runtimes-1.5.5-h2000-b238.tar.gz

markAsDownloaded cloudera/studio/cloudera-ai-agent-studio:2.0.0-b59 images/agent-studio-runtimes-1.5.5-h2000-b238.tar.gz
downloadPackageOnly fb2fa49cd2f52ce9f1a0c77cec86f068 1GB images/cdv-runtimes-1.5.5-h2000-b238.tar.gz

markAsDownloaded cloudera/cdv/runtimedataviz:8.0.8-b39 images/cdv-runtimes-1.5.5-h2000-b238.tar.gz
downloadPackageOnly bdbe5332653ecb11f5dd4ce5bbb7fd63 5GB images/cml-runtimes-cuda-1.5.5-h2000-b238.tar.gz










markAsDownloaded cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.10-cuda:2025.09.1-b5 images/cml-runtimes-cuda-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.11-cuda:2025.09.1-b5 images/cml-runtimes-cuda-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.12-cuda:2025.09.1-b5 images/cml-runtimes-cuda-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.13-cuda:2025.09.1-b5 images/cml-runtimes-cuda-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.9-cuda:2025.09.1-b5 images/cml-runtimes-cuda-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-workbench-python3.10-cuda:2025.09.1-b5 images/cml-runtimes-cuda-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-workbench-python3.11-cuda:2025.09.1-b5 images/cml-runtimes-cuda-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-workbench-python3.12-cuda:2025.09.1-b5 images/cml-runtimes-cuda-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-workbench-python3.13-cuda:2025.09.1-b5 images/cml-runtimes-cuda-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-workbench-python3.9-cuda:2025.09.1-b5 images/cml-runtimes-cuda-1.5.5-h2000-b238.tar.gz
downloadPackageOnly 01bc946564a257dc18db2fc52ebe0b51 1GB images/cml-runtimes-freshline-1.5.5-h2000-b238.tar.gz


markAsDownloaded cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.11-freshline:2025.09.1-b5 images/cml-runtimes-freshline-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-jupyterlab-r4.5-freshline:2025.09.1-b5 images/cml-runtimes-freshline-1.5.5-h2000-b238.tar.gz
downloadPackageOnly 46c23bd32a41fb66e65ed5fa1b327ed9 2GB images/cml-runtimes-standard-1.5.5-h2000-b238.tar.gz













markAsDownloaded cloudera/cdsw/ml-runtime-pbj-conda-standard:2025.09.1-b5 images/cml-runtimes-standard-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.10-standard:2025.09.1-b5 images/cml-runtimes-standard-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.11-standard:2025.09.1-b5 images/cml-runtimes-standard-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.12-standard:2025.09.1-b5 images/cml-runtimes-standard-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.13-standard:2025.09.1-b5 images/cml-runtimes-standard-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.9-standard:2025.09.1-b5 images/cml-runtimes-standard-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-workbench-python3.10-standard:2025.09.1-b5 images/cml-runtimes-standard-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-workbench-python3.11-standard:2025.09.1-b5 images/cml-runtimes-standard-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-workbench-python3.12-standard:2025.09.1-b5 images/cml-runtimes-standard-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-workbench-python3.13-standard:2025.09.1-b5 images/cml-runtimes-standard-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-workbench-python3.9-standard:2025.09.1-b5 images/cml-runtimes-standard-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-workbench-r4.5-standard:2025.09.1-b5 images/cml-runtimes-standard-1.5.5-h2000-b238.tar.gz
markAsDownloaded cloudera/cdsw/ml-runtime-pbj-workbench-scala2.12-standard:2025.09.1-b5 images/cml-runtimes-standard-1.5.5-h2000-b238.tar.gz
dockerPushOnly 365 container.repository.cloudera.com/cdp-private/cloudera/studio/cloudera-ai-agent-studio:2.0.0-b59 cloudera/studio/cloudera-ai-agent-studio:2.0.0-b59 sha256:fdf0a215fcd8ed67f2777c84908ff26283439757c75de50159c139659002b82a 5Gi  true
dockerPushOnly 366 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-conda-standard:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-conda-standard:2025.09.1-b5 sha256:1fc77a14bf9bfd8707ad9e6fd583fd5fa55e12d491f293a8974a79777143c7ae 2Gi  true
dockerPushOnly 367 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.10-cuda:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.10-cuda:2025.09.1-b5 sha256:eacb1af199bb18724d10634b2e73a3cffa931982153bfb7f4298ef5b1f5337bd 8Gi  true
dockerPushOnly 368 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.10-standard:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.10-standard:2025.09.1-b5 sha256:d78389eb1d26f0526a10c0a39bc68db24a6a23ba61151827925dff2bfd0a67e8 2Gi  true
dockerPushOnly 369 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.11-cuda:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.11-cuda:2025.09.1-b5 sha256:3f4cc35d8e7d3a6a25e9274f2bd7fcbc41d2cd1809255fe62406b1b95d2dbf6e 8Gi  true
dockerPushOnly 370 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.11-freshline:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.11-freshline:2025.09.1-b5 sha256:3783e33e2ddc3d620bd539d63870f28159899eb9f7cbba2d64005dfcfc9064bd 1Gi  true
dockerPushOnly 371 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.11-standard:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.11-standard:2025.09.1-b5 sha256:e460687445a64b164f16be3dcb4bfddfce2223ff6be1c4c745923aa92c5645af 2Gi  true
dockerPushOnly 372 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.12-cuda:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.12-cuda:2025.09.1-b5 sha256:1331ad6366254998b7d6435f7d40fea27e11351b6b2bdc704e057d4e92598f2b 8Gi  true
dockerPushOnly 373 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.12-standard:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.12-standard:2025.09.1-b5 sha256:48fddea16e34997ca8b8acd371bdb0a02e05fc15dbd1eb6b4484427f12ea2795 2Gi  true
dockerPushOnly 374 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.13-cuda:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.13-cuda:2025.09.1-b5 sha256:58a152a7ae2d82f5d1dcb713109e2cc56831cc13430a0cb144d612c3cc1aabcc 8Gi  true
dockerPushOnly 375 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.13-standard:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.13-standard:2025.09.1-b5 sha256:8897269f184ba318c2af28c663992634121df43c45829f1a02cdd77a27c8b50d 2Gi  true
dockerPushOnly 376 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.9-cuda:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.9-cuda:2025.09.1-b5 sha256:5f3398e374c577ee59c879a837c0b9c9e43d33781dbcccf55e5fbf32da7435a8 8Gi  true
dockerPushOnly 377 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.9-standard:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-jupyterlab-python3.9-standard:2025.09.1-b5 sha256:7ec2c425c17956570f619c3665012c7680c58f6ee0e969c84e03d5e12f60291f 2Gi  true
dockerPushOnly 378 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-jupyterlab-r4.5-freshline:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-jupyterlab-r4.5-freshline:2025.09.1-b5 sha256:f3f9d4c22d2ae20e14c26a04125a25e0c6d3a625bfe62dee53a03c7363dbac64 3Gi  true
dockerPushOnly 379 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-workbench-python3.10-cuda:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-workbench-python3.10-cuda:2025.09.1-b5 sha256:879ec421ebbd7bb63b3f7be91657326fbafe378ef7445fa255dd2705f3fb54da 7Gi  true
dockerPushOnly 380 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-workbench-python3.10-standard:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-workbench-python3.10-standard:2025.09.1-b5 sha256:2c534799d5b4770ccb1a604c20e886fdcf30df9b9870ca4b49d203f64e445ba8 1Gi  true
dockerPushOnly 381 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-workbench-python3.11-cuda:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-workbench-python3.11-cuda:2025.09.1-b5 sha256:7a26b3dc979ccf92999cd14af07b7f373162c5007df18d90766e73d246d8fd22 8Gi  true
dockerPushOnly 382 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-workbench-python3.11-standard:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-workbench-python3.11-standard:2025.09.1-b5 sha256:45e1b029e006cfae958f092521263cd6bf0dc128fa3336f9613edaeadf5ca3d3 1Gi  true
dockerPushOnly 383 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-workbench-python3.12-cuda:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-workbench-python3.12-cuda:2025.09.1-b5 sha256:6517cd5d164c8077902240a6bddd1823aca9d7fc2afef59410007a7d85672fd6 7Gi  true
dockerPushOnly 384 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-workbench-python3.12-standard:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-workbench-python3.12-standard:2025.09.1-b5 sha256:d747fe0371395db06c7db854e6924c810478b2054bc267c659c86d04c77e0b63 1Gi  true
dockerPushOnly 385 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-workbench-python3.13-cuda:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-workbench-python3.13-cuda:2025.09.1-b5 sha256:a2a208fc6609e9ceab66e4b1efe846a099f3d710772a1e9e70160c37103c2eb4 8Gi  true
dockerPushOnly 386 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-workbench-python3.13-standard:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-workbench-python3.13-standard:2025.09.1-b5 sha256:470b5b1e023aeb9ebc83b08acd435bb97428003f318999a7d4ea8d7e30804a13 1Gi  true
dockerPushOnly 387 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-workbench-python3.9-cuda:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-workbench-python3.9-cuda:2025.09.1-b5 sha256:c7547805c0b3e3ebb04fff44ca42e3025cbc9e6d6d87bf128baf3e580231461c 7Gi  true
dockerPushOnly 388 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-workbench-python3.9-standard:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-workbench-python3.9-standard:2025.09.1-b5 sha256:2e3800e1936249c858f914845206b96af375fd846058397b58f3d0d242325dfa 1Gi  true
dockerPushOnly 389 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-workbench-r4.5-standard:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-workbench-r4.5-standard:2025.09.1-b5 sha256:ef54f250edbe08d0b014f81929755bfc6a952fd09b9ba1d22883bbb430361d60 3Gi  true
dockerPushOnly 390 container.repository.cloudera.com/cdp-private/cloudera/cdsw/ml-runtime-pbj-workbench-scala2.12-standard:2025.09.1-b5 cloudera/cdsw/ml-runtime-pbj-workbench-scala2.12-standard:2025.09.1-b5 sha256:7ecc7585b493acbbf1010e5d79ea58790256d550b0140541672d58ba88ab66ce 1Gi  true
dockerPushOnly 391 container.repository.cloudera.com/cdp-private/cloudera/cdv/runtimedataviz:8.0.8-b39 cloudera/cdv/runtimedataviz:8.0.8-b39 sha256:d91b85a2852dc149a637c31b4ffe238955648e584ab2b6489d3d14f9ea7ba759 3Gi  true
