#!/bin/sh
# publish-app.sh <application directory> <name> <version>
#
# Builds the release of an Elixir application in a container, for the OS and the OTP of
# the DeployEx image, puts the tarball in ./bucket and points current.json at it.
# DeployEx picks it up by itself.
#
# The build directory is kept in a volume, so the next version finds the previous one
# and Jellyfish writes the appups of a hot upgrade.
set -e

if [ $# -ne 3 ]; then
  echo "usage: $0 <application directory> <name> <version>" >&2
  exit 1
fi

app_dir=$(cd "$1" && pwd)
name=$2
version=$3
here=$(cd "$(dirname "$0")" && pwd)

# Made here, as you: docker would make a directory that is missing as root
mkdir -p "$here/bucket"

docker build -q -t deployex-app-builder -f "$here/Dockerfile.app-builder" "$here" >/dev/null
# The build runs as root in the container. On Linux, what it writes to the directories of
# the host would stay owned by root, so it is given back to you when the build ends,
# whether it worked or not. The two volumes are other filesystems and are left alone
docker run --rm \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -v "$app_dir":/app \
  -v "${name}_build":/app/_build \
  -v "${name}_deps":/app/deps \
  -v "$here/bucket":/bucket \
  deployex-app-builder sh -c "
    set -e
    give_back() {
      # A file that cannot be given back, a read-only one of .git on macOS for instance,
      # does not fail a build that worked
      chown -R \"\$HOST_UID:\$HOST_GID\" /bucket || echo \"warning: could not give back /bucket\" >&2
      find /app -xdev -user root -exec chown -h \"\$HOST_UID:\$HOST_GID\" {} + || echo \"warning: could not give back /app\" >&2
    }
    trap give_back EXIT
    mix deps.get --only prod
    mix assets.deploy
    mix release --overwrite
    mkdir -p /bucket/dist/$name /bucket/versions/$name/local
    cp _build/prod/$name-$version.tar.gz /bucket/dist/$name/
    printf '{\"version\":\"%s\",\"hash\":\"local\",\"pre_commands\":[]}\n' '$version' > /bucket/versions/$name/local/current.json
    echo published $name $version
  "
