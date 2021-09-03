from snakemake.utils import min_version
import os
from pipeline.bicleaner import packs

min_version("6.6.1")

# `include` directive is not supported by Pycharm plugin, moving all rules to one file to enable live checks
# https://github.com/JetBrains-Research/snakecharm/issues/195

# Directories structure
#
#├ data
#│   ├ cache
#│   │  ├ corpus
#│   │  │  └ opus
#│   │  │    ├ ada83_v1.en.gz
#│   │  │    └ ada83_v1.ru.gz
#│   │  └ mono
#│   │     └ news-crawl
#│   │       ├ news.2019.ru.gz
#│   │       └ news.2019.en.gz
#│   └ ru-en
#│      └ test
#│        ├ original
#│        │   ├ corpus.ru.gz
#│        │   ├ corpus.en.gz
#│        │   ├ mono.ru.gz
#│        │   ├ mono.en.gz
#│        │   ├ devset.ru.gz
#│        │   └ devset.en.gz
#│        ├ evaluation
#│        │   ├ wmt12.ru
#│        │   ├ wmt12.en
#│        │   ├ wmt20.ru
#│        │   ├ wmt20.en
#│        ├ clean
#│        │   ├ corpus.ru.gz
#│        │   ├ corpus.en.gz
#│        │   ├ mono.ru.gz
#│        │   └ mono.en.gz
#│        ├ biclean
#│        │   ├ corpus.ru.gz
#│        │   ├ corpus.en.gz
#│        ├ translated
#│        │   ├ mono.ru.gz
#│        │   └ mono.en.gz
#│        ├ augmented
#│        │   ├ corpus.ru.gz
#│        │   └ corpus.en.gz
#│        ├ alignment
#│        │   ├ corpus.aln.gz
#│        │   └ lex.s2t.pruned.gz
#│        ├ merged
#│        │   ├ corpus.ru.gz
#│        │   └ corpus.en.gz
#│        └ filtered
#│            ├ corpus.ru.gz
#│            └ corpus.en.gz
#├ models
#│   ├ ru-en
#│   │   └ test
#│   │      ├ teacher
#│   │      ├ student
#│   │      ├ student-finetuned
#│   │      ├ speed
#│   │      └ exported
#│   ├ en-ru
#│      └ test
#│         └ s2s
#│
#├ experiments
#│   └ ru-en
#│      └ test
#│         └ config.sh
#├ logs


### configuration

configfile: 'config.yml'

data_root_dir = config['dirs']['data-root']

# experiment
src = config['experiment']['src']
trg = config['experiment']['trg']
experiment = config['experiment']['name']

mono_max_sent_src = config['experiment']['mono-max-sentences-src']
mono_max_sent_trg = config['experiment']['mono-max-sentences-trg']
bicleaner_threshold = config['experiment']['bicleaner-threshold']
backward_model = config['experiment']['backward-model']

experiment_dir=f"{data_root_dir}/{src}-{trg}/{experiment}"

# datasets
train_datasets = config['datasets']['train']
valid_datasets = config['datasets']['devtest']
eval_datasets = config['datasets']['test']
mono_src_datasets = config['datasets']['mono-src']
mono_trg_datasets = config['datasets']['mono-trg']

# parallelization
gpus_num = config['resources']['gpus']
gpus = ' '.join([str(n) for n in range(int(gpus_num))])
workspace = config['resources']['workspace']
partitions = config['resources']['partitions']
parts = [f'{n:02d}' for n in list(range(partitions))]
ensemble = list(range(config['experiment']['teacher-ensemble']))

# logging
log_dir = f"{data_root_dir}/logs/{src}-{trg}/{experiment}"
reports_dir = f"{data_root_dir}/reports/{src}-{trg}/{experiment}"

# binaries
cwd = os.getcwd()
marian_dir = f'{cwd}/3rd_party/marian-dev/build'
kenlm = f'{cwd}/3rd_party/kenlm'
fast_align_build = f'{cwd}/3rd_party/fast_align/build'
extract_lex_build = f'{cwd}/3rd_party/extract-lex/build'
bin = f'{cwd}/bin'
cuda_dir = config['dirs']['cuda']

