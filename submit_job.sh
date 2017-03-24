#!/bin/sh

#SBATCH -o benchmarks%j.out
#SBATCH -e benchmarks%j.err
# one hour timelimit
#SBATCH --time 2:00:00
# get gpu queue
#SBATCH -p gpu
# need 1 machine
#SBATCH -N 1
# name the job
#SBATCH -J BeliefPropagationBenchmarks

module load cuda/toolkit
module load libxml2
module load pgi
module load cmake

# build and run c benchmarks
cd /home/***REMOVED***/belief-propagation/src/c_benchmark
cmake . -DCMAKE_BUILD_TYPE=Release
make
./c_benchmark

# build and run openmp benchmarks
cd /home/***REMOVED***/belief-propagation/src/openmp_benchmark
cmake . -DCMAKE_BUILD_TYPE=Release
make
./openmp_benchmark

# build and run openacc benchmarks
cd /home/***REMOVED***/belief-propagation/src/openacc_benchmark
cmake . -DCMAKE_BUILD_TYPE=Release
make
./openacc_benchmark