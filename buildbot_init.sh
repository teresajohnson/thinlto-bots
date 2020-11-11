#!/bin/bash
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

MASTER_PORT=${MASTER_PORT:-9994}
BOT_DIR=/b

mount -t tmpfs tmpfs /tmp
mkdir -p $BOT_DIR
mount -t tmpfs tmpfs -o size=80% $BOT_DIR

BUSTER_PACKAGES=

if lsb_release -a | grep "buster" ; then
  BUSTER_PACKAGES="python3-distutils"

ADMIN_PACKAGES="tmux"

  # buildbot from "buster" does not work with llvm master.
  cat <<EOF >/etc/apt/sources.list.d/stretch.list
deb http://deb.debian.org/debian/ stretch main
deb-src http://deb.debian.org/debian/ stretch main
deb http://security.debian.org/ stretch/updates main
deb-src http://security.debian.org/ stretch/updates main
deb http://deb.debian.org/debian/ stretch-updates main
deb-src http://deb.debian.org/debian/ stretch-updates main
EOF

  cat <<EOF >/etc/apt/apt.conf.d/99stretch
APT::Default-Release "buster";
EOF

fi

(
  SLEEP=0
  for i in `seq 1 5`; do
    sleep $SLEEP
    SLEEP=$(( SLEEP + 10))

    (
      set -ex
      dpkg --add-architecture i386
      echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections
      dpkg --configure -a
      apt-get clean
      apt-get -qq -y update

      # Logs consume a lot of storage space.
      apt-get remove -qq -y --purge auditd puppet-agent google-fluentd

      apt-get install -qq -y \
        $BUSTER_PACKAGES \
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

      apt-get install -qq -y -t stretch buildbot-slave=0.8.12-1
      apt-mark hold buildbot-slave
    ) && exit 0
  done
  exit 1
) || on_error "Failed to install required packages."

update-alternatives --install "/usr/bin/ld" "ld" "/usr/bin/ld.gold" 20
update-alternatives --install "/usr/bin/ld" "ld" "/usr/bin/ld.bfd" 10

# continue with getting the build worker up.
systemctl set-property buildslave.service TasksMax=100000

chown buildbot:buildbot $BOT_DIR

rm -f /b/buildbot.tac

WORKER_NAME="$(hostname)"
WORKER_PASSWORD="$(gsutil cat gs://thinlto-buildbot/buildbot_password)"

echo "Starting build worker ${WORKER_NAME}"
buildslave create-slave -f --allow-shutdown=signal $BOT_DIR lab.llvm.org:$MASTER_PORT \
   "${WORKER_NAME}" "${WORKER_PASSWORD}"

systemctl stop buildslave.service
while pkill buildslave; do sleep 5; done;

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

cat <<EOF >/etc/default/buildslave
SLAVE_ENABLED[1]=1
SLAVE_NAME[1]="default"
SLAVE_USER[1]="buildbot"
SLAVE_BASEDIR[1]="$BOT_DIR"
SLAVE_OPTIONS[1]=""
SLAVE_PREFIXCMD[1]=""
EOF

chown -R buildbot:buildbot $BOT_DIR
systemctl daemon-reload
systemctl start buildslave.service

sleep 30
cat $BOT_DIR/twistd.log
grep "slave is ready" $BOT_DIR/twistd.log || on_error "build worker not ready"

echo "Started build worker ${WORKER_NAME} successfully."