# data
data_dir = f"{data_root_dir}/data/{src}-{trg}/{experiment}"
clean = f"{data_dir}/clean"
biclean = f"{data_dir}/biclean"
cache_dir = f"{data_dir}/cache"
original = f"{data_dir}/original"
evaluation = f"{data_dir}/evaluation"
translated = f"{data_dir}/translated"
augmented = f"{data_dir}/augmented"
merged = f"{data_dir}/merged"
filtered = f'{data_dir}/filtered'
align_dir = f"{data_dir}/alignment"

# models
models_dir = f"{data_root_dir}/models/{src}-{trg}/{experiment}"
teacher_dir = f"{models_dir}/teacher"
student_dir = f"{models_dir}/student"
student_finetuned_dir = f"{models_dir}/student-finetuned"
speed = f"{models_dir}/speed"
exported = f"{models_dir}/exported"
best_model = "model.npz.best-bleu-detok.npz"
s2s=f'{models_dir}/s2s'

# set common environment variables
envs = f'''SRC={src} TRG={trg} MARIAN="{marian_dir}" GPUS="{gpus}" WORKSPACE={workspace} \
CLEAN_TOOLS=pipeline/clean/tools CUDA_DIR="{cuda_dir}" BIN="{bin}"'''


### workflow options

results = [f'{exported}/model.{src}{trg}.intgemm.alphas.bin.gz',
           f'{exported}/lex.50.50.{src}{trg}.s2t.bin.gz',
           f'{exported}/vocab.{src}{trg}.spm.gz',
           f'{experiment_dir}/config.yaml',
           expand(f'{teacher_dir}{{ens}}/eval',ens=ensemble),
           f'{student_dir}/eval',
           f'{student_finetuned_dir}/eval',
           f'{speed}/eval',
           ]

# don't evaluate pretrained model

if not backward_model:
    backward_model = s2s
    results.append(f'{backward_model}/eval')
    train_s2s=True
else:
    train_s2s = False


# bicleaner

bicleaner_type = packs.find(src, trg)
bicleaner_env = "envs/bicleaner-ai.yml" if bicleaner_type == 'bicleaner-ai' else 'envs/bicleaner.yml'

if bicleaner_type:
    clean_corpus_src = f"{biclean}/corpus.{src}.gz"
    clean_corpus_trg = f"{biclean}/corpus.{trg}.gz"
    teacher_corpus = f'{biclean}/corpus'
    use_bicleaner=True
else:
    clean_corpus_src = f"{clean}/corpus.{src}.gz"
    clean_corpus_trg = f"{clean}/corpus.{trg}.gz"
    teacher_corpus = f'{clean}/corpus'
    use_bicleaner=False


# augmentation

if mono_trg_datasets:
    teacher_corpus = f'{augmented}/corpus'
    augment_corpus=True
else:
    augment_corpus=False


### rules

rule all:
    input: results

localrules: experiment
ruleorder: teacher > eval_teacher

rule experiment:
    message: "Saving experiment metadata"
    output: f'{experiment_dir}/config.yaml'
    priority: 100
    shell: '''
        mkdir -p "{experiment_dir}"
        cp config.yml "{output}"
        cp -r pipeline/train/configs "{experiment_dir}/"
    '''

# setup

rule setup:
    message: "Installing dependencies"
    log: f"{log_dir}/install-deps.log"
    conda: "envs/base.yml"
    threads: 1
    group: 'setup'
    output: touch("/tmp/flags/setup.done") # specific to local machine
    shell: 'bash pipeline/setup/install-deps.sh >> {log} 2>&1'

rule marian:
    message: "Compiling marian"
    log: f"{log_dir}/compile-marian.log"
    conda: "envs/base.yml"
    threads: workflow.cores
    group: 'setup'
    input: rules.setup.output
    output: trainer=protected(f"{marian_dir}/marian"),decoder=protected(f"{marian_dir}/marian-decoder"),
        scorer=protected(f"{marian_dir}/marian-scorer"),vocab=protected(f'{marian_dir}/spm_train'),
        converter=protected(f'{marian_dir}/marian-conv')
    shell: '{envs} bash pipeline/setup/compile-marian.sh {threads} >> {log} 2>&1'

