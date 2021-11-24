#!make

.ONESHELL:
SHELL=/bin/bash

### 1. change these settings
SHARED_ROOT=/data/rw/group-maml
CUDA_DIR=/usr/local/cuda
GPUS=8
WORKSPACE=12000
CLUSTER_CORES=16
CONFIG=configs/config.prod.yml
CONDA_PATH=$(SHARED_ROOT)/mambaforge
SNAKEMAKE_OUTPUT_CACHE=$(SHARED_ROOT)/cache
###

CONDA_ACTIVATE=source $(CONDA_PATH)/etc/profile.d/conda.sh ; conda activate ; conda activate
SNAKEMAKE=export SNAKEMAKE_OUTPUT_CACHE=$(SNAKEMAKE_OUTPUT_CACHE);  snakemake

### 2. setup

git-modules:
	git submodule update --init --recursive

conda:
	wget https://github.com/conda-forge/miniforge/releases/latest/download/Mambaforge-$$(uname)-$$(uname -m).sh
	bash Mambaforge-$$(uname)-$$(uname -m).sh -b -p $(CONDA_PATH)

snakemake:
	$(CONDA_ACTIVATE) base
	mamba create -c conda-forge -c bioconda -n snakemake snakemake==6.10.0 --yes
	mkdir -p "$(SNAKEMAKE_OUTPUT_CACHE)"

# build container image for cluster and run-local modes (preferred)
build:
	sudo singularity build Singularity.sif Singularity.def

# or pull container image from a registry if there is no sudo
pull:
	singularity pull Singularity.sif library://evgenypavlov/default/bergamot2:latest


### 3. run

# if you need to activate conda environment for direct snakemake commands, use
# . $(CONDA_PATH)/etc/profile.d/conda.sh && conda activate snakemake

dry-run:
	$(CONDA_ACTIVATE) snakemake
	$(SNAKEMAKE) \
	  --use-conda \
	  --cores all \
	  --cache \
	  --reason \
	  --configfile $(CONFIG) \
	  --config root="$(SHARED_ROOT)" cuda="$(CUDA_DIR)" gpus=$(GPUS) workspace=$(WORKSPACE) deps=true  \
	  -n

run-local:
	$(CONDA_ACTIVATE) snakemake
	$(SNAKEMAKE) \
	  --use-conda \
	  --reason \
	  --cores all \
	  --cache \
	  --resources gpu=$(GPUS) \
	  --configfile $(CONFIG) \
	  --config root="$(SHARED_ROOT)" cuda="$(CUDA_DIR)" gpus=$(GPUS) workspace=$(WORKSPACE) deps=true

run-local-container:
	$(CONDA_ACTIVATE) snakemake
	module load singularity
	$(SNAKEMAKE) \
	  --use-conda \
	  --use-singularity \
	  --reason \
	  --cores all \
	  --cache \
	  --resources gpu=$(GPUS) \
	  --configfile $(CONFIG) \
	  --config root="$(SHARED_ROOT)" cuda="$(CUDA_DIR)" gpus=$(GPUS) workspace=$(WORKSPACE) \
	  --singularity-args="--bind $(SHARED_ROOT),$(CUDA_DIR) --nv"

run-slurm:
	$(CONDA_ACTIVATE) snakemake
	chmod +x profiles/slurm/*
	$(SNAKEMAKE) \
	  --use-conda \
	  --reason \
	  --cores $(CLUSTER_CORES) \
	  --cache \
	  --configfile $(CONFIG) \
	  --config root="$(SHARED_ROOT)" cuda="$(CUDA_DIR)" gpus=$(GPUS) workspace=$(WORKSPACE) \
	  --profile=profiles/slurm

run-slurm-container:
	$(CONDA_ACTIVATE) snakemake
	chmod +x profiles/slurm/*
	module load singularity
	$(SNAKEMAKE) \
	  --use-conda \
	  --use-singularity \
	  --reason \
	  --verbose \
	  --cores $(CLUSTER_CORES) \
	  --cache \
	  --configfile $(CONFIG) \
	  --config root="$(SHARED_ROOT)" cuda="$(CUDA_DIR)" gpus=$(GPUS) workspace=$(WORKSPACE) \
	  --profile=profiles/slurm \
	  --singularity-args="--bind $(SHARED_ROOT),$(CUDA_DIR),/tmp --nv --containall"
# if CPU nodes don't have access to cuda dirs, use
# export CUDA_DIR=$(CUDA_DIR); $(SNAKEMAKE) \
# --singularity-args="--bind $(SHARED_ROOT),/tmp --nv --containall"


### 4. create a report

report:
	$(CONDA_ACTIVATE) snakemake
	REPORTS=$(SHARED_ROOT)/reports DT=$$(date '+%Y-%m-%d_%H-%M'); \
	mkdir -p $$REPORTS && \
	snakemake \
		--report $${REPORTS}/$${DT}_report.html \
		--configfile $(CONFIG) \
		--config root="$(SHARED_ROOT)" cuda="$(CUDA_DIR)" gpus=$(GPUS) workspace=$(WORKSPACE)

run-file-server:
	$(CONDA_ACTIVATE) snakemake
	python -m  http.server --directory $(SHARED_ROOT)/reports 8000

### extra

dag:
	snakemake \
	  --dag \
	  --configfile $(CONFIG) \
	  --config root="$(SHARED_ROOT)" cuda="$(CUDA_DIR)" gpus=$(GPUS) workspace=$(WORKSPACE) \
	  | dot -Tpdf > DAG.pdf

lint:
	snakemake --lint

install-monitor:
	$(CONDA_ACTIVATE) base
	conda create --name panoptes
	conda install -c panoptes-organization panoptes-ui

run-monitor:
	$(CONDA_ACTIVATE) panoptes
	panoptes

run-with-monitor:
	snakemake \
	  --use-conda \
	  --cores all \
	  --wms-monitor http://127.0.0.1:5000

install-tensorboard:
	$(CONDA_ACTIVATE) base
	conda env create -f envs/tensorboard.yml

tensorboard:
	$(CONDA_ACTIVATE) tensorboard
	ls -d $(SHARED_ROOT)/models/*/*/* > tb-monitored-jobs; \
	tensorboard --logdir=$$MODELS --host=0.0.0.0 &; \
	python utils/tb_log_parser.py --prefix=

install-snakepit-scheduler:
	mkdir -p $(SHARED_ROOT)/snakepit
	cd $(SHARED_ROOT)/snakepit

	curl -sL https://deb.nodesource.com/setup_12.x | sudo -E bash -
	sudo apt install nodejs

	if [ ! -e snakepit-client ]; then
	  git clone https://github.com/mozilla/snakepit-client.git
	fi
	cd snakepit-client
	npm install
	sudo npm link

	echo "http://10.2.224.243" > /root/.pitconnect.txt

	pit status

run-snakepit:
	chmod +x profiles/snakepit/*
	snakemake \
	  --use-conda \
	  --cores all \
	  --profile=profiles/snakepit
