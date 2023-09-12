#!/bin/bash
##
# Train a student model.
#

set -x
set -euo pipefail

echo "###### Training a student model"

alignment=$1
extra_params=( "${@:2}" )

ARTIFACT_EXT="${ARTIFACT_EXT:-gz}"

if [ "${ARTIFACT_EXT}" = "zst" ]; then
  zstdmt --rm -d "${alignment}"
  alignment="${alignment%%.zst}"
fi

cd "$(dirname "${0}")"

bash "train.sh" \
  "${extra_params[@]}" \
  --guided-alignment "${alignment}" \


echo "###### Done: Training a student model"