rule fast_align:
    message: "Compiling fast align"
    log: f"{log_dir}/compile-fast-align.log"
    conda: "envs/base.yml"
    threads: workflow.cores
    group: 'setup'
    input: rules.setup.output
    output: fast_align=protected(f"{bin}/fast_align"), atools=protected(f"{bin}/atools")
    shell: '{envs} bash pipeline/setup/compile-fast-align.sh {fast_align_build} {threads}  >> {log} 2>&1'

rule extract_lex:
    message: "Compiling fast align"
    log: f"{log_dir}/compile-extract-lex.log"
    conda: "envs/base.yml"
    threads: workflow.cores
    group: 'setup'
    input: rules.setup.output
    output: protected(f"{bin}/extract_lex")
    shell: '{envs} bash pipeline/setup/compile-extract-lex.sh {extract_lex_build} {threads} >> {log} 2>&1'

# data

rule data_train:
    message: "Downloading training corpus"
    log: f"{log_dir}/data_train.log"
    conda: "envs/base.yml"
    threads: 4
    group: 'data'
    input: rules.setup.output
    output: src=f"{original}/corpus.{src}.gz",trg=f"{original}/corpus.{trg}.gz"
    params: prefix=f"{original}/corpus"
    shell: '{envs} bash pipeline/data/download-corpus.sh "{params.prefix}" "{cache_dir}" train {train_datasets} >> {log} 2>&1'

rule data_val:
    message: "Downloading validation corpus"
    log: f"{log_dir}/data_val.log"
    conda: "envs/base.yml"
    threads: 4
    group: 'data'
    input: rules.setup.output
    output: src=f"{original}/devset.{src}.gz",trg=f"{original}/devset.{trg}.gz"
    params: prefix=f"{original}/devset"
    shell: '{envs} bash pipeline/data/download-corpus.sh "{params.prefix}" "{cache_dir}" valid {valid_datasets} >> {log} 2>&1'

rule data_test:
    message: "Downloading test corpus"
    log: f"{log_dir}/data_test.log"
    conda: "envs/base.yml"
    threads: 4
    group: 'data'
    input: rules.setup.output
    output: expand(f"{evaluation}/{{dataset}}.{{lng}}",dataset=eval_datasets,lng=[src, trg])
    shell: '{envs} bash pipeline/data/download-eval.sh "{evaluation}" "{cache_dir}" {eval_datasets} >> {log} 2>&1'

rule data_mono_src:
    message: "Downloading monolingual dataset for source language"
    log: f"{log_dir}/data_mono_src.log"
    conda: "envs/base.yml"
    threads: 4
    input: rules.setup.output
    output: f'{original}/mono.{src}.gz'
    shell: '''bash pipeline/data/download-mono.sh \
                "{src}" "{mono_max_sent_src}" "{original}/mono" "{cache_dir}" {mono_src_datasets} >> {log} 2>&1'''

if mono_trg_datasets:
    rule data_mono_trg:
        message: "Downloading monolingual dataset for target language"
        log: f"{log_dir}/data_mono_trg.log"
        conda: "envs/base.yml"
        threads: 4
        input: rules.setup.output
        output: f'{original}/mono.{trg}.gz'
        shell: '''bash pipeline/data/download-mono.sh \
                  "{trg}" "{mono_max_sent_trg}" "{original}/mono" "{cache_dir}" {mono_trg_datasets} >> {log} 2>&1'''

# cleaning

rule clean_corpus:
    message: "Cleaning corpus"
    log: f"{log_dir}/clean_corpus.log"
    conda: "envs/base.yml"
    threads: workflow.cores
    input: rules.data_train.output.src,rules.data_train.output.trg,rules.setup.output
    output: src=f"{clean}/corpus.{src}.gz",trg=f"{clean}/corpus.{trg}.gz"
    params: prefix_input=f"{original}/corpus",prefix_output=f"{clean}/corpus"
    shell: '''{envs} bash pipeline/clean/clean-corpus.sh "{params.prefix_input}" "{params.prefix_output}" >> {log} 2>&1'''


