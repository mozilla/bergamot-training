#!/bin/bash
##
# Translates monolingual dataset
#
# Usage:
#   translate-corpus.sh corpus_src corpus_trg model_dir output_path
#

set -x
set -euo pipefail

echo "###### Translating a corpus"

test -v GPUS
test -v MARIAN
test -v WORKSPACE
test -v WORKDIR

corpus_src=$1
corpus_trg=$2
model_dir=$3
output_path=$4

if [ -e "${output_path}" ]; then
  echo "### Corpus already exists, skipping"
  echo "###### Done: Translating a corpus"
  exit 0
fi

config="${model_dir}/model.npz.best-ce-mean-words.npz.decoder.yml"
decoder_config="${WORKDIR}/pipeline/translate/decoder.yml"
tmp_dir=$(dirname "${output_path}")/tmp
mkdir -p "${tmp_dir}"

source "${WORKDIR}/pipeline/setup/activate-python.sh"

echo "### Splitting a parallel corpus into smaller chunks"
test -s "${tmp_dir}/file.00" ||
  pigz -dc "${corpus_src}" |
  split -d -l 500000 - "${tmp_dir}/file."
test -s "${tmp_dir}/file.00.ref" ||
  pigz -dc "${corpus_trg}" |
  split -d -l 500000 - "${tmp_dir}/file." --additional-suffix .ref

echo "### Translating source sentences with Marian"
# This can be parallelized across several GPU machines.
for name in $(find "${tmp_dir}" -regex '.*file\.[0-9]+' -printf "%f\n" | shuf); do
  prefix="${tmp_dir}/${name}"
  echo "### ${prefix}"
  test -e "${prefix}.nbest" ||
    "${MARIAN}/marian-decoder" \
      -c "${config}" "${decoder_config}" \
      -i "${prefix}" \
      -o "${prefix}.nbest" \
      --log "${prefix}.log" \
      --n-best \
      -d ${GPUS} \
      -w "${WORKSPACE}"
done

echo "### Extracting the best translations from n-best lists w.r.t to the reference"
# It is CPU-only, can be run after translation on a CPU machine.
find "${tmp_dir}" -regex '.*file\.[0-9]+' -printf "%f\n" | shuf |
parallel --no-notice -k -j "$(nproc)" \
  "test -e ${tmp_dir}/{}.nbest.out || python ${WORKDIR}/pipeline/translate/bestbleu.py -i ${tmp_dir}/{}.nbest -r ${tmp_dir}/{}.ref -m bleu > ${tmp_dir}/{}.nbest.out" \
  2>"${tmp_dir}/debug.txt"

echo "### Collecting translations"
test -s "${output_path}" || cat "${tmp_dir}"/file.*.nbest.out | pigz >"${output_path}"

echo "### Comparing number of sentences ${corpus_src} vs ${output_path}"
src_len=$(pigz -dc "${corpus_src}" | wc -l)
trg_len=$(pigz -dc "${output_path}" | wc -l)
if [ "${src_len}" != "${trg_len}" ]; then
  echo "### Error: length of ${corpus_src} ${src_len} is different from ${output_path} ${trg_len}"
  exit 1
fi

rm -rf "${tmp_dir}"

echo "###### Done: Translating a corpus"
