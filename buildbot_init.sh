#!/bin/bash
# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# Script to configure GCE instance to run LLVM ThinLTO optimization build bots.

# NOTE: GCE can wait up to 20 hours before reloading this file.
# If some instance needs changes sooner just shutdown the instance 
# with GCE UI or "sudo shutdown now" over ssh. GCE will recreate
# the instance and reload the script.

function on_error {
  echo $1
  # FIXME: ON_ERROR should shutdown. Echo-ing for now, for experimentation
  # shutdown now
}

SERVER_PORT=${SERVER_PORT:-9994}
BOT_DIR=/b

mount -t tmpfs tmpfs /tmp
mkdir -p $BOT_DIR
mount -t tmpfs tmpfs -o size=80% $BOT_DIR

BUSTER_PACKAGES=

if lsb_release -a | grep "buster" ; then
  BUSTER_PACKAGES="python3-distutils"

ADMIN_PACKAGES="tmux"


fi

(
  SLEEP=0
  for i in `seq 1 5`; do
    sleep $SLEEP
    SLEEP=$(( SLEEP + 10))

    (
      set -ex
      apt-key adv --recv-keys --keyserver keyserver.ubuntu.com FEEA9169307EA071 || exit 1
      apt-key adv --recv-keys --keyserver keyserver.ubuntu.com 871920D1991BC93C || exit 1
      
      dpkg --add-architecture i386
      echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections
      dpkg --configure -a
      apt-get clean
      apt-get -qq -y update

      # Logs consume a lot of storage space.
      apt-get remove -qq -y --purge auditd puppet-agent google-fluentd

      apt-get install -qq -y \
        $BUSTER_PACKAGES \
        python3 \
        python3-pip \
        $ADMIN_PACKAGES \
        g++ \
        cmake \
        ccache \
        binutils-gold \
        binutils-dev \
        ninja-build \
        pkg-config \
        gcc-multilib \
        g++-multilib \
        gawk \
        dos2unix \
        libxml2-dev \
        rsync \
        git \
        libtool \
        m4 \
        automake \
        libgcrypt-dev \
        liblzma-dev \
        libssl-dev \
        libgss-dev \
        python-dev \
        wget \
        zlib1g-dev

    ) && exit 0
  done
  exit 1
) || on_error "Failed to install required packages."

# gold is giving a weird internal error when trying to link many files, appears
# to run out of file descriptors. Use bfd for now to workaround.
update-alternatives --install "/usr/bin/ld" "ld" "/usr/bin/ld.gold" 10
update-alternatives --install "/usr/bin/ld" "ld" "/usr/bin/ld.bfd" 20

userdel buildbot
groupadd buildbot
useradd buildbot -g buildbot -m -d /var/lib/buildbot

sudo -u buildbot python3 -m pip install --upgrade pip
python3 -m pip install buildbot-worker

chown buildbot:buildbot $BOT_DIR

rm -f /b/buildbot.tac

WORKER_NAME="$(hostname)"
WORKER_PASSWORD="$(gsutil cat gs://thinlto-buildbot/buildbot_password)"
SERVICE_NAME=buildbot-worker@b.service
[[ -d /var/lib/buildbot/workers/b ]] || ln -s $BOT_DIR /var/lib/buildbot/workers/b

while pkill buildbot-worker; do sleep 5; done;

rm -rf ${BOT_DIR}/buildbot.tac ${BOT_DIR}/twistd.log
echo "Starting build worker ${WORKER_NAME}"
sudo -u buildbot buildbot-worker create-worker -f --allow-shutdown=signal $BOT_DIR lab.llvm.org:$SERVER_PORT \
   "${WORKER_NAME}" "${WORKER_PASSWORD}"

echo "Teresa Johnson <tejohnson@google.com>" > $BOT_DIR/info/admin

{
  echo "How to reproduce locally: https://github.com/google/ml-compiler-opt/wiki/BuildBotReproduceLocally"
  echo
  uname -a | head -n1
  date
  cmake --version | head -n1
  g++ --version | head -n1
  ld --version | head -n1
  lscpu
} > $BOT_DIR/info/host

chown -R buildbot:buildbot $BOT_DIR
sudo -u buildbot buildbot-worker start $BOT_DIR

sleep 30
cat $BOT_DIR/twistd.log
grep "worker is ready" $BOT_DIR/twistd.log || on_error "build worker not ready"