if use_bicleaner:
    rule kenlm:
        message: "Installing kenlm"
        log: f"{log_dir}/kenlm.log"
        conda: bicleaner_env
        threads: workflow.cores
        group: 'setup'
        input: rules.setup.output
        output: directory(f"{bin}/kenlm")
        shell: '{envs} bash pipeline/setup/install-kenlm.sh {kenlm} {threads}  >> {log} 2>&1'

    rule bicleaner:
        message: f"Cleaning corpus using {bicleaner_type}"
        log: f"{log_dir}/bicleaner.log"
        conda: bicleaner_env
        threads: workflow.cores
        input: src=rules.clean_corpus.output.src,trg=rules.clean_corpus.output.trg,kenlm=rules.kenlm.output
        output: src=clean_corpus_src,trg=clean_corpus_trg
        params: prefix_input=f"{clean}/corpus",prefix_output=f"{biclean}/corpus"
        shell: '''{envs} bash pipeline/bicleaner/bicleaner.sh \
                    "{params.prefix_input}" "{params.prefix_output}" {bicleaner_threshold} {bicleaner_type} \
                    >> {log} 2>&1'''

rule clean_mono:
    message: "Cleaning monolingual dataset"
    log: f"{log_dir}/clean_mono_{{lang}}.log"
    conda: "envs/base.yml"
    threads: workflow.cores
    input: rules.setup.output,f'{original}/mono.{{lang}}.gz'
    output: f"{clean}/mono.{{lang}}.gz"
    params: lang='{lang}'
    shell: '''{envs} bash pipeline/clean/clean-mono.sh "{params.lang}" "{original}/mono" "{clean}/mono" >> {log} 2>&1'''

# augmentation and teacher training

rule train_vocab:
    message: "Training spm vocab"
    log: f"{log_dir}/train_vocab.log"
    conda: "envs/base.yml"
    threads: workflow.cores / 4
    resources: gpu=1
    input:
        bin=rules.marian.output.vocab,
        corpus_src=clean_corpus_src,corpus_trg=clean_corpus_trg
    output: f"{models_dir}/vocab/vocab.spm"
    params: prefix_train=f"{biclean}/corpus",prefix_test=f"{original}/devset"
    shell: '{envs} bash pipeline/train/spm-vocab.sh "{input.corpus_src}" "{input.corpus_trg}" "{output}" >> {log} 2>&1'


if train_s2s:
    rule backward:
        message: "Training backward model"
        log: f"{log_dir}/train_backward.log"
        conda: "envs/base.yml"
        threads: workflow.cores / 4
        input:
            train_src=clean_corpus_src,train_trg=clean_corpus_trg,
            val_src=rules.data_val.output.src,val_trg=rules.data_val.output.trg,
            bin=rules.marian.output.trainer, vocab=rules.train_vocab.output
        output:  model=f'{backward_model}/{best_model}'
        params: prefix_train=f"{biclean}/corpus",prefix_test=f"{original}/devset"
        shell: '''{envs} bash pipeline/train/train-s2s.sh \
                    "{backward_model}" "{params.prefix_train}" "{params.prefix_test}" "{input.vocab}" {trg} {src} \
                     >> {log} 2>&1'''

    rule eval_backward:
        message: "Evaluating backward model"
        log: f"{log_dir}/eval_backward.log"
        conda: "envs/base.yml"
        resources: gpu=gpus_num
        priority: 50
        input: model=f'{backward_model}/{best_model}', datasets=rules.data_test.output
        output:
            report(directory(f'{backward_model}/eval'),patterns=["*.bleu"],caption=f"{reports_dir}/report.rst")
        shell: '{envs} bash pipeline/train/eval.sh "{backward_model}" "{evaluation}" {trg} {src} >> {log} 2>&1'



