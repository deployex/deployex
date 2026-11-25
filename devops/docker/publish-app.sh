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

docker build -q -t deployex-app-builder -f "$here/Dockerfile.app-builder" "$here" >/dev/null
docker run --rm \
  -v "$app_dir":/app \
  -v "${name}_build":/app/_build \
  -v "${name}_deps":/app/deps \
  -v "$here/bucket":/bucket \
  deployex-app-builder sh -c "
    set -e
    mix deps.get --only prod
    mix assets.deploy
    mix release --overwrite
    mkdir -p /bucket/dist/$name /bucket/versions/$name/local
    cp _build/prod/$name-$version.tar.gz /bucket/dist/$name/
    printf '{\"version\":\"%s\",\"hash\":\"local\",\"pre_commands\":[]}\n' '$version' > /bucket/versions/$name/local/current.json
    echo published $name $version
  "
