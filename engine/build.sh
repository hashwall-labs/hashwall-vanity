#!/bin/bash

mkdir -p build

flags_common="-DCARD=1060 -Wno-deprecated-gpu-targets -diag-suppress 2464"
flags_debug="-g -G -O0"
flags_release="-O2 -maxrregcount=128"

nvcc $flags_common $flags_release -o ./build/gpu_generator ./src/gpu_generator.cu