if augment_corpus:
    rule split_mono_trg:
        message: "Splitting monolingual trg dataset"
        log: f"{log_dir}/split_mono_trg.log"
        conda: "envs/base.yml"
        threads: workflow.cores
        input: f"{clean}/mono.{trg}.gz"
        output:
            dir=directory(f'{translated}/mono_trg'),
            files=expand(f"{translated}/mono_trg/file.{{number}}",number=parts)
        shell: 'bash pipeline/translate/split-mono.sh {input} {output.dir} {partitions} >> {log} 2>&1'

    rule translate_mono_trg:
        message: "Translating monolingual trg dataset with backward model"
        log: f"{log_dir}/translate_mono_trg/{{part}}.log"
        conda: "envs/base.yml"
        threads: workflow.cores / 4
        resources: gpu=gpus_num
        input:
            rules.marian.output.trainer,file=f'{translated}/mono_trg/file.{{part}}',
            vocab=rules.train_vocab.output,model=f'{backward_model}/{best_model}'
        output: f'{translated}/mono_trg/file.{{part}}.out'
        shell: '{envs} bash pipeline/translate/translate.sh "{input.file}" "{input.vocab}" {input.model} >> {log} 2>&1'

    rule collect_mono_trg:
        message: "Collecting translated mono trg dataset"
        log: f"{log_dir}/collect_mono_trg.log"
        conda: "envs/base.yml"
        threads: workflow.cores
        input:
            files=expand(f"{translated}/mono_trg/file.{{part}}.out",part=parts)
        output: f'{translated}/mono.{src}.gz'
        params: src_mono=f"{clean}/mono.{trg}.gz",dir=directory(f'{translated}/mono_trg')
        shell: 'bash pipeline/translate/collect.sh "{params.dir}" "{output}" "{params.src_mono}" >> {log} 2>&1'

    rule merge_augmented:
        message: "Merging augmented dataset"
        log: f"{log_dir}/merge_augmented.log"
        conda: "envs/base.yml"
        input:
            src1=clean_corpus_src,src2=rules.collect_mono_trg.output,
            trg1=clean_corpus_trg,trg2=rules.split_mono_trg.input
        output: res_src=f'{augmented}/corpus.{src}.gz',res_trg=f'{augmented}/corpus.{trg}.gz'
        shell: '''bash pipeline/translate/merge-corpus.sh \
                    "{input.src1}" "{input.src2}" "{input.trg1}" "{input.trg2}" "{output.res_src}" "{output.res_trg}" \
                      >> {log} 2>&1'''

rule teacher:
    message: "Training teacher"
    log: f"{log_dir}/train_teacher{{ens}}.log"
    conda: "envs/base.yml"
    threads: workflow.cores / 4
    resources: gpu=gpus_num
    input:
        train_src=f'{teacher_corpus}.{src}.gz',train_trg=f'{teacher_corpus}.{trg}.gz',
        val_src=rules.data_val.output.src,val_trg=rules.data_val.output.trg,
        bin=rules.marian.output.trainer,vocab=rules.train_vocab.output
    output: model=f'{teacher_dir}{{ens}}/{best_model}'
    params: prefix_train=teacher_corpus, prefix_test=f"{original}/devset", dir=directory(f'{teacher_dir}{{ens}}')
    shell: '''{envs} bash pipeline/train/train-teacher.sh \
                "{params.dir}" "{params.prefix_train}" "{params.prefix_test}" "{input.vocab}" >> {log} 2>&1'''

rule eval_teacher:
    message: "Evaluating teacher model"
    log: f"{log_dir}/eval_teacher{{ens}}.log"
    conda: "envs/base.yml"
    resources: gpu=gpus_num
    priority: 50
    input:
        model=f'{teacher_dir}{{ens}}/{best_model}',
        datasets=rules.data_test.output
    output:
        report(directory(f'{teacher_dir}{{ens}}/eval'), patterns=["*.bleu"], caption=f"{reports_dir}/report.rst")
    params: dir=f'{teacher_dir}{{ens}}'
    shell: '{envs} bash pipeline/train/eval.sh "{params.dir}" "{evaluation}" {src} {trg} >> {log} 2>&1'


