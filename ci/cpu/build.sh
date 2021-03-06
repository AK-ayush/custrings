#!/bin/bash
# Copyright (c) 2019, NVIDIA CORPORATION.
###########################################
# cuStrings CPU conda build script for CI #
###########################################
set -e

# Logger function for build status output
function logger() {
  echo -e "\n>>>> $@\n"
}

# Set path and build parallel level
export PATH=/conda/bin:/usr/local/cuda/bin:$PATH
export PARALLEL_LEVEL=4

# Define path to nvcc
export CUDACXX=/usr/local/cuda/bin/nvcc

# Set home to the job's workspace
export HOME=$WORKSPACE

# Switch to project root; also root of repo checkout
cd $WORKSPACE

# Get latest tag and number of commits since tag
export GIT_DESCRIBE_TAG=`git describe --abbrev=0 --tags`
export GIT_DESCRIBE_NUMBER=`git rev-list ${GIT_DESCRIBE_TAG}..HEAD --count`

################################################################################
# SETUP - Check environment
################################################################################

logger "Get env..."
env

logger "Activate conda env..."
source activate gdf

logger "Check versions..."
python --version
$CC --version
$CXX --version
conda config --get channels
conda list
$CUDACXX --version

# FIX Added to deal with Anancoda SSL verification issues during conda builds
conda config --set ssl_verify False

################################################################################
# BUILD - Conda package builds (conda deps: libcustrings <- custrings)
################################################################################

logger "Build conda pkgs for libcustrings..."
conda build --python=${PYTHON} conda/recipes/libcustrings

logger "Build conda pkgs for custrings..."
conda build --python=${PYTHON} conda/recipes/custrings

################################################################################
# UPLOAD - Conda packages
################################################################################

logger "Upload conda pkgs for libcustrings and custrings..."
source ci/cpu/upload_anaconda.sh
