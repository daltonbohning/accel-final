# Parallel Scan in CUDA and OpenMP
## CUDA (Brent-Kung)
Currently supports array sizes up to 16,777,216 for section sizes 1024 and 2048.\
`make tests` will run tests against various sizes and verify that the CUDA algorithm is correct.
  
## OpenMP
Not yet implemented.

## Scalability Study
`make benchmarks` will produce a `.csv` with various array sizes and sections sizes of 1024 and 2048. This will be useful.

## Research Paper review
Not yet done.

## TODO
- Hook testing into OpenMP
- Implement in OpenMP
- Include benchmarks for OpenMP
- Compile results for study
- Read a paper
- Write the report