### translation with teacher

# corpus

rule split_corpus:
    message: "Splitting the corpus to translate"
    log: f"{log_dir}/split_corpus.log"
    conda: "envs/base.yml"
    threads: workflow.cores
    input: corpus_src=clean_corpus_src,corpus_trg=clean_corpus_trg
    output: expand(f"{translated}/corpus/file.{{number}}{{ext}}",number=parts,ext=['', '.ref'])
    shell: '''bash pipeline/translate/split-corpus.sh \
                {input.corpus_src} {input.corpus_trg} {translated}/corpus {partitions} >> {log} 2>&1'''

rule translate_corpus:
    message: "Translating corpus with teacher"
    log: f"{log_dir}/translate_corpus/{{part}}.log"
    conda: "envs/base.yml"
    threads: workflow.cores / 4
    resources: gpu=gpus_num
    input:
        rules.marian.output.trainer,file=f'{translated}/corpus/file.{{part}}',vocab=rules.train_vocab.output,
        teacher_models=expand(f"{teacher_dir}{{ens}}/{best_model}",ens=ensemble)
    output: f'{translated}/corpus/file.{{part}}.nbest'
    shell: '''{envs} bash pipeline/translate/translate-nbest.sh \
                "{input.file}" "{input.vocab}" {input.teacher_models} >> {log} 2>&1'''

rule extract_best:
    message: "Extracting best translations for the corpus"
    log: f"{log_dir}/extract_best.log"
    conda: "envs/base.yml"
    threads: workflow.cores
    group: 'translate_corpus'
    input: expand(f"{translated}/corpus/file.{{part}}.nbest",part=parts)
    output: expand(f"{translated}/corpus/file.{{part}}.nbest.out",part=parts)
    params: prefixes=expand(f"{translated}/corpus/file.{{part}}",part=parts)
    shell: 'bash pipeline/translate/extract-best.sh {threads} {params.prefixes} >> {log} 2>&1'

rule collect_corpus:
    message: "Collecting translated corpus"
    log: f"{log_dir}/collect_corpus.log"
    conda: "envs/base.yml"
    threads: workflow.cores
    group: 'translate_corpus'
    input: rules.extract_best.output
    output: f'{translated}/corpus.{trg}.gz'
    params: src_corpus=clean_corpus_src
    shell: 'bash pipeline/translate/collect.sh {translated}/corpus {output} {params.src_corpus} >> {log} 2>&1'

# mono

rule split_mono_src:
    message: "Splitting monolingual src dataset"
    log: f"{log_dir}/split_mono_src.log"
    conda: "envs/base.yml"
    threads: workflow.cores
    input: f"{clean}/mono.{src}.gz"
    output:
        dir=directory(f'{translated}/mono_src'),
        files=expand(f"{translated}/mono_src/file.{{number}}",number=parts)
    shell: 'bash pipeline/translate/split-mono.sh {input} {output.dir} {partitions} >> {log} 2>&1'

rule translate_mono_src:
    message: "Translating monolingual src dataset with teacher"
    log: f"{log_dir}/translate_mono_src/{{part}}.log"
    conda: "envs/base.yml"
    threads: workflow.cores / 4
    resources: gpu=gpus_num
    input:
        bin=rules.marian.output.trainer,
        file=f'{translated}/mono_src/file.{{part}}',vocab=rules.train_vocab.output,
        teacher_models=expand(f"{teacher_dir}{{ens}}/{best_model}",ens=ensemble)
    output: f'{translated}/mono_src/file.{{part}}.out'
    shell: '{envs} bash pipeline/translate/translate.sh "{input.file}" "{input.vocab}" {input.teacher_models} >> {log} 2>&1'

rule collect_mono_src:
    message: "Collecting translated mono src dataset"
    log: f"{log_dir}/collect_mono_src.log"
    conda: "envs/base.yml"
    threads: workflow.cores
    input:
        files=expand(f"{translated}/mono_src/file.{{part}}.out",part=parts)
    output: f'{translated}/mono.{trg}.gz'
    params: src_mono=f"{clean}/mono.{src}.gz",dir=f'{translated}/mono_src'
    shell: 'bash pipeline/translate/collect.sh "{params.dir}" "{output}" "{params.src_mono}" >> {log} 2>&1'

# merge

rule merge_translated:
    message: "Merging translated datasets"
    log: f"{log_dir}/merge_translated.log"
    conda: "envs/base.yml"
    input:
        src1=clean_corpus_src,src2=f"{clean}/mono.{src}.gz",
        trg1=rules.collect_corpus.output,trg2=rules.collect_mono_src.output
    output: res_src=f'{merged}/corpus.{src}.gz',res_trg=f'{merged}/corpus.{trg}.gz'
    shell: '''bash pipeline/translate/merge-corpus.sh \
                "{input.src1}" "{input.src2}" "{input.trg1}" "{input.trg2}" "{output.res_src}" "{output.res_trg}" \
                  >> {log} 2>&1'''

# train student

rule ce_filer:
    message: "Cross entropy filtering"
    log: f"{log_dir}/ce_filter.log"
    conda: "envs/base.yml"
    threads: workflow.cores
    input:
        model=rules.backward.output.model,vocab=rules.train_vocab.output,
        src_corpus=rules.merge_translated.output.res_src,trg_corpus=rules.merge_translated.output.res_trg
    output: src_corpus=f"{filtered}/corpus.{src}.gz",trg_corpus=f"{filtered}/corpus.{trg}.gz"
    params: input_prefix=f'{merged}/corpus',output_prefix=f'{filtered}/corpus'
    shell: '''{envs} bash pipeline/cefilter/ce-filter.sh \
                "{input.model}" "{input.vocab}" "{params.input_prefix}" "{params.output_prefix}" {threads}  >> {log} 2>&1'''

rule alignments:
    message: 'Training word alignment and lexical shortlists'
    log: f"{log_dir}/alignments.log"
    conda: "envs/base.yml"
    input: src_corpus=rules.ce_filer.output.src_corpus,trg_corpus=rules.ce_filer.output.trg_corpus,
        vocab=rules.train_vocab.output,
        fast_align=rules.fast_align.output.fast_align, atools=rules.fast_align.output.atools,
        extract_lex=rules.extract_lex.output
    output: alignment=f'{align_dir}/corpus.aln.gz',shortlist=f'{align_dir}/lex.s2t.pruned.gz'
    params: input_prefix=f'{filtered}/corpus'
    shell: '''{envs} bash pipeline/alignment/generate-alignment-and-shortlist.sh \
                "{params.input_prefix}" "{input.vocab}" "{align_dir}" >> {log} 2>&1'''

rule student:
    message: "Training student"
    log: f"{log_dir}/train_student.log"
    conda: "envs/base.yml"
    threads: workflow.cores / 4
    resources: gpu=gpus_num
    input:
        train_src=rules.ce_filer.output.src_corpus, train_trg=rules.ce_filer.output.trg_corpus,
        val_src=rules.data_val.output.src, val_trg=rules.data_val.output.trg,
        alignments=rules.alignments.output.alignment,
        bin=rules.marian.output.trainer, vocab=rules.train_vocab.output
    output: model=f'{student_dir}/{best_model}'
    params: prefix_train=rules.ce_filer.params.output_prefix,prefix_test=f"{original}/devset"
    shell: '''{envs} bash pipeline/train/train-student.sh \
                "{student_dir}" "{params.prefix_train}" "{params.prefix_test}" "{input.vocab}" \
                "{input.alignments}" >> {log} 2>&1'''

rule eval_student:
    message: "Evaluating student model"
    log: f"{log_dir}/eval_student.log"
    conda: "envs/base.yml"
    resources: gpu=gpus_num
    priority: 50
    input: model=rules.student.output.model, datasets=rules.data_test.output
    output: report(directory(f'{student_dir}/eval'),patterns=["*.bleu"],caption=f"{reports_dir}/report.rst")
    shell: '{envs} bash pipeline/train/eval.sh "{student_dir}" "{evaluation}" {src} {trg} >> {log} 2>&1'

# quantize

rule finetune_student:
    message: "Fine-tuning student"
    log: f"{log_dir}/finetune_student.log"
    conda: "envs/base.yml"
    threads: workflow.cores / 4
    resources: gpu=gpus_num
    input:
        train_src=rules.ce_filer.output.src_corpus, train_trg=rules.ce_filer.output.trg_corpus,
        val_src=rules.data_val.output.src,  val_trg=rules.data_val.output.trg,
        alignments=rules.alignments.output.alignment, student_model=rules.student.output.model,
        bin=rules.marian.output.trainer, vocab=rules.train_vocab.output,
    output: model=f'{student_finetuned_dir}/{best_model}'
    params: prefix_train=rules.ce_filer.params.output_prefix,prefix_test=f"{original}/devset"
    shell: '''{envs} bash pipeline/train/train-student.sh \
                "{student_finetuned_dir}" "{params.prefix_train}" "{params.prefix_test}" "{input.vocab}" \
                "{input.alignments}" "{input.student_model}" >> {log} 2>&1'''

rule eval_finetuned_student:
    message: "Evaluating fine-tuned student model"
    log: f"{log_dir}/eval_finetuned_student.log"
    conda: "envs/base.yml"
    resources: gpu=gpus_num
    priority: 50
    input: model=rules.finetune_student.output.model, datasets=rules.data_test.output
    output: report(directory(f'{student_finetuned_dir}/eval'),patterns=["*.bleu"],caption=f"{reports_dir}/report.rst")
    shell: '{envs} bash pipeline/train/eval.sh "{student_finetuned_dir}" "{evaluation}" {src} {trg} >> {log} 2>&1'

rule quantize:
    message: "Quantization"
    log: f"{log_dir}/quntize.log"
    conda: "envs/base.yml"
    resources: gpu=gpus_num
    threads: workflow.cores
    input:
        shortlist=rules.alignments.output.shortlist, model=rules.finetune_student.output.model,
        bin=rules.marian.output.decoder, vocab=rules.train_vocab.output, devset=f"{original}/devset.{src}.gz"
    output: model=f'{speed}/model.intgemm.alphas.bin'
    shell: '{envs} bash pipeline/quantize/quantize.sh \
                "{input.model}" "{input.vocab}" "{input.shortlist}" "{input.devset}" "{speed}" >> {log} 2>&1'''

rule eval_quantized:
    message: "Evaluating qunatized student model"
    log: f"{log_dir}/eval_quantized.log"
    conda: "envs/base.yml"
    group: 'export'
    threads: workflow.cores
    priority: 50
    input:
        model=rules.quantize.output.model,
        datasets=rules.data_test.output,
        shortlist=rules.alignments.output.shortlist,vocab=rules.train_vocab.output
    output: report(directory(f'{speed}/eval'),patterns=["*.bleu"],caption=f"{reports_dir}/report.rst")
    shell: '''{envs} bash pipeline/quantize/eval.sh "{speed}" "{input.shortlist}" "{evaluation}" "{input.vocab}" \
            >> {log} 2>&1'''

rule export:
    message: "Exporting models"
    log: f"{log_dir}/export.log"
    conda: "envs/base.yml"
    group: 'export'
    threads: workflow.cores
    input:
        model=rules.quantize.output.model,shortlist=rules.alignments.output.shortlist,
        vocab=rules.train_vocab.output,marian=rules.marian.output.converter
    output:
        model=f'{exported}/model.{src}{trg}.intgemm.alphas.bin.gz',
        shortlist=f'{exported}/lex.50.50.{src}{trg}.s2t.bin.gz',
        vocab=f'{exported}/vocab.{src}{trg}.spm.gz'
    shell: '{envs} bash pipeline/quantize/export.sh "{speed}" "{input.shortlist}" "{input.vocab}" "{exported}" >> {log} 2>&1'
